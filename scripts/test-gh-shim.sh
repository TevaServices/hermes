#!/bin/sh
# Test the gh shim's owner routing — offline, no network, no Docker.
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

# --- summary ----------------------------------------------------------------
echo
if [ "$fail" -eq 0 ]; then
    echo "gh shim routing: $pass case(s) pass"
    exit 0
fi
echo "gh shim routing: $fail FAILED, $pass passed" >&2
exit 1
