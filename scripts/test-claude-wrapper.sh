#!/bin/sh
# Offline tests for the `claude` wrapper's argv contract
# (docker/hermes/claude — the Claude Code entry point every profile has on
# PATH).
#
# WHY THIS EXISTS
#
# Claude Code has a permission layer of its own, separate from Hermes'. In
# print mode it cannot prompt, so its default denies every write: the first
# bare `claude -p` an agent ran on this stack walled on an unrequested
# permission, and the developer profile wrote the wrong fix into its own
# MEMORY.md ("pass --permission-mode acceptEdits"). That mode — and the plan
# and auto modes — route each call through Claude Code's permission
# *classifier*, a billed extra model call a third-party gateway cannot serve,
# and Claude Code here only ever talks to LiteLLM. So the wrapper appends
# `--dangerously-skip-permissions` itself, and the two halves that make that
# work are what this suite pins:
#
#   1. IT IS ALWAYS ON. A print-mode invocation is handed the skip flag
#      regardless of anything else the caller passed, so no agent has to
#      remember it and none can lose it.
#   2. IT IS NEVER DOUBLE-PASSED, AND A CALLER'S OWN MODE WINS. A caller who
#      passes a permission flag of their own suppresses the default rather
#      than getting both — two permission flags is a Claude Code usage
#      error, not a stricter posture.
#   3. SUBCOMMANDS AND --help/--version ARE LEFT ALONE. `claude mcp`,
#      `config`, `update`, … and the informational flags take no such
#      option; appending one would turn a working command into an error.
#
# The wrapper is exercised for real, with `claude-real` and the model
# resolver stubbed in a temp CLAUDE_HERMES_DIR (the wrapper honours that env
# var for exactly this reason). Nothing here reaches Claude Code, LiteLLM,
# or the network.
#
# Offline: no Docker, no network. Run: $ mise run test
#                                       (or: sh scripts/test-claude-wrapper.sh)

set -u

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
wrapper="$here/docker/hermes/claude"
[ -f "$wrapper" ] || { echo "wrapper not found at $wrapper" >&2; exit 2; }

tmp=$(mktemp -d) || exit 2
trap 'rm -rf "$tmp"' EXIT INT TERM

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
check() {  # check <description> <expected> <actual>
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$2], got [$3])"; fi
}

# ---------------------------------------------------------------------------
# 0. The wrapper's shape — independent of any run
# ---------------------------------------------------------------------------
grep -q -- '--dangerously-skip-permissions' "$wrapper" \
    && ok "wrapper names --dangerously-skip-permissions" \
    || bad "wrapper no longer mentions the skip flag (agents cannot pass it either)"

# The install: the Dockerfile must ship the wrapper where the entrypoint
# copies it from, or the flag exists only in the repo.
grep -q 'docker/hermes/claude' "$here/docker/hermes/Dockerfile" \
    && ok "Dockerfile ships the wrapper" \
    || bad "Dockerfile no longer COPYs docker/hermes/claude"

# ---------------------------------------------------------------------------
# The stub runtime
# ---------------------------------------------------------------------------
hermes_dir="$tmp/claude-hermes"
mkdir -p "$hermes_dir"

# claude-real: echo our argv, one arg per line, so the test can assert on it.
cat > "$hermes_dir/claude-real" <<'STUB'
#!/bin/sh
for a in "$@"; do printf '%s\n' "$a"; done
STUB
chmod +x "$hermes_dir/claude-real"

# claude-model-resolve.py: the two shapes the wrapper calls it with. Fields
# are TAB-separated; the wrapper splits on a literal tab.
cat > "$hermes_dir/claude-model-resolve.py" <<'STUB'
#!/bin/sh
case "${1:-}" in
    --window) printf '1048576\n' ;;
    *)        printf 'litellm\tsmarter\tsmart\n' ;;
esac
STUB
chmod +x "$hermes_dir/claude-model-resolve.py"

: > "$tmp/config.yaml"

# run_wrapper <args…> -> argv the wrapper handed claude-real, on stdout.
# The wrapper only reaches claude-real when the gateway is configured, so a
# key is supplied here; a run that exits non-zero prints nothing and every
# assertion below then fails loudly rather than silently passing.
run_wrapper() {
    LITELLM_API_KEY=test-key \
    CLAUDE_HERMES_DIR="$hermes_dir" \
    CLAUDE_HERMES_CONFIG="$tmp/config.yaml" \
    HERMES_HOME="$tmp" \
    sh "$wrapper" "$@" 2>/dev/null
}

# args_of <args…> -> one arg per line, exactly as claude-real received them
args_of() { run_wrapper "$@"; }

count_of() {  # count_of <needle> <haystack>
    printf '%s\n' "$2" | grep -c -x -- "$1"
}

# ---------------------------------------------------------------------------
# 1. Print mode always gets the flag
# ---------------------------------------------------------------------------
argv=$(args_of -p 'implement the thing' --max-turns 10)
check "print mode: skip flag passed" 1 "$(count_of --dangerously-skip-permissions "$argv")"
check "print mode: profile model still pinned" 1 "$(count_of smarter "$argv")"
check "print mode: caller's --max-turns preserved" 1 "$(count_of 10 "$argv")"

# ---------------------------------------------------------------------------
# 2. A caller's own permission mode wins, and nothing is doubled
# ---------------------------------------------------------------------------
argv=$(args_of -p 'x' --permission-mode plan)
check "own --permission-mode: no skip flag appended" 0 \
    "$(count_of --dangerously-skip-permissions "$argv")"
check "own --permission-mode: caller's value preserved" 1 "$(count_of plan "$argv")"

argv=$(args_of -p 'x' --permission-mode=acceptEdits)
check "own --permission-mode=<v>: no skip flag appended" 0 \
    "$(count_of --dangerously-skip-permissions "$argv")"

argv=$(args_of -p 'x' --dangerously-skip-permissions)
check "caller already passed it: exactly one occurrence" 1 \
    "$(count_of --dangerously-skip-permissions "$argv")"

# ---------------------------------------------------------------------------
# 3. Subcommands and informational flags are untouched
# ---------------------------------------------------------------------------
argv=$(args_of mcp add honcho)
check "mcp subcommand: no skip flag" 0 "$(count_of --dangerously-skip-permissions "$argv")"
check "mcp subcommand: no --model pinned" 0 "$(count_of --model "$argv")"

for sub in config update doctor; do
    argv=$(args_of "$sub")
    check "$sub subcommand: no skip flag" 0 \
        "$(count_of --dangerously-skip-permissions "$argv")"
done

for flag in --version -v --help -h; do
    argv=$(args_of "$flag")
    check "$flag: no skip flag" 0 \
        "$(count_of --dangerously-skip-permissions "$argv")"
done

# ---------------------------------------------------------------------------
# 4. A prompt that merely CONTAINS a flag word is not a flag
# ---------------------------------------------------------------------------
argv=$(args_of -p 'document why --help exists in this CLI')
check "flag word inside a prompt: skip flag still passed" 1 \
    "$(count_of --dangerously-skip-permissions "$argv")"

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------
if [ "$fail" -eq 0 ]; then
    printf '\n%d passed\n' "$pass"
    exit 0
fi
printf '\n%d FAILED, %d passed\n' "$fail" "$pass" >&2
exit 1
