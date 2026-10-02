#!/usr/bin/env python3
"""Wire the team profiles' Discord bot tokens into the host's env file.

Run this LOCALLY — the machine with your SSH key (the host never needs a
checkout). It prompts for each team bot's token with hidden input
(getpass), so nothing is typed as an argument or echoed; validates every
token against Discord BEFORE wiring anything; and then installs the
PROFILE_<NAME>_DISCORD_BOT_TOKEN lines into /etc/hermes/hermes-main.env on
the host (see scripts/hostdeploy.py for the push/merge/backup/verify
contract, which this script and create-github-apps.py share).

Before writing anything it refuses a token that is:
  * rejected by Discord
  * the MAIN bot's token (would re-create the duplicate-credential
    refusal that keeps the team gateways from starting) — checkable
    without typing the main token anywhere: the script hashes
    DISCORD_BOT_TOKEN read from the host env file over SSH
  * already entered for another profile

Why the invite URL matters: a bot token works as soon as the app exists,
but the bot is not IN the guild until someone authorizes it. The URL
carries the same permission integer as the main bot, so the team bots
land with equivalent capability.

The three privileged intents (Presence, Server Members, Message Content)
must be toggled by hand in the Developer Portal — there is no API for it,
and discord.py refuses to connect without them.

Usage:
  python3 scripts/set-team-discord-tokens.py                 # all 4 team bots
  python3 scripts/set-team-discord-tokens.py reviewer        # just one
  HERMES_SSH_HOST=<host> python3 scripts/...                 # or --host <host>

Deploy paths (scripts/hostdeploy.py):
  * sudo -n works over SSH  →  pushed + verified automatically, nothing
    is written to disk here, nothing is run on the host by hand;
  * sudo needs a password   →  artifacts land in build/discord-bots/ and
    ONE command finishes it: sh build/discord-bots/install-remote.sh;
  * no --host given         →  same artifacts, plus a warning that the
    main-token duplicate check is skipped.
"""

import argparse
import getpass
import hashlib
import json
import os
import sys
import urllib.error
import urllib.request

import hostdeploy

PROFILES = ["planner", "developer", "reviewer", "release"]
# Your Discord server's name — only used in the printed instructions.
GUILD_NAME = os.environ.get("DISCORD_GUILD_NAME", "your server")
# The main bot's effective guild permission integer — read it from
# GET /users/@me/guilds once the main bot is in your server, and pass it
# here so the team bots get exactly the same powers (including the
# CREATE_PUBLIC_THREADS + SEND_MESSAGES_IN_THREADS bits the thread-per-
# item workflow needs). The baked default is a working superset for a
# fresh server; override with DISCORD_BOT_PERMISSIONS if yours differs.
PERMISSIONS = os.environ.get("DISCORD_BOT_PERMISSIONS", "2248473465835073")
UA = "DiscordBot (https://github.com/<owner>/hermes, 1.0)"
API = "https://discord.com/api/v10"

# The privileged intents the portal must have enabled, matching the main
# bot's application flags (11051008).
PRIVILEGED = {
    1 << 13: "GATEWAY_PRESENCE (limited)",
    1 << 15: "GATEWAY_GUILD_MEMBERS (limited)",
    1 << 19: "GATEWAY_MESSAGE_CONTENT (limited)",
}


def api(path, token):
    req = urllib.request.Request(
        API + path, headers={"Authorization": "Bot " + token, "User-Agent": UA}
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.load(resp)


def collect_token(profile, main_hash, seen):
    """Prompt + validate one token. Returns (token, me, app), or None on EOF."""
    while True:
        token = getpass.getpass(f"  paste the {profile} bot token (hidden): ").strip()
        if not token:
            print("    empty — try again")
            continue
        digest = hashlib.sha256(token.encode()).hexdigest()[:12]
        if main_hash and digest == main_hash:
            print("    ✗ that is the MAIN bot's token — create a separate app")
            continue
        if digest in seen:
            print(f"    ✗ already entered for {seen[digest]}")
            continue

        try:
            me = api("/users/@me", token)
        except urllib.error.HTTPError as exc:
            # Discord normally returns a JSON body explaining the
            # rejection, but never assume the body is readable — a
            # missing one must not turn into a traceback.
            try:
                detail = exc.read().decode()[:120]
            except Exception:
                detail = str(exc.reason or "")
            print(f"    ✗ Discord rejected it ({exc.code}): {detail}")
            continue
        except Exception as exc:
            print(f"    ✗ could not reach Discord: {exc}")
            continue

        if not me.get("bot"):
            print("    ✗ that is a user token, not a bot token")
            continue

        try:
            app = api("/applications/@me", token)
        except Exception:
            app = {}
        flags = app.get("flags", 0)
        missing = [n for bit, n in PRIVILEGED.items() if not flags & bit]

        seen[digest] = profile
        print(f"    ✓ {me['username']} (app id {me['id']})")
        if missing:
            print(f"    ! privileged intents not detected: {', '.join(missing)}")
            print("      enable them on the Bot tab or it will fail to connect")
        return token, me, app


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "profiles", nargs="*", default=PROFILES,
        help=f"profiles to wire (default: {' '.join(PROFILES)})",
    )
    parser.add_argument(
        "--host", default=None,
        help="ssh destination of the docker host (else $HERMES_SSH_HOST)",
    )
    parser.add_argument(
        "--group", default=None,
        help="host group owning the env files (else $HERMES_HOST_GROUP, default ubuntu)",
    )
    parser.add_argument(
        "--env-dir", default=None,
        help="host env dir (else $HERMES_DEPLOY_ENV_DIR, default /etc/hermes)",
    )
    parser.add_argument(
        "--set-var", action="append", default=[], metavar="NAME=VALUE",
        help="merge one more env line in the same push (e.g. that profile's "
        "--set-var DISCORD_CHANNEL_RELEASE=<channel id>) — repeatable",
    )
    args = parser.parse_args(argv)

    unknown = [p for p in args.profiles if p not in PROFILES]
    if unknown:
        parser.error(f"unknown profile(s): {', '.join(unknown)} (have: {', '.join(PROFILES)})")
    for extra in args.set_var:
        if "=" not in extra or not hostdeploy.VAR_RE.match(extra):
            parser.error(f"--set-var must be NAME=value (got: {extra!r})")
    order = list(dict.fromkeys(args.profiles))

    host, group, env_file = hostdeploy.resolve(args.host, args.group, args.env_dir)
    env_text = None
    pushed_channel = False
    if host:
        ok, why = hostdeploy.sudo_ok(host)
        if ok:
            try:
                env_text = hostdeploy.read_remote_file(host, env_file)
                pushed_channel = True
            except hostdeploy.DeployError as exc:
                print(f"could not read the host env file over SSH: {exc}")
        if not pushed_channel:
            print("→ artifact fallback (install-remote.sh)")
    else:
        print("no ssh host given (--host / $HERMES_SSH_HOST) — artifact fallback")

    if env_text is not None:
        match = None
        for line in env_text.splitlines():
            if line.startswith("DISCORD_BOT_TOKEN="):
                match = line
                break
        if not match:
            sys.exit("no DISCORD_BOT_TOKEN in the host env file — is the main bot wired?")
        main_hash = hashlib.sha256(match.split("=", 1)[1].encode()).hexdigest()[:12]
        print(f"main bot token on file (hash {main_hash}) — entered tokens must differ\n")
    else:
        main_hash = None
        print(
            "! cannot read the host env file for the main-token check —\n"
            "  the duplicate check covers only what you enter in this run\n"
        )

    tokens = {}
    seen = {}
    for profile in order:
        result = collect_token(profile, main_hash, seen)
        if result is None:  # EOF on stdin (piped) — nothing half-wired
            print("\ninput ended with nothing for " + profile + " — nothing was written")
            return 1
        tokens[profile] = result
        print()

    lines = ["# Team profile Discord bots (each role its own bot identity)."]
    for profile in order:
        lines.append(f"PROFILE_{profile.upper()}_DISCORD_BOT_TOKEN={tokens[profile][0]}")
    for extra in args.set_var:
        lines.append(extra)

    deployed = False
    if pushed_channel:
        merged, names = hostdeploy.merge_env(env_text, lines)
        try:
            hostdeploy.push_remote_text(host, env_file, group, merged)
            # Read back: a successful install is not evidence (mode, presence).
            back = hostdeploy.read_remote_file(host, env_file)
            for name in names:
                hits = [l for l in back.splitlines() if l.startswith(name + "=")]
                if len(hits) != 1:
                    raise hostdeploy.DeployError(f"{name} appears {len(hits)}x")
            mode = hostdeploy.remote_mode(host, env_file)
        except hostdeploy.DeployError as exc:
            sys.exit(f"push failed after validation — nothing was wired: {exc}")
        deployed = True
        print(f"wired+verified on {host}: {env_file} (mode {mode or 'UNKNOWN — check by hand'})")
        if env_text is not None:
            print(f"(previous content kept as {env_file}.hermes-deploy.bak)")
    if not deployed:
        outdir = os.path.join("build", "discord-bots")
        script, _ = hostdeploy.write_fallback(
            outdir, host or None, group, env_file, env_lines="\n".join(lines)
        )
        print(f"artifacts → {outdir}/  (env-lines.txt is 0600; contains the tokens)")
        action = f"sh {script}"
        print(f"now run:  {action}")

    print("=" * 68)
    print("Bot tokens wired — now invite each bot to the server")
    print("=" * 68)
    for profile in order:
        token, me, app = tokens[profile]
        url = (
            f"https://discord.com/oauth2/authorize?client_id={me['id']}"
            f"&scope=bot&permissions={PERMISSIONS}"
        )
        print(f"\n{profile}: {me['username']}")
        print(f"  {url}")
    print(f"\nPick '{GUILD_NAME}' on each install screen, then merge + deploy.")

    if not deployed:
        print(
            "\nNOTE: nothing was pushed yet — run the install command printed"
            " above\nbefore deploying, or the new token lines are nowhere."
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())