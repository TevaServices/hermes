---
name: hermes-ops-runbook
description: Operator runbooks for the hermes repo that AGENTS.md deliberately does not carry every session — the post-deploy verification checklist, per-profile GitHub App + Discord bot provisioning and profile activation, the DCO / pre-push / claude-wrapper / org-App probes, and the Honcho memory checks. Load when verifying a deploy, (re)provisioning a profile, or diagnosing memory recall.
---

# hermes-ops-runbook — verification + provisioning procedures

Extracted from AGENTS.md so it loads only when needed; AGENTS.md keeps the
rules and is the pointer. Commands run on the live Docker host (placeholders
`<owner>`, `<org>`, `<your-proxy-host>` exactly as in AGENTS.md). Nothing
secret is printed: keys are read via `sudo` from `/etc/hermes` and never
echoed.

## Verification checklist (after any deploy)

```bash
docker ps --format '{{.Names}}\t{{.Status}}' | grep -E 'hermes|honcho|firecrawl|ollama'
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3002/v0/health/readiness   # 200
docker exec hermes-main hermes mcp test honcho      # Connected, ~31 tools
docker exec hermes-main hermes mcp test firecrawl   # tools discovered
# The firecrawl-guard: alive, and the agent actually routed through it
# (the MCP config names firecrawl-guard:3003, not firecrawl-api:3002).
docker inspect firecrawl-guard --format '{{.State.Health.Status}}'   # healthy
docker exec firecrawl-guard python3 -c \
  "import urllib.request,json;print(json.load(urllib.request.urlopen('http://127.0.0.1:3003/healthz')))"
#   -> {'ok': True, 'mode': 'enforce', 'egress': 'open', 'cache': 'ok'}
# Egress actually refuses (SSRF + secrets). Expect 403 + SCRAPE_BLOCKED_BY_GUARD,
# and NO new line in firecrawl-api's log for the attempt:
docker exec firecrawl-guard python3 -c "
import json,urllib.request,urllib.error
def post(u):
    r=urllib.request.Request('http://127.0.0.1:3003/v2/scrape',
        data=json.dumps({'url':u}).encode(),headers={'Content-Type':'application/json'})
    try: return urllib.request.urlopen(r,timeout=10).status
    except urllib.error.HTTPError as e: return e.code, json.load(e)['code']
print(post('http://litellm:4000/v1/models'))"
#   -> (403, 'SCRAPE_BLOCKED_BY_GUARD')
# Ingress sanitises: a real scrape comes back with the envelope.
docker exec firecrawl-guard python3 -c "
import json,urllib.request
r=urllib.request.Request('http://127.0.0.1:3003/v2/scrape',
    data=json.dumps({'url':'https://example.com','formats':['markdown']}).encode(),
    headers={'Content-Type':'application/json'})
d=json.load(urllib.request.urlopen(r,timeout=60))['data']['markdown']
print('enveloped:', d.startswith('> [GUARD]'))"
#   -> enveloped: True
# The forced classifier is NOT silently failing open — look for the
# classifier's warning rather than its absence of noise:
docker logs firecrawl-api 2>&1 | grep -i 'prompt injection' | tail -3
#   -> "Prompt injection detected..." or nothing; a repeated
#      "guard call failed ... (fail-open)" means MODEL_NAME/OPENROUTER broke
#      and the json-extraction lane is unguarded until fixed.
# Which side is broken — the model group, or just the guard call:
docker exec -e HOME=/opt/data/home hermes-main python3 -c "
import json,os,urllib.request,urllib.error
r=urllib.request.Request('http://litellm:4000/v1/chat/completions',
  data=json.dumps({'model':'firecrawl','messages':[{'role':'user','content':'hi'}],'max_tokens':5}).encode(),
  headers={'Content-Type':'application/json','Authorization':'Bearer '+os.environ['LITELLM_API_KEY']})
try: print('ok', urllib.request.urlopen(r,timeout=60).status)
except urllib.error.HTTPError as e: print('HTTP', e.code, e.read()[:200].decode())"
#   404 "ZDR violation (guardrail)" = the GROUP is down (/extract too);
#   429 "all deployments in cooldown" = aftermath, not a cause.
# The brake, live (flip in the stack environment, then deploy; no rebuild):
#   FIRECRAWL_EGRESS=closed    -> every fetch refused
#   FIRECRAWL_EGRESS=cache-only-> warmed pages served, everything else refused
# The release agent: its bot + App identity, the alt Komodo header in ITS
# home, the queue seeded. The queue run is the real check — EMPTY stdout is
# the healthy answer (the zero-token contract); anything else is work or a
# finding.
docker logs hermes-main 2>&1 | grep -E 'profiles/release|komodo alt auth header|discord connected \(profile: release\)'
docker exec -e HOME=/opt/data/profiles/release/home hermes-main ls -l home/komodo-alt-auth-header
docker exec hermes-main grep -A3 'team: release self-pull' /opt/data/profiles/release/cron/jobs.json
docker exec -e HOME=/opt/data/profiles/release/home hermes-main release-queue.sh --verbose   # names AWAITING HUMAN
docker exec -e HOME=/opt/data/profiles/release/home hermes-main release-queue.sh
# The type/* family exists on every onboarded repo (the offline suite pins
# the exact lane strings):
gh label list -R <owner>/<repo> --json name --jq '.[].name' | grep '^type/'
# Discord threads: every bot thread-capable in every routed channel (--probe
# creates + archives a real thread; named problems say guild-level vs
# channel overwrite):
python3 scripts/discord-thread-doctor.py            # all ✓, exit 0
# Gateway: /v1/models should list the four tier names PLUS the live Ollama
# Cloud catalogue (ollama/<id>) PLUS the five openrouter/ fallback ids — a
# swarm of openai/… names means check_provider_endpoint isn't taking effect.
curl -s http://127.0.0.1:4000/v1/models \
  -H "Authorization: Bearer $(sudo cat /etc/hermes/litellm.env | grep ^LITELLM_MASTER_KEY= | cut -d= -f2)" \
  | python3 -c 'import json,sys; print(*(m["id"] for m in json.load(sys.stdin)["data"]), sep="\n")'
# 200 per tier name (litellm's log names the serving backend); the fallback
# ids too (validates OpenRouter credits), plus a tool-calling round trip per
# id — Hermes requires function calling. After a REAL outage, confirm the
# fallback served: the response's `model` field / x-litellm-model-api-base
# header names the OpenRouter id, and the window after cooldown expiry names
# Ollama again.
for m in cheap smart smarter smartest; do printf '%-9s ' "$m"; \
  curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:4000/v1/chat/completions \
    -H "Authorization: Bearer $(sudo cat /etc/hermes/litellm.env | grep ^LITELLM_MASTER_KEY= | cut -d= -f2)" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"$m\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":5}"; done
# Declared windows vs the provider's own API + every fallback's
# window/tools vs OpenRouter's catalog — the ONLY check that catches
# litellm.yaml and models.toml drifting apart (needs internet, no key):
mise run check-model-windows                        # all ok, exit 0
# The gateway's DB + Redis + admin UI:
docker inspect litellm-db --format '{{.State.Health.Status}}'   # healthy
docker logs litellm 2>&1 | grep -iE 'prisma|migrat|redis' | tail -5
docker exec litellm-db psql -U litellm -d litellm -c '\dt' | head -8
#   -> LiteLLM_* tables (LiteLLM_VerificationToken, LiteLLM_UserTable, ...)
docker exec valkey valkey-cli -n 3 dbsize                        # grows in use
# Admin UI over the reverse proxy (sso/callback redirect URI pinned to
# $PROXY_BASE_URL; SSO is free ≤5 users on this version):
curl -sI https://<your-proxy-host>/ui                            # 200 or 30x
# Honcho memory end to end: plugin status (peer must be set), the per-turn
# injection audit, the deriver queue (0 errored), one timed recall — the
# "Honcho memory checks" section below.
docker exec -u hermes -e HOME=/opt/data/home -e HERMES_HOME=/opt/data \
  hermes-main /opt/hermes/bin/hermes honcho status | grep 'User peer'
docker exec honcho-db psql -U postgres -c \
  "select task_type, count(*) filter (where error is not null) as errored from queue group by 1"
# Aux lanes resolve to the tiers render.py pins them to (run against the
# DEPLOYED config — the check that would have caught four inert env pins;
# an unpinned lane answers ('auto', …) and silently runs on the primary):
docker exec -e HOME=/opt/data/home hermes-main sh -c 'grep -A3 "^auxiliary:" /opt/data/config.yaml'
docker exec -u hermes -e HOME=/opt/data/home hermes-main \
  /opt/hermes/.venv/bin/python -c "
from agent.auxiliary_client import _resolve_task_provider_model as r
for t in ('compression','title_generation','memory_query_rewrite','vision'): print(t, r(t))"
#   -> compression ('litellm','smarter',…), title_generation /
#      memory_query_rewrite ('litellm','cheap',…); vision ('auto',…)
#      is CORRECT (it must land on an image-capable model).
# Honcho's lanes: the env the deriver/api were CREATED with (a restart does
# not re-read env_file — an edited /etc/hermes/honcho.env lands on the next
# recreate):
docker inspect honcho-deriver --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | grep -E 'DERIVER|SUMMARY|DREAM|DIALECTIC'   # low must read smart, minimal cheap
# Dashboard plumbing (true in BOTH states): vendored plugin seeded into the
# default home; loopback port behaves per the gate:
docker exec hermes-main test -f /opt/data/plugins/hermes-memory-ui/dashboard/manifest.json \
  && echo "memory-ui vendored"
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:${HERMES_DASHBOARD_HOST_PORT:-9119}/
#   disabled (default): 000 — nothing listens. Expected.
#   enabled: 30x redirect to login or 401. A 200 WITHOUT a session means the
#   auth gate is NOT engaged — investigate immediately.
docker logs hermes-main 2>&1 | grep -i '\[dashboard\]' | tail -5   # no auth-provider errors
```

## Team label protocol (offline, and the live probe for a misfiled label)

Background: AGENTS.md §"Routing work to a profile".

```bash
mise run test
# Live: any open item carrying a label of the WRONG family? (An issue with
# review/* or a PR with status/* is invisible to BOTH queues.) Empty output
# is the healthy answer; the queue prints `!! FOREIGN LABEL` for a find.
docker exec -e HOME=/opt/data/profiles/developer/home hermes-main \
  gh search issues --owner <owner> --state open --limit 100 \
    --json repository,number,labels \
    --jq '.[] | ([.labels[].name] | map(select(startswith("review/"))) | length) as $n
          | select($n > 0) | "\(.repository.nameWithOwner)#\(.number)"'
docker exec -e HOME=/opt/data/profiles/reviewer/home hermes-main \
  gh search prs --owner <owner> --state open --limit 100 \
    --json repository,number,labels \
    --jq '.[] | ([.labels[].name] | map(select(startswith("status/"))) | length) as $n
          | select($n > 0) | "\(.repository.nameWithOwner)#\(.number)"'
```

## DCO sign-off hook (installed per tool-home; signs off only where the repo asks)

```bash
# Each tool-home's GLOBAL config points at the image's hook dir — the
# default home AND every profile's (the hook is useless without both):
docker exec -e HOME=/opt/data/home hermes-main git config --global core.hooksPath
docker exec -e HOME=/opt/data/profiles/developer/home hermes-main \
  git config --global core.hooksPath          # -> /opt/hermes-git-hooks
# The verified publish path is on PATH for every profile:
docker exec hermes-main test -x /usr/local/bin/git-publish.py && echo "publish ok"
docker exec hermes-main ls -l /opt/hermes-git-hooks/prepare-commit-msg   # 0755
docker exec hermes-main ls -l /opt/hermes-git-hooks/pre-push             # 0755
# pre-push probe: a github.com push is refused with the publish path named;
# the escape passes it; a non-GitHub remote passes through.
docker exec -e HOME=/opt/data/profiles/developer/home hermes-main sh -c '
  printf "refs/heads/x %s refs/heads/y %s\n" 0000000000000000000000000000000000000000 0000000000000000000000000000000000000000 |
  sh /opt/hermes-git-hooks/pre-push origin https://github.com/owner/repo.git 2>&1 | head -3'
#   -> "git push: REFUSED ... publish instead" + naming git-publish.py. With
#      HERMES_ALLOW_PUSH=1 prefixed to the sh invocation it exits 0 silently.
# Functional probe, in a throwaway repo: a repo that declares DCO gets the
# trailer; one that does not stays byte-identical. No network, no clone.
docker exec -e HOME=/opt/data/profiles/developer/home hermes-main sh -c '
  d=$(mktemp -d) && cd "$d" && git init -q -b main &&
  printf "# Contributing\n\nSign your work (DCO): a Signed-off-by line is required.\n" > CONTRIBUTING.md &&
  echo x > f && git add -A &&
  git -c user.name=probe -c user.email=probe@localhost commit -qm probe &&
  git log -1 --format=%B | grep -c "^Signed-off-by: "'
#   -> 1; 0 means the hook is missing or not executable (check hooksPath
#      first).
```

## The `claude` wrapper's argv

Skip flag for a real run, never for a subcommand — AGENTS.md §"Agent
self-management".

```bash
sh scripts/test-claude-wrapper.sh                   # offline; no container
# Live: the argv claude-real receives (needs an image built AFTER the
# CLAUDE_HERMES_DIR override landed — on an older one the wrapper ignores
# the var and answers the prompt instead of echoing argv):
docker exec -u hermes -e HERMES_HOME=/opt/data/profiles/developer \
  -e HOME=/opt/data/profiles/developer/home hermes-main sh -c '
  set -a; . /opt/data/profiles/developer/.env; set +a
  d=$(mktemp -d); mkdir -p "$d/claude-hermes"
  printf "#!/bin/sh\nfor a in \"\$@\"; do echo \"\$a\"; done\n" > "$d/claude-hermes/claude-real"
  chmod +x "$d/claude-hermes/claude-real"
  cp /opt/data/tools/claude-hermes/claude-model-resolve.py "$d/claude-hermes/"
  CLAUDE_HERMES_DIR="$d/claude-hermes" claude -p hi --max-turns 3'
#   -> the profile model, `-p`, `hi`, `--max-turns 3`,
#      `--dangerously-skip-permissions` — and NOT a second permission flag.
#      `claude mcp list` shows no skip flag at all.
# The real thing, once, to prove it still reaches the gateway:
docker exec -u hermes -e HERMES_HOME=/opt/data/profiles/developer \
  -e HOME=/opt/data/profiles/developer/home hermes-main sh -c '
  set -a; . /opt/data/profiles/developer/.env; set +a
  cd "$(mktemp -d)" && claude -p "Reply with exactly: OK" --max-turns 2'
#   -> OK, exit 0. A write is the part that used to fail — ask it to create
#      a file and check the file exists afterwards.
```

## Org GitHub Apps (after landing the org env vars + PEMs)

```bash
# Descriptors + warm token caches exist per tool-home, runtime-uid owned
docker exec hermes-main ls -la /opt/data/home/org-creds/ \
  /opt/data/profiles/developer/home/org-creds/
docker exec hermes-main sh -c 'for f in /opt/data/home/org-creds/*.token; do head -1 "$f"; done'
#   -> "<installation_id> <expiry>" per org; expiry > now + 50 min
# Boot log: one "org creds for <ORG> ->" + one "org token ok for <slug>"
# line per (tool-home, org); a FAILED line means org repos are unreachable.
docker logs hermes-main 2>&1 | grep -E 'org (creds|token)' | tail -12
# Git router: an org remote pulls with the ORG token (no prompt), a personal
# remote still works, an unknown owner falls through
docker exec -e HOME=/opt/data/home hermes-main \
  git ls-remote https://github.com/<org>/<private-repo>.git HEAD
# gh shim routing: an org target must resolve to the ORG token. Probe with
# a PRIVATE org repo from a non-git cwd — a public repo proves nothing
# (reads pass under BOTH tokens):
docker exec -e HOME=/opt/data/home hermes-main \
  sh -c 'cd /tmp && gh api repos/<org>/<private-repo> --jq .full_name'
#   -> <org>/<private-repo>. A 404 = the PERSONAL token went out (no owner
#      context, not a missing permission). `gh api` takes no -R.
# What each installation is GRANTED (user token; the App's own 404s here):
gh api /orgs/<org>/installations --jq '.installations[] | {app_slug, permissions}'
mise run test                              # routing logic, offline
docker exec hermes-main gh auth status     # shim passthrough
```

## Honcho memory checks

Context: AGENTS.md §"Honcho memory (what recall actually does)"; the
deriver's queue is the check that was silently broken.

```bash
# The plugin's own view: peer, recall mode, level, cap, connection.
docker exec -u hermes -e HOME=/opt/data/home -e HERMES_HOME=/opt/data \
  hermes-main /opt/hermes/bin/hermes honcho status      # "User peer:" must be set
docker exec -u hermes -e HOME=/opt/data/home hermes-main \
  /opt/hermes/bin/hermes honcho peers                   # per profile
# Per-turn record of what recall injected and why (logging: true; one shared
# file — every gateway s6 slot runs with HOME=/opt/data — distinguished by
# the session_key field):
docker exec hermes-main tail -3 /opt/data/.honcho/injection.log
# The deriver's health — errored rows were the structured-output fault;
# pending rows are just batching (REPRESENTATION_BATCH_*):
docker exec honcho-db psql -U postgres -c \
  "select task_type, count(*), count(*) filter (where error is not null) as errored from queue group by 1"
# Live recall, read-only, timed (a real answer is ~1-3 KB; 30s = the old bug):
docker exec honcho-api python3 -c "
import httpx,os,time; t=time.time()
r=httpx.post('http://127.0.0.1:8000/v3/workspaces/hermes/peers/hermes/chat',
  json={'query':'What do you know about this user?','reasoning_level':'minimal'},timeout=200)
print(round(time.time()-t,1),'s',len(r.text),r.status_code)"
# What actually reached an agent's turn (every injected memory block):
docker exec hermes-main python3 -c "
import sqlite3;c=sqlite3.connect('/opt/data/state.db')
print(c.execute(\"select count(*) from messages where content like '%memory-context%'\").fetchone())"
```

## Provisioning per-profile identities (GitHub Apps + Discord bots)

Every profile has its OWN bot identity in GitHub and Discord — the team
roles must be distinguishable from one another and from the main agent, and
must never share or impersonate another's. Both halves need one manual step
no API can perform; the scripts in `scripts/` wrap everything around them.

Inventory (one App + one Discord bot per profile):

| Profile | GitHub App (default name) | Discord bot |
|---|---|---|
| default | `hermes-main` | Hermes Main |
| planner | `hermes-planner` | Hermes Planner |
| developer | `hermes-dev` | Hermes Developer |
| reviewer | `hermes-reviewer` | Hermes Reviewer |
| release | `hermes-release` | Hermes Release |

App names are the DEFAULT `<prefix>-<role>`; override per profile with
`PROFILE_<NAME>_GH_APP_NAME` (App names are globally unique). App ids and
installation ids do not exist until you create the Apps. Installation ids,
git identities, and bot tokens live in `/etc/hermes/hermes-main.env` as
`PROFILE_<NAME>_*`; App and bot IDs are not secret, but **PEMs and bot
tokens are**: never echo, commit, or route them through a shell history or a
chat transcript. Both provisioning scripts run **on your machine** (the one
with the browser and the SSH key), not on the host, and deploy their own
secrets over SSH (`scripts/hostdeploy.py`, shared): content travels only by
ssh stdin or scp, never in an ssh command line, landing with `sudo install`
as `root:<host-group> 640`, the previous file kept beside it as
`<target>.hermes-deploy.bak`, every push verified by read-back. Passwordless
sudo (`sudo -n`) → automatic; otherwise each script generates an
`install-remote.sh` under gitignored `build/` running the same work through
ONE `ssh -t` (one sudo prompt). Point at the host with `--host` /
`HERMES_SSH_HOST` (an ssh-config destination, e.g. in gitignored
`mise.local.toml`); `--group` / `HERMES_HOST_GROUP` and `--env-dir` /
`HERMES_DEPLOY_ENV_DIR` default to `ubuntu` and `/etc/hermes` (deliberately
NOT `$HERMES_ENV_DIR`, which mise points at the local `secrets/` checkout).

### GitHub App for a new profile (`scripts/create-github-apps.py`)

GitHub has no API to create an App and `gh` cannot do it; the App Manifest
flow is the only automatable path and needs the account owner's browser. The
script serves the manifest from a local HTTP server, auto-submits it to
`github.com/settings/apps/new`, catches the redirect, and exchanges the
temporary code for the App's id + private key — its `setup_url` catches the
post-install redirect so the installation id is captured without anyone
reading it off a URL. Two clicks per app: **Create GitHub App**, then
**Install** with "All repositories". Run `python3
scripts/create-github-apps.py [profile ...] --host <host>` where the browser
is (default: the 4 team profiles). Artifacts land in gitignored
`build/github-apps/` (PEM mode 600, `results.json`, `env-lines.txt`); with
`--host` each PEM + env lines are pushed into `/etc/hermes/` and verified in
the same run. Re-running is safe — an existing App name fails at GitHub's
own name check before anything is created.

### Org Apps (`create-github-apps.py --org <ORG>`)

Same flow, manifests POST to the org's settings URL (browser needs org
admin); EVERYTHING lands in `build/github-apps/<orgslug>/` with org-slug'd
PEM names — a second run can never clobber the personal artifacts. The org
App-NAME prefix defaults to `<orgslug>-hermes` (deliberately different from
the personal names, which are taken); override with `--prefix` /
`HERMES_APP_PREFIX_<ORGUC>`, per profile with
`PROFILE_<NAME>_GH_APP_NAME_<ORGUC>`. The env lines are the ORG-SUFFIXED
vars plus `TEAM_ORG_DEV_BOT_<ORGUC>` (the org author filter for the
self-pull queues — add the org to `TEAM_OWNER_ORGS`). Run ONCE PER ORG; pass
`main` on the command line to include the default profile's org app.

### Bot token for a team profile (`scripts/set-team-discord-tokens.py`)

Run locally: prompts for each token with hidden input (`getpass`), and
validates every token against Discord BEFORE writing, then pushes the
`PROFILE_<NAME>_DISCORD_BOT_TOKEN` lines over SSH — same deploy contract as
the App script, read-back included. Duplicate-token checks: a token Discord
rejects, the main bot's token (hashed from `DISCORD_BOT_TOKEN` read off the
host env file — skipped with a warning without a readable host file or
`--host`), a user token, or one already entered for another profile. Pass
profile names to wire just one; `--set-var NAME=value` (repeatable) merges
additional lines in the same push — e.g. `--set-var
DISCORD_CHANNEL_RELEASE=<channel id>`. It prints each bot's invite URL
carrying the main bot's permission integer. Create the applications at
https://discord.com/developers/applications first, enabling **Message
Content** AND **Server Members** (plus Presence, matching the existing
bots) on each Bot tab. A token works as soon as the app exists, but the bot
is not *in* the guild until someone authorizes the invite URL.

### Activating a new profile

1. Create both identities with the scripts above, **with `--host`** so the
   PEMs, app/installation ids and `PROFILE_<NAME>_DISCORD_BOT_TOKEN` lines
   land in `/etc/hermes/hermes-main.env` in the same run (read-back
   verified); with no passwordless sudo, run each generated
   `install-remote.sh` right after. The `release` profile additionally
   needs `/etc/hermes/komodo-alt-auth-header` (root-owned 640).
2. Point the profile's Discord channel at it: add a route under
   `[config_extra.gateway.profile_routes]` in the default profile's
   `profile.toml`. Unrouted channels keep the default agent's behavior. A
   NEW channel id is also a new `DISCORD_CHANNEL_<NAME>` placeholder, and
   `render.py`'s `BOOT_PLACEHOLDERS` must gain it or the build fails on an
   unknown `@@VAR@@` (that failure is the point — a placeholder with no
   declaration is a literal reaching a config).
3. Commit + deploy, then verify in the logs — the entrypoint logs
   `gh authed via GitHub App (home=…, app id=…)` per profile, and the
   gateway logs `[Discord] Connected as <bot>` +
   `✓ discord connected (profile: <name>)`.