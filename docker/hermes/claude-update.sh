#!/bin/sh
# Keep Claude Code current: npm registry `latest` vs the installed
# claude-real; install atomically when they differ. Designed to be run by
# the gateway's no-agent cron (zero tokens) and at container boot.
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
[ -n "$want" ] || { echo "claude-update: registry unreachable"; exit 0; }
have=$(version_of "$REAL" | sed -n 's/^\([0-9][0-9.]*\).*/\1/p')
if [ "$have" = "$want" ]; then
    exit 0  # up to date — stay silent (no-agent cron delivers any stdout)
fi
if [ -z "$have" ]; then
    echo "claude-update: claude-real missing — run claude-provision.sh"
    exit 0
fi
echo "claude-update: $have -> $want"

# --- install (atomic: build beside, then mv over) --------------------------
if ! have node; then
    echo "claude-update: node missing"; exit 0
fi
url="https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-${want}.tgz"
tmp=$(mktemp -d) || exit 0
if curl -fsSL --retry 3 --max-time 300 "$url" -o "$tmp/cc.tgz" 2>/dev/null \
   && tar -xzf "$tmp/cc.tgz" -C "$tmp" 2>/dev/null \
   && node "$tmp/package/bundle/cli.js" --version >/dev/null 2>&1 \
   && install -m 0755 "$tmp/package/bundle/cli.js" "$REAL.tmp" \
   && mv -f "$REAL.tmp" "$REAL"; then
    rm -rf "$tmp"
    echo "claude-update: now at $(version_of "$REAL")"
else
    rm -rf "$tmp"
    echo "claude-update: install failed — previous version left intact" >&2
    exit 0
fi