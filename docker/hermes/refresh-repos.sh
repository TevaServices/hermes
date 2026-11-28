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

# Report a failed sweep on STDOUT and exit non-zero, carrying the
# remediation the next operator needs. A per-repo failure IS an incident (a
# clone that cannot fetch is a stale mirror), and a PERMANENT one — the repo
# was transferred or deleted, or this profile's GitHub App cannot see it —
# fails EVERY day until the clone is dealt with. That is not hypothetical:
# github.com/bcross/{hermes,komodo,trader}.git in a volume that arrived from
# a host whose App did own them alerted for 16 consecutive days on the Teva
# host, whose only App is TevaServices (observed 2026-11-28; the mirrors were
# moved aside, and the sweep went straight back to 4/4 silent).
fail() {
  printf '%s\n' "$1"
  printf '%s\n' "If a repo above is no longer reachable from this host, re-point the clone's origin at the live URL — or retire the clone by moving <repo>.git out of ${HERMES_REPOS_DIR:-/opt/data/repos}. Move it, do not delete it: a mirror can hold local-only s/<session> branches. Until then this sweep fails every day."
  exit 1
}

for p in /opt/data/bin/git-repo.sh /usr/local/bin/git-repo.sh; do
  if [ -x "$p" ]; then
    if ! out=$("$p" fetch 2>&1); then
      fail "$out"
    fi
    # Partial failure: the aggregate fetch exits non-zero when ANY repo
    # failed (a stale clone beats no clone for a SESSION, but a mirror that
    # cannot move is an incident for this daily sweep). Surface it too.
    case "$out" in
      *"fetch failed"*)
        fail "$out"
        ;;
    esac
    exit 0
  fi
done
echo "git-repo.sh not found (looked in /opt/data/bin, /usr/local/bin)"
exit 1
