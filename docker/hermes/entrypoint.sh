#!/bin/bash
# Hermes agent container entrypoint.
#
# Responsibilities:
#   1. Apply the rendered config overlay (/overlay, read-only) onto the
#      persistent state dir ($HERMES_HOME). The overlay covers
#      config.yaml, honcho.json, SOUL.md and skills/ — everything
#      git-managed. It deliberately does NOT touch .env, memories/,
#      sessions/, or auth state — those are runtime-owned secrets and data.
#   2. Optionally run `hermes update` in place (HERMES_UPDATE_ON_START)
#      — see the "in-place updates" notes in compose/hermes.compose.yml.
#   3. Exec the requested mode: gateway (headless, messaging platforms),
#      chat (interactive CLI; needs a TTY), or a custom command.
set -euo pipefail

HERMES_HOME="${HERMES_HOME:-/data}"
MODE="${1:-gateway}"
shift || true

mkdir -p "$HERMES_HOME"

apply_overlay() {
  [ -d /overlay ] || return 0
  [ -f /overlay/config.yaml ] && cp -f /overlay/config.yaml "$HERMES_HOME/config.yaml"
  # honcho.json disables the agent's built-in Honcho integration (see
  # render.py); Honcho reaches the agent via the honcho-mcp server only.
  [ -f /overlay/honcho.json ] && cp -f /overlay/honcho.json "$HERMES_HOME/honcho.json"
  [ -f /overlay/SOUL.md ] && cp -f /overlay/SOUL.md "$HERMES_HOME/SOUL.md"
  if [ -d /overlay/skills ]; then
    # Merge: overlay skills overwrite same-named ones; existing others
    # (including skills the agent created itself) are kept.
    mkdir -p "$HERMES_HOME/skills"
    cp -a /overlay/skills/. "$HERMES_HOME/skills/"
  fi
}

apply_overlay

# GitHub access. Two mutually exclusive modes, both driven by env vars
# from $HERMES_ENV_DIR/hermes-main.env (never committed):
#   - GitHub App (preferred): GITHUB_APP_ID + GITHUB_APP_INSTALLATION_ID
#     + GITHUB_APP_PRIVATE_KEY_PATH (PEM mounted read-only). Installation
#     tokens last 1h, so git gets a fresh token per operation via the
#     github-app-token.sh credential helper, and gh is re-authed by a
#     background refresher every 30 min. Hermes' skills hub also has
#     native app support (tools/skills_hub.py GitHubAuth) as a fallback.
#   - PAT: GH_TOKEN authenticates gh natively; git routes through
#     `gh auth git-credential`.
# /root is ephemeral, so this runs on every start, before exec'ing the
# gateway. Commit identity is a default the agent can override per-repo;
# without it any commit it makes fails with "Please tell me who you are".
git config --global user.name "${GH_GIT_NAME:-hermes-agent}"
git config --global user.email "${GH_GIT_EMAIL:-hermes-agent@localhost}"
if [ -n "${GITHUB_APP_ID:-}" ] && [ -n "${GITHUB_APP_INSTALLATION_ID:-}" ] && [ -n "${GITHUB_APP_PRIVATE_KEY_PATH:-}" ]; then
  git config --global credential."https://github.com".helper \
    '!f() { echo username=x-access-token; echo password=$(/usr/local/bin/github-app-token.sh); }; f'
  github_app_token() { /usr/local/bin/github-app-token.sh; }
  github_app_token | gh auth login --with-token \
    || echo "hermes: initial gh auth failed (refresher will retry)" >&2
  # Installation tokens expire after 1h — re-auth gh every 30 min. The
  # subshell survives the exec below (orphaned to init).
  ( while true; do sleep 1800; github_app_token | gh auth login --with-token || true; done ) &
elif [ -n "${GH_TOKEN:-}" ]; then
  git config --global credential."https://github.com".helper '!gh auth git-credential'
fi

if [ "${HERMES_UPDATE_ON_START:-false}" = "true" ]; then
  # In-place update of the agent code. Requires the code directory to be
  # a mounted volume (see compose/hermes.compose.yml), otherwise the
  # update is discarded when the container is recreated. May be
  # interactive on some versions; watch the logs on first use.
  echo "hermes: running in-place update (HERMES_UPDATE_ON_START=true)" >&2
  hermes update || echo "hermes: update failed; continuing with current code" >&2
fi

case "$MODE" in
  gateway)
    exec hermes gateway "$@"
    ;;
  chat)
    # Interactive CLI; run with: docker compose ... run --rm hermes-main chat
    exec hermes "$@"
    ;;
  *)
    exec "$MODE" "$@"
    ;;
esac