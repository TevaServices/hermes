#!/usr/bin/env bash
# Report drift between the version pins in mise.toml [env] and upstream.
#
# Read-only; safe to run anywhere (uses git ls-remote, no clones, no mise
# required). Run locally before a bump, or from a scheduled Komodo
# Action to get a "your pins are stale" signal. Bump the pin, commit,
# push — the webhook-driven rebuild is the actual update.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Version pins live in mise.toml [env] (exported to mise tasks locally;
# Komodo repeats them in komodo/resources.toml). Empty output means the
# pin is missing from mise.toml — reported below, not fatal (grep
# returns 1 on no match, which pipefail would otherwise escalate).
get_pin() {
  # "KEY = \"value\"  # trailing comment" -> value (comment optional)
  { grep -m1 -E "^${1} *= " "${REPO_ROOT}/mise.toml" \
      | sed -E 's/^[A-Z_]+ *= *"([^"]*)".*$/\1/'; } || true
}

HERMES_REF="$(get_pin HERMES_REF)"
HONCHO_VERSION="$(get_pin HONCHO_VERSION)"
FIRECRAWL_VERSION="$(get_pin FIRECRAWL_VERSION)"

echo "Checking pinned versions against upstream..."
echo

# --- Hermes: latest commit on main + the pinned ref's freshness -----------
hermes_latest="$(git ls-remote https://github.com/NousResearch/hermes-agent HEAD | cut -f1)"
hermes_pinned_sha="$(git ls-remote https://github.com/NousResearch/hermes-agent "${HERMES_REF}" | cut -f1)"
echo "hermes    pinned: ${HERMES_REF}  (${hermes_pinned_sha:-NOT FOUND})"
echo "          upstream main HEAD: ${hermes_latest}"
if [ -n "${hermes_pinned_sha}" ] && [ "${hermes_pinned_sha}" = "${hermes_latest}" ]; then
  echo "          -> up to date with main"
else
  echo "          -> PIN IS BEHIND: bump HERMES_REF in mise.toml [env]"
  echo "             (and komodo/resources.toml if deploying via Komodo)"
fi
echo

# --- Honcho ----------------------------------------------------------------
honcho_latest="$(git ls-remote https://github.com/plastic-labs/honcho HEAD | cut -f1)"
honcho_pinned="$(git ls-remote https://github.com/plastic-labs/honcho "${HONCHO_VERSION}" | cut -f1)"
echo "honcho    pinned: ${HONCHO_VERSION}  (${honcho_pinned:-NOT FOUND})"
echo "          upstream HEAD: ${honcho_latest}"
if [ -n "${honcho_pinned}" ] && [ "${honcho_pinned}" = "${honcho_latest}" ]; then
  echo "          -> up to date"
else
  echo "          -> consider bumping HONCHO_VERSION"
fi
echo

# --- Firecrawl: newest tag --------------------------------------------------
echo "firecrawl pinned: ${FIRECRAWL_VERSION}"
echo "           newest tags:"
git ls-remote --tags --refs https://github.com/firecrawl/firecrawl 'v*' \
  | cut -f2 | sed 's|refs/tags/||' | sort -V | tail -5 | sed 's/^/             /'
echo "           -> if pinning: verify the tag exists on ghcr.io/firecrawl/* too"
echo "              (https://github.com/firecrawl/firecrawl/pkgs/container/firecrawl)"