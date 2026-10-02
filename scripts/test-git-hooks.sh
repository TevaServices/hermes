#!/bin/sh
# Offline tests for the git hooks the entrypoint installs
# (docker/hermes/git-hooks/, behind every tool-home's global
# core.hooksPath).
#
# WHY THIS EXISTS
#
# Two events in the team's history are pinned here. The DCO hook exists
# because a policy job no local run mirrors once failed a PR (the
# prepare-commit-msg hook fixed the class); the pre-push hook exists
# because a PR once failed, four review rounds in a row, from committed
# pushes: a developer `git push` can never carry a signature (a GitHub
# App bot has no account settings, and GitHub only verifies commits it
# creates itself through the API), so every push became a full branch
# rewrite later — a forced replay that dismissed every standing
# approval, re-ran CI, and cost the human another approval of
# byte-identical content. The hook refuses the push at the moment of
# misuse. These tests pin both the refusal and the DCO hook's
# never-fail contract.
#
#   1. THE REFS. A `git push` against a github.com remote (https, ssh,
#      git@ spellings) exits 1 and names git-publish.py and the escape;
#      a non-GitHub remote passes through.
#   2. THE ESCAPE. HERMES_ALLOW_PUSH=1 passes a GitHub push — the escape
#      is documented in the refusal, not discoverable by brute force.
#   3. THE DCO HOOK'S CONDITION. A repo that declares the rule
#      (CONTRIBUTING.md or .github/) gets the trailer, signed as the
#      commit's own committer ident; a repo that does not keeps its
#      message byte-identical; a merge commit and an already-signed
#      message are left alone; every path exits 0 (never fails a
#      commit).
#   4. THE INSTALL. Both hook files are executable in the image dir and
#      the Dockerfile chmods both — a hook that lands 0644 silently does
#      nothing, and a hook git does not exec cannot announce the fact.
#
# The prepare-commit-msg cases run REAL commits in throwaway repos, with
# core.hooksPath pointed at the image hooks dir — the hook exercises the
# same path production does (git rev-parse --show-toplevel, git var).
# The pre-push cases invoke the hook directly; it calls no git.
#
# Offline: no Docker, no network. Run: $ mise run test
#                                       (or: sh scripts/test-git-hooks.sh)

set -u

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
hooks="$here/docker/hermes/git-hooks"
[ -d "$hooks" ] || { echo "git-hooks dir not found at $hooks" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "git not on PATH" >&2; exit 2; }

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
# 0. The install
# ---------------------------------------------------------------------------
for hook_name in prepare-commit-msg pre-push; do
    [ -x "$hooks/$hook_name" ] \
        && ok "$hook_name: executable in the image hooks dir" \
        || bad "$hook_name: not executable (git will silently skip it: chmod +x)"
done
chmodline=$(grep -A1 'chmod 0755 /opt/hermes-git-hooks/prepare-commit-msg' \
                "$here/docker/hermes/Dockerfile")
printf '%s\n' "$chmodline" | grep -q 'pre-push' \
    && ok "Dockerfile chmods both hooks" \
    || bad "Dockerfile chmod is missing a hook name (a 0644 hook never runs)"

# ---------------------------------------------------------------------------
# 1. pre-push: the refusal
# ---------------------------------------------------------------------------
ref_line="refs/heads/feature 0000000000000000000000000000000000000000 refs/heads/feature 0000000000000000000000000000000000000000"

for url in 'https://github.com/owner/repo.git' \
           'git@github.com:owner/repo.git' \
           'ssh://git@github.com/owner/repo.git' \
           'github.com:owner/repo.git'; do
    printf '%s\n' "$ref_line" \
        | sh "$hooks/pre-push" origin "$url" 2>"$tmp/pp.err"
    check "pre-push refuses $url" 1 "$?"
    grep -q 'git-publish.py' <"$tmp/pp.err" \
        && ok "refusal for $url names git-publish.py" \
        || bad "refusal for $url does not name the publish path"
    grep -q 'HERMES_ALLOW_PUSH' <"$tmp/pp.err" \
        && ok "refusal for $url names the escape" \
        || bad "refusal for $url does not name the escape"
done

# The escape: documented, exact, effective.
printf '%s\n' "$ref_line" \
    | HERMES_ALLOW_PUSH=1 sh "$hooks/pre-push" origin \
        'https://github.com/owner/repo.git' 2>/dev/null
check "HERMES_ALLOW_PUSH=1 passes the push" 0 "$?"

# Non-GitHub remotes pass (a push there needs no publish machinery).
printf '%s\n' "$ref_line" \
    | sh "$hooks/pre-push" origin 'https://gitlab.com/owner/repo.git' 2>/dev/null
check "non-GitHub remote passes" 0 "$?"

# Empty stdin (a push that moves nothing): the URL check still governs.
printf '' | sh "$hooks/pre-push" origin 'https://github.com/owner/repo.git' 2>/dev/null
check "empty stdin is still a github.com refusal" 1 "$?"

# ---------------------------------------------------------------------------
# 2. prepare-commit-msg: conditional sign-off over REAL commits
# ---------------------------------------------------------------------------
new_repo() {  # new_repo <dir>: init an empty repo with a test identity
    r="$1"; rm -rf "$r"; mkdir -p "$r"; cd "$r" || exit 2
    git init -q -b main
    git config user.name  "Probe Bot"
    git config user.email "probe-bot@example.com"
}

# Repo that declares the DCO rule in CONTRIBUTING.md -> trailer added.
new_repo "$tmp/dco-repo"
printf '# Contributing\n\nSign your work (DCO): a Signed-off-by line is required.\n' > CONTRIBUTING.md
echo a > f && git add -A
git -c core.hooksPath="$hooks" commit -qm "first fix"
n=$(git log -1 --format=%B | grep -c '^Signed-off-by: ')
check "DCO repo: commit gains the sign-off" 1 "$n"
who=$(git log -1 --format='%(trailers:key=Signed-off-by,valueonly)')
check "sign-off matches the commit's own committer ident" \
    "Probe Bot <probe-bot@example.com>" "$who"

# Already-signed message -> exactly one trailer (git commit -s idempotent).
echo b > f && git add -A
git -c core.hooksPath="$hooks" commit -qm "second fix" -s
n=$(git log -1 --format=%B | grep -c '^Signed-off-by: ')
check "already-signed commit gets exactly one trailer" 1 "$n"

# Merge commits are exempt (their parents carry their own sign-offs).
git checkout -qb side
echo c > g && git add -A && git -c core.hooksPath="$hooks" commit -qm "side"
git checkout -qm main
echo d > f && git add -A && git -c core.hooksPath="$hooks" commit -qm "main"
git -c core.hooksPath="$hooks" merge -q --no-edit side 2>/dev/null
n=$(git log -1 --format=%B | grep -c 'Signed-off-by:' || true)
n=${n:-0}
check "merge commit is not touched" 0 "$n"

# Repo whose rule is declared only in .github (workflow detection path).
new_repo "$tmp/gh-repo"
mkdir -p .github/workflows
printf 'name: ci\n- run: check for Signed-off-by\n' > .github/workflows/ci.yml
echo a > f && git add -A
git -c core.hooksPath="$hooks" commit -qm "workflow-declared work"
n=$(git log -1 --format=%B | grep -c '^Signed-off-by: ')
check "repo declaring DCO in .github: sign-off added" 1 "$n"

# Repo with NO DCO evidence -> message byte-identical.
new_repo "$tmp/plain-repo"
echo a > f && git add -A
git -c core.hooksPath="$hooks" commit -qm "plain work"
n=$(git log -1 --format=%B | grep -c 'Signed-off-by:' || true)
n=${n:-0}
check "repo without DCO evidence: message stays clean" 0 "$n"

# Every commit above succeeded — the DCO hook never fails the commit it
# rides on; make the fact explicit so the contract is re-checked whenever
# this suite runs.
ok "every commit above succeeded (the DCO hook never fails a commit)"

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------
if [ "$fail" -eq 0 ]; then
    printf '\n%d passed\n' "$pass"
    exit 0
fi
printf '\n%d FAILED, %d passed\n' "$fail" "$pass" >&2
exit 1