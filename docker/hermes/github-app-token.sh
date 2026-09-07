#!/bin/bash
# Generate a fresh GitHub App installation access token.
#
# Reads GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID and
# GITHUB_APP_PRIVATE_KEY_PATH from the environment (set in
# /etc/hermes/hermes-main.env; the PEM is mounted read-only). Signs a
# short-lived JWT with the app's private key, exchanges it for an
# installation token (1h TTL), and prints the token on stdout.
#
# Used by entrypoint.sh as git's credential helper (fresh token per
# operation) and by the gh re-auth refresher. Also usable standalone:
#   docker exec hermes-main /usr/local/bin/github-app-token.sh
set -euo pipefail

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
