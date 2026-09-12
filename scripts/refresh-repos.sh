#!/bin/sh
# Daily refresh of the central git bare clones ($HERMES_REPOS_DIR —
# /opt/data/repos/<host>/<owner>/<repo>.git).
#
# Why this exists: worktrees are cut from the clone's LOCAL branch mirrors
# (refs/heads/main), which a plain `git fetch` never moves — a clone left
# unfetched served stale mains to fresh worktrees (2026-09-12: a worktree
# cut from e418654 while origin/main was at a83b28b). git-repo.sh now
# fast-forwards local mirrors on every fetch; this job runs that sweep
# daily so clones are current even if no session opened a worktree.
#
# Zero-LLM cron job: silent when everything is already current.
set -eu

for p in /opt/data/bin/git-repo.sh /usr/local/bin/git-repo.sh; do
  if [ -x "$p" ]; then
    exec "$p" fetch
  fi
done
echo "git-repo.sh not found (looked in /opt/data/bin, /usr/local/bin)" >&2
exit 1