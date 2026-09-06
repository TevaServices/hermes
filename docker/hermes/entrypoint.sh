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
  # honcho.json disables the agent's built-in Honcho integration so the
  # honcho-mcp server owns the "honcho" toolset alias (see render.py).
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