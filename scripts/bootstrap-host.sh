#!/usr/bin/env bash
# One-time preparation of a Linux host (the Komodo Periphery machine).
#
#   sudo ./scripts/bootstrap-host.sh
#
# Creates:
#   /etc/hermes/*.env          — secret env files, copied from secrets/*.env.example
#                                if not already present (chmod 600)
#   docker network hermes-net  — shared network the three stacks join
#
# Idempotent: safe to re-run; existing env files are never overwritten.

set -euo pipefail

HERMES_ENV_DIR="${HERMES_ENV_DIR:-/etc/hermes}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ "$(id -u)" -ne 0 ] && [ "${HERMES_ENV_DIR}" = "/etc/hermes" ]; then
  echo "needs root to write ${HERMES_ENV_DIR}; re-run with sudo, or set HERMES_ENV_DIR" >&2
  exit 1
fi

command -v docker >/dev/null || { echo "docker not found — install Docker first" >&2; exit 1; }
# git is required on hosts that run the Honcho compose stack (its image
# builds from a git context) and by Komodo's repo handling.
command -v git >/dev/null || echo "warning: git not found — required for git build contexts (Honcho)" >&2

# --- secret env files -----------------------------------------------------
mkdir -p "${HERMES_ENV_DIR}"
chmod 700 "${HERMES_ENV_DIR}"

for template in "${REPO_ROOT}"/secrets/*.env.example; do
  [ -e "$template" ] || continue
  name="$(basename "$template" .env.example)"
  target="${HERMES_ENV_DIR}/${name}.env"
  if [ -e "$target" ]; then
    echo "keep existing ${target}"
  else
    cp "$template" "$target"
    chmod 600 "$target"
    echo "created ${target} — EDIT IT and fill in real values"
  fi
done

# --- shared docker network ------------------------------------------------
if docker network inspect hermes-net >/dev/null 2>&1; then
  echo "keep existing docker network hermes-net"
else
  docker network create hermes-net
  echo "created docker network hermes-net"
fi

cat <<EOF

Next steps:
  1. Fill in the secrets:  vim ${HERMES_ENV_DIR}/*.env
     (key names per profile: check build/<profile>/.env.example after \`mise run render\`)
  2. Point komodo/resources.toml at this repo and your Komodo server name,
     then follow komodo/README.md to wire the Resource Sync + webhook.
EOF