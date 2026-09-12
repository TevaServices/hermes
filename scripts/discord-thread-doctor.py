#!/usr/bin/env python3
"""Check whether each Discord bot can actually create threads, and if not, why.

Run this ON THE HOMELAB HOST from the repo checkout (it reads the bot
tokens out of /etc/hermes/hermes-main.env via `sudo cat`, so it needs
sudo rights, not to be *run* under sudo).

WHY THIS EXISTS
===============
When a bot cannot create a thread, Discord returns the same 403 for two
very different problems, and the agent-facing tool relays them
identically ("Bot lacks CREATE_PUBLIC_THREADS in this channel, or cannot
view it") — see tools/discord_tool.py `_ACTION_403_HINT`. Those two
problems have different fixes:

  * the bit is missing at GUILD level  -> the bot's role needs it (or the
    bot needs re-inviting; scripts/set-team-discord-tokens.py already
    prints a URL whose integer carries the thread bits), or
  * the bit is present at guild level but a CHANNEL OVERWRITE denies it
    -> grant Create Public Threads / Send Messages in Threads on that
    channel for the bot's role.

So this computes the *effective* permission the way Discord does:

    base  = @everyone role perms, unioned with every role the bot holds
            (or Discord's own computed value from GET /users/@me/guilds)
    then  = apply the channel's overwrites in Discord's order —
            @everyone -> union of the bot's role overwrites (deny wins)
            -> the bot's member overwrite — with ADMINISTRATOR bypassing
            overwrites entirely.

and reports each needed bit as present, denied-by-channel, or
denied-by-guild. Thread creation needs CREATE_PUBLIC_THREADS (and
SEND_MESSAGES_IN_THREADS to reply in the thread); it does NOT need
MANAGE_THREADS — that one only governs renaming/archiving/deleting
*other people's* threads.

Channels come from the profile routes in
config/profiles/default/profile.toml (the single source of truth), so
this script does not keep its own copy of the channel IDs.

Usage:
    python3 scripts/discord-thread-doctor.py
    python3 scripts/discord-thread-doctor.py --channel 1234567890
    python3 scripts/discord-thread-doctor.py --probe

`--probe` creates a real thread (auto-archive 60 minutes) and archives it
again to clean up, so a pass proves thread creation end-to-end rather
than proving the permission arithmetic.

Exit status: 0 when every checked bot/channel pair can create threads,
1 when any pair cannot (or the check could not run).
"""

import argparse
import json
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

try:
    import tomllib  # Python 3.11+ (render.py needs it too — mise pins 3.12)
except ModuleNotFoundError:  # pragma: no cover - older host interpreter
    sys.exit(
        "this script needs Python 3.11+ for stdlib tomllib; on a box with mise "
        "run it as: mise exec -- python3 scripts/discord-thread-doctor.py"
    )

ENV_FILE = "/etc/hermes/hermes-main.env"
ROUTES_FILE = "config/profiles/default/profile.toml"
UA = "DiscordBot (https://github.com/<owner>/hermes, 1.0)"
API = "https://discord.com/api/v10"

OK = "✓"
FAIL = "✗"
WARN = "!"

# Permission bits thread creation depends on, plus the two that make a
# channel usable at all (a bot that cannot view or send into the channel
# fails for reasons that have nothing to do with threads).
BITS = {
    1 << 10: "VIEW_CHANNEL",
    1 << 11: "SEND_MESSAGES",
    1 << 16: "READ_MESSAGE_HISTORY",
    1 << 35: "CREATE_PUBLIC_THREADS",
    1 << 38: "SEND_MESSAGES_IN_THREADS",
}
# Refusing to guess which of these are "critical" — the report marks all
# of them and the verdict keys off these two.
REQUIRED_FOR_THREADS = [1 << 35, 1 << 38]

ADMINISTRATOR = 1 << 3
OVERWRITE_ROLE = 0
OVERWRITE_MEMBER = 1


def sh(*args, **kw):
    return subprocess.run(args, capture_output=True, text=True, **kw)


def api(method, path, token, body=None):
    """One Discord REST call. Raises HTTPError so callers can report the
    status and Discord's own error body instead of a traceback."""
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        API + path,
        data=data,
        method=method,
        headers={
            "Authorization": "Bot " + token,
            "User-Agent": UA,
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        payload = resp.read()
    return json.loads(payload) if payload else {}


def read_env():
    out = sh("sudo", "cat", ENV_FILE)
    if out.returncode != 0:
        sys.exit(f"cannot read {ENV_FILE}: {out.stderr.strip()}")
    env = {}
    for line in out.stdout.splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, _, value = line.partition("=")
            env[key.strip()] = value.strip()
    return env


def load_routes():
    """profile -> [channel_id] from the default profile's route table."""
    path = Path(__file__).resolve().parent.parent / ROUTES_FILE
    try:
        with path.open("rb") as fh:
            data = tomllib.load(fh)
    except (OSError, tomllib.TOMLDecodeError) as exc:
        sys.exit(f"cannot read profile routes from {path}: {exc}")
    routes = (
        data.get("config_extra", {})
        .get("gateway", {})
        .get("profile_routes", {})
    )
    owners = {}
    for name, route in routes.items():
        chat_id, profile = route.get("chat_id"), route.get("profile")
        if not chat_id or not profile:
            continue
        owners.setdefault(profile, []).append((name, str(chat_id)))
    return owners


def bot_tokens(env):
    """(label, token) for the main bot plus every PROFILE_*_DISCORD_BOT_TOKEN."""
    bots = []
    main = env.get("DISCORD_BOT_TOKEN", "")
    if main:
        bots.append(("default", main))
    for key, value in sorted(env.items()):
        if key.startswith("PROFILE_") and key.endswith("_DISCORD_BOT_TOKEN") and value:
            bots.append((key[len("PROFILE_"):-len("_DISCORD_BOT_TOKEN")].lower(), value))
    return bots


def guild_level_perms(guild, token, bot_id, roles_cache):
    """The bot's guild-level permissions.

    GET /users/@me/guilds already carries Discord's own computed value;
    fall back to unioning the bot's roles (the bot's own managed role is
    identifiable by tags.bot_id) when a guild entry omits it.
    """
    if "permissions" in guild:
        return int(guild["permissions"])
    gid = guild["id"]
    if gid not in roles_cache:
        roles_cache[gid] = api("GET", f"/guilds/{gid}/roles", token)
    roles = roles_cache[gid]
    role_ids = {r["id"] for r in roles if r.get("tags", {}).get("bot_id") == bot_id}
    try:
        member = api("GET", f"/guilds/{gid}/members/{bot_id}", token)
        role_ids = set(member.get("roles", [])) | role_ids | {gid}
    except urllib.error.HTTPError:
        role_ids.add(gid)
    perms = 0
    for role in roles:
        if role["id"] in role_ids:
            perms |= int(role["permissions"])
    return perms


def effective_perms(base, channel, guild_id, bot_id, token, roles_cache):
    """Apply the channel's overwrites in Discord's order."""
    if base & ADMINISTRATOR:
        return base, "administrator"
    gid = guild_id
    if gid not in roles_cache:
        roles_cache[gid] = api("GET", f"/guilds/{gid}/roles", token)
    role_ids = {r["id"] for r in roles_cache[gid] if r.get("tags", {}).get("bot_id") == bot_id}
    try:
        member = api("GET", f"/guilds/{gid}/members/{bot_id}", token)
        role_ids |= set(member.get("roles", []))
    except urllib.error.HTTPError:
        pass

    overwrites = channel.get("permission_overwrites") or []
    perms = base
    for ow in overwrites:
        if ow.get("type") == OVERWRITE_ROLE and ow.get("id") == gid:
            perms = (perms & ~int(ow["deny"])) | int(ow["allow"])
    allow = deny = 0
    for ow in overwrites:
        if ow.get("type") == OVERWRITE_ROLE and ow.get("id") in role_ids:
            allow |= int(ow["allow"])
            deny |= int(ow["deny"])
    perms = (perms & ~deny) | allow
    for ow in overwrites:
        if ow.get("type") == OVERWRITE_MEMBER and ow.get("id") == bot_id:
            perms = (perms & ~int(ow["deny"])) | int(ow["allow"])
    return perms, "overwrites"


def probe_thread(token, channel_id):
    """Create then archive a real thread. Returns (ok, detail)."""
    try:
        thread = api(
            "POST",
            f"/channels/{channel_id}/threads",
            token,
            {"name": "hermes-thread-doctor", "type": 11, "auto_archive_duration": 60},
        )
    except urllib.error.HTTPError as exc:
        try:
            detail = exc.read().decode()[:200]
        except Exception:
            detail = str(exc.reason or "")
        return False, f"{exc.code} {detail}"
    try:
        api("PATCH", f"/channels/{thread['id']}", token, {"archived": True})
    except Exception:
        pass  # the probe already proved creation works; cleanup is best-effort
    return True, f"created thread {thread['id']}"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--channel",
        action="append",
        default=[],
        help="extra channel ID to check every bot against (repeatable)",
    )
    parser.add_argument(
        "--probe",
        action="store_true",
        help="also create a real thread in each bot's own routed channel",
    )
    args = parser.parse_args(argv)

    env = read_env()
    owners = load_routes()
    bots = bot_tokens(env)
    if not bots:
        sys.exit(f"no DISCORD_BOT_TOKEN (or PROFILE_*_DISCORD_BOT_TOKEN) in {ENV_FILE}")

    # Every routed channel, plus anything asked for explicitly.
    channels = []
    for profile in sorted(owners):
        for name, chat_id in owners[profile]:
            if chat_id not in [c[0] for c in channels]:
                channels.append((chat_id, name, profile))
    for extra in args.channel:
        if extra not in [c[0] for c in channels]:
            channels.append((extra, "(--channel)", None))
    if not channels:
        sys.exit(f"no channels to check — add routes to {ROUTES_FILE} or pass --channel")

    print("=" * 72)
    print("Discord thread doctor — can each bot create a thread?")
    print("=" * 72)

    roles_cache = {}
    failures = []
    for label, token in bots:
        print(f"\n[{label}]")
        try:
            me = api("GET", "/users/@me", token)
            guilds = api("GET", "/users/@me/guilds", token)
            print(f"  bot {me.get('username')} (id {me.get('id')}), "
                  f"{len(guilds)} guild(s)")
        except urllib.error.HTTPError as exc:
            print(f"  {FAIL} cannot authenticate this token: {exc.code} "
                  f"{exc.reason} — is it the right kind of token?")
            failures.append((label, "(auth)", f"{exc.code}"))
            continue
        guild_by_id = {g["id"]: g for g in guilds}

        for chat_id, name, owner in channels:
            try:
                channel = api("GET", f"/channels/{chat_id}", token)
            except urllib.error.HTTPError as exc:
                detail = "cannot view it (missing VIEW_CHANNEL, or bot not in the guild)"
                print(f"  {FAIL} {name} ({chat_id}): {exc.code} — {detail}")
                failures.append((label, name, f"unreadable ({exc.code})"))
                continue
            guild = guild_by_id.get(channel.get("guild_id"))
            if guild is None:
                print(f"  {FAIL} {name} ({chat_id}): bot is not in that guild")
                failures.append((label, name, "not in guild"))
                continue

            base = guild_level_perms(guild, token, me["id"], roles_cache)
            try:
                eff, how = effective_perms(
                    base, channel, channel["guild_id"], me["id"], token, roles_cache
                )
            except urllib.error.HTTPError as exc:
                print(f"  {FAIL} {name} ({chat_id}): permission read failed ({exc.code})")
                failures.append((label, name, f"perms unreadable ({exc.code})"))
                continue

            notes = []
            for bit, bit_name in BITS.items():
                if eff & bit:
                    continue
                if base & bit:
                    notes.append(f"{bit_name} denied by a CHANNEL OVERWRITE")
                else:
                    notes.append(f"{bit_name} missing at GUILD level")
            tag = "own channel" if owner == label else (owner or "extra")
            if notes:
                print(f"  {FAIL} {name} ({chat_id}, {tag}): {'; '.join(notes)}")
                failures.append((label, name, "; ".join(n.split()[0] for n in notes)))
            else:
                need = all(eff & b for b in REQUIRED_FOR_THREADS)
                mark = OK if need else FAIL
                print(f"  {mark} {name} ({chat_id}, {tag}): thread-capable "
                      f"[{'admin' if how == 'administrator' else 'perms'}]")
                if not need:
                    failures.append((label, name, "missing thread bit"))

        if args.probe:
            own = owners.get(label, [])
            if not own:
                print(f"  {WARN} no routed channel of its own — pass --channel to probe one")
            for name, chat_id in own:
                ok, detail = probe_thread(token, chat_id)
                print(f"  {OK if ok else FAIL} probe {name} ({chat_id}): {detail}")
                if not ok:
                    failures.append((label, f"probe:{name}", detail.split()[0]))

    print("\n" + "=" * 72)
    if failures:
        print(f"{FAIL} {len(failures)} problem(s):")
        for label, where, detail in failures:
            print(f"    {label:<10} {where:<28} {detail}")
        print(
            "\nFix: a GUILD-level miss needs the bot's role to hold the bit\n"
            "(re-inviting via the URL scripts/set-team-discord-tokens.py prints\n"
            "already carries the thread bits). A CHANNEL OVERWRITE needs the\n"
            "role granted 'Create Public Threads' + 'Send Messages in Threads'\n"
            "on that channel. MANAGE_THREADS is not required to create a\n"
            "thread — only to manage other people's."
        )
        return 1
    print(f"{OK} every checked bot can create threads in every checked channel.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
