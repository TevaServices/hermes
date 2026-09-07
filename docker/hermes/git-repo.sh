#!/bin/sh
# Central git repos + per-SESSION worktrees.
#
# Layout (all on the shared agent volume, one runtime uid):
#   $HERMES_REPOS_DIR (default /opt/data/repos)
#     <host>/<owner>/<repo>.git    ONE bare clone per repo — the canonical
#                                  shared object store + refs. Nobody works
#                                  in here directly.
#   $HERMES_WORKTREES_DIR (default /opt/data/worktrees)
#     <session-slug>/<repo>/       ONE worktree per (session, repo). The
#                                  slug comes from HERMES_SESSION_KEY, which
#                                  the gateway bridges into every tool
#                                  subprocess (agent:<profile>:<platform>:
#                                  <lane>:<id>...), so sessions never share
#                                  checkouts — not even two turns of the
#                                  same profile on the same repo.
#
# Rules:
#   - Profiles/sessions NEVER clone into their own space and NEVER commit
#     in the central bare repo — they add worktrees.
#   - Git refuses to check the same branch out in two worktrees. If the
#     requested branch is already checked out anywhere, the worktree gets
#     its own branch `s/<slug>` created from that branch instead; push a
#     session branch with `git push origin HEAD:<branch>`.
#
# Usage:
#   git-repo.sh ensure <git-url>
#       Idempotent central bare clone; prints the bare repo's path.
#   git-repo.sh worktree <git-url> [branch] [dest]
#       ensure + `git worktree add` for THIS session; prints the worktree
#       path. Defaults: branch = remote default branch, dest =
#       $HERMES_WORKTREES_DIR/<session-slug>/<repo>. Pass an explicit dest
#       for a second checkout within the same session.
#   git-repo.sh list
#       Every central repo and its registered worktrees.
#   git-repo.sh prune [--days N]
#       Drop worktrees whose session directory is older than N days
#       (default 14), then `git worktree prune` on every bare repo.
#       Session dirs are cheap; run this from cron weekly.
#
# Requires HERMES_SESSION_KEY (present in all gateway-spawned tool
# subprocesses; falls back to "shared" for cron/CLI contexts without one).
set -eu

REPOS="${HERMES_REPOS_DIR:-/opt/data/repos}"
WORKTREES="${HERMES_WORKTREES_DIR:-/opt/data/worktrees}"

repo_id() {
  # https://github.com/<owner>/hermes(.git) | git@github.com:<owner>/hermes.git
  #   -> github.com/<owner>/hermes.git
  case "$1" in
    git@*) printf '%s\n' "$1" | sed -e 's|^git@\([^:]*\):|\1/|' ;;
    *://*) printf '%s\n' "$1" | sed -e 's|^[a-zA-Z][a-zA-Z0-9+.-]*://||' ;;
    *)     printf '%s\n' "$1" ;;
  esac
}

session_slug() {
  key="${HERMES_SESSION_KEY:-}"
  if [ -z "$key" ]; then
    # No session context (CLI one-shot, cron, manual exec): shared lane.
    printf 'shared\n'
    return
  fi
  # agent:main:discord:thread:123:456 -> agent-main-discord-thread-123-456
  clean="$(printf '%s' "$key" | tr -c 'a-zA-Z0-9_' '-' | sed -e 's/-\{2,\}/-/g' -e 's/^-//' -e 's/-$//')"
  hash="$(printf '%s' "$key" | cksum | cut -d' ' -f1)"
  printf '%s-%s\n' "$clean" "$hash"
}

ensure() {
  dest="$REPOS/$(repo_id "$1")"
  if [ ! -d "$dest" ]; then
    mkdir -p "$(dirname "$dest")"
    git clone --bare "$1" "$dest"
  fi
  printf '%s\n' "$dest"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  ensure)
    [ "${1:-}" ] || { echo "usage: git-repo.sh ensure <git-url>" >&2; exit 2; }
    ensure "$1"
    ;;
  worktree)
    [ "${1:-}" ] || { echo "usage: git-repo.sh worktree <git-url> [branch] [dest]" >&2; exit 2; }
    url=$1
    bare=$(ensure "$url")
    if [ "${2:-}" ]; then branch=$2; else
      branch="$(git -C "$bare" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
      branch="${branch:-main}"
    fi
    repo_name="$(basename "${url%.git}")"
    dest="${3:-$WORKTREES/$(session_slug)/$repo_name}"
    if [ -e "$dest" ]; then
      echo "git-repo: destination exists: $dest (pass an explicit dest for a second checkout)" >&2
      exit 1
    fi
    mkdir -p "$(dirname "$dest")"
    if ! git -C "$bare" worktree add "$dest" "$branch" 2>/tmp/git-repo-wt.err; then
      # Branch already checked out in another worktree ("is already used
      # by worktree at ..." / "already checked out") — give this session
      # its own branch off the same commit instead of failing.
      if grep -qiE "already used by worktree|already checked out" /tmp/git-repo-wt.err 2>/dev/null; then
        sbranch="s/$(session_slug | cut -c1-40)"
        git -C "$bare" worktree add -b "$sbranch" "$dest" "$branch"
        echo "git-repo: branch '$branch' was taken; session branch '$sbranch' created (push with: git push origin HEAD:$branch)" >&2
      else
        cat /tmp/git-repo-wt.err >&2
        rm -f /tmp/git-repo-wt.err
        exit 1
      fi
    fi
    rm -f /tmp/git-repo-wt.err
    printf '%s\n' "$dest"
    ;;
  list)
    find "$REPOS" -mindepth 1 -maxdepth 3 -type d -name '*.git' 2>/dev/null | sort | while read -r bare; do
      echo "== $bare"
      git -C "$bare" worktree list | tail -n +2 | sed 's/^/   /'
    done
    ;;
  prune)
    # Safety rule: drop a worktree only if it is CLEAN (no uncommitted or
    # untracked changes — commits are never at risk, they live in the
    # shared bare repo), or if it is DIRTY but idle longer than --days
    # (default 30). Dirty-but-recent worktrees are kept, never touched.
    days=30
    if [ "${1:-}" = "--days" ] && [ -n "${2:-}" ]; then days=$2; fi
    now=$(date +%s)
    pruned=0; kept=0
    for sess in "$WORKTREES"/*/; do
      [ -d "$sess" ] || continue
      for wt in "$sess"*/; do
        [ -f "$wt/.git" ] || continue
        if [ -z "$(git -C "$wt" status --porcelain 2>/dev/null | head -1)" ]; then
          rm -rf "$wt"
          pruned=$((pruned + 1))
          echo "pruned clean worktree: $wt"
          continue
        fi
        # Newest file mtime = last real activity in this worktree.
        newest=$(find "$wt" -type f -printf '%T@\n' 2>/dev/null | sort -rn | head -1)
        newest="${newest%%.*}"
        [ -n "$newest" ] || newest=$now
        if [ $(( (now - newest) / 86400 )) -gt "$days" ]; then
          rm -rf "$wt"
          pruned=$((pruned + 1))
          echo "pruned stale dirty worktree (> ${days}d idle): $wt"
        else
          kept=$((kept + 1))
        fi
      done
      rmdir "$sess" 2>/dev/null || true
    done
    # Drop worktree admin entries whose dirs vanished above.
    find "$REPOS" -mindepth 1 -maxdepth 3 -type d -name '*.git' 2>/dev/null | while read -r bare; do
      git -C "$bare" worktree prune 2>/dev/null || true
    done
    if [ "$pruned" -gt 0 ]; then
      echo "prune: ${pruned} worktree(s) removed, ${kept} kept (dirty and <= ${days}d idle)"
    fi
    ;;
  *)
    echo "usage: git-repo.sh ensure|worktree|list|prune ..." >&2
    exit 2
    ;;
esac