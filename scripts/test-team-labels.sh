#!/bin/sh
# Offline tests for the team label protocol — the family/object invariant.
#
# WHY THIS EXISTS
#
# The team routes work by LABEL, and the labels come in two families that
# are scoped to different GitHub objects:
#
#   status/*  -> ISSUES         (planner routes, developer claims/hands off)
#   review/*  -> PULL REQUESTS  (developer hands off, reviewer judges)
#
# Each queue polls ONE family on ONE object kind, so a label of the wrong
# family does not just look untidy — it takes the item out of BOTH lanes at
# once while it still looks busy. That happened on 2026-09-25: an issue
# (TevaServices/mach#26) ended up carrying `review/ready` and no `status/*`
# label, the developer's queue could not see it and neither could the
# reviewer's, and the two profiles then traded the same issue every tick
# (the reviewer's verdict steps said "Card -> In Progress", which on a
# label-mechanism repo IS `status/in-progress` — the developer's own claim
# AND resume label) until the container was paused by hand.
#
# So two things are pinned here, both deterministically:
#
#   1. THE COMMANDS. Every `--add-label` / `--remove-label` in the shipped
#      skills and scripts targets the object its family belongs to:
#      `gh pr …` may only carry review/*, `gh issue …` only status/*, and a
#      label-writing command must name one of the two. This is the
#      mechanical version of the rule the docs state, so a future skill
#      edit that reintroduces the collision fails here rather than in
#      production.
#   2. THE NAMES. Every `status/…` / `review/…` literal anywhere in the repo
#      is one of the ten declared labels. A typo or a second spelling for
#      one state is invisible work, not a variant.
#   3. THE GUARD. team-queue.sh reports a misfiled label
#      (`!! FOREIGN LABEL`) once per condition — it must fire on a repos
#      state that has one and stay silent (and deduped) otherwise.
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
review/approved"

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
# Matches real label names only: `status/*` and `review/…` are prose for the
# family and are deliberately not literals ([a-z-] excludes both).
UNDECLARED=""
for label in $(grep -ohE '(status|review)/[a-z][a-z-]*' $FILES | sort -u); do
    declared_has "$label" || UNDECLARED="$UNDECLARED $label"
done
if [ -z "$UNDECLARED" ]; then
    ok "every label literal is one of the ten declared"
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
    if (text ~ /gh[ \t]+pr([ \t]|$)/)    v = "review"
    if (text ~ /gh[ \t]+issue([ \t]|$)/) {
        if (v != "") { report(ln, "names BOTH gh pr and gh issue", text); return }
        v = "status"
    }
    tmp = text
    while (match(tmp, /(status|review)\/[a-z][a-z-]*/)) {
        lab = substr(tmp, RSTART, RLENGTH)
        tmp = substr(tmp, RSTART + RLENGTH)
        if (v == "") {
            report(ln, "writes " lab " without naming the object (gh pr / gh issue)", text)
            continue
        }
        if (v == "review" && lab !~ /^review\//)
            report(ln, "gh pr may only carry review/*, not " lab, text)
        if (v == "status" && lab !~ /^status\//)
            report(ln, "gh issue may only carry status/*, not " lab, text)
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
grep -q 'issues) \[ -n "\$LABELS" \] || LABELS="status/in-progress status/ready"' "$queue" \
    && ok "issue queue polls the status/* family" \
    || bad "issue queue does not poll exactly status/in-progress + status/ready"
grep -q 'prs)    \[ -n "\$LABELS" \] || LABELS="review/in-progress review/ready"' "$queue" \
    && ok "PR queue polls the review/* family" \
    || bad "PR queue does not poll exactly review/in-progress + review/ready"

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
    # the foreign-label scan: the one call that asks for this json shape.
    # STUB_FOREIGN=2 returns TWO items in gh's own (relevance, unstable)
    # order — deliberately reversed, to prove the guard sorts them.
    *"--json repository,number,labels"*)
        case "${STUB_FOREIGN:-0}" in
            1) printf 'bcross/mach#26|review/ready\n' ;;
            2) printf 'bcross/mach#31|review/changes\nbcross/mach#26|review/ready\n' ;;
        esac
        ;;
    # the queue search: nothing routed (the misfiled item is invisible)
    *"--label status/in-progress"*|*"--label status/ready"*) ;;
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

run_queue() {  # run_queue <foreign 0|1> [--verbose]
    HOME="$tmp/home" HERMES_HOME="$tmp/home" TEAM_OWNER=bcross \
    STUB_FOREIGN="$1" PATH="$tmp/bin:/bin:/usr/bin" \
    sh "$tmp/queue/team-queue.sh" ${2:-}
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

# --- summary ---------------------------------------------------------------
if [ "$fail" -eq 0 ]; then
    printf '\n%s passed\n' "$pass"
    exit 0
fi
printf '\n%d FAILED, %d passed\n' "$fail" "$pass" >&2
exit 1
