#!/bin/sh
# Weekly prune of per-session git worktrees (central repos model — see
# AGENTS.md "Central git repos + per-session worktrees").
#
# Safety rule: only worktrees that are CLEAN (no uncommitted/untracked
# changes) or idle > 30 days are removed; dirty-but-recent ones are kept.
# Zero-LLM cron job: silent when nothing was pruned.
#
# Lives in the repo (committed) AND on the volume at /opt/data/scripts/
# (the cron scheduler runs it from there — survives rebuilds). The volume
# copy of git-repo.sh wins over the baked image copy, so a fix can ship
# without a rebuild.
set -eu

for p in /opt/data/bin/git-repo.sh /usr/local/bin/git-repo.sh; do
  if [ -x "$p" ]; then
    exec "$p" prune --days 30
  fi
done
echo "git-repo.sh not found (looked in /opt/data/bin, /usr/local/bin)" >&2
exit 1