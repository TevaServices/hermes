#!/bin/sh
# Offline test for the entrypoint's credential-file copy.
#
# WHY THIS EXISTS
#
# The container mounts a control-plane auth header read-only and copies it
# into a runtime-owned home, because the mount itself is 600 and unreadable
# by the agent. The first version guarded the copy with `[ -r "$MOUNT" ]` —
# and when the host file does not exist, Docker creates the mount TARGET as
# a DIRECTORY, which is perfectly readable. So the guard passed, `cp` failed
# with "omitting directory", and under `set -euo pipefail` that killed the
# entrypoint. Observed live: a 7-restart crash loop of the whole container
# from one absent credential file — every profile offline, not just the one
# the credential was for.
#
# So the contract pinned here is:
#
#   1. a MISSING credential is not fatal — it warns and returns 0;
#   2. a DIRECTORY at the mount path is not fatal either (that is what an
#      absent host file looks like from inside the container) — and it must
#      NOT be copied;
#   3. a real file IS copied, mode 600, with its content intact;
#   4. EVERY path returns 0, because this script runs under `set -e`.
#
# The function is EXTRACTED from entrypoint.sh rather than reimplemented:
# a copy of the logic would pass this test while the shipped one regressed.
#
# Run: $ mise run test      (or: sh scripts/test-entrypoint-secrets.sh)

set -u

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
entry="$here/docker/hermes/entrypoint.sh"
[ -f "$entry" ] || { echo "entrypoint not found at $entry" >&2; exit 2; }

tmp=$(mktemp -d) || exit 2
trap 'rm -rf "$tmp"' EXIT INT TERM

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

# --- extract the function --------------------------------------------------
awk '/^install_secret_file\(\) \{/,/^\}/' "$entry" > "$tmp/fn.sh"
if [ ! -s "$tmp/fn.sh" ]; then
    bad "could not extract install_secret_file from entrypoint.sh"
    printf '\n%d FAILED, %d passed\n' "$fail" "$pass" >&2
    exit 1
fi
grep -q 'return 0' "$tmp/fn.sh" || bad "the extracted function has no return 0 (cannot be non-fatal)"

# A harness with the globals the function reads, then the function itself.
RUNTIME_UID=$(id -u)
export RUNTIME_UID
. "$tmp/fn.sh"

run() {  # run <src> <dest> <label>; captures stderr and the exit code
    out=$(install_secret_file "$1" "$2" "$3" 2>&1)
    rc=$?
    printf '%s' "$out"
    return $rc
}

# --- 1. a missing source is not fatal, and is not copied ------------------
out=$(run "$tmp/nope" "$tmp/d1/f" "test header"); rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$tmp/d1/f" ]; then
    ok "a missing credential warns and returns 0 without creating anything"
else
    bad "a missing credential was fatal (rc=$rc) or created a dest"
fi
case "$out" in
    *"no test header at"*) ok "the warning names the missing file" ;;
    *) bad "no warning for the missing source (got: $out)" ;;
esac

# --- 2. a DIRECTORY at the mount path is not fatal and is not copied ------
# This is the regression: an absent host file makes Docker create the mount
# target as a directory, and `-r` says it is readable.
mkdir -p "$tmp/isdir"
out=$(run "$tmp/isdir" "$tmp/d2/f" "test header"); rc=$?
if [ "$rc" -eq 0 ]; then
    ok "a DIRECTORY at the mount path returns 0 (the crash-loop bug)"
else
    bad "a directory at the mount path was fatal — this is the 7-restart crash loop"
fi
if [ ! -e "$tmp/d2/f" ]; then
    ok "the directory was not copied to the destination"
else
    bad "a directory was copied to the destination"
fi
case "$out" in
    *"is not a regular file"*) ok "the warning says it is not a regular file" ;;
    *) bad "no 'not a regular file' warning (got: $out)" ;;
esac

# --- 3. a real file is copied, 600, content intact ------------------------
printf 'X-API-KEY: %s\n' "test-value-123" > "$tmp/real"
run "$tmp/real" "$tmp/d3/nested/deep/header" "test header" > /dev/null
if [ -f "$tmp/d3/nested/deep/header" ]; then
    ok "a real credential is copied (creating parent directories)"
else
    bad "a real credential was not copied"
fi
if [ "$(cat "$tmp/d3/nested/deep/header" 2>/dev/null)" = "X-API-KEY: test-value-123" ]; then
    ok "the copy is byte-identical"
else
    bad "the copy differs from the source"
fi
mode=$(ls -l "$tmp/d3/nested/deep/header" | cut -c1-10)
case "$mode" in
    -rw-------) ok "the copy is mode 600" ;;
    *) bad "the copy is not mode 600 (got $mode)" ;;
esac

# --- 4. every path returns 0 (the entrypoint runs under set -e) ----------
# The whole point: a credential problem degrades a capability, it does not
# take every profile offline.
allzero=1
for src in "$tmp/nope" "$tmp/isdir" "$tmp/real"; do
    install_secret_file "$src" "$tmp/d4/f" "test header" > /dev/null 2>&1 || allzero=0
    rm -f "$tmp/d4/f"
done
if [ "$allzero" -eq 1 ]; then
    ok "every source shape returns 0 — a credential fault is never fatal"
else
    bad "some source shape returned non-zero; under set -e that kills the entrypoint"
fi

# --- summary ---------------------------------------------------------------
if [ "$fail" -eq 0 ]; then
    printf '\n%s passed\n' "$pass"
    exit 0
fi
printf '\n%d FAILED, %d passed\n' "$fail" "$pass" >&2
exit 1
