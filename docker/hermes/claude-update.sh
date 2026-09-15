#!/bin/sh
# Keep Claude Code current: npm registry `latest` vs the installed
# claude-real; install atomically when they differ. Runs from the
# gateway's no_agent cron job (zero tokens) and at container boot.
#
# EVERYTHING THIS SCRIPT SAYS GOES TO STDOUT. A no_agent cron job
# delivers its script's stdout verbatim and DISCARDS stderr, so a failure
# written to stderr is a failure nobody sees: the run still records
# `ok`, and the job redelivers the same cheerful line every day. That is
# exactly how this script hid a completely broken install for weeks —
# stdout said "2.1.267 -> 2.1.273", stderr said "install failed", exit
# was 0, and the cron store said `last_status: ok, failure_streak: 0`.
# A failed install now prints the reason on stdout AND exits non-zero, so
# the run is recorded as failed and the scheduler's own notice lands in
# the same channel.
#
# Locking: a stale lock (>15 min) is broken; a live run exits quietly.
set -u

DIR=/opt/data/tools/claude-hermes
REAL=$DIR/claude-real
LOCK=$DIR/.update.lock

have() { command -v "$1" >/dev/null 2>&1; }
version_of() { "$1" --version 2>/dev/null | head -1; }
remote_latest() {
    have curl || return 1
    curl -fsSL --retry 3 --max-time 30 \
        https://registry.npmjs.org/@anthropic-ai/claude-code/latest 2>/dev/null |
        sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
        head -1
}

# --- which package holds the binary ---------------------------------------
# The CLI is NO LONGER a JS bundle inside the wrapper package. Since the
# 2.1.x cutover @anthropic-ai/claude-code ships only install.cjs, a
# bin/claude.exe stub and cli-wrapper.cjs; the ~230 MB native binary
# lives in a per-platform package (@anthropic-ai/claude-code-<platform>)
# which its postinstall copies over the stub. The old code fetched
# `package/bundle/cli.js` from the wrapper tarball — a path that stopped
# existing — so every install failed, including at boot, and claude-real
# froze at its last good version (2.1.267, Sep 9). `npm install` is not
# involved here, so we resolve the platform package ourselves and extract
# `package/claude` (install.cjs: path.join(pkgDir, 'claude')) directly.
# The platform names and the glibc/musl split match install.cjs's
# PLATFORMS map.
platform_pkg() {
    case "$(uname -m 2>/dev/null)" in
        aarch64|arm64) _cpu=arm64 ;;
        x86_64|amd64)  _cpu=x64 ;;
        *) return 1 ;;
    esac
    case "$(uname -s 2>/dev/null)" in
        Linux)
            # musl installs its own loader; a glibc image has neither file.
            if [ -e /lib/ld-musl-aarch64.so.1 ] || [ -e /lib/ld-musl-x86_64.so.1 ]; then
                printf 'linux-%s-musl' "$_cpu"
            else
                printf 'linux-%s' "$_cpu"
            fi ;;
        Darwin) printf 'darwin-%s' "$_cpu" ;;
        *) return 1 ;;
    esac
}

# Fetch, verify, then swap atomically. Extraction lands ON the volume so
# the final `mv` is a same-filesystem rename — no second 230 MB copy, and
# claude-real is never a half-written file (a concurrent `claude` either
# sees the old inode or the new one). The candidate is executed for its
# --version BEFORE it replaces anything, so a truncated download or a
# wrong-libc binary can never take the working one's place.
install_version() {
    _want=$1
    _pkg=$(platform_pkg) || {
        echo "claude-update: unsupported platform $(uname -s 2>/dev/null)/$(uname -m 2>/dev/null)"
        return 1
    }
    _url="https://registry.npmjs.org/@anthropic-ai/claude-code-${_pkg}/-/claude-code-${_pkg}-${_want}.tgz"
    _tmp=$(mktemp -d) || { echo "claude-update: mktemp failed"; return 1; }
    _new=$DIR/.claude-real.new
    rm -f "$_new"

    if curl -fsSL --retry 3 --max-time 900 "$_url" -o "$_tmp/cc.tgz" 2>/dev/null \
       && tar -xzf "$_tmp/cc.tgz" -C "$DIR" package/claude 2>/dev/null \
       && mv -f "$DIR/package/claude" "$_new" \
       && chmod 0755 "$_new" \
       && "$_new" --version >/dev/null 2>&1 \
       && mv -f "$_new" "$REAL"; then
        rm -rf "$_tmp" "$DIR/package"
        return 0
    fi
    rm -rf "$_tmp" "$DIR/package" "$_new"
    echo "claude-update: install of ${_want} (${_pkg}) failed — previous version left intact"
    echo "claude-update: fetched ${_url}"
    return 1
}

# --- lock -----------------------------------------------------------------
if [ -f "$LOCK" ]; then
    now=$(date +%s)
    mtime=$(date +%s -r "$LOCK" 2>/dev/null || echo 0)
    age=$(( now - mtime ))
    if [ "$age" -lt 900 ]; then
        exit 0  # a fresh run is in progress
    fi
    rm -f "$LOCK"
fi
: > "$LOCK"
trap 'rm -f "$LOCK"' EXIT

# --- compare --------------------------------------------------------------
want=$(remote_latest || true)
[ -n "$want" ] || {
    # Transient by nature and this runs daily — say so, but stay `ok` so a
    # flaky registry does not manufacture a failure streak.
    echo "claude-update: registry unreachable — skipping this run"
    exit 0
}
have_v=$(version_of "$REAL" | sed -n 's/^\([0-9][0-9.]*\).*/\1/p')
if [ "$have_v" = "$want" ]; then
    exit 0  # up to date — stay silent (no_agent cron delivers any stdout)
fi
if [ -z "$have_v" ]; then
    echo "claude-update: claude-real missing or unrunnable — run claude-provision.sh"
    exit 1
fi
echo "claude-update: $have_v -> $want"

# --- install --------------------------------------------------------------
if ! have curl || ! have tar; then
    echo "claude-update: curl/tar missing — cannot install"
    exit 1
fi

install_version "$want" || exit 1
echo "claude-update: now at $(version_of "$REAL")"
