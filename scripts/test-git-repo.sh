#!/bin/sh
# Offline tests for docker/hermes/git-repo.sh — no Docker, no network (a
# local file:// URL stands in for the origin). Pins the two behaviors the
# 2026-10-09 ent-network session exposed:
#   1. session worktrees live on s/<slug>, never on the default branch —
#      a commit in a session worktree must NOT advance the shared bare ref;
#   2. worktrees of a bare clone inherit core.bare=true and wedge `git
#      status` — the helper must self-heal that at creation.
# Plus the documented contract: resume reattaches the same branch, a second
# session gets its own branch, an explicit branch argument is honored, and
# ensure is idempotent.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
GIT_REPO="$SCRIPT_DIR/../docker/hermes/git-repo.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/git-repo-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# Fixtures: one origin repo with a main branch and one commit.
# ---------------------------------------------------------------------------
ORIGIN="$WORK/origin/src.git"
git init -q -b main "$ORIGIN"
git -C "$ORIGIN" config user.email t@t.invalid
git -C "$ORIGIN" config user.name t
echo one > "$ORIGIN/f"
git -C "$ORIGIN" add f
git -C "$ORIGIN" commit -qm init
URL="file://$ORIGIN"

env() { HERMES_REPOS_DIR="$WORK/repos" HERMES_WORKTREES_DIR="$WORK/wts" HERMES_SESSION_KEY="$1" sh "$GIT_REPO" "${2:-worktree}" "$URL" "${3:-}" "${4:-}"; }

expect_ok() { # desc, then command...
  desc=$1; shift
  if "$@" >/dev/null 2>&1; then :; else
    echo "FAIL: $desc"; exit 1
  fi
}
expect_eq() { # desc expected actual
  if [ "$2" != "$3" ]; then
    echo "FAIL: $1"; echo "  expected: $2"; echo "  actual:   $3"; exit 1
  fi
}

BARE="$WORK/repos$(printf '%s' "$URL" | sed 's|^file://||')"

# ---------------------------------------------------------------------------
# 1. No branch arg -> session branch s/<slug>, NOT the default branch.
# ---------------------------------------------------------------------------
OUT=$(env agent:test:discord:thread:111:222 worktree)
WT1=$(printf '%s' "$OUT" | tail -1)
[ -f "$WT1/.git" ] || { echo "FAIL: no worktree at $WT1"; exit 1; }
BR1=$(git -C "$WT1" symbolic-ref --short HEAD)
case "$BR1" in
  s/agent-test-discord-thread-111-222*) : ;;
  *) echo "FAIL: expected session branch, got '$BR1'"; exit 1 ;;
esac
expect_ok "worktree 1 git status (bare wedge self-heal)" git -C "$WT1" status --porcelain
expect_eq "worktree 1 not bare" false "$(git -C "$WT1" rev-parse --is-bare-repository)"

# 1b. A commit in the session worktree must NOT move the shared main ref.
BASE_MAIN=$(git -C "$BARE" rev-parse refs/heads/main)
echo two > "$WT1/f"
git -C "$WT1" add f
git -C "$WT1" -c user.email=t@t.invalid -c user.name=t commit -qm session-commit
expect_eq "bare main unmoved by session commit" "$BASE_MAIN" "$(git -C "$BARE" rev-parse refs/heads/main)"

# ---------------------------------------------------------------------------
# 2. Second session -> its own branch off the (fetched) default branch.
# ---------------------------------------------------------------------------
OUT2=$(env agent:test:discord:thread:333:444 worktree)
WT2=$(printf '%s' "$OUT2" | tail -1)
BR2=$(git -C "$WT2" symbolic-ref --short HEAD)
case "$BR2" in
  s/agent-test-discord-thread-333-444*) : ;;
  *) echo "FAIL: expected second session branch, got '$BR2'"; exit 1 ;;
esac
expect_ok "worktree 2 git status" git -C "$WT2" status --porcelain
expect_eq "worktree 2 sees session 1's commit is NOT on main" "$BASE_MAIN" "$(git -C "$WT2" rev-parse refs/heads/main)"

# ---------------------------------------------------------------------------
# 3. Resume: same session slug after the worktree dir is gone reattaches
#    the SAME branch (unpublished commits survive a pruned checkout).
# ---------------------------------------------------------------------------
rm -rf "$WORK/wts/"agent-test-discord-thread-111-222*
git -C "$BARE" worktree prune
OUT3=$(env agent:test:discord:thread:111:222 worktree)
WT3=$(printf '%s' "$OUT3" | tail -1)
expect_eq "resume reattaches the session branch" "$BR1" "$(git -C "$WT3" symbolic-ref --short HEAD)"
expect_eq "reattached worktree still holds the session commit" \
  "$(git -C "$BARE" rev-parse "refs/heads/$BR1")" "$(git -C "$WT3" rev-parse HEAD)"

# ---------------------------------------------------------------------------
# 4. Explicit branch argument: honored as-is (and self-healed).
# ---------------------------------------------------------------------------
OUT4=$(env agent:test:discord:thread:555:666 worktree main)
WT4=$(printf '%s' "$OUT4" | tail -1)
expect_eq "explicit branch honored" main "$(git -C "$WT4" symbolic-ref --short HEAD)"
expect_ok "explicit-branch worktree git status" git -C "$WT4" status --porcelain

# 4b. Explicit branch taken elsewhere -> session branch fallback.
OUT5=$(env agent:test:discord:thread:777:888 worktree main)
WT5=$(printf '%s' "$OUT5" | tail -1)
case "$(git -C "$WT5" symbolic-ref --short HEAD)" in
  s/agent-test-discord-thread-777-888*) : ;;
  *) echo "FAIL: taken-branch fallback did not create a session branch"; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# 5. ensure is idempotent (second call prints the same bare path).
# ---------------------------------------------------------------------------
expect_eq "ensure idempotent" \
  "$WORK/repos/$(printf '%s' "$URL" | sed 's|^file://||')" \
  "$(env agent:x ensure "$URL" >/dev/null; env agent:x ensure "$URL" | tail -1)"

echo "test-git-repo: all checks passed"
