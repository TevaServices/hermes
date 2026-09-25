#!/usr/bin/env python3
"""Is another session in this profile already working right now?

WHY THIS EXISTS

A work item must be worked in ONE session. On 2026-09-25 it was not:
the 5-minute `team: dev self-pull` cron re-injected the same in-progress
issue (`TevaServices/mach#26`) into the `developer` profile every tick
while a Discord thread session was mid-work on it. Because `team-queue.sh`
is resume-first, the issue sat at `status/in-progress` with no PR, so it
matched on every single tick, forever. Both sessions then worked the SAME
git worktree (`worktrees/shared/mach`, branch `26-approval-flow`) — two
agent turns editing one checkout, which is where the `patch` "could not
find a match for old_string" failures and a conflicted-merge `AUTO_MERGE`
came from. It took a manual container pause to stop it.

Nothing in the stack could answer the question that would have prevented
it — "is someone already on this?" — so the two lanes could not see each
other. This script is that answer, and it is deliberately NOT a claim
file or a heartbeat: a heartbeat the agent has to remember to send is a
heartbeat that goes stale during exactly the long turn it needs to cover,
and a stale heartbeat re-opens the collision. Instead liveness is read
from `state.db`, which Hermes maintains itself on every stream chunk
(`sessions.last_activity_at`; observed updating mid-turn with
`last_activity_description: "receiving stream response"`). Nothing to
keep fresh, nothing to leak, nothing to go stale.

THE TWO LANES

`source = 'cli'` is the unattended lane: a cron `bot-chat` delivery spawns
`hermes chat`, which records source `cli` (a human running `hermes chat`
by hand lands there too, and for this question the two are the same thing
— a turn nobody is watching). Every other source (`discord`, `api_server`,
...) is the user-facing lane: a human is present and can answer.

  --gate user    -> exit 0 when a USER-FACING session is live.
                    `team-queue.sh` uses this: the cron lane must stand
                    down rather than start a second turn on live work.
  --gate agent   -> exit 0 when an UNATTENDED (cli) session is live.
                    An agent uses this before picking up an item: that
                    item is already being worked, so confer for a status
                    update instead of starting a competing pass.
  --gate any     -> exit 0 when any session in the profile is live.

EXIT CODES (the contract — callers branch on these, so they matter):

  0  a matching live session exists  (its line(s) are printed)
  1  none — safe to proceed
  2  CANNOT DETERMINE — the profile's state.db is missing or unreadable.
     Callers must treat this as "gate dark", NOT as "not live": the cron
     lane proceeds as it always did, but says so out loud, because a gate
     that silently stopped protecting is indistinguishable from a quiet
     week — the exact failure mode `team-queue.sh`'s own exit codes exist
     to prevent (see its header).

Options:
  --home DIR    profile home holding state.db (default $HERMES_HOME, /opt/data)
  --ttl N       seconds of silence before a session stops counting as live
                (default $TEAM_SESSION_TTL, else 600). A live turn refreshes
                this on every stream chunk, so the TTL only needs to cover
                the gap while a model call is in flight.
  --item ITEM   scope to sessions whose RECENT messages mention ITEM
                (e.g. `TevaServices/mach#26`). Without it, any live session
                in the profile matches.
  --quiet       print nothing; exit code only.
  --json        machine-readable one object per line.
  -h, --help    this header.
"""

import json
import os
import sqlite3
import sys
import time

# How many recent messages of a live session to scan when --item is given.
# This is a binding heuristic, not a claim record: it answers "is the
# session that is breathing right now actually talking about THIS item?"
# Recent-only on purpose — a session that mentioned the item an hour ago
# and moved on must not keep the item fenced.
ITEM_SCAN_MESSAGES = 40


def die(msg, code=2):
    print(msg, file=sys.stderr)
    sys.exit(code)


def parse_args(argv):
    opts = {
        "home": os.environ.get("HERMES_HOME") or "/opt/data",
        "ttl": None,
        "item": "",
        "gate": "any",
        "quiet": False,
        "json": False,
    }
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--home":
            i += 1
            opts["home"] = argv[i] if i < len(argv) else ""
        elif a == "--ttl":
            i += 1
            opts["ttl"] = argv[i] if i < len(argv) else ""
        elif a == "--item":
            i += 1
            opts["item"] = argv[i] if i < len(argv) else ""
        elif a == "--gate":
            i += 1
            opts["gate"] = argv[i] if i < len(argv) else ""
        elif a == "--quiet":
            opts["quiet"] = True
        elif a == "--json":
            opts["json"] = True
        elif a in ("-h", "--help"):
            print(__doc__.strip())
            sys.exit(0)
        else:
            die("team-session.py: unknown argument: %s" % a)
        i += 1

    if opts["gate"] not in ("user", "agent", "any"):
        die("team-session.py: --gate must be user, agent or any")
    if opts["ttl"] is None:
        opts["ttl"] = os.environ.get("TEAM_SESSION_TTL") or "600"
    try:
        opts["ttl"] = int(str(opts["ttl"]).strip())
    except ValueError:
        die("team-session.py: --ttl must be an integer number of seconds")
    if opts["ttl"] <= 0:
        die("team-session.py: --ttl must be positive")
    return opts


def live_sessions(db_path, ttl):
    """Sessions whose last activity is within the TTL.

    Opened read-only and with a short busy timeout: this runs on the
    polling path of a cron job while the gateway is writing, and it must
    never wait long enough to become the reason a tick is late.
    """
    uri = "file:%s?mode=ro" % db_path.replace("?", "%3f").replace("#", "%23")
    con = sqlite3.connect(uri, uri=True, timeout=5.0)
    try:
        con.execute("PRAGMA query_only = 1")
        cutoff = time.time() - ttl
        rows = con.execute(
            "SELECT id, source, session_key, last_activity_at, "
            "       last_activity_description, title "
            "  FROM sessions "
            " WHERE last_activity_at IS NOT NULL AND last_activity_at >= ? "
            " ORDER BY last_activity_at DESC",
            (cutoff,),
        ).fetchall()
        out = []
        for sid, source, skey, act, desc, title in rows:
            out.append(
                {
                    "session_id": sid,
                    "source": source or "",
                    "session_key": skey or "",
                    "age_seconds": int(max(0, time.time() - float(act))),
                    "last_activity_description": desc or "",
                    "title": title or "",
                }
            )
        return out
    finally:
        con.close()


def mentions(con, session_id, item):
    """True when the session's recent messages mention `item`.

    Matched case-insensitively on the literal item so `tevaservices/mach#26`
    and `TevaServices/mach#26` both hit — the same item is written both ways
    across the issue, the branch and the thread name.
    """
    needle = item.lower()
    rows = con.execute(
        "SELECT content, tool_calls FROM messages "
        " WHERE session_id = ? AND active = 1 "
        " ORDER BY timestamp DESC LIMIT ?",
        (session_id, ITEM_SCAN_MESSAGES),
    ).fetchall()
    for content, tool_calls in rows:
        hay = "%s\n%s" % (content or "", tool_calls or "")
        if needle in hay.lower():
            return True
    return False


def label_of(session):
    return "cli" if (session["source"] or "") == "cli" else "user"


def main():
    opts = parse_args(sys.argv[1:])
    home = opts["home"].rstrip("/")
    db = os.path.join(home, "state.db")

    if not os.path.isfile(db):
        die("team-session.py: no state.db under %s" % home, 2)

    try:
        live = live_sessions(db, opts["ttl"])
    except Exception as exc:  # noqa: BLE001 - any failure is exit 2
        die("team-session.py: cannot read %s: %s" % (db, exc), 2)

    # --item scoping needs the messages table; do it in the same connection
    # so an unreachable db is still exit 2 rather than a silent "no match".
    if opts["item"]:
        try:
            uri = "file:%s?mode=ro" % db.replace("?", "%3f").replace("#", "%23")
            con = sqlite3.connect(uri, uri=True, timeout=5.0)
            try:
                con.execute("PRAGMA query_only = 1")
                live = [s for s in live if mentions(con, s["session_id"], opts["item"])]
            finally:
                con.close()
        except Exception as exc:  # noqa: BLE001
            die("team-session.py: cannot scope to %s: %s" % (opts["item"], exc), 2)

    if opts["gate"] == "user":
        live = [s for s in live if label_of(s) == "user"]
    elif opts["gate"] == "agent":
        live = [s for s in live if label_of(s) == "cli"]

    if not live:
        sys.exit(1)

    if not opts["quiet"]:
        for s in live:
            if opts["json"]:
                print(json.dumps(s, sort_keys=True))
            else:
                desc = s["last_activity_description"] or s["title"] or "-"
                print(
                    "%s  %s  last activity %ss ago  %s"
                    % (label_of(s), s["session_id"], s["age_seconds"], desc)
                )
    sys.exit(0)


if __name__ == "__main__":
    main()
