#!/bin/sh
# The reviewer's self-pull queue — a thin, named wrapper over team-queue.sh
# so the cron job has its own script path (a cron `--script` is a path only;
# it cannot carry arguments).
#
# The handoff it polls is the `review/ready` LABEL, not a review request:
# bot identities cannot be requested as PR reviewers ("GraphQL: Could not
# resolve user with login 'hermes-reviewer[bot]'"), and the REST
# endpoint lies about it — it returns 201 and silently drops the bot. See
# team-queue.sh for the full reasoning and the exit-code contract.
#
#   exit 0  work listed (the agent wakes), or healthy-and-empty (silent)
#   2/3/4/5/6 an incident — surfaced once, then deduped (6 = ORG CREDS
#           MISSING, a TEAM_OWNER_ORGS entry with no usable org App)
#
# The queue is `review/in-progress` THEN `review/ready`: a review this
# profile already claimed comes back to it first, so an interrupted review
# turn resumes instead of being silently orphaned. See team-queue.sh.
#
# Quiet IS the default (the cron contract) because the scheduler invokes a
# no_agent script with no arguments. Run --verbose when you want to see the
# healthy-but-idle state.
#
# Usage: review-queue.sh [--verbose] [--quiet] [--label LABEL]...

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
    echo "review-queue.sh: cannot locate team-queue.sh (tried $SELF_DIR, /usr/local/bin, PATH)" >&2
    exit 2
fi

exec "$QUEUE" --kind prs "$@"
