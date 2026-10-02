#!/bin/sh
# Offline test for scripts/hostdeploy.py — the SSH-push contract shared by
# create-github-apps.py and set-team-discord-tokens.py.
#
# WHY THIS EXISTS
#
# Both credential scripts used to end with a host-side step ("ssh in, run
# the installer, append these lines by hand"), where the secrets could leak
# into a shell history and the step itself could be forgotten silently. The
# scripts now push over SSH with sudo. Two contracts here are easy to break
# by accident and near-impossible to see break from the outside:
#
#   1. a secret never appears in an ssh COMMAND LINE — the host's process
#      list, `sudo audit`, and any command logging would capture it; the
#      content travels through stdin and mktemp→install on the host;
#   2. merge_env replaces by EXACT variable name and drops the comments
#      describing replaced variables — the fallback batch script ships a
#      COPY of that algorithm (it runs standalone on the host), so the copy
#      must behave identically or the two deploy paths disagree.
#
#   3. plus the invariants that make a push safe: mode exactly 640
#      root:<group>, the previous file kept as .hermes-deploy.bak, a
#      re-merge byte-identical, and ssh destinations/paths/group names
#      validated before anything runs.
#
# Run: $ mise run test      (or: sh scripts/test-hostdeploy.sh)
# Network-free: ssh is a stub (HERMES_SSH_BIN seam).

set -u

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d) || exit 2
trap 'rm -rf "$tmp"' EXIT INT TERM

PYTHONPATH="$here/scripts"
export PYTHONPATH

[ -f "$here/scripts/hostdeploy.py" ] || { echo "hostdeploy.py not found" >&2; exit 2; }

cat > "$tmp/ssh-stub" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${STUB_LOG:?}"
case "$*" in
  *"sudo -n true"*)
    [ -n "${STUB_SUDO_FAIL:-}" ] && { echo "password required" >&2; exit 1; }
    ;;
  *"sudo -n cat"*) cat "${STUB_ENV_FILE:?}" ;;
  *"sudo -n stat"*) printf '%s\n' "640 root:${STUB_GROUP:?}" ;;
  *"sudo -n install"*)
    [ -n "${STUB_INSTALL_FAIL:-}" ] && { echo "install failed" >&2; exit 1; }
    cat > "${STUB_PUSHED:?}"   # pushed content arrives on stdin
    ;;
esac
EOF
chmod 755 "$tmp/ssh-stub"

group=$(id -gn)
export STUB_LOG="$tmp/stub.log"
export STUB_ENV_FILE="$tmp/env-fixture"
export STUB_PUSHED="$tmp/pushed-content"
export STUB_GROUP="$group"
HERMES_SSH_BIN="$tmp/ssh-stub" python3 - <<'PY'
import json
import os
import secrets
import subprocess
import sys

import hostdeploy

tmp = os.path.dirname(os.environ["STUB_LOG"])

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


# --- 1. merge: replace by exact name, drop the replaced vars' comments ------
env = "\n".join(
    [
        "# leading comment above an untouched var (must survive)",
        "LITELLM_MASTER_KEY=abc",
        "# mid-file comment above an unowned var (must survive)",
        "PROFILE_MESSENGER_EXTRA=keep",
        "# Team profile Discord bots (block header — dropped with the replaced var)",
        "PROFILE_PLANNER_DISCORD_BOT_TOKEN=old-planner",
        "PROFILE_DEVELOPER_DISCORD_BOT_TOKEN=old-dev",
        "# end-of-file comment (presumed block residue)",
        "",
    ]
)
lines = [
    "# Team profile Discord bots (each role its own bot identity).",
    "PROFILE_PLANNER_DISCORD_BOT_TOKEN=new-planner",
    "PROFILE_RELEASE_DISCORD_BOT_TOKEN=new-release",
]
merged, names = hostdeploy.merge_env(env, lines)
check(
    "merge replaces an owned var",
    "PROFILE_PLANNER_DISCORD_BOT_TOKEN=new-planner" in merged
    and "old-planner" not in merged,
)
check(
    "merge drops the comment that described the replaced vars",
    merged.count("Team profile Discord bots") == 1,
)
check("merge keeps an UNOWNED var and unrelated comments",
      "PROFILE_DEVELOPER_DISCORD_BOT_TOKEN=old-dev" in merged
      and "PROFILE_MESSENGER_EXTRA=keep" in merged
      and "leading comment above an untouched var" in merged
      and "mid-file comment above an unowned var" in merged)
check("merge drops a trailing EOF comment (documented residue rule)",
      "end-of-file comment" not in merged)
check("merge covers only the incoming names", names == [
    "PROFILE_PLANNER_DISCORD_BOT_TOKEN", "PROFILE_RELEASE_DISCORD_BOT_TOKEN"])
check("merge is byte-idempotent", hostdeploy.merge_env(merged, lines)[0] == merged)
check("merge on an empty file emits just the block",
      hostdeploy.merge_env("", lines)[0] == "\n".join(lines) + "\n")
check("merge keeps LITELLM_MASTER_KEY", "LITELLM_MASTER_KEY=abc" in merged)

# --- 2. the fallback batch merge behaves IDENTICALLY -------------------------
src = os.path.join(tmp, "case")
os.makedirs(src, exist_ok=True)
with open(os.path.join(src, "lines"), "w") as fh:
    fh.write("\n".join(lines) + "\n")
with open(os.path.join(src, "env"), "w") as fh:
    fh.write(env)
with open(os.path.join(src, "batch.py"), "w") as fh:
    fh.write(hostdeploy.FALLBACK_BATCH_PY.lstrip())
manifest = {
    "group": os.environ["STUB_GROUP"],
    "env_path": os.path.join(src, "env"),
    "env_lines": "lines",
    "pushes": [],
}
with open(os.path.join(src, "manifest.json"), "w") as fh:
    json.dump(manifest, fh)
r = subprocess.run(
    [sys.executable, os.path.join(src, "batch.py"), os.path.join(src, "manifest.json")],
    capture_output=True, text=True,
)
check("fallback batch exits 0", r.returncode == 0, r.stderr[-300:])
try:
    with open(os.path.join(src, "env")) as fh:
        batch_result = fh.read()
except FileNotFoundError:
    batch_result = ""
check("fallback batch merge == merge_env", batch_result == merged,
      f"batch={batch_result!r} module={merged!r}")
check("fallback batch verified the merge", "merged 3 into" in r.stdout, r.stdout[-200:])

# --- 3. push over the ssh stub: secret on stdin only, 640 install ------------
secret = "PROFILE_PLANNER_DISCORD_BOT_TOKEN=" + secrets.token_hex(12)
target = "/etc/hermes/hermes-main.env"
hostdeploy.push_remote_text("deploy-host.test", target, os.environ["STUB_GROUP"],
                            "A=1\n" + secret + "\n")
with open(os.environ["STUB_PUSHED"]) as fh:
    pushed = fh.read()
check("pushed content matches the input byte-for-byte", pushed == "A=1\n" + secret + "\n")
log = open(os.environ["STUB_LOG"]).read()
check("no secret in any ssh command line", secret not in log)
check("no pushed value in any ssh command line", "A=1" not in log)
check("the remote install runs as root:group 640",
      "sudo -n install -o root" in log and "-m 640" in log)
check("the remote umask is 077 (tmp window is 0600)", "umask 077" in log)
check("the previous target is backed up", ".hermes-deploy.bak" in log)
check("the tmp file is removed", "rm -f" in log)

# --- 4. read-back + mode over the stub ---------------------------------------
with open(os.environ["STUB_ENV_FILE"], "w") as fh:
    fh.write("DISCORD_BOT_TOKEN=main-fixture\n")
check("read_remote_file returns the fixture",
      hostdeploy.read_remote_file("deploy-host.test", target) == open(os.environ["STUB_ENV_FILE"]).read())
check("remote_mode reads 640 root:<group>",
      hostdeploy.remote_mode("deploy-host.test", target) == f"640 root:{os.environ['STUB_GROUP']}")

# --- 5. refusals before anything runs, and a failed remote write --------------
log_before = open(os.environ["STUB_LOG"]).read()
pushed_before = open(os.environ["STUB_PUSHED"]).read()

# Validation refusals never even invoke ssh (nothing appears in the stub log):
def refused(fn, *a, **kw):
    try:
        fn(*a, **kw)
        return False
    except hostdeploy.DeployError:
        return True

check("an option-smuggling ssh destination is refused",
      refused(hostdeploy.check_host, "-oProxyCommand=evil"))
check("an invalid group name is refused",
      refused(hostdeploy.push_remote_text, "deploy-host.test", target, "bad group!", "X=1"))
check("a non-absolute path is refused",
      refused(hostdeploy.read_remote_file, "deploy-host.test", "../relative"))
check("refused calls never reached the ssh stub at all",
      open(os.environ["STUB_LOG"]).read() == log_before
      and open(os.environ["STUB_PUSHED"]).read() == pushed_before)

# A real remote failure (install exits 1) still raises, loudly:
os.environ["STUB_INSTALL_FAIL"] = "1"
check("a failed remote install raises DeployError",
      refused(hostdeploy.push_remote_text, "deploy-host.test", target,
              os.environ["STUB_GROUP"], "X=1"))
os.environ.pop("STUB_INSTALL_FAIL")

# --- 6. install-remote.sh generation ----------------------------------------
outdir = os.path.join(tmp, "fb")
os.makedirs(outdir, exist_ok=True)
pem = os.path.join(outdir, "github-app-developer.pem")
with open(pem, "w") as fh:
    fh.write("-----BEGIN PRIVATE KEY-----\n")
script, files = hostdeploy.write_fallback(
    outdir, "deploy-host.test", os.environ["STUB_GROUP"],
    "/etc/hermes/hermes-main.env",
    pem_pushes=[(pem, "/etc/hermes/github-app-developer.pem")],
    env_lines=secret + "\n",
)
body = open(script).read()
check("generated script cds to its own dir", 'cd "$(dirname "$0")"' in body)
check("generated script makes a mode-700 workdir", "mkdir -m 700" in body)
check("generated script runs ONE sudo step over ssh -t",
      body.count('ssh -t "$H"') == 1 and "sudo python3" in body)
check("generated script cleans the workdir on every exit",
      "trap" in body and "rm -rf /tmp/.hermes-deploy-" in body)
check("generated script carries no pushed secret", secret not in body)
check("env-lines.txt artifact is 0600",
      (os.stat(os.path.join(outdir, "env-lines.txt")).st_mode & 0o777) == 0o600)
check("manifest lists the pem push",
      json.load(open(os.path.join(outdir, "manifest.json")))["pushes"]
      == [["github-app-developer.pem", "/etc/hermes/github-app-developer.pem"]])

# --- 7. the no-host fallback demands HERMES_SSH_HOST at runtime --------------
outdir2 = os.path.join(tmp, "fb2")
script2, _ = hostdeploy.write_fallback(
    outdir2, None, os.environ["STUB_GROUP"], "/etc/hermes/hermes-main.env",
    env_lines="X=1\n")
check("no-host script requires HERMES_SSH_HOST at install time",
      "HERMES_SSH_HOST:?" in open(script2).read())

print()
print(f"{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PY

rc=$?
printf '\n'
exit $rc