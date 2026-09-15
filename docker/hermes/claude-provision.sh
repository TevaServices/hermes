#!/bin/sh
# Provision Claude Code at container boot onto the persistent volume —
# idempotent: cheap no-op when the current version is already there.
#
# Volume layout after this runs:
#   /opt/data/tools/claude-hermes/claude-real              the real CLI
#   /opt/data/tools/claude-hermes/claude                   the wrapper (copied)
#   /opt/data/tools/claude-hermes/claude-model-resolve.py  resolver (copied)
#   /opt/data/tools/claude-hermes/claude-env.sh            generated on demand
#   /opt/data/bin/claude + /usr/local/bin/claude           symlinks → wrapper
#
# NOT pinned: installs whatever npm's dist-tag `latest` points at (the
# per-platform registry tarball, extracted directly — no npm install).
# claude-update.sh re-checks daily via the gateway cron and swaps
# claude-real atomically; the install logic below is kept IDENTICAL to
# that script's on purpose (see the platform_pkg comment there for why
# the old `package/bundle/cli.js` path was wrong).
#
# Failures are non-fatal: boot MUST survive a failed install (the wrapper
# degrades gracefully; hermes itself does not depend on claude). They are
# printed on STDOUT with the rest of the boot log so a broken install is
# visible in `docker logs`, not buried on a discarded stream.

set -u

DIR=/opt/data/tools/claude-hermes
STAGE=/opt/claude-hermes
REAL=$DIR/claude-real
BIN=/opt/data/bin

have() { command -v "$1" >/dev/null 2>&1; }
version_of() { "$1" --version 2>/dev/null | head -1; }
remote_latest() {
    have curl || return 1
    curl -fsSL --retry 3 --max-time 30 \
        https://registry.npmjs.org/@anthropic-ai/claude-code/latest 2>/dev/null |
        sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
        head -1
}

# See claude-update.sh — the CLI moved out of the wrapper package into a
# per-platform native package at the 2.1.x cutover.
platform_pkg() {
    case "$(uname -m 2>/dev/null)" in
        aarch64|arm64) _cpu=arm64 ;;
        x86_64|amd64)  _cpu=x64 ;;
        *) return 1 ;;
    esac
    case "$(uname -s 2>/dev/null)" in
        Linux)
            if [ -e /lib/ld-musl-aarch64.so.1 ] || [ -e /lib/ld-musl-x86_64.so.1 ]; then
                printf 'linux-%s-musl' "$_cpu"
            else
                printf 'linux-%s' "$_cpu"
            fi ;;
        Darwin) printf 'darwin-%s' "$_cpu" ;;
        *) return 1 ;;
    esac
}

install_version() {
    _want=$1
    _pkg=$(platform_pkg) || {
        printf '[claude-provision] unsupported platform %s/%s — cannot install Claude Code\n' \
            "$(uname -s 2>/dev/null)" "$(uname -m 2>/dev/null)"
        return 1
    }
    _url="https://registry.npmjs.org/@anthropic-ai/claude-code-${_pkg}/-/claude-code-${_pkg}-${_want}.tgz"
    _tmp=$(mktemp -d) || return 1
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
    printf '[claude-provision] install of %s (%s) failed — previous version (if any) left intact\n' \
        "$_want" "$_pkg"
    return 1
}

mkdir -p "$DIR" "$BIN"
# Wrapper tooling: image layer → volume (per-run mutable copies).
for f in claude claude-model-resolve.py claude-env.sh claude-shell-functions.sh claude-update.sh; do
    [ -f "$STAGE/$f" ] && cp -f "$STAGE/$f" "$DIR/$f" && chmod 0755 "$DIR/$f" 2>/dev/null
done
[ -x "$DIR/claude" ] || { printf '[claude-provision] %s/claude missing — cannot provision\n' "$STAGE"; exit 0; }

# Symlinks: PATH dir (agents' shells) + the fixed path claude's agent
# shell uses (/usr/local/bin — writable at pre-drop boot time).
ln -sfn "$DIR/claude" "$BIN/claude"
ln -sfn "$DIR/claude" /usr/local/bin/claude 2>/dev/null || true

# Real CLI — absent or outdated → fetch latest from the npm registry.
want=$(remote_latest || true)
[ -n "$want" ] || { printf '[claude-provision] registry unreachable — skipping install check\n'; exit 0; }
have_v=$(version_of "$REAL" | sed -n 's/^\([0-9][0-9.]*\).*/\1/p')
if [ "$have_v" = "$want" ]; then
    printf '[claude-provision] claude-real %s up to date\n' "$have_v"
    exit 0
fi
if [ -n "$have_v" ]; then
    printf '[claude-provision] claude-real %s -> %s: updating\n' "$have_v" "$want"
else
    printf '[claude-provision] installing Claude Code %s\n' "$want"
fi

if ! have curl || ! have tar; then
    printf '[claude-provision] curl/tar missing — cannot install Claude Code\n'
    exit 0
fi

if install_version "$want"; then
    got=$(version_of "$REAL" | sed -n 's/^\([0-9][0-9.]*\).*/\1/p')
    printf '[claude-provision] now at %s\n' "${got:-$want}"
fi

# Shell source for claude's Bash tool (wrapper also generates this).
[ -f "$DIR/claude-env.sh" ] || printf 'export PATH="%s:/opt/data/bin:$PATH"\n' "$DIR" > "$DIR/claude-env.sh"

exit 0
