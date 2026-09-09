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
# registry tarball, extracted directly — no npm install). claude-update.sh
# re-checks daily via the gateway cron and swaps claude-real atomically.
#
# Failures are non-fatal: boot MUST survive a failed install (the wrapper
# degrades gracefully; hermes itself does not depend on claude).

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

mkdir -p "$DIR" "$BIN"
# Wrapper tooling: image layer → volume (per-run mutable copies).
for f in claude claude-model-resolve.py claude-env.sh claude-shell-functions.sh claude-update.sh; do
    [ -f "$STAGE/$f" ] && cp -f "$STAGE/$f" "$DIR/$f" && chmod 0755 "$DIR/$f" 2>/dev/null
done
[ -x "$DIR/claude" ] || { printf '[claude-provision] %s/claude missing — cannot provision\n' "$STAGE" >&2; exit 0; }

# Symlinks: PATH dir (agents' shells) + the fixed path claude's agent
# shell uses (/usr/local/bin — writable at pre-drop boot time).
ln -sfn "$DIR/claude" "$BIN/claude"
ln -sfn "$DIR/claude" /usr/local/bin/claude 2>/dev/null || true

# Real CLI — absent or outdated → fetch latest from the npm registry.
want=$(remote_latest || true)
[ -n "$want" ] || { printf '[claude-provision] registry unreachable — skipping install check\n' >&2; exit 0; }
have=$(version_of "$REAL" | sed -n 's/^\([0-9][0-9.]*\).*/\1/p')
if [ "$have" = "$want" ]; then
    printf '[claude-provision] claude-real %s up to date\n' "$have"
    exit 0
fi
if [ -n "$have" ]; then
    printf '[claude-provision] claude-real %s -> %s: updating\n' "$have" "$want"
else
    printf '[claude-provision] installing Claude Code %s\n' "$want"
fi

if ! have curl || ! have node; then
    printf '[claude-provision] node/curl missing — cannot install Claude Code\n' >&2
    exit 0
fi
url="https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-${want}.tgz"
tmp=$(mktemp -d) || exit 0
trap 'rm -rf "$tmp"' EXIT
if curl -fsSL --retry 3 --max-time 300 "$url" -o "$tmp/cc.tgz" 2>/dev/null \
   && tar -xzf "$tmp/cc.tgz" -C "$tmp" 2>/dev/null \
   && node "$tmp/package/bundle/cli.js" --version >/dev/null 2>&1 \
   && install -m 0755 "$tmp/package/bundle/cli.js" "$REAL.tmp" \
   && mv -f "$REAL.tmp" "$REAL"; then
    got=$(version_of "$REAL" | sed -n 's/^\([0-9][0-9.]*\).*/\1/p')
    printf '[claude-provision] now at %s\n' "${got:-$want}"
else
    printf '[claude-provision] install failed — previous version (if any) left intact\n' >&2
    exit 0
fi

# Shell source for claude's Bash tool (wrapper also generates this).
[ -f "$DIR/claude-env.sh" ] || printf 'export PATH="%s:/opt/data/bin:$PATH"\n' "$DIR" > "$DIR/claude-env.sh"

exit 0