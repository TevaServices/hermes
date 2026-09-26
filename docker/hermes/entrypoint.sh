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
#
# WHY THE ROOT COPY IS FILTERED (2026-09-25). Hermes builds a cron job's
# child env as `strip_launch_profile_env(build_subprocess_env(...))`
# (cron/scheduler.py), and that first step DELETES from the child env every
# name found in the LAUNCH profile's .env unless it is a "global" env name
# (tools/environments/local.py::strip_launch_profile_env). The launch
# profile here is the DEFAULT one — i.e. this file. A routed profile's job
# child therefore loses any non-global name that sits in it.
#
# The team-routing family is exactly that: TEAM_OWNER, TEAM_OWNER_ORGS,
# TEAM_ORG_DEV_BOT_<ORG>. team-queue.sh / review-queue.sh read them, and
# they run as `no_agent` script children that re-load NOTHING. With
# TEAM_OWNER in this file the reviewer's self-pull died 71 consecutive
# times (`team-queue.sh: owner must not be empty`, exit 64) while the
# developer's survived by luck: the scheduler calls the strip WITHOUT
# passing the job's own profile_home, so the strip keyed off whatever
# override the PREVIOUS dispatch happened to leave behind. Same scripts,
# same env builder, opposite outcomes — and a queue that fails like that is
# indistinguishable from a quiet one, which is the failure this stack's
# exit-code contract exists to prevent.
#
# Filtering here is sufficient AND complete, which is why nothing else had
# to move: compose injects the same file as container env (`env_file:`), so
# these vars are still in the gateway's environment and still reach every
# script — they are simply no longer LAUNCH-PROFILE RESIDUE. The profile
# .env copies below deliberately KEEP the TEAM_* lines: those homes are not
# the launch home, and `served_profile_child_env` re-adds a routed
# profile's own .env names for `hermes -p X` children.
#
# The rule for anything added later: a var read by a SCRIPT in a cron job
# must not live in THIS file. Put it in the stack `environment:` (komodo
# resources.toml, mirrored in mise.toml) or accept that a routed profile's
# job child will never see it.
ENV_MOUNT="${HERMES_ENV_FILE_MOUNT:-/run/hermes-env/hermes-main.env}"
if [ -f "$ENV_MOUNT" ]; then
  if ! grep -vE '^TEAM_[A-Z0-9_]+=' "$ENV_MOUNT" > "$HERMES_HOME/.env"; then
    # grep -v exits 1 when it selected nothing, and >1 on a read error.
    # Either way an empty root .env would break every service, so fall back
    # to the unfiltered copy rather than shipping a truncated one.
    echo "hermes-stack: warning: TEAM_* filter produced no output; using the unfiltered env" >&2
    cp -f "$ENV_MOUNT" "$HERMES_HOME/.env"
  fi
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

# --- 3b. ORG GitHub App credentials: host PEMs -> org-creds descriptors ----
# Every profile can hold a SECOND App per org (org-owned apps for work
# under that org; the primary App stays personal). The container env
# carries the org variants as suffixed var names:
#
#   GITHUB_APP_ID_<ORGUC> / PROFILE_<NAME>_GITHUB_APP_ID_<ORGUC>
#   ..._INSTALLATION_ID_<ORGUC> / ..._GH_GIT_NAME_<ORGUC> / _GH_GIT_EMAIL_<ORGUC>
#
# and the PEMs live on the host as github-app-<orgslug>-<profile>.pem
# (mounted with the rest of $HERMES_ENV_DIR at /run/hermes-pem — no
# compose change needed). Here each tool-home gets:
#
#   org-creds/<slug>.env   NON-SECRET descriptor (app id, installation
#                          id, pem path, org git identity) — the helpers
#                          (gh-org-token, git-credential-hermes.sh, the
#                          gh shim, git-repo.sh) read this, because Hermes
#                          strips credential env vars from tool
#                          subprocess env (GHSA-rhgp-j443-p4rf)
#   org-creds/<slug>.pem   the org App's private key (600)
#
# A declared org with NO host PEM is skipped with a loud warning: the
# descriptor is only written when the key exists, so the routing never
# half-fires. An org with no INSTALLATION_ID is likewise skipped.
sync_org_creds() {  # sync_org_creds <tool_home> <profile_name or "">
  tool_home="$1"; profile_name="$2"
  up="${profile_name^^}"
  for orguc in $(env | grep -oE "^(PROFILE_${up}_)?GITHUB_APP_ID_[A-Z0-9_]+=" 2>/dev/null | \
                    sed -n 's/^.*GITHUB_APP_ID_\([A-Z0-9_]*\)=$/\1/p' | sort -u); do
    slug="$(printf '%s' "$orguc" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9')"
    [ -n "$slug" ] || continue
    if [ -n "$profile_name" ]; then
      org_app_id="$(eval "echo \${PROFILE_${up}_GITHUB_APP_ID_${orguc}:-}")"
      org_inst_id="$(eval "echo \${PROFILE_${up}_GITHUB_APP_INSTALLATION_ID_${orguc}:-}")"
      org_git_name="$(eval "echo \${PROFILE_${up}_GH_GIT_NAME_${orguc}:-}")"
      org_git_email="$(eval "echo \${PROFILE_${up}_GH_GIT_EMAIL_${orguc}:-}")"
    else
      org_app_id="$(eval "echo \${GITHUB_APP_ID_${orguc}:-}")"
      org_inst_id="$(eval "echo \${GITHUB_APP_INSTALLATION_ID_${orguc}:-}")"
      org_git_name="$(eval "echo \${GH_GIT_NAME_${orguc}:-}")"
      org_git_email="$(eval "echo \${GH_GIT_EMAIL_${orguc}:-}")"
    fi
    if [ -z "$org_app_id" ] || [ -z "$org_inst_id" ]; then
      echo "hermes-stack: warning: org $orguc has no app id/installation id for profile ${profile_name:-main}; org credentials skipped" >&2
      continue
    fi
    if [ -n "$profile_name" ]; then
      pem_mount="/run/hermes-pem/github-app-${slug}-${profile_name}.pem"
    else
      pem_mount="/run/hermes-pem/github-app-${slug}-main.pem"
    fi
    if [ ! -f "$pem_mount" ]; then
      echo "hermes-stack: warning: no org PEM for $orguc at $pem_mount; org credentials skipped (install it on the host first)" >&2
      continue
    fi
    mkdir -p "$tool_home/org-creds"
    cp -f "$pem_mount" "$tool_home/org-creds/${slug}.pem"
    chmod 600 "$tool_home/org-creds/${slug}.pem"
    # Descriptor: NON-secret (ids only), but 600 anyway — it names the
    # bot identity, and cheap paranoia costs nothing. Var names are the
    # exact ones github-app-token.sh reads, so helpers just source it.
    {
      printf 'ORG_NAME=%s\n' "$orguc"
      printf 'ORG_SLUG=%s\n' "$slug"
      printf 'GITHUB_APP_ID=%s\n' "$org_app_id"
      printf 'GITHUB_APP_INSTALLATION_ID=%s\n' "$org_inst_id"
      printf 'GITHUB_APP_PRIVATE_KEY_PATH=%s\n' "$tool_home/org-creds/${slug}.pem"
      [ -n "$org_git_name" ] && printf 'GH_GIT_NAME=%s\n' "$org_git_name"
      [ -n "$org_git_email" ] && printf 'GH_GIT_EMAIL=%s\n' "$org_git_email"
    } > "$tool_home/org-creds/${slug}.env"
    chmod 600 "$tool_home/org-creds/${slug}.env"
    echo "hermes-stack: org creds for $orguc -> $tool_home/org-creds/${slug}.env (app id=${org_app_id})"
  done
}

# Org PEMs for the main home + every profile home (bootstrap-profiles.sh
# above created any missing profile dirs).
sync_org_creds "$HERMES_HOME/home" ""
if [ -d "$HERMES_HOME/profiles" ]; then
  for profile_dir in "$HERMES_HOME/profiles"/*/; do
    [ -d "$profile_dir" ] || continue
    sync_org_creds "${profile_dir%/}/home" "$(basename "${profile_dir%/}")"
  done
fi
if [ -d "$HERMES_HOME" ]; then
  chown -R "$RUNTIME_UID:$RUNTIME_UID" "$HERMES_HOME/home/org-creds" 2>/dev/null || true
  [ ! -d "$HERMES_HOME/profiles" ] || \
    chown -R "$RUNTIME_UID:$RUNTIME_UID" "$HERMES_HOME"/profiles/*/home/org-creds 2>/dev/null || true
fi

# --- 3c. Komodo auth header: host mount -> runtime-owned home -------------
# Same trap as the PEMs, and it bit the same way: the header is mounted
# read-only from the host, where it is 600 and owned by the host user, so
# the s6 services (UID 10000) get "curl: option -H: error encountered when
# reading a file" — which reads to an agent as "the Komodo API key is not
# working". Nothing is wrong with the key; the agent simply cannot open the
# file. Copy it onto the data volume (which the runtime owns); the mount
# stays the source of truth and is refreshed here on every boot.
#
# This script's job is the FILE ONLY. The env var that points at it is
# declared in compose (hermes-main `environment:`), because that is the only
# place s6 services read their environment from — s6-overlay starts them
# from /run/s6/container_environment, so an `export` here would never reach
# the gateway or its tool subprocesses. (Learned the hard way: exporting it
# looked right, logged right, and was invisible to every service.)
#
# DEFAULT PROFILE ONLY, deliberately. komodo-ops is a default-profile skill,
# so the HOMELAB control-plane credential belongs to that profile alone —
# the team profiles have no reason to drive THIS control plane, and each
# extra copy is another place a credential can be read from. (The release
# profile gets the ALTERNATE control plane's header instead, in the block below:
# a different control plane, and the only role that deploys.)
KOMODO_MOUNT="${KOMODO_AUTH_HEADER_MOUNT:-/etc/komodo-auth-header}"
# Copy a credential file off its unreadable read-only mount into a
# runtime-owned home. THE GUARD IS `-f`, NOT `-r`, and that distinction is
# load-bearing: when the host file does not exist, Docker creates the mount
# TARGET as a DIRECTORY, and a directory is perfectly readable — so `-r`
# passes and `cp` then fails with "omitting directory". Under this script's
# `set -euo pipefail` that killed the entrypoint and crash-looped the whole
# container (observed: a 7-restart loop from an absent credential file,
# which takes every profile offline, not just the one that credential was
# for). A MISSING CREDENTIAL IS NOT A FATAL CONDITION — it degrades one
# capability and must be reported, never fatal. Every path here returns 0.
install_secret_file() {  # <src> <dest> <label>
  if [ ! -e "$1" ]; then
    echo "hermes-stack: warning: no $3 at $1 (skipped)" >&2
    return 0
  fi
  if [ ! -f "$1" ]; then
    echo "hermes-stack: warning: $3 at $1 is not a regular file (skipped)" >&2
    return 0
  fi
  mkdir -p "$(dirname "$2")" 2>/dev/null || return 0
  if cp -f "$1" "$2" 2>/dev/null; then
    chown "$RUNTIME_UID:$RUNTIME_UID" "$2" 2>/dev/null || true
    chmod 600 "$2" 2>/dev/null || true
    echo "hermes-stack: $3 -> $2"
  else
    echo "hermes-stack: warning: could not install $3 from $1" >&2
  fi
  return 0
}

install_secret_file "$KOMODO_MOUNT" "$HERMES_HOME/home/komodo-auth-header" \
  "komodo auth header"

# --- 3d. the ALTERNATE control plane's auth header (release profile only) ----
# A SEPARATE Komodo from the one above: its own core, its own servers, its
# own key. Same FILE-vs-CONFIG split and the same non-readable mount, so the
# same treatment applies (copy it to the runtime-owned home; the var that
# points here lives in compose).
#
# RELEASE PROFILE ONLY, deliberately — the release agent is the only role
# that deploys, and each extra copy is another place a credential can be read
# from. The named-profile home is created by bootstrap-profiles.sh before
# this runs; if it does not exist yet (a first boot ordering surprise), say
# so rather than failing, because the rest of the container is unaffected.
KOMODO_ALT_MOUNT="${KOMODO_ALT_AUTH_HEADER_MOUNT:-/etc/komodo-alt-auth-header}"
if [ -d "$HERMES_HOME/profiles/release" ]; then
  install_secret_file "$KOMODO_ALT_MOUNT" \
    "$HERMES_HOME/profiles/release/home/komodo-alt-auth-header" \
    "alternate komodo auth header"
else
  echo "hermes-stack: warning: release profile home missing; alternate komodo header not copied" >&2
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
  # git identity + credential helper. The helper is the STACK ROUTER
  # (git-credential-hermes.sh): it serves the ORG App's installation
  # token when the remote's owner matches an org descriptor
  # ($HOME/org-creds/<owner>.env, synced in §3b) and replays the request
  # into `gh auth git-credential` otherwise — so the personal behavior
  # is exactly what it was: the entrypoint's background refresher keeps
  # gh logged in with a fresh installation token (minted at boot + every
  # 30 min, so the stored token is always < 1h old). This needs NO env
  # inheritance — Hermes strips credential vars from tool subprocesses by
  # design (GHSA-rhgp-j443-p4rf), and gh reads its token from the
  # tool-home's ~/.config/gh/hosts.yml.
  #
  # useHttpPath=true is what makes the router work: without it git sends
  # no path component, and without the path the router cannot see the
  # owner. (Verified against git 2.54: with the default false, the path
  # is not sent at all and per-owner routing is impossible.)
  #
  # core.hooksPath is the DCO sign-off hook (/opt/hermes-git-hooks): it
  # adds a `Signed-off-by:` matching the commit's own identity, but only
  # in repos that declare a DCO rule in CONTRIBUTING.md or a CI
  # workflow. Per-HOME global config is the right scope, not per-repo:
  # the repos are cloned at runtime (git-repo.sh), and a worktree shares
  # its common dir's hooks — so pointing at an image path is the only
  # way every repo and worktree gets it without a runtime install step.
  # The trade-off is that a repo's own .git/hooks is bypassed; hooks are
  # not cloned, so there is normally nothing there to bypass.
  "$S6_SETUIDGID" hermes /bin/sh -c '
    export HOME="$1"
    git config --global user.name  "$2"
    git config --global user.email "$3"
    git config --global credential.https://github.com.useHttpPath true
    git config --global credential.https://github.com.helper \
      "!/usr/local/bin/git-credential-hermes.sh"
    git config --global core.hooksPath /opt/hermes-git-hooks
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

  # ORG Apps: mint once per org at boot (warm cache, loud failure).
  # Independent of the personal App branch above — a profile could hold
  # org credentials without a personal App. Runtime refresh is LAZY +
  # cached: gh-org-token reuses the cached token while it is >5min from
  # expiry and re-mints on miss, so no second refresher loop per org per
  # home is needed.
  for orgenv in "$tool_home"/org-creds/*.env; do
    [ -f "$orgenv" ] || continue
    org_slug="$(basename "$orgenv" .env)"
    if "$S6_SETUIDGID" hermes /bin/sh -c '
         export HOME="$1"
         </dev/null
         ORG_CREDS_DIR="$HOME/org-creds" gh-org-token "$2" >/dev/null
       ' sh "$tool_home" "$org_slug"; then
      echo "hermes-stack: org token ok for $org_slug (home=$tool_home)"
    else
      echo "hermes-stack: FAILED to mint the org token for $org_slug (home=$tool_home) — org-owned repos will be unreachable until this is fixed" >&2
    fi
  done
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