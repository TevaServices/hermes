#!/bin/sh
# git credential router — THE credential helper for https://github.com in
# every profile's tool-home. Picks the GitHub App installation token by
# the OWNER the request is for:
#
#   owner has an org descriptor ($HOME/org-creds/<owner>.env)
#     -> mint/reuse the ORG App's installation token
#   no descriptor
#     -> replay the request into `gh auth git-credential` (the personal
#        App token gh keeps logged in; today's behavior, unchanged)
#
# Why a single router instead of git's per-URL config keys
# (credential.https://github.com/<org>.helper): git matches credential
# config by URL and only consults the path when
# credential.https://github.com.useHttpPath is true — and its path match
# is CASE-SENSITIVE while GitHub owners are case-insensitive, so a
# remote cloned with a lowercase owner would silently miss. One helper
# that reads the path off stdin and case-folds it has neither problem.
# (useHttpPath=true is still required — without it git sends no path at
# all. entrypoint.sh sets it alongside this helper.)
#
# Speaks the git credential helper protocol: reads the request (key=…
# lines, blank-line terminated) on stdin, prints username=/password= +
# a blank line on success. Git invokes this as
#   /usr/local/bin/git-credential-hermes.sh get
# (git appends the operation name; we accept and ignore it).
set -eu

# Only "get" mints. "erase"/"store" (git retrying after a rejection,
# or storing an approved credential) replay into gh exactly as before.
op="${1:-get}"
if [ "$op" != "get" ]; then
    exec gh auth git-credential "$@"
fi

req="$(cat)"

host="$(printf '%s\n' "$req" | sed -n 's/^host=//p' | head -1 | tr 'A-Z' 'a-z' | cut -d: -f1)"
path="$(printf '%s\n' "$req" | sed -n 's/^path=//p' | head -1)"
if [ -z "$host" ] && [ -z "$path" ]; then
    # url= form: some git versions hand the full URL instead of the parts.
    url="$(printf '%s\n' "$req" | sed -n 's/^url=//p' | head -1)"
    case "$url" in
        https://github.com/*) host="github.com"; path="${url#https://github.com/}" ;;
        *) exit 0 ;;
    esac
fi

# Only github.com routes here; any other host emits nothing (the helper
# is configured for https://github.com only anyway) — same as before.
[ "$(printf '%s' "$host" | cut -d: -f1)" = "github.com" ] || exit 0

# owner = first path segment; empty means no owner info -> personal path.
owner="$(printf '%s' "$path" | cut -d/ -f1 | tr -d '[:space:]')"

# --- org descriptor resolution (same chain as gh-org-token) -----------------
creds_dir="${ORG_CREDS_DIR:-}"
if [ -z "$creds_dir" ] && [ -d "${HOME:-}/org-creds" ]; then
    creds_dir="$HOME/org-creds"
fi
if [ -z "$creds_dir" ]; then
    script_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." 2>/dev/null && pwd)" || script_root=""
    if [ -n "$script_root" ] && [ -d "$script_root/home/org-creds" ]; then
        creds_dir="$script_root/home/org-creds"
    fi
fi

# Case-insensitive AND separator-insensitive owner match: GitHub owners
# are case-insensitive while the filesystem here is not; descriptor
# filenames follow the slug convention (lowercase, [a-z0-9] only).
owner_slug="$(printf '%s' "$owner" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9')"

if [ -n "$owner" ] && [ -n "$creds_dir" ]; then
    desc=""
    for f in "$creds_dir"/*.env; do
        [ -f "$f" ] || continue
        if [ "$(basename "$f" .env | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9')" = "$owner_slug" ]; then
            desc="$f"
            break
        fi
    done
    if [ -n "$desc" ]; then
        if ! token="$(gh-org-token "$owner_slug")"; then
            echo "git-credential-hermes.sh: no org token for '$owner' — refusing to fall back to the personal App for an org-owned repo" >&2
            exit 1
        fi
        printf 'username=x-access-token\npassword=%s\n\n' "$token"
        exit 0
    fi
fi

# Personal / unknown owner: exactly what git got before the router.
# REPLAY the captured request: the router consumed the helper's stdin
# above (req="$(cat)"), and gh's git-credential helper reads the request
# from stdin — exec'ing gh with an empty stdin serves nothing (git then
# falls through to an interactive prompt). "$@" forwards the operation
# name git appended (typically `get`).
printf '%s\n' "$req" | gh auth git-credential "$@"
exit $?