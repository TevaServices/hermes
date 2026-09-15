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
# Zero-LLM cron job, and SILENT when healthy. `git-repo.sh fetch` echoes
# every repo it refreshed plus a summary line, which is not news; a job
# that posts "5/5 repos refreshed" into the channel every single day is
# noise that trains people to ignore the channel. So the output is
# captured rather than streamed, and printed ONLY when something failed.
# Failures go to STDOUT (a no_agent job discards stderr) and the job
# exits non-zero, so a broken refresh is delivered and recorded instead
# of looking like a quiet day.
set -eu

for p in /opt/data/bin/git-repo.sh /usr/local/bin/git-repo.sh; do
  if [ -x "$p" ]; then
    if ! out=$("$p" fetch 2>&1); then
      printf '%s\n' "$out"
      exit 1
    fi
    # Partial failure: fetch_bare reports a per-repo error but the sweep
    # still exits 0 (a stale clone beats no clone). Surface it anyway.
    case "$out" in
      *"fetch failed"*)
        printf '%s\n' "$out"
        exit 1
        ;;
    esac
    exit 0
  fi
done
echo "git-repo.sh not found (looked in /opt/data/bin, /usr/local/bin)"
exit 1
