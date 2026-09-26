#!/usr/bin/env python3
"""Create this stack's per-profile GitHub Apps through the App Manifest flow.

WHY THIS SCRIPT EXISTS: GitHub has no API to *create* a GitHub App — the
REST API can only manage apps that already exist, and `gh` has no
equivalent of `gh app create`. The manifest flow is the one automatable
path: the browser POSTs a JSON manifest to github.com/settings/apps/new,
the account owner clicks "Create GitHub App", GitHub redirects back with
a temporary code, and that code is exchanged at
POST /app-manifests/{code}/conversions for the app's id, slug and private
key (PEM). The browser step is unavoidable; everything around it is not.

So this script does everything except two clicks per app:

  1. serves http://127.0.0.1:<port>/ and auto-submits the manifest
     (click 1: "Create GitHub App")
  2. catches the redirect, converts the code, writes the PEM (mode 600)
  3. bounces the browser to the install page with "All repositories"
     preselected (click 2: "Install")
  4. catches the post-install setup_url redirect and records the
     installation id — this is why the manifest carries setup_url
  5. chains straight into the next app, then shows a summary page

Artifacts land in build/github-apps/ (gitignored):

  github-app-<profile>.pem   private key, mode 600
  results.json               app id / installation id / slug per profile
  env-lines.txt              the PROFILE_* lines for hermes-main.env
  host-install.sh            copies the PEMs into /etc/hermes on the host

ORG RUNS (--org) namespace everything into build/github-apps/<orgslug>/
with org-slug'd PEM names (github-app-<orgslug>-<profile>.pem) and
org-suffixed env lines (e.g. PROFILE_DEVELOPER_GITHUB_APP_ID_<ORGUC>
plus TEAM_ORG_DEV_BOT_<ORGUC>) — a second run can never clobber the
personal artifacts, and vice versa. Env vars: HERMES_APP_PREFIX_<ORGUC>
or --prefix sets the org App-name prefix; default "<orgslug>-hermes"
(acmecorp-hermes-planner), distinct from the personal names because
GitHub App names are globally unique. Run once PER ORG — any number of
orgs, each with its own block in hermes-main.env.

Secrets are never printed: the PEM is written straight to disk and only
its path is reported. Re-running is safe — an app whose name already
exists fails at click 1 with GitHub's own "name is already taken" error.

Usage:
  python3 scripts/create-github-apps.py                 # the 3 team apps
  python3 scripts/create-github-apps.py planner         # just one
  python3 scripts/create-github-apps.py main            # the default profile's app
  python3 scripts/create-github-apps.py --org my-org    # org-owned apps
  python3 scripts/create-github-apps.py --org my-org main planner developer reviewer
                                                        # org apps for ALL profiles
  python3 scripts/create-github-apps.py --print-url     # don't open a browser

App names default to "<prefix>-<suffix>" (hermes-planner, hermes-dev,
hermes-reviewer). Override per profile with PROFILE_<NAME>_GH_APP_NAME —
GitHub App names are globally unique, so a name collision is fixed that way.
"""

import argparse
import html
import json
import os
import secrets
import shutil
import stat
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

OUTPUT_DIR = os.path.join("build", "github-apps")

# App names default to "<prefix>-<suffix>". GitHub App names are GLOBALLY
# unique, so if the default is taken, set PROFILE_<NAME>_GH_APP_NAME per
# profile (secrets/hermes-main.env.example) and re-run. Org runs get a
# DIFFERENT default prefix — "<orgslug>-hermes" (e.g.
# acmecorp-hermes-planner) — because the personal run's names
# (hermes-planner, …) are taken by the existing personal apps.
#
# The App name must match the App's slug on GitHub, because the bot identity
# git commits carry is "<slug>[bot]" — that is PROFILE_<NAME>_GH_GIT_NAME,
# which write_summary() emits alongside the app id so the two cannot drift.
DEFAULT_APP_PREFIX = os.environ.get("HERMES_APP_PREFIX", "hermes")

# One App per profile, least privilege per role (config/skills/
# team-conventions/SKILL.md — planner reads code, developer drafts PRs,
# reviewer merges). "metadata: read" is mandatory for every App.
#
# `app_suffix` (not the profile name) is what goes into the App name: the
# profile dir is "developer" so its PEM is github-app-developer.pem, but the
# identity the team knows is "<prefix>-dev[bot]".
#
# "main" is the default profile's App (the primary agent). It is opt-in —
# DEFAULT_ORDER covers the team profiles; pass `main` on the
# command line when you want it (the org run needs all of them).
APPS = {
    "main": {
        "app_suffix": "main",
        "description": "Hermes main agent — the default profile: repos, issues, PRs",
        "permissions": {
            "metadata": "read",
            "contents": "write",
            "issues": "write",
            "pull_requests": "write",
        },
    },
    "planner": {
        "app_suffix": "planner",
        "description": "Hermes planner — PM/design: issues, specs, boards (read-only code)",
        "permissions": {
            "metadata": "read",
            "contents": "read",
            "issues": "write",
            "pull_requests": "read",
        },
    },
    "developer": {
        "app_suffix": "dev",
        "description": "Hermes developer — implementation: branches and draft pull requests",
        "permissions": {
            "metadata": "read",
            "contents": "write",
            "issues": "write",
            "pull_requests": "write",
        },
    },
    "reviewer": {
        "app_suffix": "reviewer",
        "description": "Hermes reviewer — review gates; hands off to release",
        "permissions": {
            "metadata": "read",
            "contents": "write",
            "issues": "write",
            "pull_requests": "write",
        },
    },
    "release": {
        "app_suffix": "release",
        # Merges the approved PR and files the bug issues a failed release
        # produces. Deliberately WITHOUT the `workflows` permission, like
        # every other team App: a workflow file runs arbitrary code with the
        # repo's secrets, so granting it would widen what a confused agent
        # could do. An item that needs CI changes is the user's to land.
        "description": "Hermes release — merges approved PRs, cuts releases, deploys and validates",
        "permissions": {
            "metadata": "read",
            "contents": "write",
            "issues": "write",
            "pull_requests": "write",
        },
    },
}


def org_slug(org: str) -> str:
    """The org's slug: lowercase [a-z0-9] only — used in filenames."""
    return "".join(c for c in org.lower() if c.isalnum())


def org_var_suffix(org: str) -> str:
    """The env-var suffix for an org: uppercase, non-[A-Z0-9] -> '_'.

    "Acme Corp" -> ACME_CORP. Used for GITHUB_APP_ID_<ORGUC> and friends;
    the entrypoint's slug derivation (lowercase, strip non-alphanumerics)
    maps it back to the same slug both spellings share.
    """
    return "".join(c if c.isalnum() else "_" for c in org.upper())


def app_name(profile: str, org=None) -> str:
    """The App name for a profile.

    Personal runs: PROFILE_<NAME>_GH_APP_NAME wins; otherwise
    "<prefix>-<suffix>" from HERMES_APP_PREFIX (default "hermes").
    Org runs: PROFILE_<NAME>_GH_APP_NAME_<ORGUC> wins; then --prefix /
    HERMES_APP_PREFIX_<ORGUC>; then default "<orgslug>-hermes" — a
    different default from the personal run, because GitHub App names
    are globally unique and the personal run's names are taken.
    """
    if org:
        orguc = org_var_suffix(org)
        override = os.environ.get(f"PROFILE_{profile.upper()}_GH_APP_NAME_{orguc}", "").strip()
        if override:
            return override
        prefix = os.environ.get(f"HERMES_APP_PREFIX_{orguc}", "").strip()
        if not prefix:
            prefix = org_slug(org) + "-hermes"
        return f"{prefix}-{APPS[profile]['app_suffix']}"
    override = os.environ.get(f"PROFILE_{profile.upper()}_GH_APP_NAME", "").strip()
    if override:
        return override
    return f"{DEFAULT_APP_PREFIX}-{APPS[profile]['app_suffix']}"


def bot_login(profile: str, org=None) -> str:
    """The bot identity git commits carry — the App slug plus `[bot]`."""
    return f"{app_name(profile, org)}[bot]"


def gh_login():
    """This machine's gh login, used to build the default homepage URL."""
    exe = shutil.which("gh")
    if not exe:
        return None
    try:
        out = subprocess.run(
            [exe, "api", "user", "--jq", ".login"],
            capture_output=True,
            text=True,
            timeout=15,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return out.stdout.strip() or None


def owner_for(org):
    """The account the Apps belong to: --org, else the local gh login."""
    if org:
        return org
    return gh_login() or "<owner>"


DEFAULT_ORDER = ["planner", "developer", "reviewer", "release"]


# --- tiny HTML helpers ------------------------------------------------------

PAGE_CSS = """
body{font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;
     max-width:44rem;margin:12vh auto;padding:0 1.5rem;color:#1f2328}
h1{font-size:1.35rem;margin:0 0 .4rem}
p{margin:.5rem 0}
code{background:#f0f1f3;padding:.15em .4em;border-radius:4px;font-size:.9em}
ol{margin:.8rem 0}
.ok{font-size:2rem;margin:0 0 .2rem}
.muted{color:#656d76}
.err{color:#b62324}
.step{border-left:3px solid #d0d7de;padding-left:1rem;margin:1.2rem 0}
"""


def page(title, body, head=""):
    """Wrap body in a minimal page. head is injected into <head>."""
    return (
        "<!doctype html><meta charset=utf-8>"
        f"<title>{html.escape(title)}</title>"
        f"<style>{PAGE_CSS}</style>{head}"
        f"<h1>{html.escape(title)}</h1>{body}"
    )


def redirect_page(title, body, url, delay=1.5):
    """A page that shows body, then moves the browser on to url."""
    head = f'<meta http-equiv="refresh" content="{delay};url={html.escape(url)}">'
    body += (
        f'<p class="muted">Continuing automatically… '
        f'<a href="{html.escape(url)}">or click here</a>.</p>'
        "<script>setTimeout(function(){location.href="
        f"{json.dumps(url)};}},{int(delay * 1000)})</script>"
    )
    return page(title, body, head)


# --- the flow ---------------------------------------------------------------


class Flow:
    """Shared state between the HTTP handler and the driving thread."""

    def __init__(self, order, outdir, port, repo_url, org=None):
        self.order = order
        self.outdir = outdir
        self.port = port
        self.repo_url = repo_url
        # None = create USER-owned Apps; an org name = create org-owned Apps
        # (the manifest must be POSTed to the org's settings URL for that).
        self.org = org
        self.tokens = {}  # csrf state token -> profile
        self.pending_install = None  # profile whose install page we opened
        self.results = {}  # profile -> {app_id, slug, installation_id, ...}
        self.finished = threading.Event()

    def manifest_url(self):
        """Where the browser POSTs the manifest — org-owned or user-owned."""
        if self.org:
            return f"https://github.com/organizations/{self.org}/settings/apps/new"
        return "https://github.com/settings/apps/new"

    def base(self):
        return f"http://127.0.0.1:{self.port}"

    def new_token(self, profile):
        token = secrets.token_urlsafe(24)
        self.tokens[token] = profile
        return token

    def next_pending(self):
        """First profile in order with no installation_id recorded yet."""
        for profile in self.order:
            if not self.results.get(profile, {}).get("installation_id"):
                return profile
        return None

    def manifest(self, profile):
        app = APPS[profile]
        return {
            "name": app_name(profile, self.org),
            "url": self.repo_url,
            "description": app["description"],
            "redirect_url": f"{self.base()}/manifest/callback",
            # setup_url is what hands us the installation id: GitHub
            # redirects here (rather than to github.com/settings) after
            # an install, appending ?installation_id=…&setup_action=install
            "setup_url": f"{self.base()}/setup",
            "setup_on_update": True,
            "public": False,
            "request_oauth_on_install": False,
            "default_permissions": app["permissions"],
            "default_events": [],
            # No webhook: the team works GitHub-first via pull/poll, not
            # event push. active:false keeps GitHub from delivering
            # anywhere. The placeholder URL is never contacted.
            "hook_attributes": {
                "url": "https://example.com/hermes-unused-webhook",
                "active": False,
            },
        }


def gh_token():
    """This machine's gh token, used only as a conversion fallback."""
    exe = shutil.which("gh")
    if not exe:
        return None
    try:
        out = subprocess.run(
            [exe, "auth", "token"], capture_output=True, text=True, timeout=15
        )
    except (OSError, subprocess.SubprocessError):
        return None
    token = out.stdout.strip()
    return token or None


def convert(code):
    """Exchange a manifest code for the app's credentials.

    The code is the credential, so this normally needs no auth; a token
    is attached only if the unauthenticated attempt is rejected.
    """
    url = f"https://api.github.com/app-manifests/{code}/conversions"
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "hermes-app-manifest/1.0",
    }
    attempts = [headers]
    token = gh_token()
    if token:
        attempts.append({**headers, "Authorization": f"Bearer {token}"})

    last = None
    for attempt in attempts:
        req = urllib.request.Request(url, method="POST", headers=attempt)
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.load(resp)
        except urllib.error.HTTPError as exc:
            last = exc
            if exc.code not in (401, 403, 404):
                break
        except urllib.error.URLError as exc:
            last = exc
            break
    raise RuntimeError(f"manifest conversion failed: {last}")


def save_app(app, flow, profile):
    """Write the PEM and record the app's identity. Never logs the key."""
    pem = app.get("pem")
    if not pem:
        raise RuntimeError("conversion response carried no private key")
    if flow.org:
        pem_name = f"github-app-{org_slug(flow.org)}-{profile}.pem"
    else:
        pem_name = f"github-app-{profile}.pem"
    path = os.path.join(flow.outdir, pem_name)
    # Create private from the start, then tighten — never a window where
    # the key is world-readable.
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write(pem if pem.endswith("\n") else pem + "\n")
    os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)

    flow.results.setdefault(profile, {}).update(
        {
            "app_name": app.get("name"),
            "app_id": app.get("id"),
            "app_slug": app.get("slug"),
            "client_id": app.get("client_id"),
            "html_url": app.get("html_url"),
            "pem_path": path,
        }
    )
    return path


class Handler(BaseHTTPRequestHandler):
    flow = None  # set in main()

    def log_message(self, *args):
        pass  # quiet: the browser carries the narrative, not this terminal

    def send_html(self, body, code=200):
        raw = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        flow = self.flow
        parsed = urlparse(self.path)
        qs = parse_qs(parsed.query)
        route = parsed.path

        if route == "/":
            self.handle_start(qs)
        elif route == "/manifest/callback":
            self.handle_callback(qs)
        elif route == "/setup":
            self.handle_setup(qs)
        elif route == "/done":
            self.handle_done()
        else:
            self.send_html(page("Not found", "<p>Nothing here.</p>"), 404)

    # --- routes ---

    def handle_start(self, qs):
        flow = self.flow
        requested = (qs.get("app") or [None])[0]
        profile = requested if requested in flow.order else flow.next_pending()
        if profile is None:
            self.send_html(redirect_page("All done", "", f"{flow.base()}/done", 0.5))
            return

        app = APPS[profile]
        token = flow.new_token(profile)
        manifest = html.escape(json.dumps(flow.manifest(profile)), quote=True)
        remaining = [p for p in flow.order if p != profile and not flow.results.get(p, {}).get("installation_id")]
        body = (
            f'<div class="step"><p>Creating the GitHub App '
            f'<code>{html.escape(app_name(profile, flow.org))}</code> for the '
            f'<strong>{html.escape(profile)}</strong> profile.</p>'
            "<p>On the GitHub page that opens, click "
            "<strong>Create GitHub App</strong>.</p>"
            f'<p class="muted">Permissions: '
            f'{html.escape(", ".join(f"{k}:{v}" for k, v in sorted(app["permissions"].items())))}</p>'
            + (
                f'<p class="muted">Still to do: {html.escape(", ".join(remaining))}</p>'
                if remaining
                else ""
            )
            + "</div>"
            "<p>Submitting to GitHub…</p>"
            f'<form id="m" method="post" '
            f'action="{html.escape(flow.manifest_url())}?state={html.escape(token)}">'
            f'<input type="hidden" name="manifest" value="{manifest}"></form>'
            "<script>document.getElementById('m').submit()</script>"
        )
        self.send_html(page(f"Create {app_name(profile, flow.org)}", body))

    def handle_callback(self, qs):
        flow = self.flow
        code = (qs.get("code") or [None])[0]
        token = (qs.get("state") or [None])[0]
        profile = flow.tokens.pop(token, None)

        if not code or not profile:
            self.send_html(
                page("Manifest callback rejected",
                     '<p class="err">Missing or mismatched <code>code</code>/'
                     '<code>state</code>.</p><p>Start over: '
                     f'<a href="{flow.base()}/">retry</a>.</p>'),
                400,
            )
            return

        try:
            app = convert(code)
            save_app(app, flow, profile)
        except Exception as exc:  # surfaced in the browser, not swallowed
            self.send_html(
                page("App creation failed",
                     f'<p class="err">{html.escape(str(exc))}</p>'
                     f'<p>Re-run the script to retry <code>{html.escape(profile)}</code>.</p>'),
                500,
            )
            return

        flow.pending_install = profile
        slug = flow.results[profile]["app_slug"]
        install_url = f"https://github.com/apps/{slug}/installations/new"
        body = (
            f'<p class="ok">✓</p><p>Created <code>{html.escape(flow.results[profile]["app_name"])}</code> '
            f'(app id {flow.results[profile]["app_id"]}).</p>'
            '<div class="step"><p>Next: on the install page, choose '
            '<strong>All repositories</strong>, then click <strong>Install</strong>.</p></div>'
        )
        self.send_html(redirect_page("App created", body, install_url))

    def handle_setup(self, qs):
        flow = self.flow
        installation_id = (qs.get("installation_id") or [None])[0]
        profile = flow.pending_install

        if not installation_id or not profile:
            self.send_html(
                page("Install callback rejected",
                     '<p class="err">No <code>installation_id</code>, or no '
                     "install was pending.</p>"),
                400,
            )
            return

        flow.results.setdefault(profile, {})["installation_id"] = installation_id
        flow.results[profile]["repository_selection"] = (
            (qs.get("setup_action") or ["install"])[0]
        )
        flow.pending_install = None

        nxt = flow.next_pending()
        if nxt:
            body = (
                f'<p class="ok">✓</p><p>Installed <code>{html.escape(profile)}</code> '
                f'(installation id {html.escape(str(installation_id))}).</p>'
                f'<p>Next: <strong>{html.escape(nxt)}</strong>.</p>'
            )
            self.send_html(redirect_page("Installed", body, f"{flow.base()}/?app={nxt}", 2.5))
        else:
            self.send_html(
                redirect_page(
                    "All apps installed",
                    f'<p class="ok">✓</p><p>Installed <code>{html.escape(profile)}</code> '
                    f'(installation id {html.escape(str(installation_id))}).</p>',
                    f"{flow.base()}/done",
                    0.8,
                )
            )

    def handle_done(self):
        flow = self.flow
        rows = "".join(
            f"<li><code>{html.escape(p)}</code> — app {r.get('app_id')}, "
            f"installation {r.get('installation_id')}</li>"
            for p, r in flow.results.items()
            if r.get("installation_id")
        )
        self.send_html(
            page(
                "All GitHub Apps ready",
                f"<p>You can close this tab and return to the terminal.</p><ul>{rows}</ul>",
            )
        )
        flow.finished.set()


# --- summary ----------------------------------------------------------------


def env_lines(order, results, org=None):
    """The hermes-main.env lines for what this run created.

    Personal runs emit the classic bare PROFILE_* vars; org runs emit the
    ORG-SUFFIXED vars (org as an uppercase suffix, e.g.
    PROFILE_DEVELOPER_GITHUB_APP_INSTALLATION_ID_ACME_CORP) plus the
    org routing line (TEAM_ORG_DEV_BOT_<ORGUC>) that the self-pull
    queues read for the org author filter.
    """
    orguc = org_var_suffix(org) if org else None
    if org:
        slug = org_slug(org)
        lines = [
            f"# ORG Apps ({orguc}) — PEMs install as"
            f" github-app-{slug}-<profile>.pem, descriptors are wired by"
            " the entrypoint",
            f"# (also add the org to TEAM_OWNER_ORGS so the queues poll it)",
        ]
    else:
        orguc = None
        lines = []
    for profile in order:
        r = results.get(profile)
        if not r or not r.get("installation_id"):
            continue
        if orguc:
            if profile == "main":
                p = ""
            else:
                p = "PROFILE_%s_" % profile.upper()
            lines.append(f"# {profile} (org {orguc} App: {r['app_name']})")
            lines.append(f"{p}GITHUB_APP_ID_{orguc}={r['app_id']}")
            lines.append(f"{p}GITHUB_APP_INSTALLATION_ID_{orguc}={r['installation_id']}")
            lines.append(f"{p}GH_GIT_NAME_{orguc}={r['app_name']}[bot]")
            lines.append(
                f"{p}GH_GIT_EMAIL_{orguc}={r['app_name']}[bot]@users.noreply.github.com"
            )
        else:
            var = profile.upper()
            lines.append(f"# {profile} (App: {r['app_name']})")
            lines.append(f"PROFILE_{var}_GITHUB_APP_ID={r['app_id']}")
            lines.append(f"PROFILE_{var}_GITHUB_APP_INSTALLATION_ID={r['installation_id']}")
            # Derived, so the commit identity can never drift from the App the
            # commits are actually minted from. The entrypoint uses these to set
            # the profile's git author/committer.
            lines.append(f"PROFILE_{var}_GH_APP_NAME={r['app_name']}")
            lines.append(f"PROFILE_{var}_GH_GIT_NAME={bot_login(profile)}")
            lines.append(
                f"PROFILE_{var}_GH_GIT_EMAIL={bot_login(profile)}@users.noreply.github.com"
            )
    if org:
        dev = results.get("developer") or {}
        if dev.get("installation_id"):
            lines.append(f"TEAM_ORG_DEV_BOT_{orguc}={dev['app_name']}[bot]")
    return "\n".join(lines)


def write_summary(flow):
    outdir = flow.outdir
    done = {p: r for p, r in flow.results.items() if r.get("installation_id")}
    suffix = f"-{org_slug(flow.org)}" if flow.org else ""

    with open(os.path.join(outdir, f"results{suffix}.json"), "w") as fh:
        json.dump(flow.results, fh, indent=2, sort_keys=True)
        fh.write("\n")

    with open(os.path.join(outdir, f"env-lines{suffix}.txt"), "w") as fh:
        fh.write(env_lines(flow.order, flow.results, org=flow.org) + "\n")

    env_dir = os.environ.get("HERMES_ENV_DIR", "/etc/hermes")
    group = os.environ.get("HERMES_HOST_GROUP", "ubuntu")
    script = os.path.join(outdir, f"host-install{suffix}.sh")
    with open(script, "w") as fh:
        fh.write("#!/bin/sh\n")
        fh.write(f"# Run ON THE DOCKER HOST (the Komodo Periphery machine) from\n")
        fh.write(f"# the repo checkout. Installs the App private keys into\n")
        fh.write(f"# {env_dir} as root:{group} 640.\n")
        fh.write("set -eu\n")
        for profile in flow.order:
            if profile not in done:
                continue
            if flow.org:
                slug = org_slug(flow.org)
                src = f"{OUTPUT_DIR}/{slug}/github-app-{slug}-{profile}.pem"
                dst = f"{env_dir}/github-app-{slug}-{profile}.pem"
            else:
                src = f"{OUTPUT_DIR}/github-app-{profile}.pem"
                dst = f"{env_dir}/github-app-{profile}.pem"
            fh.write(f"sudo install -o root -g {group} -m 640 {src} {dst}\n")
    os.chmod(script, 0o755)

    print("\n" + "=" * 68)
    print("GitHub Apps created")
    print("=" * 68)
    for profile in flow.order:
        r = flow.results.get(profile)
        if not r:
            print(f"  {profile:<10} — not created")
            continue
        if not r.get("installation_id"):
            print(f"  {profile:<10} — app {r['app_id']} created, NOT INSTALLED")
            continue
        print(
            f"  {profile:<10} — app {r['app_id']}, "
            f"installation {r['installation_id']}, {r['app_name']}"
        )
        print(f"               PEM: {r['pem_path']}")

    print(f"\nEnv lines → {os.path.join(outdir, 'env-lines.txt')}")
    print(env_lines(flow.order, flow.results))
    print(
        f"\nNext:\n"
        f"  1. add those lines to hermes-main.env on the host\n"
        f"  2. copy the PEMs in:  sh {os.path.join(outdir, 'host-install.sh')}\n"
        f"  3. commit the env-file change if the templates need it, then deploy"
    )


# --- entry point ------------------------------------------------------------


def free_port(preferred):
    import socket

    for candidate in [preferred] + list(range(8766, 8790)):
        with socket.socket() as sock:
            try:
                sock.bind(("127.0.0.1", candidate))
                return candidate
            except OSError:
                continue
    raise SystemExit("no free local port for the manifest flow")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "profiles",
        nargs="*",
        default=DEFAULT_ORDER,
        help=f"profiles to create apps for (default: {' '.join(DEFAULT_ORDER)})",
    )
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument(
        "--print-url",
        action="store_true",
        help="print the URL instead of opening a browser",
    )
    parser.add_argument("--timeout", type=int, default=1800, help="seconds")
    parser.add_argument(
        "--org",
        metavar="NAME",
        help="create the Apps OWNED BY this organization instead of your "
        "user account (the browser must be logged in with admin rights on "
        "it). Omit for user-owned Apps.",
    )
    parser.add_argument(
        "--prefix",
        help="override the App-NAME prefix for this run (org default: "
        "'<orgslug>-hermes'; personal: $HERMES_APP_PREFIX, default 'hermes'). "
        "Per-profile overrides still win: PROFILE_<NAME>_GH_APP_NAME, or "
        "PROFILE_<NAME>_GH_APP_NAME_<ORG> on an org run.",
    )
    parser.add_argument(
        "--repo-url",
        help="the App's homepage URL (default: https://github.com/<owner>/hermes, "
        "where <owner> is --org if given, else your gh login)",
    )
    args = parser.parse_args(argv)

    if args.prefix:
        if args.org:
            os.environ[f"HERMES_APP_PREFIX_{org_var_suffix(args.org)}"] = args.prefix
        else:
            os.environ["HERMES_APP_PREFIX"] = args.prefix

    unknown = [p for p in args.profiles if p not in APPS]
    if unknown:
        raise SystemExit(f"unknown profile(s): {', '.join(unknown)} (have: {', '.join(APPS)})")
    order = list(dict.fromkeys(args.profiles))

    repo_url = args.repo_url or f"https://github.com/{owner_for(args.org)}/hermes"

    # Org runs namespace EVERYTHING into their own subdirectory (and
    # their PEMs carry the org slug), so a second run can never clobber
    # the personal PEMs and vice versa.
    outdir = OUTPUT_DIR
    if args.org:
        outdir = os.path.join(OUTPUT_DIR, org_slug(args.org))
    os.makedirs(outdir, exist_ok=True)

    port = free_port(args.port)
    flow = Flow(order, outdir, port, repo_url=repo_url, org=args.org)
    Handler.flow = flow

    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()

    start = f"{flow.base()}/?app={order[0]}"
    print(f"Serving the manifest flow on {flow.base()}")
    print(f"  apps, in order: {', '.join(order)}")
    print(f"  app owner:     {args.org or owner_for(None)}")
    for profile in order:
        print(f"    {profile:<10} -> {app_name(profile, args.org)}")
    print(f"  homepage:      {repo_url}")
    print(f"  artifacts →    {outdir}/")
    print("\nTwo clicks per app: Create GitHub App, then Install (All repositories).")
    if args.print_url:
        print(f"\nOpen this in the browser you're logged into GitHub with:\n  {start}\n")
    else:
        print("Opening your browser…\n")
        webbrowser.open(start)

    completed = flow.finished.wait(timeout=args.timeout)
    server.shutdown()

    if not completed:
        print("\nTimed out waiting for the flow to finish.")

    missing = [p for p in order if not flow.results.get(p, {}).get("installation_id")]
    write_summary(flow)

    if missing:
        print(f"\nIncomplete: {', '.join(missing)} — re-run for just those:")
        print(f"  python3 {sys.argv[0]} {' '.join(missing)}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
