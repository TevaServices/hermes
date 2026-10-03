#!/bin/sh
# Test the gh shim's owner routing AND its label gate — offline, no
# network, no Docker.
#
# WHY THIS EXISTS: `docker/hermes/gh` decides *which* GitHub App identity a
# command runs as, and getting it wrong is silent. The failure that
# prompted this test (2026-09-25): the reviewer's REST calls ran as the
# PERSONAL App instead of the org App, 403'd with "Resource not accessible
# by integration", and were reported up as a missing App permission — which
# sent an operator to grant something already granted. The routing decision
# is exactly the kind of thing a unit test catches and a live probe does
# not, because a live probe on a PUBLIC repo looks identical under both
# tokens (see the shim's header).
#
# The seam is GH_REAL (the shim's real binary, overridable by env): point it
# at a stub that prints the token it was handed, stub `gh-org-token` to mint
# a recognizable one, and the shim's decision becomes observable. Every case
# below is a decision the shim makes on argv + cwd alone.
#
# The LABEL GATE has its own cases (`R1 …` = the families' object rule:
# review/* refused SET on an issue, status/* refused SET on a PR —
# --remove-label always passes; `R2 …` = the reviewer fence: gh issue
# edit/close/reopen refused from the reviewer's tool-home). The reviewer
# fixture home is shaped like the real one (`…/profiles/reviewer[/home]`)
# with an EMPTY org-creds descriptor, so org routing stays inert and what
# the cases pin is the fence itself. Refusals are asserted by exit code and
# stderr marker — the stub must never be exec'd on a refused call.
#
# `R3 …` is the BODY GATE: an inline --body/-b on a whole-body write
# (issue/pr create|edit) is refused, every gh-accepted spelling, while
# --body-file, `gh issue comment --body` and non-issue/pr subcommands pass.
# The body fixtures use SINGLE quotes on purpose — inside double quotes
# this test file would run the command substitution it is testing for.
#
# `R4 …` is the CI GATE: a write that ASSERTS a verdict on a PR — the handoff
# (review/ready), the verdict (review/approved, or the `pr review --approve`
# that IS the approval), and the merge — is refused while a check is red or
# still running. It is the one gate that runs gh-real (that is how it asks),
# so its cases assert the real command did not happen rather than that the stub
# was never reached, and they cover the FAIL-OPEN half too: no checks reported,
# an unknown bucket and a query it cannot make all pass through, and a
# rejection (`review/changes`, `--request-changes`) is never gated.
#
#   $ mise run test-gh-shim      (or: sh scripts/test-gh-shim.sh)

set -u

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
shim="$here/docker/hermes/gh"
[ -f "$shim" ] || { echo "shim not found at $shim" >&2; exit 2; }
# Free syntax check — there is no shellcheck in this repo's toolchain.
sh -n "$shim" || { echo "syntax error in $shim" >&2; exit 2; }

tmp=$(mktemp -d) || exit 2
trap 'rm -rf "$tmp"' EXIT INT TERM

pass=0
fail=0

# --- stubs ------------------------------------------------------------------
mkdir -p "$tmp/bin" "$tmp/home/org-creds"

# Stand-in for gh-real: report the identity the shim chose, then stop.
# (The real CLI is what needs the network; the shim's decision does not.)
#
# The `pr checks` arm exists for the CI gate (R4), which is the ONE gate that
# has to run gh-real to ask its question — it reads this stub's answer off
# stdout the way the real gate reads gh's. $CHECKS_STUB pins the bucket list
# `--json bucket --jq …` would have printed; unset means "no checks reported"
# (also what a failed query looks like), and the real gh exits non-zero there,
# which the gate must not read as a verdict.
cat > "$tmp/bin/gh-real" <<'STUB'
#!/bin/sh
if [ "${1:-}" = pr ] && [ "${2:-}" = checks ]; then
    [ -n "${CHECKS_STUB-}" ] || exit 1
    printf '%s\n' "$CHECKS_STUB"
    exit 0
fi
printf 'token=%s\n' "${GH_TOKEN:-<none>}"
STUB

# Stand-in for the token minter. The shim only asks it for a token once a
# descriptor matched, so echoing a recognizable value is enough to prove
# which owner was routed.
cat > "$tmp/bin/gh-org-token" <<'STUB'
#!/bin/sh
printf 'ORGTOKEN:%s\n' "$1"
STUB
chmod 0755 "$tmp/bin/gh-real" "$tmp/bin/gh-org-token"

# One org with credentials: the shim matches on the descriptor's FILE NAME.
: > "$tmp/home/org-creds/acme.env"

# --- working directories ----------------------------------------------------
# A scratch dir (no git) is where an agent writes REST payloads from — the
# exact cwd that produced the incident.
mkdir -p "$tmp/scratch"
mkdir -p "$tmp/wt-org" "$tmp/wt-personal"
( cd "$tmp/wt-org" && git init -q -b main && \
  git remote add origin https://github.com/acme/widget.git )
( cd "$tmp/wt-personal" && git init -q -b main && \
  git remote add origin https://github.com/bcross/widget.git )

# --- gate fixture homes ------------------------------------------------------
# The reviewer fence keys on HOME/HERMES_HOME; give the case table real-shaped
# homes. The reviewer's carries an org-creds descriptor (one EMPTY acme.env) so
# "R1 ahead of org mint" proves the gate fires with org routing LIVE for the
# same invocation — the refusal precedes any token mint. The default home is
# what case_refused pins so an inherited HERMES_HOME cannot skew the matrix.
mkdir -p "$tmp/homes/default"
for h in reviewer; do
    mkdir -p "$tmp/homes/profiles/$h/home/org-creds"
    : > "$tmp/homes/profiles/$h/home/org-creds/acme.env"
done

# --- the case table ---------------------------------------------------------
# name | expected token | cwd | preset GH_TOKEN ("" = unset) | args…
case_run() {
    name="$1"; expect="$2"; cwd="$3"; preset="$4"; shift 4
    if [ -n "$preset" ]; then
        out=$(cd "$cwd" && env HOME="$tmp/home" GH_REAL="$tmp/bin/gh-real" \
                PATH="$tmp/bin:$PATH" GH_TOKEN="$preset" sh "$shim" "$@" 2>&1)
    else
        out=$(cd "$cwd" && env -u GH_TOKEN HOME="$tmp/home" \
                GH_REAL="$tmp/bin/gh-real" PATH="$tmp/bin:$PATH" \
                GIT_CEILING_DIRECTORIES="$tmp" sh "$shim" "$@" 2>&1)
    fi
    if [ "$out" = "$expect" ]; then
        printf 'ok   %-34s %s\n' "$name" "$out"
        pass=$((pass + 1))
    else
        printf 'FAIL %-34s expected %s, got %s\n' "$name" "$expect" "$out"
        fail=$((fail + 1))
    fi
}

# Gate cases run as a profile home (both signals set from one path).
case_run_as() {
    name="$1"; expect="$2"; cwd="$3"; phome="$4"; shift 4
    out=$(cd "$cwd" && env -u GH_TOKEN HOME="$phome/home" HERMES_HOME="$phome" \
            GH_REAL="$tmp/bin/gh-real" PATH="$tmp/bin:$PATH" \
            GIT_CEILING_DIRECTORIES="$tmp" sh "$shim" "$@" 2>&1); rc=$?
    if [ "$out" = "$expect" ]; then
        printf 'ok   %-34s %s\n' "$name" "$out"
        pass=$((pass + 1))
    else
        printf 'FAIL %-34s expected %s, got %s\n' "$name" "$expect" "$out"
        fail=$((fail + 1))
    fi
}

# Only HERMES_HOME points at the reviewer (HOME stays default) — the two
# signals are OR'd, so each direction must fire alone.
case_refused_hh_only() {
    name="$1"; marker="$2"; cwd="$3"; rh="$4"; shift 4
    out=$(cd "$cwd" && env -u GH_TOKEN HOME="$tmp/home" HERMES_HOME="$rh" \
            GH_REAL="$tmp/bin/gh-real" PATH="$tmp/bin:$PATH" \
            GIT_CEILING_DIRECTORIES="$tmp" sh "$shim" "$@" 2>&1 1>"$tmp/ref-stdout"); rc=$?
    stubhit=""
    case "$out" in *TOKEN-LEAK*) stubhit=" (stub exec'd)";; esac
    failmsg=""
    case "$out" in *"$marker"*) ;; *) failmsg="expected stderr to contain '$marker'" ;; esac
    if [ "$rc" -eq 0 ] || [ -n "$stubhit" ] || [ -n "$failmsg" ]; then
        printf 'FAIL %-34s rc=%s%s%s\n' "$name" "$rc" "$stubhit" \
            "${failmsg:+ — $failmsg (out: $(printf '%s' "$out" | head -2))}"
        fail=$((fail + 1))
    else
        printf 'ok   %-34s refused\n' "$name"
        pass=$((pass + 1))
    fi
}

# Only HOME points at the reviewer.
case_refused_home_only() {
    name="$1"; marker="$2"; cwd="$3"; rh="$4"; shift 4
    out=$(cd "$cwd" && env -u GH_TOKEN HOME="$rh/home" HERMES_HOME="$tmp/homes/default" \
            GH_REAL="$tmp/bin/gh-real" PATH="$tmp/bin:$PATH" \
            GIT_CEILING_DIRECTORIES="$tmp" sh "$shim" "$@" 2>&1 1>"$tmp/ref-stdout"); rc=$?
    stubhit=""
    case "$out" in *TOKEN-LEAK*) stubhit=" (stub exec'd)";; esac
    failmsg=""
    case "$out" in *"$marker"*) ;; *) failmsg="expected stderr to contain '$marker'" ;; esac
    if [ "$rc" -eq 0 ] || [ -n "$stubhit" ] || [ -n "$failmsg" ]; then
        printf 'FAIL %-34s rc=%s%s%s\n' "$name" "$rc" "$stubhit" \
            "${failmsg:+ — $failmsg (out: $(printf '%s' "$out" | head -2))}"
        fail=$((fail + 1))
    else
        printf 'ok   %-34s refused\n' "$name"
        pass=$((pass + 1))
    fi
}

# The gate's refusals print a corrected shape (or a routing instruction) on
# stderr and stop before gh-real. Assert exit != 0, the marker, and no exec.
# stderr starts "gh shim:" on every refusal, so that prefix rides along.
case_refused() {
    name="$1"; marker="$2"; cwd="$3"; preset="$4"; shift 4
    if [ -n "$preset" ]; then
        out=$(cd "$cwd" && env HOME="$tmp/home" HERMES_HOME="$tmp/homes/default" \
                GH_REAL="$tmp/bin/gh-real" PATH="$tmp/bin:$PATH" \
                GIT_CEILING_DIRECTORIES="$tmp" GH_TOKEN="$preset" \
                sh "$shim" "$@" 2>&1 >/dev/null); rc=$?
    else
        out=$(cd "$cwd" && env -u GH_TOKEN HOME="$tmp/home" HERMES_HOME="$tmp/homes/default" \
                GH_REAL="$tmp/bin/gh-real" PATH="$tmp/bin:$PATH" \
                GIT_CEILING_DIRECTORIES="$tmp" sh "$shim" "$@" 2>&1 1>"$tmp/ref-stdout"); rc=$?
    fi
    stubhit=""
    case "$out" in *TOKEN-LEAK*) stubhit=" (stub exec'd)";; esac
    failmsg=""
    case "$out" in "gh shim:"*) ;; *) failmsg="expected stderr to start 'gh shim:'" ;; esac
    case "$out" in *"$marker"*) ;; *) failmsg="${failmsg}${failmsg:+; }expected stderr to contain '$marker'" ;; esac
    if [ "$rc" -eq 0 ] || [ -n "$stubhit" ] || [ -n "$failmsg" ]; then
        printf 'FAIL %-34s rc=%s%s%s\n' "$name" "$rc" "$stubhit" \
            "${failmsg:+ — $failmsg (out: $(printf '%s' "$out" | head -2))}"
        fail=$((fail + 1))
    else
        printf 'ok   %-34s refused\n' "$name"
        pass=$((pass + 1))
    fi
}

# Same shape as case_refused but overrides the home env — HOME and
# HERMES_HOME are the reviewer fence's two signals, so a case names both
# explicitly. home_spec is the base path of a profile home (…/profiles/<p>).
case_refused_as() {
    name="$1"; marker="$2"; cwd="$3"; phome="$4"; shift 4
    out=$(cd "$cwd" && env -u GH_TOKEN HOME="$phome/home" HERMES_HOME="$phome" \
            GH_REAL="$tmp/bin/gh-real" PATH="$tmp/bin:$PATH" \
            GIT_CEILING_DIRECTORIES="$tmp" sh "$shim" "$@" 2>&1 1>"$tmp/ref-stdout"); rc=$?
    stubhit=""
    case "$out" in *TOKEN-LEAK*) stubhit=" (stub exec'd)";; esac
    failmsg=""
    case "$out" in *"$marker"*) ;; *) failmsg="expected stderr to contain '$marker'" ;; esac
    if [ "$rc" -eq 0 ] || [ -n "$stubhit" ] || [ -n "$failmsg" ]; then
        printf 'FAIL %-34s rc=%s%s%s\n' "$name" "$rc" "$stubhit" \
            "${failmsg:+ — $failmsg (out: $(printf '%s' "$out" | head -2))}"
        fail=$((fail + 1))
    else
        printf 'ok   %-34s refused\n' "$name"
        pass=$((pass + 1))
    fi
}

ORG="token=ORGTOKEN:acme"
PERSONAL="token=<none>"

# The incident: a REST write on an org repo, run from a scratch dir.
# The owner is in the path; `gh api` accepts no -R, so this is the only
# signal the shim has.
case_run "api path -> org" \
    "$ORG" "$tmp/scratch" "" \
    api repos/acme/widget/pulls/1/reviews -X POST --input p.json
case_run "api path, leading slash" \
    "$ORG" "$tmp/scratch" "" \
    api /repos/acme/widget/issues/1/comments --input c.json
case_run "api orgs path -> org" \
    "$ORG" "$tmp/scratch" "" \
    api orgs/acme/installations --jq .total_count
# Owner matching is case-insensitive (GitHub owners are; the slug is
# lowercased before the descriptor lookup).
case_run "api uppercase owner -> org" \
    "$ORG" "$tmp/scratch" "" \
    api repos/Acme/widget/issues
case_run "api full URL endpoint -> org" \
    "$ORG" "$tmp/scratch" "" \
    api https://api.github.com/repos/acme/widget/issues
# A query string is not part of the path, and must not defeat the match
# (it is the shape `gh api 'repos/o/r/issues?state=open'` takes).
case_run "api path with query -> org" \
    "$ORG" "$tmp/scratch" "" \
    api repos/acme/widget/issues?state=open
# The endpoint path is the TARGET, so it outranks the cwd: a personal
# worktree must not capture an org-scoped call made from it.
case_run "api path beats cwd" \
    "$ORG" "$tmp/wt-personal" "" \
    api repos/acme/widget/issues/1/comments --input c.json
# gh expands {owner}/{repo} from the cwd itself, so a placeholder must fall
# through to the cwd fallback rather than be read as an owner named
# "{owner}" — reading it literally would send a call that works today to
# the personal token.
case_run "api {owner} placeholder -> cwd" \
    "$ORG" "$tmp/wt-org" "" \
    api repos/\{owner\}/\{repo\}/pulls/1/reviews

# No owner anywhere -> personal (unchanged behaviour).
case_run "api graphql -> personal" \
    "$PERSONAL" "$tmp/scratch" "" \
    api graphql -f query='{viewer{login}}'
case_run "api unknown owner -> personal" \
    "$PERSONAL" "$tmp/scratch" "" \
    api repos/bcross/widget/issues --jq length
case_run "api unowned endpoint -> personal" \
    "$PERSONAL" "$tmp/scratch" "" \
    api user/repos --jq length
# A flag VALUE that merely contains a path must not be mistaken for one:
# this loop cannot know which args are values, so the match is anchored.
case_run "flag value not a path" \
    "$PERSONAL" "$tmp/scratch" "" \
    api user/repos -f note=repos/acme/widget
# `-X PUT` is a value too, and the common spelling for a write.
case_run "-X method value not a path" \
    "$ORG" "$tmp/scratch" "" \
    api -X PUT repos/acme/widget/topics -f topics[]=team

# The pre-existing owner sources keep working, in every -R spelling gh
# accepts (`gh -Rorg/repo pr list` is valid and was previously missed).
case_run "-R flag -> org" \
    "$ORG" "$tmp/scratch" "" \
    pr view 1 -R acme/widget
case_run "-R= form -> org" \
    "$ORG" "$tmp/scratch" "" \
    pr view 1 -R=acme/widget
case_run "attached -Rorg/repo -> org" \
    "$ORG" "$tmp/scratch" "" \
    pr view 1 -Racme/widget
case_run "--repo flag -> org" \
    "$ORG" "$tmp/scratch" "" \
    pr view 1 --repo acme/widget
case_run "--repo= form -> org" \
    "$ORG" "$tmp/scratch" "" \
    pr view 1 --repo=acme/widget
case_run "cwd origin -> org" \
    "$ORG" "$tmp/wt-org" "" \
    pr list
case_run "cwd origin personal" \
    "$PERSONAL" "$tmp/wt-personal" "" \
    pr list
# `--hostname` takes a value; the VALUE must not become the subcommand, or
# the api-path scan is skipped and the call goes personal.
case_run "--hostname value skipped" \
    "$ORG" "$tmp/scratch" "" \
    --hostname github.com api repos/acme/widget/issues

# --- the label gate (R1: family/object; R2: the reviewer fence) --------------
# Rule 1 fires profile-agnostically on SET (the default home is pinned by
# case_refused); refusals must precede org minting AND the GH_TOKEN
# passthrough, which is why the gate sits above step 3. Org-repo cases
# (acme) prove the gate coexists with live org routing — a passing acme
# call still mints ORGTOKEN; bcross cases pin the personal passthrough.

# Refused SETs — every gh-accepted spelling of the label flags, both objects.
case_refused "R1 issue review/ready separated" \
    "review/ready" "$tmp/scratch" "" \
    issue edit 23 --repo acme/widget --add-label review/ready
case_refused "R1 issue review/ready = form" \
    "review/ready" "$tmp/scratch" "" \
    issue edit 23 --repo=acme/widget --add-label=review/ready
case_refused "R1 issue comma mix refuses" \
    "review/ready" "$tmp/scratch" "" \
    issue edit 23 -R acme/widget --add-label "type/bug,review/ready"
case_refused "R1 issue -l attached form" \
    "review/ready" "$tmp/scratch" "" \
    issue edit 23 -Racme/widget -lreview/ready
case_refused "R1 pr status/in-progress" \
    "status/in-progress" "$tmp/scratch" "" \
    pr edit 31 --repo acme/widget --add-label status/in-progress
case_refused "R1 issue create --label" \
    "review/ready" "$tmp/scratch" "" \
    issue create --repo acme/widget --title t -l review/ready
case_refused "R1 pr create -l" \
    "status/ready" "$tmp/scratch" "" \
    pr create --repo acme/widget --title t -l status/ready
case_refused "R1 comma list whole-value" \
    "status/ready" "$tmp/scratch" "" \
    pr edit 31 -R acme/widget --add-label "status/ready,type/bug"
case_refused "R1 under preset GH_TOKEN" \
    "review/changes" "$tmp/scratch" "ghp_preset" \
    issue edit 23 -R acme/widget --add-label review/changes
case_refused "R1 fires before org mint" \
    "review/ready" "$tmp/scratch" "" \
    issue edit 23 --repo acme/widget --add-label review/ready
case_refused_as "R1 as reviewer, org creds live" \
    "review/ready" "$tmp/scratch" "$tmp/homes/profiles/reviewer" \
    issue edit 23 --repo acme/widget --add-label review/ready

# Pass — correct families, untouched shapes, filters, gh api.
case_run "R1 pass: status on issue (org route)" \
    "token=ORGTOKEN:acme" "$tmp/scratch" "" \
    issue edit 23 --repo acme/widget --add-label status/in-review
case_run "R1 pass: review on pr" \
    "token=<none>" "$tmp/scratch" "" \
    pr edit 31 --repo bcross/widget --add-label review/ready
case_run "R1 pass: release filing shape" \
    "token=<none>" "$tmp/scratch" "" \
    issue create --repo bcross/widget --title t --label type/bug --label status/ready
case_run "R1 pass: type/* on pr" \
    "token=<none>" "$tmp/scratch" "" \
    pr edit 31 --repo bcross/widget --add-label type/breaking
case_run "R1 pass: comma all-legal" \
    "token=ORGTOKEN:acme" "$tmp/scratch" "" \
    issue edit 23 -R acme/widget --add-label "type/bug,status/in-progress"
case_run "R1 pass: --remove-label foreign" \
    "token=<none>" "$tmp/scratch" "" \
    issue edit 26 --repo bcross/widget --remove-label review/ready
case_run "R1 pass: --label as filter" \
    "token=ORGTOKEN:acme" "$tmp/scratch" "" \
    issue list --repo acme/widget --label status/ready
case_run "R1 pass: label list subcmd" \
    "token=<none>" "$tmp/scratch" "" \
    label list --repo bcross/widget
case_run "R1 pass: pr edit -l review" \
    "token=<none>" "$tmp/scratch" "" \
    pr edit 31 --repo bcross/widget -l review/changes
case_run "R1 pass: gh api unscreened" \
    "token=ORGTOKEN:acme" "$tmp/scratch" "" \
    api repos/acme/widget/issues/23/labels -f labels[]=review/ready

# Rule 2 — the reviewer fence. Fires on issue edit/close/reopen from the
# reviewer home; PR work and reads pass; HERMES_HOME alone and HOME alone
# each fire; the default home stays open (fail-open by design).
case_refused_as "R2 reviewer issue edit refused" \
    "@hermes-planner" "$tmp/scratch" "$tmp/homes/profiles/reviewer" \
    issue edit 26 --repo acme/widget --add-label status/in-progress
case_refused_as "R2 reviewer issue close refused" \
    "@hermes-planner" "$tmp/scratch" "$tmp/homes/profiles/reviewer" \
    issue close 26 --repo acme/widget
case_refused_as "R2 reviewer issue reopen refused" \
    "@hermes-planner" "$tmp/scratch" "$tmp/homes/profiles/reviewer" \
    issue reopen 26 --repo acme/widget
case_run_as "R2 pass: reviewer issue view" \
    "token=<none>" "$tmp/scratch" "$tmp/homes/profiles/reviewer" \
    issue view 26 --repo bcross/widget
case_run_as "R2 pass: reviewer pr edit" \
    "token=<none>" "$tmp/scratch" "$tmp/homes/profiles/reviewer" \
    pr edit 31 --repo bcross/widget --add-label review/ready
case_refused_hh_only "R2 HERMES_HOME-only fires" \
    "@hermes-planner" "$tmp/scratch" "$tmp/homes/profiles/reviewer" \
    issue edit 26 --repo bcross/widget --remove-label status/ready
case_refused_home_only "R2 HOME-only fires" \
    "@hermes-planner" "$tmp/scratch" "$tmp/homes/profiles/reviewer" \
    issue edit 26 --repo bcross/widget --remove-label status/ready
case_refused_hh_only "R2 trailing-slash HERMES_HOME fires" \
    "@hermes-planner" "$tmp/scratch" "$tmp/homes/profiles/reviewer/" \
    issue edit 26 --repo bcross/widget --remove-label status/ready
case_run "R2 pass: default home issue edit" \
    "token=<none>" "$tmp/scratch" "" \
    issue edit 26 --repo bcross/widget --remove-label status/ready

# --- the body gate (R3: inline --body on a whole-body write) ----------------
# The shape that filed five corrupted issues in one repo. Refused on
# BOTH objects, every flag spelling, and from every
# profile (rule 3 is shape-based, not role-based) — including under a
# preset GH_TOKEN, since it sits above the passthrough like R1/R2.
case_refused "R3 issue edit --body separated" \
    "inline --body" "$tmp/scratch" "" \
    issue edit 43 --repo acme/widget --body '## Goal
Publish the `mach` agent. State lives in `MACH_STATE_DIR`.'
case_refused "R3 issue create --body" \
    "inline --body" "$tmp/scratch" "" \
    issue create --repo acme/widget --title t --body 'run `systemctl enable machd`'
case_refused "R3 issue edit --body= form" \
    "inline --body" "$tmp/scratch" "" \
    issue edit 43 --repo=acme/widget --body='run `mach install`'
case_refused "R3 pr edit -b separated" \
    "inline --body" "$tmp/scratch" "" \
    pr edit 44 -R acme/widget -b 'see `install.go`'
case_refused "R3 pr create -b attached" \
    "inline --body" "$tmp/scratch" "" \
    pr create --repo bcross/widget --title t -b'attach `mach`'
case_refused "R3 pr edit -b= form" \
    "inline --body" "$tmp/scratch" "" \
    pr edit 44 --repo bcross/widget -b='x `y`'
case_refused "R3 under preset GH_TOKEN" \
    "inline --body" "$tmp/scratch" "ghp_preset" \
    issue edit 43 --repo acme/widget --body 'body with a `span`'
case_refused_as "R3 as reviewer, org creds live" \
    "inline --body" "$tmp/scratch" "$tmp/homes/profiles/reviewer" \
    pr edit 44 --repo acme/widget --body 'a `span`'
# (A reviewer's `issue edit --body` is refused by R2 first — its message is
# the useful one there, since the reviewer should not be editing issues at
# all. The PR case above is the profile-agnostic proof: the reviewer fence
# is silent on PRs, so what fires is rule 3, from a non-default home.)
# A body line must not leak into the action/subcommand scan: the value of
# --body is swallowed, so `issue edit 43 --body <doc>` still reads action
# as `edit` and still routes by owner (here: refused, and NOT by the
# label gate, whose marker is a label name).
case_refused "R3 body value not an action" \
    "inline --body" "$tmp/scratch" "" \
    issue edit 43 --repo acme/widget --body 'review/ready'

# Pass — the file shape, one-line comments, and subcommands that are not
# whole-body writes. The one-line comment is the deliberate non-gate.
case_run "R3 pass: issue edit --body-file" \
    "token=<none>" "$tmp/scratch" "" \
    issue edit 43 --repo bcross/widget --body-file body.md
case_run "R3 pass: issue create --body-file" \
    "token=<none>" "$tmp/scratch" "" \
    issue create --repo bcross/widget --title t --body-file body.md
case_run "R3 pass: pr create --body-file" \
    "token=<none>" "$tmp/scratch" "" \
    pr create --repo bcross/widget --title t --body-file body.md
case_run "R3 pass: pr edit -F attached" \
    "token=<none>" "$tmp/scratch" "" \
    pr edit 44 --repo bcross/widget -Fbody.md
case_run "R3 pass: one-line issue comment" \
    "token=<none>" "$tmp/scratch" "" \
    issue comment 43 --repo bcross/widget --body 'lgtm'
case_run "R3 pass: release notes untouched" \
    "token=<none>" "$tmp/scratch" "" \
    release create v1 --repo bcross/widget --notes 'x `y` z'
case_run "R3 pass: issue create, no body flag" \
    "token=<none>" "$tmp/scratch" "" \
    issue create --repo bcross/widget --title t -l type/chore

# Passthroughs, which must never be second-guessed.
case_run "preset GH_TOKEN wins" \
    "token=ghp_explicit" "$tmp/wt-org" "ghp_explicit" \
    api repos/acme/widget/issues
case_run "gh auth * passthrough" \
    "$PERSONAL" "$tmp/wt-org" "" \
    auth status

# --- R4: the CI gate --------------------------------------------------------
# A verdict write (the handoff, the verdict, the approval, the merge) is
# refused while CI is red or still running. Unlike the gates above, this one
# RUNS gh-real (that is how it asks), so the assertion is not "the stub was
# never exec'd" — it is that the real command did not happen, which shows up
# as a missing `token=` line, plus a refusal on stderr.
#
#   $1 name  $2 CHECKS_STUB answer  $3 "refused" or the expected stdout
#   $4 marker required on stderr when refused
# CI_PRESET=… on the call presets GH_TOKEN, which must not route around the
# gate any more than it routes around the label gate (the queue scripts set it
# on every call).
case_ci() {
    name="$1"; checks="$2"; mode="$3"; marker="${4:-}"; shift 4
    # An assignment prefixed to a FUNCTION call persists after it returns (a
    # POSIX sh quirk — only a simple command's assignment is scoped), so clear
    # it here or the next case inherits this one's preset token.
    preset="${CI_PRESET:-}"; CI_PRESET=""
    if [ -n "$preset" ]; then
        out=$(cd "$tmp/scratch" && env HOME="$tmp/home" GH_TOKEN="$preset" \
                GH_REAL="$tmp/bin/gh-real" PATH="$tmp/bin:$PATH" \
                CHECKS_STUB="$checks" GIT_CEILING_DIRECTORIES="$tmp" \
                sh "$shim" "$@" 2>&1); rc=$?
    else
        out=$(cd "$tmp/scratch" && env -u GH_TOKEN HOME="$tmp/home" \
                GH_REAL="$tmp/bin/gh-real" PATH="$tmp/bin:$PATH" \
                CHECKS_STUB="$checks" GIT_CEILING_DIRECTORIES="$tmp" \
                sh "$shim" "$@" 2>&1); rc=$?
    fi
    ran=""
    case "$out" in *"token="*) ran=" (the command ran anyway)";; esac
    if [ "$mode" = refused ]; then
        hit=""
        case "$out" in *"$marker"*) ;; *) hit=" — stderr lacks '$marker'";; esac
        if [ "$rc" -eq 0 ] || [ -n "$ran" ] || [ -n "$hit" ]; then
            printf 'FAIL %-34s rc=%s%s%s\n' "$name" "$rc" "$ran" "$hit"
            fail=$((fail + 1))
        else
            printf 'ok   %-34s refused\n' "$name"
            pass=$((pass + 1))
        fi
        return
    fi
    if [ "$out" = "$mode" ]; then
        printf 'ok   %-34s %s\n' "$name" "$out"
        pass=$((pass + 1))
    else
        printf 'FAIL %-34s expected %s, got %s\n' "$name" "$mode" "$out"
        fail=$((fail + 1))
    fi
}

case_ci "R4 handoff, CI red"             "fail,pass"    refused "CI is RED" \
    pr edit 44 --repo bcross/widget --add-label review/ready
case_ci "R4 handoff, CI still running"   "pending,pass" refused "still RUNNING" \
    pr edit 44 --repo bcross/widget --add-label review/ready
case_ci "R4 verdict, CI red"             "fail"         refused "CI is RED" \
    pr edit 44 --repo bcross/widget --add-label review/approved
case_ci "R4 the approval itself"         "fail,pass"    refused "CI is RED" \
    pr review 44 --repo bcross/widget --approve
case_ci "R4 approval, cancel bucket"     "cancel"       refused "CI is RED" \
    pr review 44 --repo bcross/widget --approve
case_ci "R4 merge, CI red"               "fail"         refused "CI is RED" \
    pr merge 44 --repo bcross/widget --squash
case_ci "R4 org repo, CI red"            "fail"         refused "CI is RED" \
    pr edit 44 --repo acme/widget --add-label review/ready
CI_PRESET=ghp_explicit case_ci "R4 handoff, preset GH_TOKEN" "fail" refused "CI is RED" \
    pr edit 44 --repo bcross/widget --add-label review/ready

# The gate must never stand between the reviewer and a rejection, nor between
# a claim and the work: only the writes that ASSENT are fenced.
case_ci "R4 pass: CI green"              "pass,skipping" "token=<none>" \
    pr edit 44 --repo bcross/widget --add-label review/ready
case_ci "R4 pass: org routing intact"   "pass"          "token=ORGTOKEN:acme" \
    pr edit 44 --repo acme/widget --add-label review/ready
case_ci "R4 pass: the claim (a swap)"    "fail"          "token=ORGTOKEN:acme" \
    pr edit 44 --repo acme/widget --remove-label review/ready --add-label review/in-progress
case_ci "R4 pass: review/changes"        "fail"          "token=<none>" \
    pr edit 44 --repo bcross/widget --add-label review/changes
case_ci "R4 pass: request-changes"       "fail"          "token=<none>" \
    pr review 44 --repo bcross/widget --request-changes -b 'no'
case_ci "R4 pass: no checks reported"    ""              "token=<none>" \
    pr edit 44 --repo bcross/widget --add-label review/ready
case_ci "R4 pass: unknown bucket"        "weird"         "token=<none>" \
    pr edit 44 --repo bcross/widget --add-label review/ready
case_ci "R4 pass: no number to query"    "fail"          "token=<none>" \
    pr edit --repo bcross/widget --add-label review/ready
case_ci "R4 pass: not a verdict write"   "fail"          "token=<none>" \
    pr view 44 --repo bcross/widget

# --- summary ----------------------------------------------------------------
echo
if [ "$fail" -eq 0 ]; then
    echo "gh shim routing: $pass case(s) pass"
    exit 0
fi
echo "gh shim routing: $fail FAILED, $pass passed" >&2
exit 1