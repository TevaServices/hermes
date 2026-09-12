#!/bin/sh
# The team's self-pull queue, with a LOUD failure mode.
#
# WHY THIS EXISTS
#
# The team routes work by LABEL, not by assignee: GitHub App bot
# identities cannot be assigned issues or PRs at all — the API answers
# 403 / "cannot be assigned to issues or pull requests", and
# `GET /repos/{o}/{r}/assignees/{login}` returns 404 for every bot,
# including dependabot. That is a platform rule about the ASSIGNEE's
# account type, so no token change fixes it: the repo owner's own user
# token fails identically. Bot identities cannot be requested as PR
# REVIEWERS either (`gh pr edit --add-reviewer <bot>` → "GraphQL: Could
# not resolve user with login …"; the REST endpoint returns 201 and
# SILENTLY DROPS the bot, so read back rather than trusting the status
# code). `status/ready` on the issue and `review/ready` on the PR ARE
# the handoffs.
#
# The trap that rule left behind: `gh search` returns an EMPTY list both
# when there is genuinely no work AND when the query itself is broken
# (bad flag, expired token, missing label, lost scope). Those two states
# are indistinguishable downstream, so a broken queue looks exactly like
# a quiet week and the pipeline stalls with no signal — which is how an
# earlier revision of the self-pull command sat dead for days
# (`--assignee:x --state:open --is:issue` are all invalid gh syntax;
# each run errored, nothing ever noticed).
#
# So this script never just "prints nothing". It always reports one of:
#
#   exit 0  QUEUE OK      — issues/PRs listed, or "QUEUE EMPTY" (healthy)
#   exit 2  QUERY BROKEN  — gh failed; stderr is relayed verbatim
#   exit 3  SEARCH BLIND  — the query works but sees NOTHING anywhere:
#                           suspect token/scope/permission, not an idle team
#   exit 4  NOT ONBOARDED — no repo carries the topic tag, so there is
#                           no work surface at all
#   exit 5  LABEL MISSING — an onboarded repo lacks the routing label;
#                           work routed there would be invisible forever
#
# Exits 2-5 are incidents, not idle states: surface them (they are the
# only signal that the pipeline has stopped) rather than reporting "no
# work".
#
# Usage:
#   team-queue.sh [--kind issues|prs] [--label LABEL] [--owner OWNER]
#                 [--author LOGIN] [--cron] [--quiet]
#
#   --cron   The no_agent cron contract (see config/cron.toml). Stdout is
#            DELIVERED verbatim and an EMPTY stdout is silent, so:
#              * work found      -> print it (the agent wakes and works)
#              * healthy + empty -> print NOTHING (zero tokens, no noise)
#              * incident        -> print it ONCE, then stay silent until
#                                   the condition changes (state file), so
#                                   a persistent fault wakes the team once
#                                   instead of every tick.
#            In --cron mode the exit code tracks "did I emit anything
#            new", not "is the world healthy" — a deduped incident is
#            silent AND exits 0 so it cannot generate a failure ping on
#            every single tick. The emitted message is the durable record.
#
# Env: TEAM_OWNER (default the user), TEAM_QUEUE_LABEL, TEAM_TOPIC
#      (default hermes-team), HERMES_HOME (for the dedupe state file).
#      Run per installation/account with that account's token — see the
#      team-github-token skill.

set -u

KIND="issues"
LABEL=""
OWNER="${TEAM_OWNER:-<owner>}"
TOPIC="${TEAM_TOPIC:-hermes-team}"
AUTHOR=""
CRON=0
QUIET=0

while [ $# -gt 0 ]; do
    case "$1" in
        --kind) KIND="$2"; shift 2 ;;
        --label) LABEL="$2"; shift 2 ;;
        --owner) OWNER="$2"; shift 2 ;;
        --author) AUTHOR="$2"; shift 2 ;;
        --cron) CRON=1; shift ;;
        --quiet) QUIET=1; shift ;;
        # Print the header comment block: line 2 through the last `#`
        # line before the first non-comment line, so the range tracks the
        # header instead of being a line number that rots.
        -h|--help) sed -n '2,/^[^#]/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "team-queue.sh: unknown argument: $1" >&2; exit 64 ;;
    esac
done

case "$KIND" in
    issues) [ -n "$LABEL" ] || LABEL="status/ready" ;;
    prs)    [ -n "$LABEL" ] || LABEL="review/ready" ;;
    *) echo "team-queue.sh: --kind must be issues or prs" >&2; exit 64 ;;
esac

log() { [ "$QUIET" -eq 1 ] || echo "$@"; }
fail() { echo "$@" >&2; }

# An empty --owner is not "no filter": gh omits the qualifier and searches
# ALL of GitHub, so a typo'd variable yields a confident list of strangers'
# issues instead of an error. Refuse it.
if [ -z "$OWNER" ]; then
    fail "team-queue.sh: owner must not be empty (an empty owner searches all of GitHub)."
    exit 64
fi

ERR=$(mktemp)
trap 'rm -f "$ERR"' EXIT INT TERM

count_lines() {
    if [ -z "$1" ]; then echo 0; else printf '%s\n' "$1" | wc -l | tr -d ' '; fi
}

# Dedupe state lives per-label so the two queues never share a slot.
state_file() {
    printf '%s/team-queue-%s.state' \
        "${HERMES_HOME:-/opt/data}/cache" \
        "$(printf '%s' "$LABEL" | tr -c 'a-zA-Z0-9' '-')"
}

# Emit an incident, honouring the --cron dedupe contract.
# $@ = the lines to emit. Returns 1 when suppressed (unchanged), else 0.
incident() {
    if [ "$CRON" -eq 0 ]; then
        fail "$@"
        return 0
    fi
    key=$(printf '%s' "$*" | cksum | tr -d ' ')
    f=$(state_file)
    mkdir -p "$(dirname "$f")" 2>/dev/null || true
    if [ -f "$f" ] && [ "$(cat "$f" 2>/dev/null)" = "$key" ]; then
        return 1   # unchanged — stay silent
    fi
    printf '%s' "$key" > "$f" 2>/dev/null || true
    echo "$@"
    return 0
}

# Clear the dedupe state on a healthy run, so a fault that recurs after a
# good period is reported again rather than being suppressed forever.
clear_state() {
    [ "$CRON" -eq 1 ] || return 0
    rm -f "$(state_file)" 2>/dev/null || true
}

# --- 1. the queue itself -------------------------------------------------
# Only the PR queue is author-scoped (the reviewer reviews the dev bot's
# work); the issue queue is label-only. AUTHOR_OPT is deliberately
# unquoted at the call site — it is a pre-split "flag value" pair.
AUTHOR_OPT=""
if [ "$KIND" = "prs" ]; then
    AUTHOR="${AUTHOR:-hermes-dev[bot]}"
fi
[ -n "$AUTHOR" ] && AUTHOR_OPT="--author $AUTHOR"

# shellcheck disable=SC2086
QUEUE=$(gh search "$KIND" --owner "$OWNER" --label "$LABEL" --state open \
            --limit 30 --json repository,number,title,url $AUTHOR_OPT \
            --jq '.[] | "\(.repository.nameWithOwner)#\(.number)  \(.title)  \(.url)"' \
            2>"$ERR")
rc=$?

if [ "$rc" -ne 0 ]; then
    if incident "QUEUE BROKEN  the self-pull query failed (gh exit $rc).
  command: gh search $KIND --owner $OWNER --label $LABEL --state open
  stderr: $(head -3 "$ERR" | tr '\n' ' ')
  This is an incident, not an empty queue — the pipeline is stalled."; then
        exit 2
    fi
    exit 0
fi

N=$(count_lines "$QUEUE")
if [ "$N" -gt 0 ]; then
    clear_state
    log "QUEUE OK  $N item(s) labelled $LABEL for $OWNER:"
    [ "$QUIET" -eq 1 ] || log ""
    printf '%s\n' "$QUEUE"
    exit 0
fi

# --- 2. empty: is it us or is it the world? ------------------------------
# The queue is filtered by label, so an empty result is only meaningful
# if an UNFILTERED search can see anything at all. If it cannot, the
# problem is credentials/scope, not a quiet backlog.
#
# Deliberately NOT --state open: zero OPEN items is a perfectly normal
# quiet state (a team between PRs has no open PRs), so requiring one
# would cry wolf constantly. Searching every state asks the question we
# actually care about — "can this token see this owner's work at all?" —
# and a brand-new empty account is covered by the onboarding check below.
BLIND=$(gh search "$KIND" --owner "$OWNER" --limit 1 \
            --json number --jq '.[] | .number' 2>/dev/null)
if [ "$(count_lines "$BLIND")" -eq 0 ]; then
    if incident "SEARCH BLIND  the queue is empty, but so is an unfiltered search.
  gh search sees NO open $KIND at all for owner '$OWNER'.
  Suspect: expired/invalid token, lost scopes, or the App installation
  losing repo access — NOT an idle team."; then
        exit 3
    fi
    exit 0
fi

# --- 3. is anything even onboarded? --------------------------------------
REPOS=$(gh search repos --owner "$OWNER" --topic "$TOPIC" --limit 100 \
            --json fullName --jq '.[] | .fullName' 2>"$ERR")
rc=$?
if [ "$rc" -ne 0 ]; then
    # Do NOT swallow this. A failed topic query and an empty one look
    # identical, and the empty branch below reports "NOT ONBOARDED" —
    # which is how a wrong --json field name ("nameWithOwner" instead of
    # "fullName") spent its life being reported as a repo that was never
    # onboarded, while the repo WAS onboarded and the topic WAS set.
    if incident "TOPIC QUERY BROKEN  could not list '$TOPIC' repos under '$OWNER' (gh exit $rc).
  stderr: $(head -2 "$ERR" | tr '\n' ' ')
  Without this the onboarded-repo check is meaningless — do not trust
  any 'NOT ONBOARDED' conclusion until this succeeds."; then
        exit 2
    fi
    exit 0
fi

NR=$(count_lines "$REPOS")
if [ "$NR" -eq 0 ]; then
    if incident "NOT ONBOARDED  no repo under '$OWNER' carries the '$TOPIC' topic.
  The team has no work surface: nothing can be routed to you, and every
  future run will look identical to this one.
  Run the team-onboarding procedure (planner owns it)."; then
        exit 4
    fi
    exit 0
fi

# --- 4. do the onboarded repos carry the routing label? ------------------
# A repo without it is worse than un-onboarded: work routed there is
# silently invisible to this queue forever.
#
# This is the only per-repo fan-out in the script (one `gh label list` per
# onboarded repo) and the cron runs it every few minutes, so a HEALTHY
# result is cached with a TTL — the label set is a slow-moving fact about
# repo setup, not a per-tick condition. A missing label is deliberately
# never cached: it must keep firing until someone fixes it. Tune with
# TEAM_LABEL_CHECK_TTL (seconds, default 6h).
CACHE="$(dirname "$(state_file)")/team-labels-$(printf '%s' "$LABEL" | tr -c 'a-zA-Z0-9' '-').cache"
MISSING=""
NEED_CHECK=1
if [ -f "$CACHE" ]; then
    CACHED_AT=$(head -1 "$CACHE" 2>/dev/null || echo 0)
    case "$CACHED_AT" in ''|*[!0-9]*) CACHED_AT=0 ;; esac
    if [ $(( $(date +%s) - CACHED_AT )) -lt "${TEAM_LABEL_CHECK_TTL:-21600}" ]; then
        NEED_CHECK=0
        MISSING=$(sed -n '2p' "$CACHE" 2>/dev/null || true)
    fi
fi

if [ "$NEED_CHECK" -eq 1 ]; then
    for R in $REPOS; do
        FOUND=$(gh label list -R "$R" --search "$LABEL" --json name \
                    --jq '.[] | .name' 2>/dev/null)
        case "$FOUND" in
            *"$LABEL"*) ;;
            *) MISSING="$MISSING $R" ;;
        esac
    done
    if [ -z "$MISSING" ]; then
        mkdir -p "$(dirname "$CACHE")" 2>/dev/null || true
        { date +%s; echo ""; } > "$CACHE" 2>/dev/null || true
    fi
fi

if [ -n "$MISSING" ]; then
    CREATE=""
    for R in $MISSING; do CREATE="$CREATE
    gh label create $LABEL --repo $R"; done
    if incident "LABEL MISSING  onboarded repo(s) lack '$LABEL':$MISSING
  Work routed there would never reach this queue. Create it:$CREATE"; then
        exit 5
    fi
    exit 0
fi

clear_state
if [ "$CRON" -eq 1 ]; then
    exit 0    # healthy + empty: silent, zero tokens
fi
log "QUEUE EMPTY  query healthy: $NR onboarded repo(s), all labelled"
log "  $LABEL, nothing routed to $OWNER right now."
exit 0
