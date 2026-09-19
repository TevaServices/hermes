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
#   team-queue.sh [--kind issues|prs] [--label LABEL]... [--owner OWNER]
#                 [--author LOGIN] [--verbose] [--quiet]
#
#   --label may be repeated. Each label is one search and the results are
#   merged in the order given, so the FIRST label is the highest priority.
#   That is how RESUME works: the cron passes the in-flight label first
#   (`status/in-progress` then `status/ready`), so a profile that was
#   interrupted mid-item is handed its own unfinished work before it is
#   offered anything new. Without this an interrupted item — claimed, so
#   no longer `status/ready` — would never be surfaced again and the work
#   would sit half-done forever.
#
#   THE DEFAULT IS THE CRON CONTRACT, because that is how this runs in
#   production and the scheduler gives no way to say so: a no_agent job
#   is invoked as `bash <script>` with NO ARGUMENTS (scheduler.py:
#   `argv = [_bash, str(path)]`). An opt-in `--cron` flag therefore never
#   fires under cron — the delivered output was the healthy-but-idle
#   "QUEUE EMPTY" line, waking the profile's agent on every tick with
#   nothing to do. So quiet is the default and --verbose is the opt-out.
#
#   Default (no flags), stdout is DELIVERED verbatim and EMPTY stdout is
#   silent:
#     * work found      -> print it (the agent wakes and works)
#     * healthy + empty -> print NOTHING (zero tokens, no noise)
#     * incident        -> print it ONCE, then stay silent until the
#                          condition changes (state file), so a
#                          persistent fault wakes the team once instead
#                          of every tick.
#   In that mode the exit code tracks "did I emit anything new", not "is
#   the world healthy" — a deduped incident is silent AND exits 0 so it
#   cannot generate a failure ping on every tick. The emitted message is
#   the durable record.
#
#   --verbose  Human/debug mode: always print the healthy-but-idle line
#              and never dedupe incidents. Use this when you are running
#              it by hand and want to see the state.
#
# Env: TEAM_OWNER (REQUIRED — the GitHub account whose repos carry the
#      topic tag; the script refuses to run without it rather than
#      searching all of GitHub), TEAM_QUEUE_LABEL, TEAM_TOPIC
#      (default hermes-team), HERMES_HOME (for the dedupe state file).
#      Run per installation/account with that account's token — see the
#      team-github-token skill.

set -u

KIND="issues"
LABELS=""
OWNER="${TEAM_OWNER:-}"
TOPIC="${TEAM_TOPIC:-hermes-team}"
AUTHOR=""
VERBOSE=0
QUIET=0

while [ $# -gt 0 ]; do
    case "$1" in
        --kind) KIND="$2"; shift 2 ;;
        --label) LABELS="$LABELS $2"; shift 2 ;;
        --owner) OWNER="$2"; shift 2 ;;
        --author) AUTHOR="$2"; shift 2 ;;
        --verbose) VERBOSE=1; shift ;;
        # Accepted as a no-op: cron behaviour is the DEFAULT now. An older
        # caller — or a skill that has not been updated — passing the old
        # flag must not hard-fail with exit 64 inside a cron run.
        --cron) shift ;;
        --quiet) QUIET=1; shift ;;
        # Print the header comment block: line 2 through the last `#`
        # line before the first non-comment line, so the range tracks the
        # header instead of being a line number that rots.
        -h|--help) sed -n '2,/^[^#]/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "team-queue.sh: unknown argument: $1" >&2; exit 64 ;;
    esac
done

case "$KIND" in
    # IN-FLIGHT FIRST, then newly-routable. The cron job passes no
    # arguments (a no_agent script is invoked as `bash <script>`), so this
    # default IS the resume behaviour: an item the profile already claimed
    # comes back to it before it is offered anything new. An item left
    # `status/in-progress` by an interrupted turn would otherwise never be
    # surfaced again — it is no longer `ready`, so nothing else would
    # return it, and the work would sit half-done forever.
    issues) [ -n "$LABELS" ] || LABELS="status/in-progress status/ready" ;;
    prs)    [ -n "$LABELS" ] || LABELS="review/in-progress review/ready" ;;
    *) echo "team-queue.sh: --kind must be issues or prs" >&2; exit 64 ;;
esac
# Normalise the accumulated list (leading/duplicate spaces from repeat flags).
LABELS=$(printf '%s' "$LABELS" | tr -s ' ' | sed 's/^ *//; s/ *$//')
# A single slug for state/cache filenames, stable regardless of order.
LABEL_SLUG=$(printf '%s' "$LABELS" | tr ' ' '+' | tr -c 'a-zA-Z0-9.+-' '-')

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

# --- housekeeping: close finished work-item threads ----------------------
# A work item's Discord thread stays open until the PR is merged, and the
# merge closes the issue (`Closes #N`). Doing that here — in the token-free
# polling path rather than in the agent's turn — is what makes the
# lifetime real: the thread closes even if the agent that opened it never
# wakes again. Output is deliberately swallowed: this is bookkeeping, not
# queue output, and it must never wake a profile or land in the delivered
# message. (team-thread.sh is seeded next to this script.)
TEAM_THREAD_SH=""
for c in team-thread.sh /usr/local/bin/team-thread.sh "$(dirname "$0")/team-thread.sh"; do
    if [ -x "$c" ]; then TEAM_THREAD_SH="$c"; break; fi
    if command -v "$c" >/dev/null 2>&1; then TEAM_THREAD_SH=$(command -v "$c"); break; fi
done
if [ -n "$TEAM_THREAD_SH" ]; then
    "$TEAM_THREAD_SH" sweep >/dev/null 2>>"$ERR" || true
fi

count_lines() {
    if [ -z "$1" ]; then echo 0; else printf '%s\n' "$1" | wc -l | tr -d ' '; fi
}

# Dedupe state lives per-label so the two queues never share a slot.
state_file() {
    printf '%s/team-queue-%s.state' \
        "${HERMES_HOME:-/opt/data}/cache" \
        "$LABEL_SLUG"
}

# Emit an incident, honouring the dedupe contract.
# $@ = the lines to emit. Returns 1 when suppressed (unchanged), else 0.
#
# Always STDOUT, never stderr: under cron stdout IS the delivery channel
# (stderr goes to the job's log and reaches nobody), and for a human it is
# the thing they actually read.
incident() {
    if [ "$VERBOSE" -eq 1 ]; then
        echo "$@"
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

# --- handoff audit --------------------------------------------------------
# An in-progress item whose PR is open but NOT handed off is the one state
# that LOOKS like progress and is actually a stall. The hand-off is
# `gh pr ready` PLUS the `review/ready` label, so a PR that skipped either
# is invisible to the reviewer — whose queue IS that label — and the item
# sits in status/in-progress indefinitely, looking busy while nothing
# moves. Worse, an agent can report a hand-off it never performed: observed
# live, a turn whose summary said "review/ready label added" while the PR
# was still a draft with no labels. Nothing downstream noticed, because a
# missing label is indistinguishable from "nothing to review".
#
# So the queue says it out loud, in the same output the agent already
# reads. Deterministic, no agent turn required.
audit_handoffs() {
    printf '%s\n' "$1" | while IFS= read -r line; do
        printf '%s\n' "$line"
        key=$(printf '%s' "$line" | awk '{print $1}')
        case "$key" in */*'#'*) ;; *) continue ;; esac
        repo=${key%#*}; num=${key##*#}
        labels=$(gh issue view "$num" --repo "$repo" --json labels \
                    --jq '[.labels[].name]|join(",")' 2>/dev/null) || continue
        case ",$labels," in *",status/in-progress,"*) ;; *) continue ;; esac
        pr=$(gh pr list --repo "$repo" --state open --limit 50 \
               --json number,isDraft,labels,body \
               --jq "[.[] | select((.body // \"\") | test(\"(?i)closes #${num}\\\\b\"))] | .[0]
                     | if . == null then \"\" else \"\\(.number)|\\(.isDraft)|\\([.labels[].name]|join(\",\"))\" end" \
               2>/dev/null) || continue
        [ -n "$pr" ] || continue
        pnum=${pr%%|*}; rest=${pr#*|}; pdraft=${rest%%|*}; plabels=${rest#*|}
        why=""
        [ "$pdraft" = "true" ] && why="still a draft"
        case ",$plabels," in
            *",review/ready,"*) ;;
            *) if [ -n "$why" ]; then why="$why and missing review/ready"
               else why="missing review/ready"; fi ;;
        esac
        [ -n "$why" ] || continue
        printf '    !! HANDOFF INCOMPLETE: PR #%s is %s — the reviewer cannot see it until `gh pr ready` + `review/ready`\n' \
               "$pnum" "$why"
    done
}

# Clear the dedupe state on a healthy run, so a fault that recurs after a
# good period is reported again rather than being suppressed forever.
clear_state() {
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

QUEUE=""
for L in $LABELS; do
    # shellcheck disable=SC2086
    PART=$(gh search "$KIND" --owner "$OWNER" --label "$L" --state open \
              --limit 30 --json repository,number,title,url $AUTHOR_OPT \
              --jq '.[] | "\(.repository.nameWithOwner)#\(.number)  \(.title)  \(.url)"' \
              2>"$ERR")
    rc=$?
    if [ "$rc" -ne 0 ]; then
        if incident "QUEUE BROKEN  the self-pull query failed (gh exit $rc).
  command: gh search $KIND --owner $OWNER --label $L --state open
  stderr: $(head -3 "$ERR" | tr '\n' ' ')
  This is an incident, not an empty queue — the pipeline is stalled."; then
            exit 2
        fi
        exit 0
    fi
    QUEUE="$QUEUE
$PART"
done
# Dedupe by item id, preserving the LABEL ORDER given (first label wins),
# so resume entries stay ahead of newly-routable ones.
QUEUE=$(printf '%s\n' "$QUEUE" | awk 'NF && !seen[$1]++')

N=$(count_lines "$QUEUE")
if [ "$N" -gt 0 ]; then
    clear_state
    log "QUEUE OK  $N item(s) labelled $LABELS for $OWNER:"
    [ "$QUIET" -eq 1 ] || log ""
    if [ "$KIND" = "issues" ]; then
        audit_handoffs "$QUEUE"
    else
        printf '%s\n' "$QUEUE"
    fi
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
CACHE="$(dirname "$(state_file)")/team-labels-$LABEL_SLUG.cache"
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
    # Every label this queue polls must exist, or the work routed under it
    # is invisible forever. A repo is only "good" when it carries them ALL.
    for R in $REPOS; do
        for L in $LABELS; do
            FOUND=$(gh label list -R "$R" --search "$L" --json name \
                        --jq '.[] | .name' 2>/dev/null)
            case "$FOUND" in
                *"$L"*) ;;
                *) MISSING="$MISSING $R:$L" ;;
            esac
        done
    done
    if [ -z "$MISSING" ]; then
        mkdir -p "$(dirname "$CACHE")" 2>/dev/null || true
        { date +%s; echo ""; } > "$CACHE" 2>/dev/null || true
    fi
fi

if [ -n "$MISSING" ]; then
    CREATE=""
    for RL in $MISSING; do CREATE="$CREATE
    gh label create $(printf '%s' "$RL" | cut -d: -f2) --repo $(printf '%s' "$RL" | cut -d: -f1)"; done
    if incident "LABEL MISSING  onboarded repo(s) lack a routing label:$MISSING
  Work routed under that label would never reach this queue. Create it:$CREATE"; then
        exit 5
    fi
    exit 0
fi

clear_state
if [ "$VERBOSE" -eq 0 ]; then
    exit 0    # healthy + empty: SILENT (zero tokens — the cron default)
fi
log "QUEUE EMPTY  query healthy: $NR onboarded repo(s), all labelled"
log "  $LABELS, nothing routed to $OWNER right now."
exit 0
