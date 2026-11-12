#!/bin/sh
# Mint a LiteLLM virtual key scoped to an explicit model allow-list.
#
# Every LLM caller in the stack gets its OWN key: Hermes (`hermes`), Honcho
# (`honcho`), Open WebUI (`openwebui`), and Firecrawl (`firecrawl`). The
# gateway MASTER key is then held only by the litellm container itself. A
# compromised app can reach only the models its key lists, and revoking one
# key does not disturb the others.
#
# The master key is read from the litellm CONTAINER's own environment; it is
# never passed through the host shell or an argument. The generated key is
# the only secret this script emits.
#
# Usage:
#   sh scripts/mint-service-key.sh --alias hermes \
#       --models cheap,smart,smarter,smartest
#   sh scripts/mint-service-key.sh --alias openwebui --models all-proxy-models
#   sh scripts/mint-service-key.sh --alias honcho --models cheap,smart \
#       --out /etc/hermes/honcho-key.env --var LLM_OPENAI_API_KEY
#
# `--models` accepts a comma-separated allow-list, or the LiteLLM sentinel
# `all-proxy-models` (every model the gateway serves, including future ones).
# Prefer an explicit list; the sentinel is for a consumer whose model picker
# is deliberately the whole catalogue.
#
# `--out` writes `<VAR>=<key>` (mode 600) instead of printing the key.
# Put the result in the matching /etc/hermes/*.env file:
#   hermes   -> LITELLM_API_KEY (and OPENAI_API_KEY, which mirrors it)
#   honcho   -> LLM_OPENAI_API_KEY
#   openwebui -> the OPENWEBUI_LITELLM_API_KEY Komodo Variable
# and redeploy (a plain restart does not re-read env_file / Komodo vars).
#
# Re-running creates a NEW key. Revoke the previous one (LiteLLM admin UI or
# POST /key/delete) after confirming the new one serves a request.

set -eu

alias=
models=
var=OPENAI_API_KEY
out=
purpose=
budget=
rpm=

usage() {
    sed -n '2,37p' "$0" | sed 's/^#//'
    exit "${1:-2}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --alias)   alias=$2; shift 2 ;;
        --models)  models=$2; shift 2 ;;
        --var)     var=$2; shift 2 ;;
        --out)     out=$2; shift 2 ;;
        --purpose) purpose=$2; shift 2 ;;
        --budget)  budget=$2; shift 2 ;;
        --rpm)     rpm=$2; shift 2 ;;
        -h|--help) usage 0 ;;
        *) echo "unknown argument: $1" >&2; usage ;;
    esac
done

[ -n "$alias" ] || { echo "--alias is required" >&2; usage; }
[ -n "$models" ] || { echo "--models is required" >&2; usage; }

command -v docker >/dev/null 2>&1 || { echo "docker not found" >&2; exit 2; }
docker inspect litellm >/dev/null 2>&1 || {
    echo "litellm container not found; start the stack first" >&2
    exit 2
}

payload=$(python3 - "$alias" "$models" "$purpose" "$budget" "$rpm" <<'PY'
import json, sys
alias, models, purpose, budget, rpm = sys.argv[1:6]
if models.strip() == "all-proxy-models":
    allow = ["all-proxy-models"]
else:
    allow = [m.strip() for m in models.split(",") if m.strip()]
if not allow:
    sys.exit("--models resolved to an empty allow-list")
body = {
    "key_alias": alias,
    "models": allow,
    "metadata": {
        "service": alias,
        "purpose": purpose or f"{alias} LLM traffic",
    },
}
if budget:
    body["max_budget"] = float(budget)
    body["budget_duration"] = "30d"
if rpm:
    body["rpm_limit"] = int(rpm)
print(json.dumps(body))
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
    printf '%s=%s\n' "$var" "$key" > "$out"
    echo "wrote $out (mode 600)"
else
    printf '%s\n' "$key"
fi
