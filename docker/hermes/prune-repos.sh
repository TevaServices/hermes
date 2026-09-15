#!/bin/sh
# Weekly prune of per-session git worktrees (central repos model — see
# AGENTS.md "Central git repos + per-session worktrees").
#
# Safety rule: only worktrees that are CLEAN (no uncommitted/untracked
# changes) or idle > 30 days are removed; dirty-but-recent ones are kept.
#
# Zero-LLM cron job: silent when nothing was pruned (git-repo.sh prune
# only speaks when it actually removed something). A no_agent job
# delivers its script's STDOUT and DISCARDS stderr, so the not-found
# diagnostic below goes to stdout too — on stderr it would be invisible
# and the job would just look quiet.
set -eu

for p in /opt/data/bin/git-repo.sh /usr/local/bin/git-repo.sh; do
  if [ -x "$p" ]; then
    exec "$p" prune --days 30
  fi
done
echo "git-repo.sh not found (looked in /opt/data/bin, /usr/local/bin)"
exit 1
