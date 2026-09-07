#!/bin/bash
# <owner>/hermes stack entrypoint — declarative bootstrap, then upstream s6.
#
# The image FROMs the official nousresearch/hermes-agent image, whose
# entrypoint (docker/entrypoint-dispatch.sh) owns PID 1: it execs
# s6-overlay's /init, which runs the stage2 bootstrap (UID remap, volume
# chown, config seeding) and supervises the gateway services (the
# default profile at gateway-default, named profiles at gateway-<name>).
#
# This wrapper runs FIRST (as root, before /init) and only does the work
# upstream doesn't know about:
#   1. hermes-bootstrap-profiles.sh — apply baked overlays into profile
#      dirs, provision missing profiles (first boot).
#   1b. Claim the data volume for the runtime user.
#   2. Sync the mounted GitHub App PEM (read-only host mount, unreadable
#      by the unprivileged runtime user) into the persistent tool-home
#      ($HERMES_HOME/home), owned by the runtime user, and point
#      GITHUB_APP_PRIVATE_KEY_PATH at the copy for all child processes.
#   3. Configure git identity + gh auth (as the runtime user, via
#      s6-setuidgid) in every profile's tool-home, plus a background
#      token refresher (installation tokens expire after 1h).
#   4. Exec the upstream dispatcher — s6 takes over from there.
set -euo pipefail

export HERMES_HOME="${HERMES_HOME:-/opt/data}"
RUNTIME_UID="$(id -u hermes 2>/dev/null || echo 10000)"
# /command/s6-setuidgid ships with the s6-overlay symlinks tarball and is
# on PATH even before /init runs.
S6_SETUIDGID="$(command -v s6-setuidgid || echo /command/s6-setuidgid)"

# --- 1. Overlay apply + profile provisioning ------------------------------
# Baked /overlay (render.py output at build time): default profile ->
# $HERMES_HOME root, named profiles -> $HERMES_HOME/profiles/<name>/.
# Merge semantics: git-managed files overwrite, runtime state untouched.
if [ -x /usr/local/bin/hermes-bootstrap-profiles.sh ]; then
  /usr/local/bin/hermes-bootstrap-profiles.sh true
fi

# --- 1b. Data volume ownership: claim it for the runtime user -------------
# The volume root must be writable by the runtime UID before anything
# drops to `hermes` below (git/gh config) and before the s6 services run
# as it — upstream's stage2 chown only runs after our `exec /init`, i.e.
# after this script would already have died on an unwritable volume. A
# full recursive chown is safe because this is a named Docker volume
# holding agent state only (compose binds no host paths inside it) —
# upstream stays targeted for host-bind volumes, and its targeted chown
# would also leave root-owned top-level state files (config.yaml,
# kanban.db, auth.json) unusable for the runtime user. Unconditional: it
# self-heals root-owned strays that `docker exec` writes, and costs ~1s
# against a 17k-file volume.
chown -R "$RUNTIME_UID:$RUNTIME_UID" "$HERMES_HOME" 2>/dev/null || \
  echo "hermes-stack: warning: chown of $HERMES_HOME failed" >&2

# --- 2. Runtime .env: host env file -> persistent volume ------------------
# s6 services run as the unprivileged `hermes` user; the env file is
# bind-mounted read-only from /etc/hermes (root:ubuntu 640) and could
# never be read in place. Sync it into $HERMES_HOME/.env (which the
# runtime owns) on every boot — the mounted file stays the source of
# truth. Compose still injects the same file as container env so this
# entrypoint sees GITHUB_APP_ID etc.
ENV_MOUNT="${HERMES_ENV_FILE_MOUNT:-/run/hermes-env/hermes-main.env}"
if [ -f "$ENV_MOUNT" ]; then
  cp -f "$ENV_MOUNT" "$HERMES_HOME/.env"
  chown "$RUNTIME_UID:$RUNTIME_UID" "$HERMES_HOME/.env"
  chmod 600 "$HERMES_HOME/.env"
fi

# --- 3. GitHub App PEM: host mount -> persistent tool-home ----------------
# The PEM is bind-mounted read-only from /etc/hermes (root:ubuntu 640 on
# the host); the s6 services run as UID 10000 and could never read it
# there. Copy it onto the data volume (which the runtime owns) and aim
# the env var at the copy. The mounted file stays the source of truth —
# refreshed from it on every boot.
PEM_MOUNT="${GITHUB_APP_PEM_MOUNT:-/run/hermes-pem/github-app-main.pem}"
if [ -f "$PEM_MOUNT" ]; then
  PEM_DEST="$HERMES_HOME/home/github-app-main.pem"
  mkdir -p "$HERMES_HOME/home"
  cp -f "$PEM_MOUNT" "$PEM_DEST"
  chown "$RUNTIME_UID:$RUNTIME_UID" "$PEM_DEST" "$HERMES_HOME/home"
  chmod 600 "$PEM_DEST"
  export GITHUB_APP_PRIVATE_KEY_PATH="$PEM_DEST"
fi

# --- 4. git + gh for the runtime user, per tool-home -----------------------
# Tool subprocesses (git, gh, ...) run with HOME=$HERMES_HOME/home for
# the default profile (hermes_constants.get_subprocess_home, container
# mode); named profiles get $HERMES_HOME/profiles/<name>/home. Configure
# each home that exists, AS the runtime user, so credential state is
# owned by it. App mode is preferred; PAT (GH_TOKEN) is the fallback.
# The gh token refresher runs in the background, orphaned to PID 1
# (s6 reaps orphans), so it survives the exec below.
configure_github_for_home() {
  tool_home="$1"
  mkdir -p "$tool_home"
  chown "$RUNTIME_UID:$RUNTIME_UID" "$tool_home" 2>/dev/null || true
  if [ -n "${GITHUB_APP_ID:-}" ] && [ -n "${GITHUB_APP_INSTALLATION_ID:-}" ] \
     && [ -n "${GITHUB_APP_PRIVATE_KEY_PATH:-}" ]; then
    # git identity + credential helper pointing at the shared gh app
    # helper. GITHUB_APP_PRIVATE_KEY_PATH was exported by the PEM sync
    # step above and is inherited through s6-setuidgid.
    "$S6_SETUIDGID" hermes /bin/sh -c '
      export HOME="$1"
      git config --global user.name  "${GH_GIT_NAME:-hermes-agent}"
      git config --global user.email "${GH_GIT_EMAIL:-hermes-agent@localhost}"
      git config --global credential.https://github.com.helper \
        "/usr/local/bin/gh-credential-helper.sh"
    ' sh "$tool_home"
    if "$S6_SETUIDGID" hermes /bin/sh -c '
      export HOME="$1" </dev/null
      t="$(/usr/local/bin/github-app-token.sh)" || exit 1
      [ -n "$t" ] || { echo "empty installation token" >&2; exit 1; }
      printf %s "$t" | gh auth login --with-token
    ' sh "$tool_home"; then
      echo "hermes-stack: gh authed via GitHub App (home=$tool_home)"
    else
      echo "hermes-stack: initial gh auth failed (refresher will retry)" >&2
    fi
    # Installation tokens expire after 1h — refresh gh every 30 min.
    # Guarded the same way: a failed/empty token never reaches gh, so the
    # loop can never fall into gh's interactive device-flow prompt.
    "$S6_SETUIDGID" hermes /bin/sh -c '
      export HOME="$1" </dev/null
      while true; do
        sleep 1800
        t="$(/usr/local/bin/github-app-token.sh)" || continue
        [ -n "$t" ] || continue
        printf %s "$t" | gh auth login --with-token || true
      done
    ' sh "$tool_home" &
  elif [ -n "${GH_TOKEN:-}" ]; then
    "$S6_SETUIDGID" hermes /bin/sh -c '
      export HOME="$1"
      git config --global user.name  "${GH_GIT_NAME:-hermes-agent}"
      git config --global user.email "${GH_GIT_EMAIL:-hermes-agent@localhost}"
      git config --global credential.https://github.com.helper "!gh auth git-credential"
    ' sh "$tool_home"
  fi
}

configure_github_for_home "$HERMES_HOME/home"
# Tool-homes of provisioned named profiles (bootstrap-profiles.sh above
# created any missing ones just before this).
if [ -d "$HERMES_HOME/profiles" ]; then
  for profile_dir in "$HERMES_HOME/profiles"/*/; do
    [ -d "$profile_dir" ] || continue
    configure_github_for_home "${profile_dir%/}/home"
  done
fi

# --- 5. Hand off to the upstream entrypoint ---------------------------------
# entrypoint-dispatch.sh: PID 1 -> /init (s6 supervision tree) -> CMD
# (gateway run -> registered into the gateway-default s6 slot on first
# boot by the boot reconciler, then kept alive as a sleep-infinity
# heartbeat by the redirect logic in hermes_cli/gateway.py).
exec /opt/hermes/docker/entrypoint-dispatch.sh "$@"