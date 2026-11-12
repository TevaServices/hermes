#!/bin/sh
# Mint a LiteLLM virtual key scoped to the `firecrawl` model group.
#
# Firecrawl's LLM features (extract + the forced prompt-injection classifier)
# only ever need that one group. Giving Firecrawl the gateway MASTER key — as
# the old firecrawl.env.example did — lets a compromised Firecrawl (or a
# prompt-injected page that reaches its extractor) call every tier and every
# upstream model on the stack. This key closes that lateral path: models is a
# hard allow-list, and the budget/rpm limits cap the blast radius.
#
# The master key is read from the litellm CONTAINER's own environment; it is
# never passed through the host shell or an argument. The generated key is the
# only secret this script emits.
#
# Usage:
#   sh scripts/mint-firecrawl-key.sh                 # print the key
#   sh scripts/mint-firecrawl-key.sh --out /etc/hermes/firecrawl-key.env
#   sh scripts/mint-firecrawl-key.sh --alias firecrawl --budget 5 --rpm 120
#
# Put the result in /etc/hermes/firecrawl.env as:
#   OPENAI_API_KEY=<key>
# and redeploy (the next deploy recreates firecrawl-api; a plain restart does
# not re-read env_file).
#
# Re-running creates a NEW key. Revoke the previous one (LiteLLM admin UI or
# POST /key/delete) after confirming the new one serves a scrape.

set -eu

alias=firecrawl
budget=5
rpm=60
out=

usage() {
    sed -n '2,30p' "$0" | sed 's/^#//'
    exit "${1:-2}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --alias)  alias=$2; shift 2 ;;
        --budget) budget=$2; shift 2 ;;
        --rpm)    rpm=$2; shift 2 ;;
        --out)    out=$2; shift 2 ;;
        -h|--help) usage 0 ;;
        *) echo "unknown argument: $1" >&2; usage ;;
    esac
done

command -v docker >/dev/null 2>&1 || { echo "docker not found" >&2; exit 2; }
docker inspect litellm >/dev/null 2>&1 || {
    echo "litellm container not found; start the stack first" >&2
    exit 2
}

payload=$(python3 - "$alias" "$budget" "$rpm" <<'PY'
import json, sys
alias, budget, rpm = sys.argv[1], float(sys.argv[2]), int(sys.argv[3])
print(json.dumps({
    "key_alias": alias,
    "models": ["firecrawl"],
    "max_budget": budget,
    "budget_duration": "30d",
    "rpm_limit": rpm,
    "metadata": {
        "service": "firecrawl",
        "purpose": "Firecrawl LLM features; public web content only",
    },
}))
PY
)

response=$(docker exec -i litellm python3 - "$payload" <<'PY'
import json, os, sys, urllib.error, urllib.request

payload = json.loads(sys.argv[1])
req = urllib.request.Request(
    "http://127.0.0.1:4000/key/generate",
    data=json.dumps(payload).encode(),
    headers={
        "Authorization": "Bearer " + os.environ["LITELLM_MASTER_KEY"],
        "Content-Type": "application/json",
    },
    method="POST",
)
try:
    with urllib.request.urlopen(req, timeout=30) as r:
        sys.stdout.write(r.read().decode())
except urllib.error.HTTPError as e:
    sys.stderr.write("LiteLLM /key/generate failed: %s\n%s\n" %
                     (e.code, e.read().decode(errors="replace")))
    sys.exit(1)
except Exception as e:
    sys.stderr.write("LiteLLM /key/generate failed: %s\n" % e)
    sys.exit(1)
PY
)

key=$(printf '%s' "$response" | python3 -c '
import json, sys
try:
    body = json.load(sys.stdin)
except Exception:
    sys.exit("could not parse LiteLLM response")
if "key" not in body:
    sys.exit("LiteLLM response has no key: %r" % (body,))
print(body["key"])
')

if [ -n "$out" ]; then
    umask 077
    printf 'OPENAI_API_KEY=%s\n' "$key" > "$out"
    echo "wrote $out (mode 600)"
else
    printf '%s\n' "$key"
fi
