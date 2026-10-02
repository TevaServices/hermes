#!/bin/sh
# Test the gh shim — owner routing and the label gate. Offline, no network,
# no Docker.
#
# WHY THIS EXISTS: `docker/hermes/gh` decides *which* GitHub App identity a
# command runs as, and whether an label-edit call is even legal, and
# getting either wrong is silent. The routing failure that
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
cat > "$tmp/bin/gh-real" <<'STUB'
#!/bin/sh
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

# Passthroughs, which must never be second-guessed.
case_run "preset GH_TOKEN wins" \
    "token=ghp_explicit" "$tmp/wt-org" "ghp_explicit" \
    api repos/acme/widget/issues
case_run "gh auth * passthrough" \
    "$PERSONAL" "$tmp/wt-org" "" \
    auth status

# --- the label gate ----------------------------------------------------------
# The gate keyed on subcmd+action+label flags: families are object-scoped
# (status/* issues, review/* PRs, type/* both), and the reviewer profile
# may not edit issues at all. A refusal exits non-zero and never reaches
# gh-real, with the corrective command in the message.
#
# run_shim is the flexible runner behind the new helpers: cwd as $1,
# profile home as $SHIM_HOME (like every profile's tool-home env), optional
# HERMES_HOME as $SHIM_HERMES_HOME (empty = the default profile's /opt/data
# situation — the variable is set but empty, which the shim must treat as
# no match), optional preset token as $2.

SHIM_HOME="$tmp/home"
SHIM_HERMES_HOME=""

run_shim() { # cwd | preset-GH_TOKEN ("" = unset) | args…
    cwd="$1"; preset="$2"; shift 2
    if [ -n "$preset" ]; then
        out=$(cd "$cwd" && env HOME="$SHIM_HOME" \
                HERMES_HOME="${SHIM_HERMES_HOME:-}" \
                GH_REAL="$tmp/bin/gh-real" PATH="$tmp/bin:$PATH" \
                GIT_CEILING_DIRECTORIES="$tmp" GH_TOKEN="$preset" \
                sh "$shim" "$@" 2>&1)
    else
        out=$(cd "$cwd" && env -u GH_TOKEN HOME="$SHIM_HOME" \
                HERMES_HOME="${SHIM_HERMES_HOME:-}" \
                GH_REAL="$tmp/bin/gh-real" PATH="$tmp/bin:$PATH" \
                GIT_CEILING_DIRECTORIES="$tmp" \
                sh "$shim" "$@" 2>&1)
    fi
    run_rc=$?
}

expect_pass() { # name | expected output
    name="$1"; want="$2"
    if [ "$run_rc" -eq 0 ] && [ "$out" = "$want" ]; then
        printf 'ok   %-34s %s\n' "$name" "$out"
        pass=$((pass + 1))
    else
        printf 'FAIL %-34s rc=%s expected %s, got %s\n' "$name" "$run_rc" "$want" "$out"
        fail=$((fail + 1))
    fi
}

expect_refuse() { # name | marker substring
    name="$1"; marker="$2"
    if [ "$run_rc" -ne 0 ] && printf '%s' "$out" | grep -qF -- "$marker"; then
        printf 'ok   %-34s refused: %s\n' "$name" "$marker"
        pass=$((pass + 1))
    else
        printf 'FAIL %-34s rc=%s expected refusal with %s, got %s\n' \
            "$name" "$run_rc" "$marker" "$out"
        fail=$((fail + 1))
    fi
}

# Reviewer tool-home with an org descriptor (the fence must not stop the
# reviewer's legitimate PR work or issue reads — those still route).
mkdir -p "$tmp/profiles/reviewer/home/org-creds"
: > "$tmp/profiles/reviewer/home/org-creds/acme.env"

# Rule 1: foreign family -> refuse, on both objects and in every spelling.
SHIM_HOME="$tmp/home"; SHIM_HERMES_HOME=""
run_shim "$tmp/scratch" "" issue edit 7 --repo acme/widget --add-label review/ready
expect_refuse "issue edit review/* refused" "PR-family label on an ISSUE"
run_shim "$tmp/scratch" "" issue edit 7 --repo acme/widget --remove-label review/changes
expect_refuse "issue edit --remove-label refused" "PR-family label on an ISSUE"
run_shim "$tmp/scratch" "" issue edit 7 --repo acme/widget --add-label 'type/bug,review/ready'
expect_refuse "comma list flagged member" "PR-family label on an ISSUE"
run_shim "$tmp/scratch" "" issue edit 7 --repo acme/widget --add-label=review/ready
expect_refuse "--add-label= attached form" "PR-family label on an ISSUE"
run_shim "$tmp/scratch" "" pr edit 9 --repo acme/widget --add-label status/in-progress
expect_refuse "pr edit status/* refused" "ISSUE-family label on a PR"
run_shim "$tmp/scratch" "" pr create -R acme/widget --label status/ready
expect_refuse "pr create status/* refused" "ISSUE-family label on a PR"
run_shim "$tmp/scratch" "" issue create -R acme/widget -l review/ready
expect_refuse "issue create -l shorthand" "PR-family label on an ISSUE"
run_shim "$tmp/scratch" "" pr create -R acme/widget -lstatus/ready
expect_refuse "pr create -l attached form" "ISSUE-family label on a PR"

# Rule 1 pass-throughs: correct families, filters, reads, label/labels mgmt.
run_shim "$tmp/scratch" "" issue edit 7 --repo acme/widget --add-label status/in-review
expect_pass "issue edit status/* -> org" "$ORG"
run_shim "$tmp/wt-org" "" pr edit 9 --add-label review/approved --remove-label review/changes
expect_pass "pr edit review/* -> org" "$ORG"
run_shim "$tmp/scratch" "" issue create -R acme/widget --label type/bug --label status/ready
expect_pass "release issue filing -> org" "$ORG"
run_shim "$tmp/scratch" "" issue create -R acme/widget --label 'type/bug,type/security'
expect_pass "release type/* comma list" "$ORG"
run_shim "$tmp/wt-personal" "" issue edit 1 --add-label status/ready
expect_pass "personal repo correct family" "$PERSONAL"
run_shim "$tmp/scratch" "" issue list -R acme/widget --label status/ready
expect_pass "--label as filter -> org" "$ORG"
run_shim "$tmp/scratch" "" label list -R acme/widget
expect_pass "gh label list -> org" "$ORG"
run_shim "$tmp/scratch" "" search prs --label review/approved
expect_pass "search label filter -> personal" "$PERSONAL"
run_shim "$tmp/scratch" "" api -X PUT repos/acme/widget/issues/1/labels --input p.json
expect_pass "api labels PUT (non-gate) -> org" "$ORG"

# Rule 2: the reviewer fence — fail-closed only where the profile is known.
SHIM_HERMES_HOME=""
SHIM_HOME="$tmp/profiles/reviewer/home"
run_shim "$tmp/scratch" "" issue edit 7 --repo acme/widget --add-label status/ready
expect_refuse "reviewer issue edit refused" "the reviewer never edits an issue"
run_shim "$tmp/scratch" "" issue close 7 --repo acme/widget
expect_refuse "reviewer issue close refused" "the reviewer never edits an issue"
run_shim "$tmp/scratch" "" issue view 7 --repo acme/widget
expect_pass "reviewer issue view -> org" "$ORG"
run_shim "$tmp/scratch" "" pr edit 9 --repo acme/widget --add-label review/approved
expect_pass "reviewer pr edit -> org" "$ORG"
# HERMES_HOME alone identifies the profile too (the gateway drops HERMES_HOME
# from cron children while the tool-home HOME may be ambiguous).
SHIM_HOME="$tmp/home"
SHIM_HERMES_HOME="$tmp/profiles/reviewer"
run_shim "$tmp/scratch" "" issue edit 7 --repo acme/widget
expect_refuse "HERMES_HOME-only fence" "the reviewer never edits an issue"
# Default profile: unset-signal HERMES_HOME must fail open...
SHIM_HERMES_HOME=""
run_shim "$tmp/scratch" "" issue edit 7 --repo acme/widget --add-label status/ready
expect_pass "default profile issue edit" "$ORG"
# ...and a preset GH_TOKEN must not route around the gate (the gate sits
# above the GH_TOKEN passthrough on purpose).
SHIM_HOME="$tmp/profiles/reviewer/home"; SHIM_HERMES_HOME=""
run_shim "$tmp/scratch" "ghp_explicit" issue edit 7 --repo acme/widget
expect_refuse "fence above GH_TOKEN passthrough" "the reviewer never edits an issue"

# --- summary ----------------------------------------------------------------
echo
if [ "$fail" -eq 0 ]; then
    echo "gh shim routing: $pass case(s) pass"
    exit 0
fi
echo "gh shim routing: $fail FAILED, $pass passed" >&2
exit 1
