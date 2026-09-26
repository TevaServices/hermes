#!/usr/bin/env python3
"""Wire the team profiles' Discord bot tokens into /etc/hermes/hermes-main.env.

Run this ON THE HOMELAB HOST. It prompts for each team bot's token with
hidden input (getpass), so the token never lands in a shell history, a
process list, or a terminal scrollback — and never in a chat transcript.

Before writing anything it validates each token against Discord and
refuses to proceed on:
  * a token Discord rejects
  * the MAIN bot's token (would re-create the duplicate-credential
    refusal that keeps the team gateways from starting)
  * a token already entered for another profile

It then rewrites the PROFILE_<NAME>_DISCORD_BOT_TOKEN lines in the host
env file (idempotent — existing lines are replaced), preserving the
file's mode, and prints the invite URL for each bot.

Why the invite URL matters: a bot token works as soon as the app exists,
but the bot is not IN the guild until someone authorizes it. The URL
carries the same permission integer as the main bot, so the team bots
land with equivalent capability.

The three privileged intents (Presence, Server Members, Message Content)
must be toggled by hand in the Developer Portal — there is no API for it,
and discord.py refuses to connect without them.
"""

import getpass
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

ENV_DIR = os.environ.get("HERMES_ENV_DIR", "/etc/hermes")
ENV_FILE = os.path.join(ENV_DIR, "hermes-main.env")
# Group owning the env file on the host (640, root:<group>).
HOST_GROUP = os.environ.get("HERMES_HOST_GROUP", "ubuntu")
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


def sh(*args, **kw):
    return subprocess.run(args, capture_output=True, text=True, **kw)


def api(path, token):
    req = urllib.request.Request(
        API + path,
        headers={"Authorization": "Bot " + token, "User-Agent": UA},
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.load(resp)


def read_env():
    out = sh("sudo", "cat", ENV_FILE)
    if out.returncode != 0:
        sys.exit(f"cannot read {ENV_FILE}: {out.stderr.strip()}")
    return out.stdout


def main_token_hash(env_text):
    match = re.search(r"^DISCORD_BOT_TOKEN=(.*)$", env_text, re.M)
    if not match:
        sys.exit("no DISCORD_BOT_TOKEN in the env file — is the main bot wired?")
    return hashlib.sha256(match.group(1).encode()).hexdigest()[:12]


def main():
    env_text = read_env()
    main_hash = main_token_hash(env_text)
    print(f"main bot token on file (hash {main_hash}) — entered tokens must differ\n")

    tokens = {}
    seen = {}
    for profile in PROFILES:
        while True:
            token = getpass.getpass(f"  paste the {profile} bot token (hidden): ").strip()
            if not token:
                print("    empty — try again")
                continue
            digest = hashlib.sha256(token.encode()).hexdigest()[:12]
            if digest == main_hash:
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
            missing = [n for b, n in PRIVILEGED.items() if not flags & b]

            tokens[profile] = (token, me, app)
            seen[digest] = profile
            print(f"    ✓ {me['username']} (app id {me['id']})")
            if missing:
                print(f"    ! privileged intents not detected: {', '.join(missing)}")
                print("      enable them on the Bot tab or it will fail to connect")
            break
        print()

    # Rewrite the env file: drop any existing per-profile token lines,
    # then append the fresh set. Keeps every other line untouched.
    lines = [l for l in env_text.splitlines() if not re.match(r"^PROFILE_[A-Z0-9]+_DISCORD_BOT_TOKEN=", l)]
    while lines and not lines[-1].strip():
        lines.pop()
    lines.append("")
    lines.append("# Team profile Discord bots (each role its own bot identity).")
    for profile in PROFILES:
        lines.append(f"PROFILE_{profile.upper()}_DISCORD_BOT_TOKEN={tokens[profile][0]}")
    new_text = "\n".join(lines) + "\n"

    # Write via a root-owned temp file, then move into place — never widen
    # the mode, never leave a partial file.
    with tempfile.NamedTemporaryFile("w", delete=False, dir="/tmp") as fh:
        fh.write(new_text)
        tmp = fh.name
    os.chmod(tmp, 0o600)
    if sh("sudo", "install", "-o", "root", "-g", HOST_GROUP, "-m", "640", tmp, ENV_FILE).returncode:
        sys.exit("failed to install the updated env file")
    os.unlink(tmp)

    print("=" * 68)
    print("Wired into " + ENV_FILE + " — now invite each bot to the server")
    print("=" * 68)
    for profile in PROFILES:
        token, me, app = tokens[profile]
        url = (f"https://discord.com/oauth2/authorize?client_id={me['id']}"
               f"&scope=bot&permissions={PERMISSIONS}")
        print(f"\n{profile}: {me['username']}")
        print(f"  {url}")
    print(f"\nPick '{GUILD_NAME}' on each install screen, then tell Claude to deploy.")


if __name__ == "__main__":
    main()
