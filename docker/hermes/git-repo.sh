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
#   git-repo.sh fetch [<git-url>]
#       Refresh a central clone (or ALL of them) from origin — no args
#       fetches every <host>/<owner>/<repo>.git under $REPOS. Always
#       updates remote-tracking refs (origin/*) AND the local mirror of
#       the default branch (refs/heads/<branch>) so worktrees cut from
#       the clone's local branches are current. Network failures are
#       reported but never fatal (a stale clone beats a dead script).
#   git-repo.sh worktree <git-url> [branch] [dest]
#       ensure + fetch + `git worktree add` for THIS session; prints the
#       worktree path. Defaults: branch = remote default branch, dest =
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

# Refresh one bare clone: fetch origin's refs AND fast-forward the local
# branch mirrors (refs/heads/*). Worktrees are cut from local branches, so
# a plain `git fetch` (origin/* only) is not enough — e418654-style stale
# worktrees happened exactly because main was mirrored once at clone time
# and never moved again.
#
# Safe under set -eu: network failure -> message + return 1, and callers
# decide. `fetch` with no arg loops over every clone and never fails the
# command (stale clone beats dead script), but still exits nonzero if
# EVERY clone failed so cron can signal.
fetch_bare() {
  bare="$1"
  if ! git -C "$bare" fetch origin '+refs/heads/*:refs/remotes/origin/*' --prune 2>/tmp/git-repo-fetch.err; then
    echo "git-repo: fetch failed for $bare:" >&2
    sed 's/^/  /' /tmp/git-repo-fetch.err >&2
    rm -f /tmp/git-repo-fetch.err
    return 1
  fi
  rm -f /tmp/git-repo-fetch.err
  # Fast-forward local branch mirrors to their origin counterparts.
  git -C "$bare" for-each-ref --format='%(refname:short)' refs/remotes/origin |
    grep -v '/HEAD$' |
    while IFS= read -r r; do
      local_ref="refs/heads/${r#origin/}"
      if git -C "$bare" show-ref --verify --quiet "$local_ref"; then
        # Only fast-forward; never move a local branch backwards.
        if git -C "$bare" merge-base --is-ancestor "$local_ref" "$r" 2>/dev/null; then
          git -C "$bare" update-ref "$local_ref" "$r"
        fi
      fi
    done
  printf '%s\n' "$bare"
}

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  ensure)
    [ "${1:-}" ] || { echo "usage: git-repo.sh ensure <git-url>" >&2; exit 2; }
    ensure "$1"
    ;;
  fetch)
    if [ "${1:-}" ]; then
      bare="$REPOS/$(repo_id "$1")"
      [ -d "$bare" ] || { echo "git-repo: no central clone for $1 (run: git-repo.sh ensure $1)" >&2; exit 1; }
      fetch_bare "$bare"
    else
      rc=0; total=0; ok=0
      for bare in $(find "$REPOS" -mindepth 1 -maxdepth 3 -type d -name '*.git' 2>/dev/null | sort); do
        total=$((total + 1))
        if fetch_bare "$bare"; then ok=$((ok + 1)); else rc=1; fi
      done
      echo "git-repo fetch: $ok/$total repo(s) refreshed"
      # All-failed -> nonzero so cron/monitoring can signal; partial ok -> 0.
      [ "$total" -gt 0 ] && [ "$ok" -eq 0 ] && exit 1
      exit "$rc"
    fi
    ;;
  worktree)
    [ "${1:-}" ] || { echo "usage: git-repo.sh worktree <git-url> [branch] [dest]" >&2; exit 2; }
    url=$1
    bare=$(ensure "$url")
    if [ "${2:-}" ]; then branch=$2; else
      branch="$(git -C "$bare" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
      branch="${branch:-main}"
    fi
    # Refresh the clone BEFORE cutting the worktree: this is the whole
    # point — a worktree from a stale local branch defeats the shared
    # clone. Failure is non-fatal (offline session still gets a worktree;
    # it just sees the last-fetched state).
    fetch_bare "$bare" || echo "git-repo: proceeding with last-fetched state" >&2
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

    # Org commit identity: a worktree of an ORG-owned repo commits as the
    # ORG bot (e.g. acmecorp-hermes-dev[bot]), not the personal one.
    # The credential side routes itself (git-credential-hermes.sh picks
    # the org token from the remote owner); the AUTHOR side needs git
    # config, which cannot vary per org at the global level — so each
    # worktree gets its own local identity when the repo's owner matches
    # an org descriptor.
    #
    # extensions.worktreeConfig is REQUIRED for the scoping: without it,
    # `git config` inside a worktree writes the COMMON bare config and
    # the org bot identity would leak onto every session's worktree of
    # that repo. With it, values land in this worktree's own
    # worktrees/<id>/config.worktree. Idempotent.
    git -C "$bare" config extensions.worktreeConfig true 2>/dev/null || true
    owner="$(printf '%s' "$(repo_id "$url")" | cut -d/ -f2)"
    oslug="$(printf '%s' "$owner" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9')"
    creds_dir="${ORG_CREDS_DIR:-}"
    [ -n "$creds_dir" ] || creds_dir="${HOME:-}/org-creds"
    if [ -n "$oslug" ] && [ -d "$creds_dir" ]; then
      for d in "$creds_dir"/*.env; do
        [ -f "$d" ] || continue
        if [ "$(basename "$d" .env | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9')" = "$oslug" ]; then
          # shellcheck disable=SC1090
          if . "$d" && [ -n "${GH_GIT_NAME:-}" ] && [ -n "${GH_GIT_EMAIL:-}" ]; then
            git -C "$dest" config --worktree user.name "$GH_GIT_NAME"
            git -C "$dest" config --worktree user.email "$GH_GIT_EMAIL"
          fi
          break
        fi
      done
    fi

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