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
#   2. Sync the mounted env file into $HERMES_HOME/.env AND synthesize
#      each named profile's own .env: the host env file plus
#      PROFILE_<NAME>_<VAR> entries mapped to their bare names (so a
#      profile-specific Discord token or GitHub App credential lands at
#      the var name Hermes expects, per profile).
#   3. Sync GitHub App PEM mounts (read-only host mounts, unreadable by
#      the unprivileged runtime user) into the persistent tool-homes
#      ($HERMES_HOME/home and $HERMES_HOME/profiles/<name>/home), owned
#      by the runtime user — one PEM per App (main + one per team
#      profile), each pointed at by its own env var.
#   4. Configure git identity + gh auth (as the runtime user, via
#      s6-setuidgid) in every profile's tool-home — each profile with
#      its OWN App credentials when declared (PROFILE_<NAME>_GITHUB_APP*)
#      and its OWN git identity (PROFILE_<NAME>_GH_GIT_NAME) — plus a
#      background token refresher per home (installation tokens expire
#      after 1h).
#   5. Exec the upstream dispatcher — s6 takes over from there.
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

# --- 1c. Claude Code provisioning (coding-agent delegation) ---------------
# Installs/copies the wrapper tooling + claude-real CLI onto the persistent
# volume (latest npm release, NOT pinned — claude-update.sh re-checks daily
# via the gateway cron). Runs pre-drop, so the /usr/local/bin symlink lands
# while still root. Non-fatal on failure; see hermes-stack-ops skill.
if [ -x /opt/claude-hermes/claude-provision.sh ]; then
  /opt/claude-hermes/claude-provision.sh || true
  # The CLI must stay updatable by the runtime user (daily cron runs as
  # `hermes`, and it atomically replaces claude-real).
  [ ! -d "$HERMES_HOME/tools/claude-hermes" ] || \
    chown -R "$RUNTIME_UID:$RUNTIME_UID" "$HERMES_HOME/tools/claude-hermes" 2>/dev/null || true
fi

# --- 2. Runtime .env: host env file -> persistent volume ------------------
# s6 services run as the unprivileged `hermes` user; the env file is
# bind-mounted read-only from $HERMES_ENV_DIR (root:<host-group> 640) and could
# never be read in place. Sync it into $HERMES_HOME/.env (which the
# runtime owns) on every boot — the mounted file stays the source of
# truth. Compose still injects the same file as container env so this
# entrypoint sees GITHUB_APP_ID etc.
#
# Team profiles: each named profile gets its own .env = the host env
# file PLUS any PROFILE_<NAME>_<VAR> entries mapped to their bare names
# (e.g. PROFILE_DEVELOPER_DISCORD_BOT_TOKEN -> DISCORD_BOT_TOKEN), so a
# profile's own Discord bot token lands at the var name the gateway's
# per-profile credential resolution expects (the multiplexer reads each
# profile's own .env scope).
ENV_MOUNT="${HERMES_ENV_FILE_MOUNT:-/run/hermes-env/hermes-main.env}"
if [ -f "$ENV_MOUNT" ]; then
  cp -f "$ENV_MOUNT" "$HERMES_HOME/.env"
  chown "$RUNTIME_UID:$RUNTIME_UID" "$HERMES_HOME/.env"
  chmod 600 "$HERMES_HOME/.env"
  if [ -d "$HERMES_HOME/profiles" ]; then
    for profile_dir in "$HERMES_HOME/profiles"/*/; do
      [ -d "$profile_dir" ] || continue
      profile_name="$(basename "${profile_dir%/}")"
      profile_env="${profile_dir%/}/.env"
      prefix="PROFILE_${profile_name^^}_"
      # Which bare names will THIS profile define? (PROFILE_<NAME>_<VAR>
      # -> <VAR>, below.) Those are exactly the names the inherited copy
      # must NOT keep a copy of.
      own=$(env | grep -oE "^${prefix}[A-Z0-9_]+=" 2>/dev/null \
              | sed "s/^${prefix}//; s/=$//" | tr '\n' '|' | sed 's/|$//' || true)
      # Copy the host env file MINUS every PROFILE_* line (teammates'
      # secrets stay out of each profile's own .env scope) AND minus the
      # host's own bare copies of the names this profile overrides.
      #
      # That second exclusion is load-bearing, not tidiness. The host env
      # file carries the DEFAULT profile's own secrets under their bare
      # names (DISCORD_BOT_TOKEN, GITHUB_APP_ID, …), so without it this
      # profile's .env ends up defining each of those keys TWICE — the
      # default profile's value first, this profile's appended after.
      # The dotenv loader is last-wins and so resolves correctly, which
      # hid this for a long time; but ANY first-match reader gets the
      # default profile's credential. Observed live: the developer agent
      # posted into #dev as the MAIN bot, because it read the token with
      # `grep … | head -1` — which is exactly what an agent reaching for
      # a secret writes. Duplicate keys are a trap; leave only one.
      if [ -n "$own" ]; then
        grep -vE "^PROFILE_[A-Z0-9]+_[A-Z0-9_]+=|^(${own})=" "$ENV_MOUNT" > "$profile_env" || true
      else
        grep -vE '^PROFILE_[A-Z0-9]+_[A-Z0-9_]+=' "$ENV_MOUNT" > "$profile_env" || true
      fi
      # `|| true` inside the brace group: with no PROFILE_<NAME>_* vars in
      # the container env (team not onboarded yet), grep exits 1 and
      # pipefail would otherwise kill the entrypoint silently (set -e).
      { env | grep -E "^${prefix}[A-Z0-9_]+=" || true; } | \
        while IFS='=' read -r key value; do
          printf '%s=%s\n' "${key#"$prefix"}" "$value" >> "$profile_env"
        done
      chown "$RUNTIME_UID:$RUNTIME_UID" "$profile_env"
      chmod 600 "$profile_env"
    done
  fi
fi

# --- 3. GitHub App PEMs: host mounts -> persistent tool-homes -------------
# PEMs are bind-mounted read-only from $HERMES_ENV_DIR (root:<group> 640 on
# the host); the s6 services run as UID 10000 and could never read them
# there. Copy each onto the data volume (which the runtime owns) and
# aim its env var at the copy. The mounted files stay the source of
# truth — refreshed from them on every boot.
#
# Layout: the main App's PEM at $GITHUB_APP_PEM_MOUNT
# (default /run/hermes-pem/github-app-main.pem); team-profile Apps'
# PEMs at /run/hermes-pem/github-app-<profile>.pem (compose mounts
# them there; see compose/hermes.compose.yml).
copy_pem() {  # copy_pem <mount> <tool_home> <dest_name>
  mount="$1"; tool_home="$2"; dest_name="$3"
  if [ -f "$mount" ]; then
    mkdir -p "$tool_home"
    dest="$tool_home/$dest_name"
    cp -f "$mount" "$dest"
    chown "$RUNTIME_UID:$RUNTIME_UID" "$dest" "$tool_home"
    chmod 600 "$dest"
  fi
}

PEM_MOUNT="${GITHUB_APP_PEM_MOUNT:-/run/hermes-pem/github-app-main.pem}"
copy_pem "$PEM_MOUNT" "$HERMES_HOME/home" "github-app-main.pem"
if [ -f "$HERMES_HOME/home/github-app-main.pem" ]; then
  export GITHUB_APP_PRIVATE_KEY_PATH="$HERMES_HOME/home/github-app-main.pem"
fi

if [ -d "$HERMES_HOME/profiles" ]; then
  for profile_dir in "$HERMES_HOME/profiles"/*/; do
    [ -d "$profile_dir" ] || continue
    profile_name="$(basename "${profile_dir%/}")"
    copy_pem "/run/hermes-pem/github-app-${profile_name}.pem" \
      "${profile_dir%/}/home" "github-app-${profile_name}.pem"
    # Point the profile's own .env at the runtime-owned copy (replace
    # the rendered placeholder line if present, else append it — the
    # host env file deliberately omits the var; the entrypoint owns it).
    if [ -f "${profile_dir%/}/home/github-app-${profile_name}.pem" ] \
       && [ -f "${profile_dir%/}/.env" ]; then
      pem_env="${profile_dir%/}/.env"
      pem_dest="${profile_dir%/}/home/github-app-${profile_name}.pem"
      if grep -q '^GITHUB_APP_PRIVATE_KEY_PATH=' "$pem_env"; then
        sed -i "s#^GITHUB_APP_PRIVATE_KEY_PATH=.*#GITHUB_APP_PRIVATE_KEY_PATH=${pem_dest}#" "$pem_env"
      else
        printf 'GITHUB_APP_PRIVATE_KEY_PATH=%s\n' "$pem_dest" >> "$pem_env"
      fi
    fi
  done
fi

# --- 3b. Komodo auth header: host mount -> runtime-owned home -------------
# Same trap as the PEMs, and it bit the same way: the header is mounted
# read-only from the host, where it is 600 and owned by the host user, so
# the s6 services (UID 10000) get "curl: option -H: error encountered when
# reading a file" — which reads to an agent as "the Komodo API key is not
# working". Nothing is wrong with the key; the agent simply cannot open the
# file. Copy it onto the data volume (which the runtime owns) and aim
# KOMODO_AUTH_HEADER at the copy; the mount stays the source of truth and is
# refreshed here on every boot.
#
# DEFAULT PROFILE ONLY, deliberately. komodo-ops is a default-profile skill,
# so the control-plane credential belongs to that profile alone — the team
# profiles have no reason to drive Komodo, and each extra copy is another
# place a credential can be read from.
KOMODO_MOUNT="${KOMODO_AUTH_HEADER_MOUNT:-/etc/komodo-auth-header}"
if [ -r "$KOMODO_MOUNT" ]; then
  mkdir -p "$HERMES_HOME/home"
  KOMODO_DEST="$HERMES_HOME/home/komodo-auth-header"
  cp -f "$KOMODO_MOUNT" "$KOMODO_DEST"
  chown "$RUNTIME_UID:$RUNTIME_UID" "$KOMODO_DEST" "$HERMES_HOME/home"
  chmod 600 "$KOMODO_DEST"
  export KOMODO_AUTH_HEADER="$KOMODO_DEST"
  # Also land it in the default profile's .env: the gateway loads that with
  # override=True, and a tool subprocess that re-execs through a fresh login
  # shell otherwise loses an export made only in this process.
  if [ -f "$HERMES_HOME/.env" ]; then
    if grep -q '^KOMODO_AUTH_HEADER=' "$HERMES_HOME/.env"; then
      sed -i "s#^KOMODO_AUTH_HEADER=.*#KOMODO_AUTH_HEADER=${KOMODO_DEST}#" "$HERMES_HOME/.env"
    else
      printf 'KOMODO_AUTH_HEADER=%s\n' "$KOMODO_DEST" >> "$HERMES_HOME/.env"
    fi
  fi
  echo "hermes-stack: komodo auth header -> $KOMODO_DEST"
else
  echo "hermes-stack: warning: no readable komodo auth header at $KOMODO_MOUNT" >&2
fi

# --- 4. git + gh for the runtime user, per tool-home -----------------------
# Tool subprocesses (git, gh, ...) run with HOME=$HERMES_HOME/home for
# the default profile (hermes_constants.get_subprocess_home, container
# mode); named profiles get $HERMES_HOME/profiles/<name>/home. Configure
# each home that exists, AS the runtime user, so credential state is
# owned by it. App mode is preferred; PAT (GH_TOKEN) is the fallback.
# The gh token refreshers run in the background, orphaned to PID 1
# (s6 reaps orphans), so they survive the exec below.
#
# Team profiles carry their own App credentials via PROFILE_<NAME>_*
# vars in the container env (from the host env file): their gh auth and
# token refresh mint from THOSE, so commits/PRs/reviews/merges carry
# the role's own bot identity. Profiles without own credentials fall
# back to the main App.
#
# Git identity: PROFILE_<NAME>_GH_GIT_NAME / _GH_GIT_EMAIL override the
# main GH_GIT_NAME / GH_GIT_EMAIL per profile — each role commits as
# its own bot (distinct attribution in GitHub), never impersonating.
configure_github_for_home() {  # <tool_home> [profile_name]
  tool_home="$1"
  profile="${2:-}"
  if [ -n "$profile" ] \
     && [ -n "$(eval "echo \${PROFILE_${profile^^}_GITHUB_APP_ID:-}")" ]; then
    # Team profile with its own GitHub App credentials (PROFILE_<NAME>_*
    # vars come from the host env file via the container environment).
    APP_ID="$(eval "echo \${PROFILE_${profile^^}_GITHUB_APP_ID}")"
    APP_INSTALLATION_ID="$(eval "echo \${PROFILE_${profile^^}_GITHUB_APP_INSTALLATION_ID:-}")"
    APP_PEM="$tool_home/github-app-${profile}.pem"
    GIT_NAME="$(eval "echo \${PROFILE_${profile^^}_GH_GIT_NAME:-\${GH_GIT_NAME:-hermes-agent}}")"
    GIT_EMAIL="$(eval "echo \${PROFILE_${profile^^}_GH_GIT_EMAIL:-\${GH_GIT_EMAIL:-hermes-agent@localhost}}")"
  else
    APP_ID="${GITHUB_APP_ID:-}"
    APP_INSTALLATION_ID="${GITHUB_APP_INSTALLATION_ID:-}"
    APP_PEM="${GITHUB_APP_PRIVATE_KEY_PATH:-}"
    GIT_NAME="${GH_GIT_NAME:-hermes-agent}"
    GIT_EMAIL="${GH_GIT_EMAIL:-hermes-agent@localhost}"
  fi

  mkdir -p "$tool_home"
  chown "$RUNTIME_UID:$RUNTIME_UID" "$tool_home" 2>/dev/null || true
  # git identity + credential helper. Git routes through gh's OWN
  # credential store (`gh auth git-credential`): the entrypoint's
  # background refresher keeps gh logged in with a fresh installation
  # token (minted at boot + every 30 min, so the stored token is always
  # < 1h old). This needs NO env inheritance — Hermes strips credential
  # vars from tool subprocesses by design (GHSA-rhgp-j443-p4rf), and
  # gh reads its token from the tool-home's ~/.config/gh/hosts.yml.
  "$S6_SETUIDGID" hermes /bin/sh -c '
    export HOME="$1"
    git config --global user.name  "$2"
    git config --global user.email "$3"
    git config --global credential.https://github.com.helper \
      "!gh auth git-credential"
  ' sh "$tool_home" "$GIT_NAME" "$GIT_EMAIL"

  if [ -n "$APP_ID" ] && [ -n "$APP_INSTALLATION_ID" ] && [ -n "$APP_PEM" ]; then
    # Initial auth + background refresher for THIS home's App identity.
    "$S6_SETUIDGID" hermes /bin/sh -c '
      export HOME="$1" GITHUB_APP_ID="$2" \
             GITHUB_APP_INSTALLATION_ID="$3" GITHUB_APP_PRIVATE_KEY_PATH="$4"
      </dev/null
      t="$(/usr/local/bin/github-app-token.sh)" || exit 1
      [ -n "$t" ] || { echo "empty installation token" >&2; exit 1; }
      printf %s "$t" | gh auth login --with-token
    ' sh "$tool_home" "$APP_ID" "$APP_INSTALLATION_ID" "$APP_PEM" \
      && echo "hermes-stack: gh authed via GitHub App (home=$tool_home, app id=${APP_ID})" \
      || echo "hermes-stack: initial gh auth failed for $tool_home (refresher will retry)" >&2
    # Installation tokens expire after 1h — refresh gh every 30 min so
    # the stored token (`gh auth status` in the tool-home) is always
    # fresh. Guarded: a failed/empty token never reaches gh, so the loop
    # can never fall into gh's interactive device-flow prompt.
    "$S6_SETUIDGID" hermes /bin/sh -c '
      export HOME="$1" GITHUB_APP_ID="$2" \
             GITHUB_APP_INSTALLATION_ID="$3" GITHUB_APP_PRIVATE_KEY_PATH="$4"
      </dev/null
      while true; do
        sleep 1800
        t="$(/usr/local/bin/github-app-token.sh)" || continue
        [ -n "$t" ] || continue
        printf %s "$t" | gh auth login --with-token || true
      done
    ' sh "$tool_home" "$APP_ID" "$APP_INSTALLATION_ID" "$APP_PEM" &
  elif [ -n "${GH_TOKEN:-}" ]; then
    echo "hermes-stack: no App credentials for $tool_home; PAT fallback (git identity only)" >&2
  fi
}

configure_github_for_home "$HERMES_HOME/home"
# Tool-homes of provisioned named profiles (bootstrap-profiles.sh above
# created any missing ones just before this).
if [ -d "$HERMES_HOME/profiles" ]; then
  for profile_dir in "$HERMES_HOME/profiles"/*/; do
    [ -d "$profile_dir" ] || continue
    configure_github_for_home "${profile_dir%/}/home" "$(basename "${profile_dir%/}")"
  done
fi

# --- 5. Hand off to the upstream entrypoint ---------------------------------
# entrypoint-dispatch.sh: PID 1 -> /init (s6 supervision tree) -> CMD
# (gateway run -> registered into the gateway-default s6 slot on first
# boot by the boot reconciler, then kept alive as a sleep-infinity
# heartbeat by the redirect logic in hermes_cli/gateway.py).
exec /opt/hermes/docker/entrypoint-dispatch.sh "$@"