#!/bin/sh
# Offline tests for the team label protocol — the family/object invariant.
#
# WHY THIS EXISTS
#
# The team routes work by LABEL, and the labels come in three families:
#
#   status/*  -> ISSUES         (planner routes, developer claims/hands off)
#   review/*  -> PULL REQUESTS  (developer hands off, reviewer judges)
#   type/*    -> BOTH           (what the change IS: bug/feature/chore/
#                                security/breaking — it classifies, it does
#                                not hand off, so it is legal on either
#                                object and must never be called foreign)
#
# The first two are scoped to different GitHub objects, and each queue polls
# ONE family on ONE object kind, so a label of the wrong family does not
# just look untidy — it takes the item out of BOTH lanes at once while it
# still looks busy. That happened on 2026-09-25: an issue (TevaServices/
# mach#26) ended up carrying `review/ready` and no `status/*` label, the
# developer's queue could not see it and neither could the reviewer's, and
# the two profiles then traded the same issue every tick (the reviewer's
# verdict steps said "Card -> In Progress", which on a label-mechanism repo
# IS `status/in-progress` — the developer's own claim AND resume label)
# until the container was paused by hand.
#
# So these things are pinned here, all deterministically:
#
#   1. THE COMMANDS. Every `--add-label` / `--remove-label` in the shipped
#      skills and scripts targets an object its family belongs to: `gh pr …`
#      may carry review/* or type/*, `gh issue …` status/* or type/*, and a
#      label-writing command must name one of the two objects. This is the
#      mechanical version of the rule the docs state, so a future skill
#      edit that reintroduces the collision fails here rather than in
#      production.
#   2. THE NAMES. Every `status/…` / `review/…` / `type/…` literal anywhere
#      in the repo is one of the fifteen declared labels. A typo or a second
#      spelling for one state is invisible work, not a variant.
#   3. THE GUARD. team-queue.sh reports a misfiled label
#      (`!! FOREIGN LABEL`) once per condition — it must fire on a repo
#      state that has one, stay silent on a clean one, and NOT fire on a
#      `type/*` label, which is legal on both objects.
#   4. THE QUEUES' PRECEDENCE AND GATES. The developer's queue polls BUG
#      lanes before the plain ones (the two-label AND lanes are the bug
#      hoist), and the release lane emits a PR only when the approval on
#      record is a HUMAN's — a bot's approval sets review state APPROVED
#      too, so `gh search --review approved` alone would merge on the
#      reviewer bot's verdict hours before a human looked.
#
# Everything is offline: no Docker, no network, `gh` is stubbed on PATH, and
# the queue script is run from a copy so the session gate and the thread
# sweep (which want a real profile home) are simply not found.
#
# Run: $ mise run test      (or: sh scripts/test-team-labels.sh)

set -u

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
queue="$here/docker/hermes/team-queue.sh"
[ -f "$queue" ] || { echo "team-queue.sh not found at $queue" >&2; exit 2; }
# Free syntax check — there is no shellcheck in this repo's toolchain.
sh -n "$queue" || { echo "syntax error in $queue" >&2; exit 2; }

tmp=$(mktemp -d) || exit 2
trap 'rm -rf "$tmp"' EXIT INT TERM

pass=0
fail=0

ok()   { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

# --- the declared protocol --------------------------------------------------
DECLARED="status/backlog status/ready status/in-progress status/in-review
status/blocked status/done review/ready review/in-progress review/changes
review/approved type/bug type/feature type/chore type/security type/breaking"

declared_has() {
    case " $(printf '%s' "$DECLARED" | tr '\n' ' ') " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

# Files the protocol is declared in. `render.py` is included because it
# bakes the skills into the image; the two top-level docs because they are
# where an operator reads the protocol.
FILES=$(find "$here/config" "$here/docker/hermes" -type f \
            \( -name '*.md' -o -name '*.sh' -o -name '*.toml' -o -name '*.py' \) \
        ; printf '%s\n' "$here/AGENTS.md" "$here/README.md")

# --- 1. every label literal is declared ------------------------------------
# Matches real label names only: `status/*`, `review/*` and `type/*` are
# prose for the families and are deliberately not literals ([a-z-] excludes
# the `*`).
UNDECLARED=""
for label in $(grep -ohE '(status|review|type)/[a-z][a-z-]*' $FILES | sort -u); do
    declared_has "$label" || UNDECLARED="$UNDECLARED $label"
done
if [ -z "$UNDECLARED" ]; then
    ok "every label literal is one of the fifteen declared"
else
    bad "undeclared label literal(s):$UNDECLARED"
fi

# --- 2. label writes target the object their family belongs to -------------
# Runs over LOGICAL lines (backslash continuations joined), because every
# real handoff is a two-line command.
violations=$(awk -v FAMILY_OF='' '
function check(text, ln,    lab, v, tmp) {
    if (text !~ /--(add|remove)-label/) return
    # Which object does this command address?
    v = ""
    if (text ~ /gh[ \t]+pr([ \t]|$)/)    v = "pr"
    if (text ~ /gh[ \t]+issue([ \t]|$)/) {
        if (v != "") { report(ln, "names BOTH gh pr and gh issue", text); return }
        v = "issue"
    }
    tmp = text
    while (match(tmp, /(status|review|type)\/[a-z][a-z-]*/)) {
        lab = substr(tmp, RSTART, RLENGTH)
        tmp = substr(tmp, RSTART + RLENGTH)
        if (v == "") {
            report(ln, "writes " lab " without naming the object (gh pr / gh issue)", text)
            continue
        }
        # type/* is legal on EITHER object: it classifies the change rather
        # than handing it off, so both sets include it.
        if (v == "pr" && lab !~ /^(review|type)\//)
            report(ln, "gh pr may only carry review/* or type/*, not " lab, text)
        if (v == "issue" && lab !~ /^(status|type)\//)
            report(ln, "gh issue may only carry status/* or type/*, not " lab, text)
    }
}
function report(ln, why, text) {
    gsub(/[ \t]+/, " ", text)
    printf "%s:%d: %s\n", FILENAME, ln, why
}
{
    raw = $0
    line = raw
    sub(/\\[ \t]*$/, "", line)
    if (buf == "") first = FNR
    buf = buf (buf == "" ? "" : " ") line
    if (raw ~ /\\[ \t]*$/) next
    check(buf, first)
    buf = ""
}
END { if (buf != "") check(buf, first) }
' $FILES)

if [ -z "$violations" ]; then
    ok "every label write targets the object its family belongs to"
else
    bad "label writes on the wrong object/family:"
    printf '%s\n' "$violations" | sed 's/^/       /'
fi

# --- 3. the queues poll one family per object kind -------------------------
# The mapping is only real if the scripts search by it.
grep -q 'issues) \[ -n "\$LABELS" \] || LABELS="status/in-progress,type/bug status/ready,type/bug status/in-progress status/ready"' "$queue" \
    && ok "issue queue polls status/* with the BUG lanes first" \
    || bad "issue queue does not hoist bugs — expected the pair lanes BEFORE the plain ones"
# The hoist is positional, and pinning the literal above only proves the
# string; this proves the ORDER does what the string claims. A pair lane that
# came after the plain lane it overlaps would be dead: the plain lane already
# claimed the item, and the dedupe is first-label-wins.
pair_at=$(grep -o 'LABELS="status/in-progress,type/bug[^"]*"' "$queue" | head -1 \
            | awk '{ n = index($0, "status/in-progress,type/bug"); print n }')
plain_at=$(grep -o 'LABELS="status/in-progress,type/bug[^"]*"' "$queue" | head -1 \
            | awk '{ print index($0, "status/in-progress status/ready") }')
if [ "${pair_at:-0}" -gt 0 ] && [ "${plain_at:-0}" -gt "${pair_at:-0}" ]; then
    ok "bug lanes precede the plain lanes they overlap (the hoist is real)"
else
    bad "bug lanes do not precede the plain lanes — the hoist would be dead"
fi
grep -q 'prs)    \[ -n "\$LABELS" \] || LABELS="review/in-progress review/ready"' "$queue" \
    && ok "PR queue polls the review/* family" \
    || bad "PR queue does not poll exactly review/in-progress + review/ready"
# The release lane: review/approved is the REVIEWER's verdict; the human gate
# is a separate read-back. Pinning the lane proves it polls the right label.
grep -q 'releases) SEARCH_KIND="prs"; \[ -n "\$LABELS" \] || LABELS="review/approved"' "$queue" \
    && ok "release queue polls review/approved" \
    || bad "release queue does not poll exactly review/approved"
# The release lane must SEARCH PRs. `releases` is a queue kind, not a gh
# search kind — passing it to `gh search` would fail every call.
grep -q 'ogh search "\$SEARCH_KIND"' "$queue" \
    && ok "searches use SEARCH_KIND, not the queue kind" \
    || bad "a search still uses \$KIND — \`--kind releases\` would break it"

# --- 4. the guard fires, dedupes, and stays quiet when clean ---------------
# Hermetic run: the script is executed from a copy, so `$(dirname $0)` has
# neither team-thread.sh nor team-session.py — the sweep and the session gate
# are then not found and do not run (no Discord, no state.db, no python).
mkdir -p "$tmp/queue" "$tmp/bin" "$tmp/home"
cp "$queue" "$tmp/queue/team-queue.sh"

# Canned gh. Its `--jq` program is already applied here — the stub stands in
# for gh's OUTPUT, so each branch prints what the real call would have
# printed. Matched on flags, not on argument order.
cat > "$tmp/bin/gh" <<'STUB'
#!/bin/sh
args="$*"
case "$args" in
    # --- release lane: the HUMAN gate read-back ---------------------------
    # gh's --jq has already picked the most recent non-bot review, so the
    # stub prints "login|state" — the two fields the gate tests. Default is
    # "no non-bot review at all", which is the state that must NOT merge.
    *"pulls/27/reviews"*) printf '%s\n' "${STUB_HUMAN_REVIEW:-|NONE}" ;;
    # CODEOWNERS, fetched with the RAW media type — so the body is the file.
    *"contents/.github/CODEOWNERS"*|*"contents/CODEOWNERS"*)
        printf '%s\n' "${STUB_CODEOWNERS:-* @bcross}" ;;
    # --- release lane: the triage scan -----------------------------------
    *"repos/bcross/mach/tags"*) printf '%s' "${STUB_TAGS:-}" ;;
    "release list"*|*"release list -R"*) printf '%s' "${STUB_RELEASED:-}" ;;
    "run list"*"--workflow release.yml"*) printf '%s' "${STUB_RUNS:-}" ;;
    # the release lane's own search
    *"--label review/approved"*)
        printf '%s' "${STUB_APPROVED_PRS:-}"; ;;
    # --- the issue lanes, incl. the bug-first AND pairs --------------------
    # PAIR branches FIRST: a pair lane reaches gh as TWO --label flags, and
    # its argument string therefore CONTAINS the plain lane's — `case` takes
    # the first match, so a plain branch above these would swallow every pair
    # lane and the hoist would silently stop being tested.
    *"--label status/in-progress --label type/bug"*) printf '%s' "${STUB_LANE_INPROG_BUG:-}" ;;
    *"--label status/ready --label type/bug"*)       printf '%s' "${STUB_LANE_READY_BUG:-}" ;;
    # an emitted issue's labels, for the type notice
    "issue view"*) printf '%s' "${STUB_ISSUE_LABELS:-status/ready}" ;;
    # An unresolvable author fails the WHOLE query ("Invalid search query …
    # The listed users cannot be searched"). The stub reproduces that exactly,
    # because the fallback it triggers is the thing under test.
    *"--author hermes-dev[bot]"*)
        echo "Invalid search query. The listed users cannot be searched." >&2
        exit 1 ;;
    # the foreign-label scan: the one call that asks for this json shape.
    # STUB_FOREIGN=2 returns TWO items in gh's own (relevance, unstable)
    # order — deliberately reversed, to prove the guard sorts them.
    *"--json repository,number,labels"*)
        case "${STUB_FOREIGN:-0}" in
            1) printf 'bcross/mach#26|review/ready\n' ;;
            2) printf 'bcross/mach#31|review/changes\nbcross/mach#26|review/ready\n' ;;
        esac
        ;;
    # the queue search: by default nothing routed (the misfiled item is
    # invisible to this lane), but configurable for the ordering tests.
    *"--label status/in-progress"*|*"--label status/ready"*) printf '%s' "${STUB_LANE_PLAIN:-}" ;;
    # the PR queue search: one item, so a dropped filter is visible in output
    *"--label review/in-progress"*|*"--label review/ready"*)
        printf 'bcross/mach#27  Fix the thing  https://github.com/bcross/mach/pull/27\n' ;;
    # the blind check ("can this token see anything at all?")
    *"--limit 1"*"--json number"*) printf '2\n' ;;
    # the onboarded-repo topic search
    "search repos"*) printf 'bcross/mach\n' ;;
    # the label-existence check: every label it asks about exists
    "label list"*)
        for a in "$@"; do
            case "$prev" in
                --search) printf '%s\n' "$a" ;;
            esac
            prev="$a"
        done
        ;;
esac
exit 0
STUB
chmod 0755 "$tmp/bin/gh"

run_queue() {  # run_queue <foreign 0|1|2> [--verbose] [TEAM_OWNER_ORGS] [kind] [TEAM_OWNER_DEV_BOT]
    # TEAM_* is set to empty on purpose: on the deployed host compose injects
    # the stack environment into EVERY process (env_file:), so an unset-but-
    # present TEAM_OWNER_ORGS would add an org owner with no credentials here
    # — which is exactly how this test first failed in the container.
    kind="${4:-}"
    HOME="$tmp/home" HERMES_HOME="$tmp/home" TEAM_OWNER=bcross \
    TEAM_OWNER_ORGS="${3:-}" TEAM_OWNER_DEV_BOT="${5:-}" \
    STUB_FOREIGN="$1" PATH="$tmp/bin:/bin:/usr/bin" \
    sh "$tmp/queue/team-queue.sh" ${kind:+--kind "$kind"} ${2:-}
}

out=$(run_queue 1)
case "$out" in
    *"FOREIGN LABEL"*"bcross/mach#26"*"review/ready"*)
        ok "guard reports the misfiled label" ;;
    *)  bad "guard did not report a foreign label (got: $(printf '%s' "$out" | tr '\n' '|'))" ;;
esac
case "$out" in
    *"gh issue edit 26 --repo bcross/mach --remove-label review/ready"*)
        ok "guard names the undo command" ;;
    *)  bad "guard does not name the undo command" ;;
esac

# Same condition again: the notice is deduped, so a standing fault wakes the
# profile once — and a quiet run with nothing to say prints NOTHING at all
# (that is the cron contract: empty stdout is healthy-and-idle).
out=$(run_queue 1)
if [ -z "$out" ]; then
    ok "guard is deduped on the second run (silent)"
else
    bad "guard reprinted on an unchanged condition: $(printf '%s' "$out" | tr '\n' '|')"
fi

# --verbose never dedupes (it is the "show me the real state" mode).
out=$(run_queue 1 --verbose)
case "$out" in
    *"FOREIGN LABEL"*) ok "guard still reports under --verbose" ;;
    *) bad "guard silent under --verbose" ;;
esac

# gh search orders by relevance, not stably, and incident() dedupes on a hash
# of the message text — so the finding list must be sorted, or an unchanged
# fault reprints on every tick. Two items, handed over in reverse.
rm -rf "$tmp/home"; mkdir -p "$tmp/home"
out=$(run_queue 2 --verbose)
found=$(printf '%s\n' "$out" | grep -o 'bcross/mach#[0-9]*' | tr '\n' ' ')
if [ "$found" = "bcross/mach#26 bcross/mach#31 " ]; then
    ok "findings are sorted (a stable dedupe key)"
else
    bad "findings not sorted — dedupe key would churn (got: $found)"
fi

# A clean repos state must produce no accusation. Fresh HOME so the previous
# run's dedupe slot cannot mask a false positive.
rm -rf "$tmp/home"; mkdir -p "$tmp/home"
out=$(run_queue 0 --verbose)
case "$out" in
    *"FOREIGN LABEL"*) bad "guard accused a clean repo state" ;;
    *) ok "clean state gets no FOREIGN LABEL notice" ;;
esac

# An owner whose credentials fail exits the script early (ORG CREDS MISSING) —
# and THAT incident is deduped, so the exit is silent. Anything placed after it
# never runs again, which is how the guard was unreachable on the live stack
# while a misfiled label was sitting there. The notice must survive it.
rm -rf "$tmp/home"; mkdir -p "$tmp/home"
out=$(run_queue 1 --verbose "NoSuchOrg")
case "$out" in
    *"FOREIGN LABEL"*"bcross/mach#26"*)
        ok "guard reports its finding even when an owner's creds fail" ;;
    *)  bad "an unresolvable owner suppressed the guard (got: $(printf '%s' "$out" | tr '\n' '|' | head -c 200))" ;;
esac

# --- 5. the author filter is DECLARED, not assumed -------------------------
# It shipped as a hardcoded `hermes-dev[bot]` default, which was right only
# while the team's repos lived under the personal account. Once they moved to
# an org that login stopped resolving — and an unresolvable author fails the
# WHOLE query, so every reviewer run took the fallback and announced AUTHOR
# FILTER DROPPED on a queue that was working correctly. A login in the source
# cannot be fixed by an operator; a variable can.
if grep -qE '\$\{[A-Za-z_]+:-[^}]*\[bot\]\}' "$queue"; then
    bad "a bot login is hardcoded as a default: $(grep -nE '\$\{[A-Za-z_]+:-[^}]*\[bot\]\}' "$queue" | head -1)"
else
    ok "no bot login is hardcoded as a default (author filters are declared)"
fi

# The PR lane with no declared author: unfiltered, and NO complaint about it.
rm -rf "$tmp/home"; mkdir -p "$tmp/home"
out=$(run_queue 0 --verbose "" prs "")
case "$out" in
    *"AUTHOR FILTER DROPPED"*)
        bad "PR lane complains about an author filter it was never given" ;;
    *"bcross/mach#27"*)
        ok "PR lane runs unfiltered when no author is declared" ;;
    *)  bad "PR lane listed nothing (got: $(printf '%s' "$out" | tr '\n' '|' | head -c 160))" ;;
esac

# A DECLARED filter that has gone stale still widens loudly rather than dying
# — that safety net is the reason the hardcoded default could be dropped.
rm -rf "$tmp/home"; mkdir -p "$tmp/home"
out=$(run_queue 0 --verbose "" prs "hermes-dev[bot]")
case "$out" in
    *"AUTHOR FILTER DROPPED"*) ok "a stale declared filter is reported, not fatal" ;;
    *)  bad "a stale declared filter was swallowed" ;;
esac
case "$out" in
    *"bcross/mach#27"*) ok "work still flows under a stale declared filter" ;;
    *)  bad "a stale declared filter emptied the queue" ;;
esac

# --- 6. bug-first: the AND lanes hoist bugs, deterministically -------------
# Precedence here IS lane order (the queue runs one search per lane and
# dedupes first-label-wins), so the hoist is "put the pair lane first". This
# asserts the OUTCOME, not the mechanism: with all three lanes holding an
# item, the bug items must come out before the feature one.
export STUB_LANE_INPROG_BUG STUB_LANE_READY_BUG STUB_LANE_PLAIN STUB_ISSUE_LABELS
STUB_LANE_INPROG_BUG='bcross/mach#40  interrupted bug  https://x/40'
STUB_LANE_READY_BUG='bcross/mach#41  new bug  https://x/41'
STUB_LANE_PLAIN='bcross/mach#42  new feature  https://x/42'
STUB_ISSUE_LABELS='status/ready,type/bug'
rm -rf "$tmp/home"; mkdir -p "$tmp/home"
out=$(run_queue 0 --verbose "" issues)
order=$(printf '%s\n' "$out" | grep -o 'bcross/mach#4[0-9]' | awk '!seen[$0]++' | tr '\n' ' ')
if [ "$order" = "bcross/mach#40 bcross/mach#41 bcross/mach#42 " ]; then
    ok "bugs are hoisted: interrupted bug, then new bug, then the feature"
else
    bad "bug-first ordering wrong (got: '$order')"
fi

# --- 7. the type/* family is legal on BOTH objects ------------------------
# It classifies the change rather than handing it off, so a guard that called
# it foreign would fire on every correctly-labelled item. Checked at the
# SOURCE, because the stub stands in for gh's post-jq output and so cannot
# exercise the guard's own selectors.
if grep -q 'startswith("type/")' "$queue"; then
    bad "the foreign-label guard scans type/* — it is legal on both objects"
else
    ok "the foreign-label guard does not treat type/* as foreign"
fi
for fam in 'startswith("review/")' 'startswith("status/")'; do
    grep -q "$fam" "$queue" || bad "the foreign-label guard stopped scanning $fam"
done

# An emitted issue with no type/* is NAMED, not withheld: it still flows, it
# is simply not hoisted by the bug lanes and its bump will default to patch.
STUB_ISSUE_LABELS='status/ready'
STUB_LANE_INPROG_BUG=""; STUB_LANE_READY_BUG=""
STUB_LANE_PLAIN='bcross/mach#42  new feature  https://x/42'
rm -rf "$tmp/home"; mkdir -p "$tmp/home"
out=$(run_queue 0 "" "" issues)
case "$out" in
    *"TYPE MISSING"*"bcross/mach#42"*) ok "an untyped item still flows, and is named" ;;
    *) bad "no TYPE MISSING notice for an item with no type/* label" ;;
esac
STUB_ISSUE_LABELS='status/ready,type/feature'
rm -rf "$tmp/home"; mkdir -p "$tmp/home"
out=$(run_queue 0 "" "" issues)
case "$out" in
    *"TYPE MISSING"*) bad "TYPE MISSING fired on a correctly typed item" ;;
    *) ok "a typed item gets no notice" ;;
esac

# --- 8. the release lane: the gate is a HUMAN's approval ------------------
# The bug this pins: a bot's approval sets review state APPROVED too, and the
# reviewer bot approves BEFORE the human ever looks (live on mach#27:
# reviewer bot 23:00:59Z, bcross 08:22:50Z). A lane gated on
# `gh search --review approved` would merge on the bot's verdict.
export STUB_APPROVED_PRS STUB_HUMAN_REVIEW STUB_CODEOWNERS STUB_TAGS STUB_RELEASED STUB_RUNS
STUB_APPROVED_PRS='bcross/mach#27  Fix the thing  https://github.com/bcross/mach/pull/27'
STUB_CODEOWNERS='* @bcross'
STUB_TAGS=""; STUB_RELEASED=""; STUB_RUNS=""
STUB_HUMAN_REVIEW='|NONE'          # only the bot has reviewed so far
rm -rf "$tmp/home"; mkdir -p "$tmp/home"
out=$(run_queue 0 "" "" releases)
if [ -z "$out" ]; then
    ok "release lane is SILENT while only a bot has approved (zero LLM calls)"
else
    bad "release lane emitted on a bot-only approval: $(printf '%s' "$out" | tr '\n' '|' | head -c 160)"
fi
out=$(run_queue 0 --verbose "" releases)
case "$out" in
    *"AWAITING HUMAN"*) ok "under --verbose it names what it is waiting for" ;;
    *) bad "release lane did not explain why it emitted nothing" ;;
esac

STUB_HUMAN_REVIEW='bcross|APPROVED'
rm -rf "$tmp/home"; mkdir -p "$tmp/home"
out=$(run_queue 0 "" "" releases)
case "$out" in
    *"Fix the thing"*) ok "a human approval releases the PR" ;;
    *) bad "release lane did not emit a human-approved PR (got: $(printf '%s' "$out" | tr '\n' '|' | head -c 160))" ;;
esac

# Approved, but by someone who is not a code owner: still not releasable.
# Asserted on the item's TITLE, not its `owner/repo#N`: the CODEOWNER
# notice legitimately NAMES the item, so a key-based check would read its
# own warning as a release and pass for the wrong reason.
STUB_HUMAN_REVIEW='randomreviewer|APPROVED'
rm -rf "$tmp/home"; mkdir -p "$tmp/home"
out=$(run_queue 0 "" "" releases)
case "$out" in
    *"Fix the thing"*) bad "release lane emitted a PR approved by a non-code-owner" ;;
    *) ok "a non-code-owner approval does not release the PR" ;;
esac
case "$out" in
    *"CODEOWNER APPROVAL MISSING"*) ok "and it says so, rather than looking idle" ;;
    *) bad "a non-code-owner approval was swallowed silently" ;;
esac

# A CODEOWNERS the token cannot read must not become a silent pass: the
# non-bot approval still gates, and the run must not claim to have checked.
STUB_HUMAN_REVIEW='bcross|APPROVED'
STUB_CODEOWNERS=''
rm -rf "$tmp/home"; mkdir -p "$tmp/home"
out=$(run_queue 0 "" "" releases)
case "$out" in
    *"bcross/mach#27"*) ok "an unreadable CODEOWNERS falls back to the non-bot approval" ;;
    *) bad "an unreadable CODEOWNERS blocked a legitimately approved PR" ;;
esac
STUB_CODEOWNERS='* @bcross'

# --- 9. release triage: a stuck release is reported, once -----------------
STUB_APPROVED_PRS=""; STUB_HUMAN_REVIEW='|NONE'
STUB_TAGS='v0.9.0'
rm -rf "$tmp/home"; mkdir -p "$tmp/home"
out=$(run_queue 0 "" "" releases)
case "$out" in
    *"RELEASE TAGGED, NOT PUBLISHED"*"bcross/mach#v0.9.0"*)
        ok "a tag with no release and no run in flight is reported" ;;
    *) bad "stuck tag not reported (got: $(printf '%s' "$out" | tr '\n' '|' | head -c 160))" ;;
esac
out=$(run_queue 0 "" "" releases)
if [ -z "$out" ]; then
    ok "the triage finding is deduped on the second run"
else
    bad "triage finding reprinted unchanged: $(printf '%s' "$out" | tr '\n' '|' | head -c 160)"
fi

# A run still IN FLIGHT is the resumable "waiting on CI" state, not a fault —
# otherwise a 6-minute release workflow would wake the agent every tick.
rm -rf "$tmp/home"; mkdir -p "$tmp/home"
STUB_RUNS='RUNNING v0.9.0'
out=$(run_queue 0 "" "" releases)
if [ -z "$out" ]; then
    ok "a release run still in flight is not a finding"
else
    bad "an in-flight release run was reported as stuck"
fi

# A workflow that ENDED badly names the conclusion and the run URL.
rm -rf "$tmp/home"; mkdir -p "$tmp/home"
STUB_RUNS='BAD v0.9.0 failure https://github.com/bcross/mach/actions/runs/1'
out=$(run_queue 0 "" "" releases)
case "$out" in
    *"RELEASE WORKFLOW FAILED"*"bcross/mach#v0.9.0"*"failure"*)
        ok "a failed release workflow is reported with its conclusion" ;;
    *) bad "failed release workflow not reported (got: $(printf '%s' "$out" | tr '\n' '|' | head -c 200))" ;;
esac
unset STUB_APPROVED_PRS STUB_HUMAN_REVIEW STUB_CODEOWNERS STUB_TAGS STUB_RELEASED STUB_RUNS
unset STUB_LANE_INPROG_BUG STUB_LANE_READY_BUG STUB_LANE_PLAIN STUB_ISSUE_LABELS

# --- summary ---------------------------------------------------------------
if [ "$fail" -eq 0 ]; then
    printf '\n%s passed\n' "$pass"
    exit 0
fi
printf '\n%d FAILED, %d passed\n' "$fail" "$pass" >&2
exit 1
