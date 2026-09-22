#!/bin/bash
# Generate a fresh GitHub App installation access token.
#
# Reads GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID and
# GITHUB_APP_PRIVATE_KEY_PATH from the environment (set in
# /etc/hermes/hermes-main.env; the PEM is mounted read-only). Signs a
# short-lived JWT with the app's private key, exchanges it for an
# installation token (1h TTL), and prints the token on stdout.
#
# The three values may also be passed as flags, which override the
# environment — this is how the org-credential helpers (gh-org-token,
# git-credential-hermes.sh) mint for the ORG App after sourcing its
# descriptor, without the caller having to export anything:
#   github-app-token.sh --app-id X --installation-id Y --pem Z
#
# Used by entrypoint.sh for gh's initial auth + re-auth refresher and by
# gh-org-token for the org credential sets. Also usable standalone:
#   docker exec hermes-main /usr/local/bin/github-app-token.sh
set -euo pipefail

while [ $# -gt 0 ]; do
    case "$1" in
        --app-id) GITHUB_APP_ID="$2"; shift 2 ;;
        --installation-id) GITHUB_APP_INSTALLATION_ID="$2"; shift 2 ;;
        --pem) GITHUB_APP_PRIVATE_KEY_PATH="$2"; shift 2 ;;
        *) echo "github-app-token.sh: unknown argument: $1" >&2; exit 64 ;;
    esac
done

: "${GITHUB_APP_ID:?GITHUB_APP_ID not set}"
: "${GITHUB_APP_INSTALLATION_ID:?GITHUB_APP_INSTALLATION_ID not set}"
: "${GITHUB_APP_PRIVATE_KEY_PATH:?GITHUB_APP_PRIVATE_KEY_PATH not set}"

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

now=$(date +%s)
header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
payload=$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' \
  "$((now - 60))" "$((now + 600))" "$GITHUB_APP_ID" | b64url)
sig=$(printf '%s.%s' "$header" "$payload" \
  | openssl dgst -sha256 -sign "$GITHUB_APP_PRIVATE_KEY_PATH" | b64url)
jwt="$header.$payload.$sig"

curl -fsS --max-time 20 --retry 2 -X POST \
  -H "Authorization: Bearer $jwt" \
  -H "Accept: application/vnd.github.v3+json" \
  "https://api.github.com/app/installations/$GITHUB_APP_INSTALLATION_ID/access_tokens" \
  | sed -n 's/.*"token": *"\([^"]*\)".*/\1/p'
