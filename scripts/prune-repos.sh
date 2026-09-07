#!/bin/sh
# Weekly prune of idle per-session git worktrees (central repos model —
# see AGENTS.md "Central git repos + per-session worktrees").
#
# Drops session dirs under $HERMES_WORKTREES_DIR idle > 7 days, then runs
# `git worktree prune` on every bare repo in $HERMES_REPOS_DIR so the
# worktree admin entries for deleted dirs are dropped. Zero-LLM cron job:
# stdout is empty on a quiet run, so the scheduler delivers nothing.
#
# Lives in the repo (committed) AND on the volume at /opt/data/scripts/
# (the cron scheduler runs it from there — survives rebuilds).
set -eu

for p in /usr/local/bin/git-repo.sh /opt/data/bin/git-repo.sh; do
  if [ -x "$p" ]; then
    exec "$p" prune --days 7
  fi
done
echo "git-repo.sh not found (looked in /usr/local/bin, /opt/data/bin)" >&2
exit 1