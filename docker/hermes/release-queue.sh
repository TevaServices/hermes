#!/bin/sh
# The release agent's self-pull queue — a thin, named wrapper over
# team-queue.sh so the cron job has its own script path (a cron `--script`
# is a path only; it cannot carry arguments).
#
# THREE things wake the release agent, and NOTHING else does:
#
#   1. a MERGE — an open PR labelled `review/approved` whose approval on
#      record is a HUMAN's, by a login in the repo's CODEOWNERS. The label
#      is the REVIEWER's verdict, not the human's, and those are hours
#      apart in practice: `gh search --review approved` is satisfied by a
#      BOT's approval too (the reviewer bot approves first — live on
#      mach#27, reviewer 23:00:59Z then bcross 08:22:50Z), so the approval
#      is read back rather than inferred. A PR approved but still waiting on
#      a human is DROPPED, not listed: a human's wait must cost zero tokens.
#   2. a STUCK RELEASE — a `v*` tag with no GitHub release and no run in
#      flight, or a release workflow that concluded badly. A run still
#      running is deliberately NOT a finding: that is the resumable
#      "waiting on CI" state, and reporting it would wake the agent every
#      tick for the length of a 6-minute workflow.
#   3. an UNDEPLOYED RELEASE — a published release that is not the version
#      the agent's own state file records as deployed. This is the resume
#      lane, and the state file is the declaration that the repo has an
#      internal deployment; nothing is inferred about other repos.
#
#   exit 0  work or a finding listed (the agent wakes), or healthy-and-empty
#           (silent)
#   2/3/4/5/6 an incident — surfaced once, then deduped (6 = ORG CREDS
#           MISSING, a TEAM_OWNER_ORGS entry with no usable org App)
#
# The release TRIAGE findings use their own dedupe slot AND carry a
# first-seen epoch (TEAM_RELEASE_RETRY_TTL, default 6h): unlike the other
# notices they re-emit, because a stalled release is unattended work and a
# delivery lost to a container restart must not read as a resolution. See
# team-queue.sh for the full reasoning and the exit-code contract.
#
# Quiet IS the default (the cron contract) because the scheduler invokes a
# no_agent script with no arguments. Run --verbose when you want to see the
# healthy-but-idle state, the dropped-but-awaiting PRs, and the queue's
# own audit lines.
#
# Usage: release-queue.sh [--verbose] [--quiet] [--label LANE]...

set -u

# Resolve team-queue.sh without trusting PATH: under cron the environment
# is minimal, so prefer explicit locations, then fall back to PATH.
#
# Every candidate below contains a slash ON PURPOSE. A bare name would
# be resolved by `exec` against PATH, not the current directory — so
# picking up "./team-queue.sh" as the bare name "team-queue.sh" fails
# with `exec: team-queue.sh: not found` even though the file is right
# there. `command -v` also returns an absolute path, which is why it is
# the only PATH-based branch.
SELF_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || SELF_DIR="."

if [ -n "${TEAM_QUEUE_SH:-}" ]; then
    QUEUE="$TEAM_QUEUE_SH"
else
    QUEUE=""
    for c in \
        "$SELF_DIR/team-queue.sh" \
        /usr/local/bin/team-queue.sh
    do
        if [ -x "$c" ]; then QUEUE="$c"; break; fi
    done
    if [ -z "$QUEUE" ]; then
        QUEUE=$(command -v team-queue.sh 2>/dev/null || true)
    fi
fi

if [ -z "$QUEUE" ] || [ ! -x "$QUEUE" ]; then
    echo "release-queue.sh: cannot locate team-queue.sh (tried $SELF_DIR, /usr/local/bin, PATH)" >&2
    exit 2
fi

exec "$QUEUE" --kind releases "$@"
