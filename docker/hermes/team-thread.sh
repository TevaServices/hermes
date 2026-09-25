#!/bin/sh
# One Discord thread per work item, in the CALLING profile's own channel.
#
# Why this exists
#   The team posts status into Discord, but a work item spans many turns
#   across many cron wakes, and each wake is a FRESH session with no chat
#   context — so an agent cannot remember a thread id between turns. This
#   keeps that mapping on disk instead, so the thread survives the agent.
#
#   It also owns thread LIFETIME. A work item's thread stays open until
#   the PR is merged; the merge closes the issue (`Closes #N`), and
#   `sweep` turns "issue closed" into "thread archived". Sweep is
#   deterministic and needs no agent turn, so it is called from the
#   profile's cron queue script — a thread cannot be stranded open just
#   because the agent that opened it never ran again.
#
# Identity and channel are DERIVED, never hardcoded:
#   * bot token  <- $HERMES_HOME/.env DISCORD_BOT_TOKEN (so each role
#                   posts as its OWN bot; last occurrence wins, matching
#                   the dotenv loader)
#   * channel    <- $HERMES_HOME/config.yaml platforms.discord.extra.
#                   allowed_channels[0] (the rendered per-profile fence,
#                   which is already the single source of truth)
#
# Usage:
#   team-thread.sh open  <key> [title]   create (or reuse) the thread; prints its id
#   team-thread.sh post  <key> <text>    post into the thread
#   team-thread.sh close <key> [--lock]  archive (optionally lock) + forget
#   team-thread.sh sweep                 close threads whose issue is CLOSED
#   team-thread.sh list                  show tracked threads
#   team-thread.sh id    <key>           print the tracked thread id, if any
#
# <key> identifies the work item: <owner>/<repo>#<n>, e.g. <owner>/mach#7,
# where <n> is the ISSUE number — always, including for the reviewer, whose
# queue prints PR numbers. The sweep below resolves every key as an issue
# (`Closes #N` is what closes it on merge), so a thread opened with a PR
# number is archived against an unrelated issue or never archived at all.
# The reviewer maps PR -> issue from the PR body:
#   gh pr view <PR#> --json body --jq '.body | capture("(?i)closes #(?<n>[0-9]+)").n'
#
# Exit: 0 ok; 2 could not resolve credentials/channel; 3 the API refused;
#       4 no such tracked thread. Never fails silently.

set -u

UA="HermesTeamThread/1.0 (+https://github.com/<owner>/hermes)"
API="https://discord.com/api/v10"
HERMES_HOME="${HERMES_HOME:-/opt/data}"

die() { echo "team-thread.sh: $*" >&2; exit "${2:-2}"; }

# --- derived configuration ------------------------------------------------
env_file="$HERMES_HOME/.env"
config_file="$HERMES_HOME/config.yaml"

# Last occurrence wins — the same rule the dotenv loader applies, so this
# can never disagree with what the agent's own `hermes send` would use.
read_token() {
    [ -f "$env_file" ] || return 1
    sed -n 's/^DISCORD_BOT_TOKEN=//p' "$env_file" | tail -1
}

read_channel() {
    [ -f "$config_file" ] || return 1
    grep -m1 'allowed_channels' "$config_file" 2>/dev/null \
        | sed 's/.*\[//; s/\].*//' | tr -d ' "' | cut -d, -f1
}

TOKEN=$(read_token) || true
CHANNEL=$(read_channel) || true
[ -n "${TOKEN:-}" ] || die "no DISCORD_BOT_TOKEN in $env_file"
[ -n "${CHANNEL:-}" ] || die "no platforms.discord.extra.allowed_channels in $config_file"

STATE_DIR="$HERMES_HOME/cache/threads"

state_file() {   # sanitize the key into a filename
    printf '%s/%s' "$STATE_DIR" "$(printf '%s' "$1" | tr -c 'a-zA-Z0-9._-' '_')"
}

api() {  # api METHOD PATH [JSON]  -> body on stdout, non-zero on HTTP error
    method="$1"; path="$2"; body="${3:-}"
    if [ -n "$body" ]; then
        out=$(curl -sS -X "$method" -H "Authorization: Bot $TOKEN" \
              -H "User-Agent: $UA" -H "Content-Type: application/json" \
              -d "$body" -w '\n%{http_code}' "$API$path" 2>&1)
    else
        out=$(curl -sS -X "$method" -H "Authorization: Bot $TOKEN" \
              -H "User-Agent: $UA" -w '\n%{http_code}' "$API$path" 2>&1)
    fi
    code=$(printf '%s\n' "$out" | tail -1)
    payload=$(printf '%s\n' "$out" | sed '$d')
    case "$code" in
        2*) printf '%s' "$payload"; return 0 ;;
        *)  printf '%s' "$payload" >&2; die "Discord API $method $path -> HTTP $code" 3 ;;
    esac
}

json_str() {  # extract a flat "key": "value" from a JSON blob
    sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}

# --- commands -------------------------------------------------------------
cmd_open() {
    key="$1"; title="${2:-$1}"
    f=$(state_file "$key")
    if [ -f "$f" ]; then
        tid=$(head -1 "$f")
        existing=$(api GET "/channels/$tid" 2>/dev/null) || existing=""
        archived=$(printf '%s' "$existing" | sed -n 's/.*"thread_metadata".*"archived"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p')
        if [ -n "$tid" ] && [ "$archived" = "false" ]; then
            echo "$tid"; return 0      # still open — reuse, never duplicate
        fi
    fi
    mkdir -p "$STATE_DIR"
    created=$(api POST "/channels/$CHANNEL/threads" \
        "$(printf '{"name":%s,"type":11,"auto_archive_duration":10080}' \
           "$(printf '%s' "$title" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))')")")
    tid=$(printf '%s' "$created" | json_str id)
    [ -n "$tid" ] || die "thread creation returned no id: $created" 3
    { printf '%s\n' "$tid"; printf '%s\n' "$key"; } > "$f"
    echo "$tid"
}

cmd_post() {
    key="$1"; text="$2"
    f=$(state_file "$key")
    [ -f "$f" ] || die "no thread tracked for '$key' (open it first)" 4
    tid=$(head -1 "$f")
    body=$(printf '%s' "$text" | python3 -c 'import json,sys; print(json.dumps({"content": sys.stdin.read()}))')
    api POST "/channels/$tid/messages" "$body" >/dev/null
    echo "posted to $key ($tid)"
}

cmd_close() {
    key="$1"; lock="${2:-}"
    f=$(state_file "$key")
    [ -f "$f" ] || die "no thread tracked for '$key'" 4
    tid=$(head -1 "$f")
    if [ "$lock" = "--lock" ]; then
        api PATCH "/channels/$tid" '{"archived": true, "locked": true}' >/dev/null
    else
        api PATCH "/channels/$tid" '{"archived": true}' >/dev/null
    fi
    rm -f "$f"
    echo "closed $key ($tid)"
}

# A thread closes when its work item is DONE, and "done" is defined by the
# issue being closed — which is what `Closes #N` does on merge. Checking
# the issue (not the PR) keeps this to one cheap call per tracked thread
# and works whether the item ended in a merge or a close.
cmd_sweep() {
    [ -d "$STATE_DIR" ] || { echo "no tracked threads"; return 0; }
    n=0
    for f in "$STATE_DIR"/*; do
        [ -f "$f" ] || continue
        key=$(sed -n '2p' "$f")
        case "$key" in
            */*'#'*) ;;
            *) continue ;;   # not a <owner>/<repo>#<n> key — leave it alone
        esac
        repo=$(printf '%s' "$key" | cut -d'#' -f1)
        num=$(printf '%s' "$key" | cut -d'#' -f2)
        state=$(gh issue view "$num" --repo "$repo" --json state --jq .state 2>/dev/null) || continue
        if [ "$state" = "CLOSED" ]; then
            tid=$(head -1 "$f")
            if api PATCH "/channels/$tid" '{"archived": true}' >/dev/null 2>&1; then
                rm -f "$f"; n=$((n+1))
                echo "swept $key (issue closed, thread $tid archived)"
            fi
        fi
    done
    [ "$n" -eq 0 ] && echo "no threads to sweep"
    return 0
}

cmd_list() {
    [ -d "$STATE_DIR" ] || { echo "no tracked threads"; return 0; }
    found=0
    for f in "$STATE_DIR"/*; do
        [ -f "$f" ] || continue
        found=1
        printf '%s -> thread %s\n' "$(sed -n '2p' "$f")" "$(head -1 "$f")"
    done
    [ "$found" -eq 1 ] || echo "no tracked threads"
}

cmd_id() {
    f=$(state_file "$1")
    [ -f "$f" ] || exit 4
    head -1 "$f"
}

case "${1:-}" in
    open)  [ $# -ge 2 ] || die "usage: open <key> [title]" 64; cmd_open "$2" "${3:-}" ;;
    post)  [ $# -ge 3 ] || die "usage: post <key> <text>" 64; cmd_post "$2" "$3" ;;
    close) [ $# -ge 2 ] || die "usage: close <key> [--lock]" 64; cmd_close "$2" "${3:-}" ;;
    sweep) cmd_sweep ;;
    list)  cmd_list ;;
    id)    [ $# -ge 2 ] || die "usage: id <key>" 64; cmd_id "$2" ;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' ;;
    *) die "unknown command '${1:-}' (open|post|close|sweep|list|id)" 64 ;;
esac
