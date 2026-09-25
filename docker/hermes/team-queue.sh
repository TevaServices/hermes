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
# ONE SESSION PER WORK ITEM — the queue YIELDS, it does not compete.
#
# An item is worked in exactly one session. Before emitting, every item is
# checked against the profile's own live sessions (team-session.py, reading
# `state.db` — no claim file, no heartbeat to go stale) and any item a live
# session is already on is DROPPED from the output. If that leaves nothing,
# this script prints nothing and exits 0, so no bot-chat turn is spawned at
# all — the cron lane simply exits without working. A live session also
# fences its own predecessor: because the check is `--gate any`, a previous
# delivery still in flight holds its item, which is what stops the next tick
# stacking a second wake on running work.
#
# This is per ITEM, so a live session on one issue never fences a newly
# routable issue elsewhere, and the fence lifts by itself when that turn
# stops breathing (liveness is `sessions.last_activity_at`, refreshed on
# every stream chunk, expiring after TEAM_SESSION_TTL, default 600s).
# It exists because on 2026-09-25 this queue re-injected one in-progress
# issue every 5 minutes while a Discord session was mid-work on it; both
# edited the same worktree until the container had to be paused by hand.
#
# If team-session.py is missing or cannot read state.db the gate is DARK:
# items are still emitted (work keeps flowing) and a deduped incident says
# so, because a guard that silently stopped guarding is indistinguishable
# from a quiet week.
#
# LABEL FAMILIES ARE OBJECT-SCOPED, AND THIS QUEUE SAYS WHEN THEY ARE NOT.
# `status/*` belongs on ISSUES and `review/*` on PULL REQUESTS (see the
# team-conventions skill), and this queue polls exactly one family on one
# object kind. So a label of the wrong family is not untidiness: it takes
# the item out of BOTH lanes at once while it still looks busy, and the
# queue that would otherwise have listed it is the one that cannot see it.
# Observed 2026-09-25 on TevaServices/mach#26 (an issue left carrying
# `review/ready` and no `status/*`), where the two profiles then traded the
# same issue every tick. A deduped `FOREIGN LABEL` incident names the item,
# the label and the command that undoes it. It changes no exit code below:
# work still flows, so it is a warning riding the delivery, not a stall.
#
# MULTI-OWNER: TEAM_OWNER is the PERSONAL owner (searched with the
# profile's own gh auth state); TEAM_OWNER_ORGS (space-separated org
# names) adds org owners, each searched with that org's own App
# installation token (gh-org-token via the org-creds descriptors —
# see git-credential-hermes.sh). The results MERGE; every health check
# runs PER OWNER and the incidents name the owner they are about:
#
#   exit 6  ORG CREDS MISSING — a TEAM_OWNER_ORGS entry has no resolvable
#           org descriptor (PEM not installed / env vars missing). An org
#           queue silently missing is the dual-owner version of exit 3.
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
# Env: TEAM_OWNER (REQUIRED — the personal GitHub account whose repos
#      carry the topic tag; the script refuses to run without it rather
#      than searching all of GitHub), TEAM_OWNER_ORGS (optional, org
#      owners for the org Apps), TEAM_ORG_DEV_BOT_<ORG> (the org
#      developer bot login — author filter for org PR searches;
#      provisioning's env-lines emits it), TEAM_QUEUE_LABEL, TEAM_TOPIC
#      (default hermes-team), HERMES_HOME (for the dedupe state file),
#      TEAM_SESSION_TTL (seconds of session silence before an item stops
#      counting as held; default 600 — see team-session.py),
#      ORG_CREDS_DIR (org descriptor dir override; default resolution:
#      $HOME/org-creds, then <script_root>/home/org-creds for cron).

set -u

KIND="issues"
LABELS=""
OWNER="${TEAM_OWNER:-}"
ORGS="${TEAM_OWNER_ORGS:-}"
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

# --- org descriptor resolution (same chain as gh-org-token) ---------------
CREDS_DIR="${ORG_CREDS_DIR:-}"
if [ -z "$CREDS_DIR" ] && [ -d "${HOME:-}/org-creds" ]; then
    CREDS_DIR="$HOME/org-creds"
fi
if [ -z "$CREDS_DIR" ]; then
    script_root="$(CDPATH= cd -- "$(dirname "$0")/.." 2>/dev/null && pwd)" || script_root=""
    if [ -n "$script_root" ] && [ -d "$script_root/home/org-creds" ]; then
        CREDS_DIR="$script_root/home/org-creds"
    fi
fi

slug_of() {  # owner/org name -> slug (lowercase [a-z0-9], like gh-org-token)
    printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9'
}

ERR=$(mktemp)
OUTDIR=$(mktemp -d)
trap 'rm -rf "$ERR" "$OUTDIR"' EXIT INT TERM

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

# --- one session per work item -------------------------------------------
# team-session.py answers "is a session in this profile already working on
# this exact item?" — the question nothing could answer on 2026-09-25, when
# this queue re-injected one in-progress issue every 5 minutes while a
# Discord session was mid-work on it and both edited the same worktree.
# Seeded next to this script (image /usr/local/bin, and the profile's
# scripts dir); absent = the gate is off, which is the pre-fix behaviour.
TEAM_SESSION_PY=""
for c in /usr/local/bin/team-session.py "$(dirname "$0")/team-session.py" team-session.py; do
    if [ -f "$c" ]; then TEAM_SESSION_PY="$c"; break; fi
done

count_lines() {
    if [ -z "$1" ]; then echo 0; else printf '%s\n' "$1" | wc -l | tr -d ' '; fi
}

# Dedupe state lives per-label so the two queues never share a slot.
state_file() {
    printf '%s/team-queue-%s.state' \
        "${HERMES_HOME:-/opt/data}/cache" \
        "$LABEL_SLUG"
}

# The foreign-label guard's own slot — see foreign_incident(). Kept separate
# so neither it nor the generic slot can silence the other.
foreign_state_file() {
    printf '%s/team-queue-%s-foreign.state' \
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

# Same contract, OWN SLOT. The generic slot holds one key for the whole label
# set, so two standing incidents in one lane overwrite each other's key and
# both reprint every tick — and worse, one can SILENCE the other. The
# foreign-label guard must not be at the mercy of an unrelated standing fault
# (this lane already carries one: the unresolvable personal author login), so
# it keeps its findings in `-foreign.state`, cleared only by a healthy run.
foreign_incident() {
    if [ "$VERBOSE" -eq 1 ]; then
        echo "$@"
        return 0
    fi
    key=$(printf '%s' "$*" | cksum | tr -d ' ')
    f=$(foreign_state_file)
    mkdir -p "$(dirname "$f")" 2>/dev/null || true
    if [ -f "$f" ] && [ "$(cat "$f" 2>/dev/null)" = "$key" ]; then
        return 1
    fi
    printf '%s' "$key" > "$f" 2>/dev/null || true
    echo "$@"
    return 0
}

# --- owner loop helpers ---------------------------------------------------
# The queue runs ONCE PER OWNER with THAT owner's token: the personal
# owner uses gh's own auth state (the primary App's installation token,
# refreshed by the entrypoint); each org owner mints/uses its org App
# installation token (gh-org-token against the org descriptor). The
# wrapper below applies the CURRENT owner's token; CUR_TOKEN/EMPTY means
# personal. Every gh call inside the pipeline goes through ogh().
CUR_TOKEN=""

ogh() {  # gh with the current owner's token applied
    if [ -n "$CUR_TOKEN" ]; then
        GH_TOKEN="$CUR_TOKEN" gh "$@"
    else
        gh "$@"
    fi
}

# Resolve an owner entry to (owner, slug, token). $1 = owner name,
# $2 = slug ("" for the personal owner). Prints nothing; sets ORG_TOKEN.
# Returns 1 when an org owner has no usable credentials.
resolve_owner() {
    ORG_TOKEN=""
    [ -n "$2" ] || return 0
    if [ ! -d "$CREDS_DIR" ]; then
        fail "team-queue.sh: org owner '$1' has no org-creds directory ($CREDS_DIR missing)."
        return 1
    fi
    ORG_TOKEN="$(ORG_CREDS_DIR="$CREDS_DIR" gh-org-token "$2" 2>&1)" || {
        fail "team-queue.sh: org token for '$1' failed: $ORG_TOKEN"
        return 1
    }
    [ -n "$ORG_TOKEN" ] || { fail "team-queue.sh: empty org token for '$1'"; return 1; }
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
# reads. Deterministic, no agent turn required. Runs per owner (ogh), so
# the per-item calls carry that owner's token.
audit_handoffs() {
    printf '%s\n' "$1" | while IFS= read -r line; do
        printf '%s\n' "$line"
        key=$(printf '%s' "$line" | awk '{print $1}')
        case "$key" in */*'#'*) ;; *) continue ;; esac
        repo=${key%#*}; num=${key##*#}
        labels=$(ogh issue view "$num" --repo "$repo" --json labels \
                    --jq '[.labels[].name]|join(",")' 2>/dev/null) || continue
        case ",$labels," in *",status/in-progress,"*) ;; *) continue ;; esac
        pr=$(ogh pr list --repo "$repo" --state open --limit 50 \
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

# --- label family / object guard -----------------------------------------
# `status/*` belongs on ISSUES and `review/*` on PULL REQUESTS, and each
# queue polls ONE family on ONE object kind. So a label of the wrong family
# does not merely look untidy — it takes the item out of both lanes at once
# while it still looks busy. Observed 2026-09-25: TevaServices/mach#26 ended
# up carrying `review/ready` and no `status/*` label at all, so the
# developer's queue (issues by status/*) could not see it and neither could
# the reviewer's (PRs by review/*); the two profiles then traded the same
# issue on every tick until the container was paused by hand. Nothing
# reported it, because a misfiled label is indistinguishable from "nothing
# to do" — exactly the blind spot the HANDOFF INCOMPLETE audit above exists
# for. Deterministic: no agent turn required, the line rides the delivery
# the profile's agent already reads.
#
# ONE unfiltered search per owner, with THAT owner's token, filtered here.
# NOT one search per label: repeating `--label` means AND, not OR, so a
# four-label check would quadruple the calls this 5-minute tick makes.
audit_foreign_labels() {  # $1 = owner (for the message); uses $KIND, ogh()
    case "$KIND" in
        issues)
            # `repository.nameWithOwner` (not `url`) because the item key must
            # match the queue's own `owner/repo#N`, and the remediation needs
            # the repo by name. The label list is SORTED IN JQ: `gh search`
            # orders by relevance, not stably, and incident() dedupes on a
            # cksum of the message — an unstable order would reprint forever.
            JQ='.[] | ([.labels[].name] | map(select(startswith("review/"))) | sort | join(",")) as $f | select($f != "") | "\(.repository.nameWithOwner)#\(.number)|\($f)"'
            OWN="PR-family label on an ISSUE"
            FIX="gh issue edit"
            HINT="the PR for it is the one whose body says Closes #<num>"
            ;;
        prs)
            JQ='.[] | ([.labels[].name] | map(select(startswith("status/"))) | sort | join(",")) as $f | select($f != "") | "\(.repository.nameWithOwner)#\(.number)|\($f)"'
            OWN="ISSUE-family label on a PR"
            FIX="gh pr edit"
            HINT="the issue is the one this PR closes"
            ;;
        *) return 0 ;;
    esac
    # A failed search is NOT this guard's to report: the blind/broken checks
    # own credential faults, and crying FOREIGN LABEL on a query error would
    # be a false accusation. Stay silent and let them speak.
    FOUND=$(ogh search "$KIND" --owner "$1" --state open --limit 100 \
              --json repository,number,labels --jq "$JQ" 2>/dev/null) || return 0
    [ -n "$FOUND" ] || return 0
    # Sorted again here (LC_ALL=C, so the cron env and a human shell agree) for
    # the same dedupe reason: identical finding sets must hash identically.
    while IFS='|' read -r key labels; do
        [ -n "$key" ] || continue
        repo=${key%#*}; num=${key##*#}
        FOREIGN_LABEL="$FOREIGN_LABEL $key"
        FOREIGN_DETAIL="$FOREIGN_DETAIL
  !! FOREIGN LABEL: $key carries $labels — that is a $OWN.
     Fix: $FIX $num --repo $repo --remove-label $labels   ($HINT). Until it
     moves, the item is invisible to BOTH queues — each polls one family on
     one object kind — while it still looks busy."
    done <<EOF
$(printf '%s\n' "$FOUND" | LC_ALL=C sort)
EOF
}

# Clear the dedupe state on a healthy run, so a fault that recurs after a
# good period is reported again rather than being suppressed forever. Both
# slots: the guard's notice must come back if the label is reintroduced.
clear_state() {
    rm -f "$(state_file)" "$(foreign_state_file)" 2>/dev/null || true
}

# Clearing the dedupe state is for a HEALTHY run only. A dark gate, a
# dropped author filter or a misfiled label must keep its slot, or its
# notice reprints on every tick — the noise the dedupe exists to prevent.
clear_state_unless_degraded() {
    if [ -z "$GATE_DARK" ] && [ -z "$FILTER_FALLBACK" ] && [ -z "$FOREIGN_LABEL" ]; then
        clear_state
    fi
}

# --- 1. the queue, per owner ---------------------------------------------
# Only the PR queue is author-scoped (the reviewer reviews the dev bot's
# work); the issue queue is label-only. AUTHOR_OPT is deliberately
# unquoted at the call site — it is a pre-split "flag value" pair.
# The personal owner keeps the classic default author; an org owner uses
# TEAM_ORG_DEV_BOT_<ORGUC> (set by provisioning), or no author filter
# when that is unset (the org PRs then come from every author — a wider
# net, never a narrower one).
#
# The same principle covers a filter that is present but UNRESOLVABLE,
# which is what an author login becomes once its App loses the repos it was
# installed on. GitHub answers `author:<login>` for an unknown or unviewable
# user with "Invalid search query … The listed users cannot be searched"
# (gh exit 1) — a failure of the WHOLE query, so the queue dies with it.
# Observed 2026-09-25: the personal `hermes-dev[bot]` stopped resolving
# after its repos moved to an org, and every reviewer run died as "QUEUE
# BROKEN" while its org half was perfectly healthy. So the search is retried
# WITHOUT the filter: a wider net is recoverable, a dead queue is not. The
# notice below is what keeps the widening visible instead of silent.
if [ "$KIND" = "prs" ]; then
    AUTHOR="${AUTHOR:-hermes-dev[bot]}"
fi

run_queue_search() {  # run_queue_search <owner> <label> <author_opt>
    # $3 is a pre-split "flag value" pair (or empty) and MUST stay unquoted.
    # shellcheck disable=SC2086
    ogh search "$KIND" --owner "$1" --label "$2" --state open \
        --limit 30 --json repository,number,title,url $3 \
        --jq '.[] | "\(.repository.nameWithOwner)#\(.number)  \(.title)  \(.url)"'
}

BROKEN=""      # "<owner>|<label>|<rc>|<stderr-head>" lines
FILTER_FALLBACK=""   # "<owner>/<label>(<author>)" where the filter was dropped
BLIND_OWNERS=""
SEEN_OWNERS="" # owners whose unfiltered search saw anything
ORG_FAIL=""
# Misfiled labels ("<owner>/<repo>#<n>", for the dedupe slot) and their
# message body. Kept OUT of the queue itself: this is an audit of the repos'
# state, not of the work routed to this profile.
FOREIGN_LABEL=""
FOREIGN_DETAIL=""

SEEN_SLUGS=""
for O in $OWNER $ORGS; do
    if [ "$O" = "$OWNER" ]; then SLUG=""; else SLUG=$(slug_of "$O"); fi
    OSLUG="$SLUG"
    [ -n "$OSLUG" ] || OSLUG="personal"
    # Case variants / duplicates of an owner would mint, search and list
    # twice (same descriptor, same items) — process each slug once.
    case " $SEEN_SLUGS " in *" $OSLUG "*) continue ;; esac
    SEEN_SLUGS="$SEEN_SLUGS $OSLUG"
    [ -n "$OSLUG" ] || OSLUG="personal"

    if ! resolve_owner "$O" "$SLUG"; then
        ORG_FAIL="$ORG_FAIL $O"
        continue
    fi
    CUR_TOKEN="$ORG_TOKEN"

    # Author per owner: org owners use their own bot if declared.
    OA="$AUTHOR"
    if [ -n "$SLUG" ] && [ "$KIND" = "prs" ]; then
        # The suffix convention is uppercase + non-[A-Z0-9] -> '_'
        # ("Acme Corp" -> ACME_CORP) — the same derivation provisioning's
        # env-lines uses, so the two can never drift.
        orguc=$(printf '%s' "$O" | tr 'a-z' 'A-Z' | tr -c 'A-Z0-9_' '_')
        obot="$(eval "echo \${TEAM_ORG_DEV_BOT_${orguc}:-}")"
        [ -n "$obot" ] && OA="$obot" || OA=""
    fi
    AUTHOR_OPT=""
    [ -n "$OA" ] && AUTHOR_OPT="--author $OA"

    OQ=""
    for L in $LABELS; do
        PART=$(run_queue_search "$O" "$L" "$AUTHOR_OPT" 2>"$ERR")
        rc=$?
        if [ "$rc" -ne 0 ] && [ -n "$AUTHOR_OPT" ]; then
            # The filter itself may be what failed (see the header): retry
            # unfiltered before declaring the owner broken.
            PART=$(run_queue_search "$O" "$L" "" 2>"$ERR")
            rc=$?
            [ "$rc" -eq 0 ] && FILTER_FALLBACK="$FILTER_FALLBACK $OSLUG/$L($OA)"
        fi
        if [ "$rc" -ne 0 ]; then
            BROKEN="$BROKEN
$O|$L|$rc|$(head -3 "$ERR" | tr '\n' ' ')"
            break
        fi
        OQ="$OQ
$PART"
    done
    if [ -n "$BROKEN" ]; then continue; fi
    # Dedupe by item id, preserving the LABEL ORDER given (first label
    # wins), so resume entries stay ahead of newly-routable ones.
    OQ=$(printf '%s\n' "$OQ" | awk 'NF && !seen[$1]++')
    printf '%s\n' "$OQ" > "$OUTDIR/queue.$OSLUG"

    # --- 2. empty: is it us or is it the world? --------------------------
    # The queue is filtered by label, so an empty result is only meaningful
    # if an UNFILTERED search can see anything at all. If it cannot, the
    # problem is credentials/scope, not a quiet backlog.
    #
    # Deliberately NOT --state open: zero OPEN items is a perfectly normal
    # quiet state (a team between PRs has no open PRs), so requiring one
    # would cry wolf constantly. Searching every state asks the question we
    # actually care about — "can this token see this owner's work at all?" —
    # and a brand-new empty account is covered by the onboarding check below.
    BLIND=$(ogh search "$KIND" --owner "$O" --limit 1 \
                --json number --jq '.[] | .number' 2>/dev/null)
    if [ "$(count_lines "$BLIND")" -eq 0 ]; then
        BLIND_OWNERS="$BLIND_OWNERS $O"
        continue
    fi

    # --- 2b. the other lane's label family on this owner's open work -------
    # Scanned HERE, per owner and with that owner's token — deliberately NOT
    # after the loop. Everything after the loop can exit early on a
    # credential fault (ORG CREDS MISSING), and that incident is DEDUPED, so
    # the exit is silent: the guard would then be unreachable for EVERY owner
    # whenever ONE owner's creds fail. Observed 2026-09-25, on this very
    # guard: the 5-minute tick logged `empty stdout — silent run` while a
    # misfiled label was live, because the developer profile's org creds were
    # not resolvable in the first seconds after a container recreate and the
    # deduped credential incident exited the script before the guard ran.
    # Findings accumulate; the notice is emitted below.
    audit_foreign_labels "$O"

    # --- 3. is anything even onboarded? -----------------------------------
    REPOS=$(ogh search repos --owner "$O" --topic "$TOPIC" --limit 100 \
                --json fullName --jq '.[] | .fullName' 2>"$ERR")
    rc=$?
    if [ "$rc" -ne 0 ]; then
        # Do NOT swallow this. A failed topic query and an empty one look
        # identical, and the empty branch below reports "NOT ONBOARDED" —
        # which is how a wrong --json field name ("nameWithOwner" instead
        # of "fullName") spent its life being reported as a repo that was
        # never onboarded, while the repo WAS onboarded and the topic WAS
        # set.
        BROKEN="$BROKEN
$O|topic|$rc|$(head -2 "$ERR" | tr '\n' ' ')"
        continue
    fi
    printf '%s\n' "$REPOS" > "$OUTDIR/repos.$OSLUG"
done

# A dropped author filter WIDENS the queue, which the operator has to know
# about — a queue quietly scanning more than it was configured to is exactly
# the "looks like progress" state this script's incidents exist to name. It
# keeps its dedupe slot (see the clear_state guards below), so it is said
# once rather than every tick.
if [ -n "$FILTER_FALLBACK" ]; then
    incident "AUTHOR FILTER DROPPED  GitHub could not resolve the author login, so the PR search was re-run WITHOUT it for:$FILTER_FALLBACK
  This queue is WIDER than the configured author filter and can list PRs by
  other authors. Either fix the login, or unset it deliberately — an org
  owner with no TEAM_ORG_DEV_BOT_<ORG> already searches unfiltered, by
  design." || true
fi

# --- 1b. foreign-family labels, reported before anything can exit ---------
# Emitted BEFORE the credential exit below on purpose: that exit is deduped,
# so once the fault is known the script goes silent, and anything after it
# would never run again (see the scan's comment in the owner loop).
#
# Through its OWN dedupe slot, not the shared one. The shared slot holds a
# single key per label set, so a standing unrelated incident — a dropped
# author filter, a missing org token — would otherwise silence this notice,
# or be silenced by it, on every alternating tick. A guard that stops
# guarding because the queue happens to be complaining about something else
# is the failure this whole script exists to avoid.
if [ -n "$FOREIGN_LABEL" ]; then
    foreign_incident "FOREIGN LABEL  a label of the wrong family is on an object:$FOREIGN_DETAIL
  Each queue polls one family on one object kind, so a misfiled label makes
  the item invisible to BOTH lanes while it still looks busy — undo it as the
  line above says. Said once; it returns when the condition changes." || true
fi

if [ -n "$ORG_FAIL" ]; then
    if incident "ORG CREDS MISSING  org owner(s) with no usable App credentials:$ORG_FAIL
  The org queue is silently missing work: either the PEM is not installed
  on the host (/etc/hermes/github-app-<org>-<profile>.pem) or the org env
  vars are not in hermes-main.env. See the hermes-stack-ops skill."; then
        exit 6
    fi
    exit 0
fi

# --- one session per work item: drop what a live session already holds ----
# Per ITEM, not per profile: a live session on #26 must not fence a newly
# routable issue in another repo, and a turn that is still running keeps
# refreshing its own liveness — so the item it holds comes back the moment
# that turn ends, without a blanket hold and without a heartbeat to go
# stale. `--gate any` (not `user`): the unattended lane must stand down for
# a live user session AND for its own previous delivery still in flight —
# stacking a second wake on work already running is the same collision.
GATE_DARK=""
# --verbose is the "show me the real queue" mode, so the gate is bypassed
# there: a human debugging wants to see the items, including the ones a live
# session is holding.
if [ -n "$TEAM_SESSION_PY" ] && [ "$VERBOSE" -eq 0 ]; then
    for f in "$OUTDIR"/queue.*; do
        [ -f "$f" ] || continue
        : > "$f.kept"
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            item=$(printf '%s' "$line" | awk '{print $1}')
            case "$item" in
                # Not item-shaped (a stray line): keep it, it is not ours
                # to interpret — the caller's own audit handles those.
                */*'#'*) ;;
                *) printf '%s\n' "$line" >> "$f.kept"; continue ;;
            esac
            python3 "$TEAM_SESSION_PY" --home "${HERMES_HOME:-/opt/data}" \
                --gate any --item "$item" --quiet
            case $? in
                0) : ;;                       # live session holds it: drop
                1) printf '%s\n' "$line" >> "$f.kept" ;;
                # Unavailable: KEEP the item (work keeps flowing) but flag it.
                # A gate that silently stopped protecting is indistinguishable
                # from a quiet week — the same failure this script's exit
                # codes exist to prevent.
                *) GATE_DARK="yes"; printf '%s\n' "$line" >> "$f.kept" ;;
            esac
        done < "$f"
        mv "$f.kept" "$f"
    done
    if [ -n "$GATE_DARK" ]; then
        incident "SESSION GATE UNAVAILABLE  team-session.py could not read the profile's state.db.
  The one-session-per-item guard is DARK: this queue will hand over work a
  live session may already be working. Work is still flowing; investigate
  ${HERMES_HOME:-/opt/data}/state.db before trusting the queue again." || true
    fi
fi

QUEUE=$(cat "$OUTDIR"/queue.* 2>/dev/null | awk 'NF && !seen[$1]++')

N=$(count_lines "$QUEUE")
QUEUE=$(cat "$OUTDIR"/queue.* 2>/dev/null | awk 'NF && !seen[$1]++')

N=$(count_lines "$QUEUE")
if [ "$N" -gt 0 ]; then
    # A DARK gate or a dropped author filter keeps its dedupe slot: clearing
    # it would reprint that notice every tick — see clear_state_unless_degraded.
    clear_state_unless_degraded
    OWNERS_DISPLAY="$OWNER"
    for O in $ORGS; do OWNERS_DISPLAY="$OWNERS_DISPLAY $O"; done
    log "QUEUE OK  $N item(s) labelled $LABELS for $OWNERS_DISPLAY:"
    [ "$QUIET" -eq 1 ] || log ""
    if [ "$KIND" = "issues" ]; then
        # audit per owner, with that owner's token
        for O in $OWNER $ORGS; do
            if [ "$O" = "$OWNER" ]; then SLUG="personal"; else SLUG=$(slug_of "$O"); fi
            [ -f "$OUTDIR/queue.$SLUG" ] || continue
            if [ "$SLUG" = "personal" ]; then CUR_TOKEN=""; else
                resolve_owner "$O" "$SLUG" >/dev/null 2>&1 && CUR_TOKEN="$ORG_TOKEN" || CUR_TOKEN=""
            fi
            audit_handoffs "$(cat "$OUTDIR/queue.$SLUG")" || true
        done
    else
        printf '%s\n' "$QUEUE"
    fi
    # A broken or blind owner NEXT TO a working one must still surface
    # (its items would otherwise silently vanish from the merge) — but
    # never fail the run for it: work IS flowing.
    if [ -n "$BROKEN" ]; then
        while IFS='|' read -r o l rc esrc; do
            [ -n "$o" ] || continue
            incident "QUEUE BROKEN (partially)  owner '$o', label '$l': gh exit $rc — $esrc
  The other owner(s) listed work above; this one's query failed and its
  items are missing from the merge." || true
        done <<EOF
$BROKEN
EOF
    fi
    if [ -n "$BLIND_OWNERS" ]; then
        incident "SEARCH BLIND  while other owners listed work above, an unfiltered search sees NO $KIND at all for:$BLIND_OWNERS
  Suspect: expired/invalid token, lost scopes, or the App installation
  losing repo access — NOT an idle team." || true
    fi
    exit 0
fi

# Everything empty from here on: aggregate the per-owner health.

if [ -n "$BROKEN" ]; then
    DETAIL=""
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        o=${line%%|*}; rest=${line#*|}; l=${rest%%|*}; rest=${rest#*|}; rc=${rest%%|*}; esrc=${rest#*|}
        DETAIL="$DETAIL
  owner '$o', label '$l': gh exit $rc — $esrc"
    done <<EOF
$BROKEN
EOF
    if incident "QUEUE BROKEN  the self-pull query failed.
$DETAIL
  This is an incident, not an empty queue — the pipeline is stalled."; then
        exit 2
    fi
    exit 0
fi

# Blind only if EVERY owner is blind: one working owner means the query
# works and the world is genuinely quiet for it — the others get their
# own line in the incident.
if [ -n "$BLIND_OWNERS" ]; then
    ALLOK=""
    for O in $OWNER $ORGS; do
        case " $BLIND_OWNERS " in *" $O "*) ;; *) ALLOK="$ALLOK $O" ;; esac
    done
    if [ -z "$(printf '%s' "$ALLOK" | tr -d ' ')" ]; then
        if incident "SEARCH BLIND  the queue is empty, and so is an unfiltered search.
  gh search sees NO open $KIND at all for owner(s):$BLIND_OWNERS
  Suspect: expired/invalid token, lost scopes, or the App installation
  losing repo access — NOT an idle team."; then
            exit 3
        fi
        exit 0
    fi
    # Some owners work, some are blind, nothing labelled anywhere: fall
    # through to the onboarded checks, but mention the blind ones.
    BLIND_NOTE="SEARCH BLIND (partially): no unfiltered $KIND visible for:$BLIND_OWNERS
  The other owner(s) work fine; the blind ones suspect token/scope/lost
  App installation access."
else
    BLIND_NOTE=""
fi

# --- 3b. onboarded repos, per owner ---------------------------------------
NR_TOTAL=0
REPOS=""
for O in $OWNER $ORGS; do
    if [ "$O" = "$OWNER" ]; then SLUG="personal"; else SLUG=$(slug_of "$O"); fi
    [ -f "$OUTDIR/repos.$SLUG" ] || continue
    R=$(cat "$OUTDIR/repos.$SLUG" 2>/dev/null)
    [ -n "$(printf '%s' "$R" | tr -d '[:space:]')" ] || continue
    REPOS="$REPOS
$R"
    NR=$(count_lines "$R")
    NR_TOTAL=$((NR_TOTAL + NR))
done

if [ "$NR_TOTAL" -eq 0 ]; then
    if [ -n "$BLIND_NOTE" ]; then
        if incident "$BLIND_NOTE"; then exit 3; fi
        exit 0
    fi
    # Every owner came back blind-or-empty on repos with no incident —
    # the classic "quiet but healthy" case falls through here only when
    # searches worked and nothing is onboarded. That is exit 4.
    if incident "NOT ONBOARDED  no repo under '$OWNER'${ORGS:+ (or under$ORGS)} carries the '$TOPIC' topic.
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
# TEAM_LABEL_CHECK_TTL (seconds, default 6h). The cache is PER OWNER
# (the token that must see the labels differs per owner).
for O in $OWNER $ORGS; do
    if [ "$O" = "$OWNER" ]; then SLUG="personal"; else SLUG=$(slug_of "$O"); fi
    [ -f "$OUTDIR/repos.$SLUG" ] || continue
    REPOS=$(cat "$OUTDIR/repos.$SLUG")
    NR=$(count_lines "$REPOS")
    [ "$NR" -eq 0 ] && continue

    CACHE="$(dirname "$(state_file)")/team-labels-$SLUG-$LABEL_SLUG.cache"
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
        if [ "$SLUG" = "personal" ]; then
            resolve_owner "$O" "" >/dev/null 2>&1
            CUR_TOKEN="$ORG_TOKEN"
        else
            if ! resolve_owner "$O" "$SLUG"; then
                continue
            fi
            CUR_TOKEN="$ORG_TOKEN"
        fi
        # Every label this queue polls must exist, or the work routed
        # under it is invisible forever. A repo is only "good" when it
        # carries them ALL.
        for R in $REPOS; do
            for L in $LABELS; do
                FOUND=$(ogh label list -R "$R" --search "$L" --json name \
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
        if incident "LABEL MISSING  onboarded repo(s) under '$O' lack a routing label:$MISSING
  Work routed under that label would never reach this queue. Create it:$CREATE"; then
            exit 5
        fi
        exit 0
    fi
done

clear_state_unless_degraded
if [ "$VERBOSE" -eq 0 ]; then
    exit 0    # healthy + empty: SILENT (zero tokens — the cron default)
fi
OWNERS_DISPLAY="$OWNER"
for O in $ORGS; do OWNERS_DISPLAY="$OWNERS_DISPLAY $O"; done
log "QUEUE EMPTY  query healthy: $NR_TOTAL onboarded repo(s), all labelled"
log "  $LABELS, nothing routed to $OWNERS_DISPLAY right now."
[ -z "$BLIND_NOTE" ] || log "$BLIND_NOTE"
exit 0