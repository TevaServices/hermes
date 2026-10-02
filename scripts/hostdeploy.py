#!/usr/bin/env python3
"""SSH-push plumbing shared by the local credential scripts.

scripts/create-github-apps.py and scripts/set-team-discord-tokens.py both
run on the OPERATOR'S machine — the one with the browser (App manifests,
invite URLs) and the SSH key. Their artifacts (private keys, token lines)
belong in $HERMES_DEPLOY_ENV_DIR on the docker host, root:<group> 640,
where the container mounts them. Reading that directory needs root, so the
historical flow ended with "ssh in and run this installer by hand, then
append these lines to the env file" — a host-side step where the secrets
could leak into a shell history if done carelessly, and which could also
be forgotten entirely (the deploy then starts nothing, with no error).

This module is the contract that replaces that step:

  * Content travels over SSH STDIN only. A secret NEVER appears inside an
    ssh command line — the remote command names umask, mktemp and paths,
    and the host's process list never shows a credential.
  * Every remote write is mktemp (0600 via umask) → sudo install -o root
    -g <group> -m 640 → atomic install, with the previous content kept as
    <target>.hermes-deploy.bak. Never a widened mode, never a partial
    file.
  * Every push is VERIFIED by reading the target back (content and mode).
    A status code is not evidence (the same principle the cron
    reconciler's read-back check follows).
  * env-file changes are merged, never appended blindly: merge_env()
    replaces by exact variable name and drops the comment lines that
    described a replaced variable — a re-run leaves the file
    byte-identical, and unrelated lines (including other scripts' blocks)
    are untouched.

When the host's sudo can be used non-interactively (`sudo -n true`
succeeds — typical on a key-only cloud host), everything is pushed
automatically. When it needs a password, scripts fall back to
write_fallback(): it generates install-remote.sh, which runs locally,
scp's the artifacts to a private /tmp workdir and does the identical sudo
step through one `ssh -t` (the tty carries the sudo prompt) — one command,
one password prompt, no secrets typed or echoed.

Only stdlib; no argument parsing here — scripts resolve common flags
through resolve(). Test seam: HERMES_SSH_BIN replaces the ssh binary so
scripts/test-hostdeploy.sh can exercise the real command building against
a stub (the same seam shape the gh shim's GH_REAL uses).
"""

import json
import os
import re
import secrets
import shlex
import shutil
import subprocess

# Test seam (scripts/test-hostdeploy.sh): the ssh binary to invoke.
SSH_BIN = os.environ.get("HERMES_SSH_BIN", "ssh")

# The host-side env dir CANNOT reuse HERMES_ENV_DIR: on the repo machine
# mise sets that to the local secrets/ checkout, which would silently
# point remote pushes at the wrong path. The deploy target has its own
# name, defaulting to the real host path.
DEFAULT_ENV_DIR = "/etc/hermes"
DEFAULT_GROUP = "ubuntu"

VAR_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")


class DeployError(RuntimeError):
    """A push/read/probe failed loudly; the caller decides the fallback."""


def resolve(host=None, group=None, env_dir=None):
    """(host, group, env_file) from flags > env vars > defaults.

    env_file is <env_dir>/hermes-main.env — the file both credential
    scripts merge into. host is required for anything remote; an empty
    string means "no SSH destination configured" and callers fall back.
    """
    host = (host or os.environ.get("HERMES_SSH_HOST", "")).strip()
    group = group or os.environ.get("HERMES_HOST_GROUP", DEFAULT_GROUP)
    env_dir = env_dir or os.environ.get("HERMES_DEPLOY_ENV_DIR", DEFAULT_ENV_DIR)
    return host, group, os.path.join(env_dir, "hermes-main.env")


def check_host(host):
    """Reject anything that is not a plain ssh destination.

    An ssh destination is also parsed for OPTIONS, so a value with a
    leading dash could smuggle ProxyCommand etc. through the client.
    Config aliases, IPs and user@host all pass.
    """
    if not host or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._@-]*", host):
        raise DeployError(
            f"refusing ssh destination {host!r} — set --host or HERMES_SSH_HOST"
        )
    return host


def ssh(host, command, text=None, timeout=30):
    """Run one command over SSH, content in via stdin, output captured."""
    check_host(host)
    try:
        return subprocess.run(
            [SSH_BIN, "-o", "ConnectTimeout=10", host, command],
            input=text if text is not None else "",
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise DeployError(f"ssh {host} failed: {exc}") from exc


def sudo_ok(host):
    """Can this SSH account use sudo without a password?"""
    proc = ssh(host, "sudo -n true", timeout=15)
    return proc.returncode == 0, (proc.stderr or proc.stdout or "").strip()[:200]


def read_remote_file(host, path):
    """sudo cat a root-owned host file (content; never in a command line)."""
    check_path(path)
    proc = ssh(host, f"sudo -n cat {shlex.quote(path)}")
    if proc.returncode != 0:
        raise DeployError(
            f"could not read {path} on {host}: "
            f"{(proc.stderr or '').strip()[:200]}"
        )
    return proc.stdout


def remote_mode(host, path):
    """The target's mode and owner as '<mode> <user>:<group>', or None."""
    check_path(path)
    proc = ssh(host, f"sudo -n stat -c '%a %U:%G' {shlex.quote(path)}")
    if proc.returncode != 0:
        return None
    return proc.stdout.strip() or None


def check_path(path):
    """Absolute, no whitespace/no metacharacters — then shlex.quote makes it safe."""
    if not re.fullmatch(r"/[A-Za-z0-9._/@+:-]+", path):
        raise DeployError(f"refusing to touch non-absolute or odd path {path!r}")
    return path


# The umask is the point: the credential sits in a /tmp file for the gap
# between mktemp and install, and umask 077 means that window is 0600
# even though mktemp alone creates 0666&~umask. The .bak keeps the
# previous content so a bad push is a `sudo mv` away from undone.
INSTALL_SNIPPET = (
    "umask 077; t=$(mktemp) || exit 1; trap 'rm -f \"$t\"' EXIT; "
    "cat > \"$t\" || exit 1; "
    "sudo -n cp -p {bak_src} {bak_dst} 2>/dev/null; "
    "sudo -n install -o root -g {group} -m 640 \"$t\" {target}"
)


def push_remote_text(host, target, group, text, timeout=60):
    """Install text at target as root:<group> 640, backing up the old file.

    Raises DeployError with the remote stderr on failure; the caller
    verifies by reading back (a successful exit is not evidence).
    """
    check_path(target)
    if not re.fullmatch(r"[a-zA-Z_][a-zA-Z0-9_-]*", group):
        raise DeployError(f"refusing remote group {group!r}")
    cmd = INSTALL_SNIPPET.format(
        bak_src=shlex.quote(target),
        bak_dst=shlex.quote(target + ".hermes-deploy.bak"),
        group=group,
        target=shlex.quote(target),
    )
    proc = ssh(host, cmd, text=text, timeout=timeout)
    if proc.returncode != 0:
        raise DeployError(
            f"install to {target} on {host} failed: "
            f"{(proc.stderr or proc.stdout or '').strip()[:300]}"
        )
    return True


def merge_env(env_text, lines):
    """Merge KEY=value lines into env-file text; returns (new_text, names).

    Rules, mirrored by the fallback batch script below (the test pins the
    two against each other — keep both in lockstep):
      * a variable line whose name matches an incoming one is REPLACED,
        by exact name (a suffix match never matches);
      * comment lines (and the blank line) immediately above a replaced
        variable are dropped with it — they describe what was replaced,
        so a re-run cannot stack stale '# <profile> (App: ...)' headers;
      * every unrelated line, in order, is untouched;
      * the incoming block (its comment lines included) lands at EOF after
        exactly one blank separator, so running twice is a no-op;
      * a comment line at EOF with no variable after it is presumed block
        residue and dropped — the env files here end in generated blocks,
        never hand-written notes.
    """
    owned = [line for line in lines if line.strip()]
    names = set()
    for line in owned:
        if not line.lstrip().startswith("#") and "=" in line:
            names.add(line.split("=", 1)[0].strip())

    out, pending = [], []  # pending: blank/comment lines that MIGHT be a header
    for line in env_text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            pending.append(line)
            continue
        name = line.split("=", 1)[0].strip()
        if name in names:
            pending = []  # the buffered comments described these variables
            continue
        out.extend(pending)
        pending = []
        out.append(line)
    # Trailing blanks go; trailing comments would just re-attach to the new
    # block forever (they precede no variable), so keep them out too.
    pending = [
        line
        for line in pending
        if line.strip() and not line.lstrip().startswith("#")
    ]
    # (In practice this only ever drops EOF blanks; the block lands clean.)
    out.extend(pending)
    while out and not out[-1].strip():
        out.pop()

    block = ["", *owned] if out else owned
    return "\n".join(out + block) + "\n", sorted(names)


# --- fallback: sudo needs a password ----------------------------------------
#
# sudo -n fails, so nothing can be pushed silently. write_fallback() stages
# the same work as artifacts and generates install-remote.sh: it scp's the
# files into a mode-700 /tmp workdir, runs batch.py ONCE via `ssh -t`
# (single sudo password prompt), and cleans the workdir on every exit.
# batch.py below re-implements push_remote_text + merge_env for the remote
# side — test-hostdeploy.sh holds them to identical behaviour.

FALLBACK_BATCH_PY = r'''
# Generated. Run as root on the docker host: the one sudo step of
# install-remote.sh. Installs the pushed files and merges the env lines,
# with the same rules, backup suffix and verification as
# scripts/hostdeploy.py (pinned by scripts/test-hostdeploy.sh).
import json
import os
import shutil
import sys


def merge_env_text(env_text, owned):
    names = set()
    for line in owned:
        s = line.strip()
        if s and not s.startswith("#") and "=" in s:
            names.add(s.split("=", 1)[0])
    out, pending = [], []
    for line in env_text.splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            pending.append(line)
            continue
        if s.split("=", 1)[0] in names:
            pending = []
            continue
        out.extend(pending)
        pending = []
        out.append(line)
    pending = [l for l in pending if l.strip() and not l.lstrip().startswith("#")]
    out.extend(pending)
    while out and not out[-1].strip():
        out.pop()
    block = ["", *owned] if out else owned
    return "\n".join(out + block) + "\n"


def install(src, dst, group):
    if os.path.exists(dst):
        shutil.copy2(dst, dst + ".hermes-deploy.bak")
    tmp = dst + ".hermes-deploy.tmp"
    shutil.copyfile(src, tmp)
    os.chmod(tmp, 0o640)
    shutil.chown(tmp, group=group)
    os.replace(tmp, dst)


def main():
    manifest = json.load(open(sys.argv[1], encoding="utf-8"))
    here = os.path.dirname(os.path.abspath(sys.argv[1]))
    group = manifest["group"]
    log = []
    for src, dst in manifest.get("pushes", []):
        install(os.path.join(here, src), dst, group)
        log.append("installed " + dst)
    if manifest.get("env_lines"):
        path = os.path.join(here, manifest["env_lines"])
        owned = [l.rstrip("\n") for l in open(path, encoding="utf-8") if l.strip()]
        env_path = manifest["env_path"]
        with open(env_path, encoding="utf-8") as fh:
            new = merge_env_text(fh.read(), owned)
        tmp = env_path + ".hermes-deploy.tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(new)
        os.chmod(tmp, 0o640)
        shutil.chown(tmp, group=group)
        if os.path.exists(env_path):
            shutil.copy2(env_path, env_path + ".hermes-deploy.bak")
        os.replace(tmp, env_path)
        names = [
            l.split("=", 1)[0]
            for l in owned
            if not l.lstrip().startswith("#") and "=" in l
        ]
        with open(env_path, encoding="utf-8") as fh:
            text = fh.read()
        missing = [n for n in names if not any(
            line.startswith(n + "=") for line in text.splitlines())]
        if missing:
            sys.exit("merge verify failed, missing: " + ", ".join(missing))
        log.append("merged %s into %s, verified" % (len(owned), env_path))
    print("hermes-deploy: " + ("; ".join(log) if log else "nothing to do"))


if __name__ == "__main__":
    main()
'''


def write_fallback(outdir, host, group, env_file, pem_pushes=(), env_lines=None):
    """Stage artifacts + generate install-remote.sh; returns (script, files).

    pem_pushes: [(local_path, remote_target), ...] — usually the PEMs.
    env_lines:  the exact env-file lines to merge (a secrets file, so it
                is written 0600 and scp'd -p). None = env untouched.
    host:       the ssh destination, or None when the caller had none —
                the generated script then demands $HERMES_SSH_HOST at run
                time instead of baking a value that was never given.
    """
    os.makedirs(outdir, exist_ok=True)
    workdir = f"/tmp/.hermes-deploy-{secrets.token_hex(6)}"
    files = []
    env_lines_name = None
    if env_lines:
        env_lines_name = "env-lines.txt"
        path = os.path.join(outdir, env_lines_name)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(env_lines if env_lines.endswith("\n") else env_lines + "\n")
        os.chmod(path, 0o600)
        files.append(env_lines_name)

    pushes = [[os.path.basename(src), dst] for src, dst in pem_pushes]
    files.extend(src for src, _ in pushes)
    manifest_path = os.path.join(outdir, "manifest.json")
    with open(manifest_path, "w", encoding="utf-8") as fh:
        json.dump(
            {"group": group, "env_path": env_file, "env_lines": env_lines_name,
             "pushes": pushes},
            fh, indent=2,
        )
        fh.write("\n")

    batch_path = os.path.join(outdir, "batch-deploy.py")
    with open(batch_path, "w", encoding="utf-8") as fh:
        fh.write(FALLBACK_BATCH_PY.lstrip())

    script = os.path.join(outdir, "install-remote.sh")
    with open(script, "w", encoding="utf-8") as fh:
        fh.write("#!/bin/sh\n")
        fh.write(
            "# Generated with no passwordless sudo on the host — this is the"
            " manual step.\n"
            "# Run from the Mac (it cd's to its own dir, where the artifacts"
            " sit):\n"
            f"#   sh {script}\n"
            "# scp's everything into a mode-700 workdir, then ONE `ssh -t`"
            " runs the sudo merge\n"
            "# (you'll be prompted for the host's sudo password once)."
            " Secrets ride scp+stdin,\n"
            "# never a command line. Cleanup runs on every exit.\n"
        )
        fh.write("set -eu\n")
        fh.write('cd "$(dirname "$0")"\n')
        if host:
            fh.write(f"H='{check_host(host)}'\n")
        else:
            fh.write('H="${HERMES_SSH_HOST:?set HERMES_SSH_HOST (or pass --host at generation)}"\n')
        fh.write(f"W='{workdir}'\n")
        fh.write(
            f"trap 'ssh -o ConnectTimeout=10 \"$H\" \"rm -rf {workdir}\""
            " >/dev/null 2>&1 || true' EXIT\n"
        )
        fh.write(f'ssh -o ConnectTimeout=10 "$H" "rm -rf {workdir} && mkdir -m 700 {workdir}"\n')
        names = " ".join(["manifest.json", "batch-deploy.py", *files])
        fh.write(f'scp -q -p {names} "$H:{workdir}/"\n')
        fh.write(f'ssh -t "$H" "sudo python3 {workdir}/batch-deploy.py {workdir}/manifest.json"\n')
    os.chmod(script, 0o755)
    return script, files