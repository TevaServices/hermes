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

Secrets are never printed: the PEM is written straight to disk and only
its path is reported. Re-running is safe — an app whose name already
exists fails at click 1 with GitHub's own "name is already taken" error.

Usage:
  python3 scripts/create-github-apps.py                 # the 3 team apps
  python3 scripts/create-github-apps.py planner         # just one
  python3 scripts/create-github-apps.py --print-url     # don't open a browser
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

REPO_URL = "https://github.com/<owner>/hermes"
OUTPUT_DIR = os.path.join("build", "github-apps")

# One App per profile, least privilege per role (config/skills/
# team-conventions/SKILL.md — planner reads code, developer drafts PRs,
# reviewer merges). "metadata: read" is mandatory for every App.
#
# The profile name (config/profiles/<name>/) and the App name differ for
# the developer — the profile is "developer" (so the PEM is
# github-app-developer.pem) but the identity the team knows is
# hermes-dev[bot] (secrets/hermes-main.env.example
# PROFILE_DEVELOPER_GH_GIT_NAME). Keep app_name in sync with that.
APPS = {
    "planner": {
        "app_name": "hermes-planner",
        "description": "Hermes planner — PM/design: issues, specs, boards (read-only code)",
        "permissions": {
            "metadata": "read",
            "contents": "read",
            "issues": "write",
            "pull_requests": "read",
        },
    },
    "developer": {
        "app_name": "hermes-dev",
        "description": "Hermes developer — implementation: branches and draft pull requests",
        "permissions": {
            "metadata": "read",
            "contents": "write",
            "issues": "write",
            "pull_requests": "write",
        },
    },
    "reviewer": {
        "app_name": "hermes-reviewer",
        "description": "Hermes reviewer — review gates and merges after the human gate",
        "permissions": {
            "metadata": "read",
            "contents": "write",
            "issues": "write",
            "pull_requests": "write",
        },
    },
}

DEFAULT_ORDER = ["planner", "developer", "reviewer"]


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

    def __init__(self, order, outdir, port):
        self.order = order
        self.outdir = outdir
        self.port = port
        self.tokens = {}  # csrf state token -> profile
        self.pending_install = None  # profile whose install page we opened
        self.results = {}  # profile -> {app_id, slug, installation_id, ...}
        self.finished = threading.Event()

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
            "name": app["app_name"],
            "url": REPO_URL,
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
    path = os.path.join(flow.outdir, f"github-app-{profile}.pem")
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
            f'<code>{html.escape(app["app_name"])}</code> for the '
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
            f'action="https://github.com/settings/apps/new?state={html.escape(token)}">'
            f'<input type="hidden" name="manifest" value="{manifest}"></form>'
            "<script>document.getElementById('m').submit()</script>"
        )
        self.send_html(page(f"Create {app['app_name']}", body))

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


def env_lines(order, results):
    lines = []
    for profile in order:
        r = results.get(profile)
        if not r or not r.get("installation_id"):
            continue
        var = profile.upper()
        lines.append(f"# {profile} (App: {r['app_name']})")
        lines.append(f"PROFILE_{var}_GITHUB_APP_ID={r['app_id']}")
        lines.append(f"PROFILE_{var}_GITHUB_APP_INSTALLATION_ID={r['installation_id']}")
    return "\n".join(lines)


def write_summary(flow):
    outdir = flow.outdir
    done = {p: r for p, r in flow.results.items() if r.get("installation_id")}

    with open(os.path.join(outdir, "results.json"), "w") as fh:
        json.dump(flow.results, fh, indent=2, sort_keys=True)
        fh.write("\n")

    with open(os.path.join(outdir, "env-lines.txt"), "w") as fh:
        fh.write(env_lines(flow.order, flow.results) + "\n")

    script = os.path.join(outdir, "host-install.sh")
    with open(script, "w") as fh:
        fh.write("#!/bin/sh\n")
        fh.write("# Run ON THE HOMELAB HOST from the repo checkout.\n")
        fh.write("set -eu\n")
        for profile in flow.order:
            if profile not in done:
                continue
            fh.write(
                f"sudo install -o root -g ubuntu -m 640 "
                f"{OUTPUT_DIR}/github-app-{profile}.pem "
                f"/etc/hermes/github-app-{profile}.pem\n"
            )
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
    args = parser.parse_args(argv)

    unknown = [p for p in args.profiles if p not in APPS]
    if unknown:
        raise SystemExit(f"unknown profile(s): {', '.join(unknown)} (have: {', '.join(APPS)})")
    order = list(dict.fromkeys(args.profiles))

    outdir = OUTPUT_DIR
    os.makedirs(outdir, exist_ok=True)

    port = free_port(args.port)
    flow = Flow(order, outdir, port)
    Handler.flow = flow

    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()

    start = f"{flow.base()}/?app={order[0]}"
    print(f"Serving the manifest flow on {flow.base()}")
    print(f"  apps, in order: {', '.join(order)}")
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
