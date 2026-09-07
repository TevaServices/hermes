#!/bin/sh
# Git credential helper for the GitHub App (hermes-main[bot]).
# Git invokes this on every github.com operation; it mints a fresh
# installation token (1h TTL) via github-app-token.sh. Runs as the
# unprivileged runtime user with HOME=$HERMES_HOME/home (set by the
# entrypoint when it configures git) — the PEM copy lives in that
# tool-home, pointed at by GITHUB_APP_PRIVATE_KEY_PATH.
echo username=x-access-token
echo password="$(/usr/local/bin/github-app-token.sh)"