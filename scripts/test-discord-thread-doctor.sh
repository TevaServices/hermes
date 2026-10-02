#!/bin/sh
# Offline test for scripts/discord-thread-doctor.py — the route-table read.
#
# WHY THIS EXISTS
#
# profile.toml's chat_ids became @@VAR@@ PLACEHOLDERS when the render system
# went in (real ids live in hermes-main.env as DISCORD_CHANNEL_*). The
# doctor's first version passed them to the Discord API verbatim — an
# invalid snowflake — so every check 400'd with a misleading "cannot view
# it (missing VIEW_CHANNEL...)": a diagnosis tool reporting ALL-fail on a
# healthy setup, exactly when someone is debugging threads.
#
# The contract pinned here (load_routes):
#   1. a @@VAR@@ placeholder expands from the env it is given — the same
#      mapping render.py applies;
#   2. an UNSET placeholder lands in the separate `unset` report and the
#      channel is skipped, not queried (and not a failure);
#   3. a literal chat id passes through untouched;
#   4. routes without chat_id/profile stay skipped (pre-existing rule);
#   5. it reads the repo's own route file without crashing and returns the
#      (owners, unset) shape.
#
# Run: $ mise run test      (or: sh scripts/test-discord-thread-doctor.sh)
# No network: the Discord API is never touched — load_routes is pure.

set -u

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d) || exit 2
trap 'rm -rf "$tmp"' EXIT INT TERM

# The doctor needs python3.11+ (tomllib) — the same guard as the doctor
# itself; via mise run test the mise-pinned python is on PATH, but a bare
# `sh scripts/...` on a host with an older python must go through mise too.
PY="python3"
command -v mise >/dev/null 2>&1 && PY="mise exec -- python3"

$PY - "$here" "$tmp" <<'PY'
import importlib.util
import os
import sys

here, tmp = sys.argv[1], sys.argv[2]

passed = 0
failed = 0


def check(label, cond, detail=""):
    global passed, failed
    if cond:
        passed += 1
        print(f"ok   {label}")
    else:
        failed += 1
        print(f"FAIL {label}" + (f" — {detail}" if detail else ""))


spec = importlib.util.spec_from_file_location(
    "doctor", os.path.join(here, "scripts", "discord-thread-doctor.py"))
doc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(doc)

routes_file = os.path.join(tmp, "routes.toml")
with open(routes_file, "w") as fh:
    fh.write("""
[config_extra.gateway.profile_routes]
planning_channel = { chat_id = "@@DISCORD_CHANNEL_PLANNER@@", profile = "planner" }
dev_channel = { chat_id = "@@DISCORD_CHANNEL_DEVELOPER@@", profile = "developer" }
shared_channel = { chat_id = "@@DISCORD_CHANNEL_PLANNER@@", profile = "planner" }
unset_channel = { chat_id = "@@DISCORD_CHANNEL_NOTWIRED@@", profile = "reviewer" }
weird_route = { chat_id = "", profile = "" }
""")

# 1+2+4: expansion, pass-through, unset reporting, empty route skipped.
owners, unset = doc.load_routes(
    {"DISCORD_CHANNEL_PLANNER": "111", "DISCORD_CHANNEL_DEVELOPER": "222"},
    path=routes_file,
)
check("placeholder expands to the env's value",
      owners.get("planner") == [("planning_channel", "111"),
                                ("shared_channel", "111")]
      and owners.get("developer") == [("dev_channel", "222")])
check("the same placeholder under two profiles resolves identically",
      [c for _, c in owners["planner"]] == ["111", "111"])
check("routes without chat_id/profile are skipped", not any(n == "weird_route"
      for chans in owners.values() for n, _ in chans))
# 2b: the unwired placeholder is REPORTED, not resolved
check("an unset placeholder is reported and skipped",
      unset == [("unset_channel", "DISCORD_CHANNEL_NOTWIRED")]
      and not any(n == "unset_channel" for chans in owners.values() for n, _ in chans))

# 3: a literal chat id passes through untouched.
with open(routes_file, "w") as fh:
    fh.write('[config_extra.gateway.profile_routes]\n'
             'legacy_channel = { chat_id = "1234567890", profile = "planner" }\n')
owners, unset = doc.load_routes({}, path=routes_file)
check("a literal chat id passes through unexpanded",
      owners.get("planner") == [("legacy_channel", "1234567890")] and unset == [])

# 5: the repo's own route file parses without crashing (shape only — every
# id may be a placeholder here, which is fine).
real = os.path.join(here, "config", "profiles", "default", "profile.toml")
owners, unset = doc.load_routes({}, path=real)
check("the repo's own route table parses (owners + unset are iterables)",
      isinstance(owners, dict) and isinstance(unset, list))

# The docstring's promise: unset placeholders are skipped, not a sys.exit —
# i.e. load_routes returned, it did not quit the process mid-report.

print()
print(f"{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PY

exit $?