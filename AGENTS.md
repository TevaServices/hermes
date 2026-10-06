# AGENTS.md — hermes (agent stack, deployed by Komodo)

A GitOps-managed [Hermes agent](https://github.com/NousResearch/hermes-agent)
stack: one container (a thin build over the official
`nousresearch/hermes-agent` image) hosting ALL profiles under its s6
supervision, its configuration rendered at image-build time from small
declarative files (`config/` → `render.py` → `/overlay/<profile>`), plus
[Honcho](https://github.com/plastic-labs/honcho) (memory),
[Firecrawl](https://docs.firecrawl.dev/contributing/self-host) (web), and a
[LiteLLM](https://docs.litellm.ai/) proxy (the stack's single LLM gateway).
Everything runs on the Docker host under **Komodo GitOps** — read
[the komodo repo's AGENTS.md](https://github.com/<owner>/komodo) for the
control plane, API cheatsheet, and deploy mechanics.

> **On-demand runbooks.** Procedures not needed in every session — the full
> post-deploy **verification checklist**, per-profile **GitHub App + Discord
> provisioning** and profile activation, the DCO / pre-push / `claude`-wrapper
> / org-App probes, and the **Honcho memory checks** — live in the project
> skill **`hermes-ops-runbook`** (invoke as `/hermes-ops-runbook`, or on
> ops-shaped work). This file keeps the rules; the skill keeps the
> step-by-step procedures.

## Deployment model

Deployed as the Komodo Stack **`hermes`** (server `<your-komodo-server>`): one
compose project merging all files under `compose/`, cloned from this repo at
deploy time. **The compose project name is `hermes`** — named volumes are
prefixed `hermes_*` (agent state, honcho Postgres, firecrawl db, the shared
valkey + lavinmq) and hold live data; do not rename the stack. It must deploy
before komodo-core can start with it (`hermes_net` is declared external in
komodo's compose).

- **Merging a PR to `main` = build + deploy** (GitHub webhook → the Komodo
  `rebuild-hermes-agent` procedure: build `hermes-agent` → build `litellm` →
  deploy `hermes`, sequentially, defined in the komodo repo's
  `resources.toml`). Honcho images build upstream-first via the
  `rebuild-honcho` procedure (`execute/RunProcedure
  {"procedure":"rebuild-honcho"}` — no webhook). Config/compose-only changes
  cost a Dockerfile cache-hit build (~1 min).
- **`main` is protected — land every change through a squash-merged PR.** The
  `Main` ruleset rejects direct pushes (`git push origin main` fails with
  `GH013`), force-pushes and branch deletion, requires verified landing
  commits, and permits only squash merges; a `Release tags` ruleset blocks
  moving or deleting a `v*` tag. The webhook fires on the *push* a squash
  merge produces — merge = deploy is literally the same event.
- **Images are built by Komodo Builds — never compose build** (the stack runs
  `run_build = false`; images `hermes-agent:v2026.9.24`, `litellm:main`,
  `honcho:main`, `honcho-mcp:main`, `builder = "<your-builder>"`). The
  `hermes-agent` and `litellm` Builds use a **repo-root build context**
  (`build_path = "."`) — the Dockerfiles COPY `docker/hermes/*`, `config/` +
  `render.py` (rendered inside the build), and `config/litellm.yaml` (see
  `.dockerignore`). Missed webhook: merge, then `execute/RunBuild` per build,
  then `execute/DeployStack {"stack":"hermes"}` — and check `GetStack` →
  `info.deployed_hash`; a webhook delivery can 200 but skip if Komodo is
  mid-operation or restarting.
- **Config is baked into images, so deploys restart intelligently.** A
  config-only change invalidates just the final COPY layer → new image → the
  deploy's `compose up` recreates only the affected service. No bind-mounted
  config files, no reloader sidecar, no manual restarts; never hand-edit a
  container's config in place. A deploy is a no-op for services whose image
  and compose config didn't change — confirm recreation via `docker inspect
  <container> --format '{{.State.StartedAt}}'`. Host edits to
  `/etc/hermes/*.env` DO trigger recreation on the next deploy (compose
  hashes env_file contents).
- The agent image is a thin build FROM the official base image — code, venv,
  launcher, Node, and the s6 tree are upstream's problem; don't re-implement
  them here. The venv is uv-managed (no pip; `uv pip install --python
  <venv>/bin/python`).

### Bumping HERMES_REF (the update checklist)

The ref is the FROM tag of the official base image (publishes per-release, so
a bump upgrades agent code and the supervision tree together). Update it in
**all** of: the `hermes-agent` Build's `image_tag` AND `build_args`, the stack
`environment` in the komodo repo's resources.toml, `mise.toml [env]` (the
Dockerfile ARG defaults flow through compose, so only mise.toml needs the
edit), and `render.py`'s `_FALLBACK_CONFIG_VERSION` (local preview only — the
build-time stamp derives from the base image). A ref bump is exactly when the
source patches in `docker/hermes/patches/` break: their anchors are upstream
line numbers, the build fails loudly if an anchor moved, and an
already-adopted patch reverse-applies with a NOTICE telling you to delete it
(an unpatched image is never shipped silently). Then RunBuild → DeployStack,
and always verify `hermes mcp test honcho` + `hermes mcp test firecrawl`
against the new image — Hermes' MCP SDK pin is where HTTP-transport breakage
has landed before (refs from v2026.8.31 on natively support mcp 2.x; the old
`mcp<2` pin was dropped at that bump).

## Secrets

Runtime secrets live in root-owned files on the host — `/etc/hermes/*.env`
(mode 640, `root:<host-group>`), mounted read-only into Periphery, wired via
the stack `environment` `HERMES_ENV_DIR=/etc/hermes`. Templates are in
`secrets/*.env.example`; nothing secret is ever committed, echoed, or routed
through a shell history or chat transcript.

- **Every LLM in the stack goes through the LiteLLM proxy**
  (`http://litellm:4000` + `config/litellm.yaml`). The proxy holds the real
  upstream keys (`OLLAMA_API_KEY` for Ollama Cloud, `OPENROUTER_API_KEY`,
  both in `litellm.env`) and routes each model name among that group's
  members (`router_settings.routing_strategy: latency-based-routing` — inert
  while each tier has one member, meaningful when one grows a second
  deployment, which is also when same-capability-class starts to matter: a
  fallback with a smaller window silently breaks long-context work). Two
  wildcards serve try-before-promote: `ollama/*` (every other Ollama Cloud
  model, callable as `ollama/<model-id>`, expanded in `/v1/models` from the
  provider's own list via `litellm_settings.check_provider_endpoint`) and
  `openrouter/*` (2026-10-06, `openrouter/<model-id>` on the shared
  non-free ZDR-guarded key — the `firecrawl` group's `:free`-only rule and
  separate key are untouched). **A wildcard id has NO declared window**
  (models.toml declares windows per TIER) — fine for a try, not something an
  agent should rely on; explicit ids always beat the wildcard.
  **Bare-name aliases are the DEFAULT vocabulary** (2026-10-06): `glm-5.3-flash`,
  `glm-5.3`, `kimi-k3`, `gemma4`, `nemotron-3-nano` (+ later additions) —
  unprefixed, no `:cloud` suffix (`nemotron-3-nano`'s `:30b` variant is
  required by Ollama Cloud and lives inside `litellm_params`, never in the
  caller's string). Each alias is a one-member Ollama Cloud group whose
  `router_settings.fallbacks` chain names its OpenRouter twin — the provider
  namespaces genuinely differ (z-ai/…, moonshotai/…), so the pairing is an
  EXPLICIT table (litellm.yaml alias block + models.toml rows, in the same
  change; `mise run check-model-windows` verifies both sides), deliberately
  NOT heuristic catalog matching: a wrong silent auto-pair serves the WRONG
  model, while a missing pair fails loudly. The `ollama/`-prefixed spelling
  shares the alias's chain (litellm strips the provider prefix); an
  undeclared bare name, the wildcards, and openrouter/-typed ids stay
  chain-less and fail loudly — no `default_fallbacks`. Apps authenticate with
  the master key (`LITELLM_MASTER_KEY`, `openssl rand -hex 32`), mirrored
  into each app's env as `LITELLM_API_KEY` / `LLM_OPENAI_API_KEY` /
  `OPENAI_API_KEY` — same value everywhere.
- **`config/litellm.yaml` is the backend file; the apps only ever send one of
  four TIER NAMES.** `cheap` / `smart` / `smarter` / `smartest` are LiteLLM
  `model_name` groups, and everything under a group's `litellm_params` —
  provider, upstream id, `api_base`, key, extra params, extra members — is
  the implementer's to point anywhere: moving a tier to another provider is
  an edit to this file and NOTHING else (windows are in lockstep with
  `config/models.toml`, see §"Agent runtime invariants"). Current backends
  (windows verified via `POST ollama.com/api/show`, re-checkable with `mise
  run check-model-windows`):
  **cheap** = `nemotron-3-nano:30b` (256k; `smart_model_routing`'s cheap lane
  for short/simple turns, Hermes' mechanical aux lanes (title generation,
  memory-query rewrite — see §"Auxiliary side tasks"), and Honcho's VOLUME
  lanes: the deriver, which runs on every message, plus the `minimal`
  dialectic level),
  **smart** = `gemma4:cloud` (256k, vision; the planner profile, and Honcho's
  REASONING lanes: dream deduction/induction, summaries, and the
  `low`/medium/high/max dialectic levels — `low` is the DEFAULT level for
  every dialectic query and runs a 5-round agentic tool loop, so it is
  reasoning work however light the name sounds),
  **smarter** = `glm-5.3-flash` (1M, vision; the default, developer and
  release profiles, and aux compression — the one lane that needs
  intelligence AND a big window),
  **smartest** = `glm-5.3` (1M, **no vision**; the reviewer, plus the opt-in
  `/model smartest` escalation — kimi-k3 is the drop-in swap if the top tier
  ever needs images).
  Because the tier names ARE the gateway's model names, `/model cheap` …
  `/model smartest` all resolve mid-session.
- **Outage fallbacks: the GATEWAY owns the failure path, not Hermes
  (2026-10-02).** Each tier's Ollama Cloud deployment has a same-model
  OpenRouter fallback in `litellm.yaml`'s `router_settings.fallbacks` (window
  ≥ the tier's, tools-capable, checked by `mise run
  check-model-windows` against OpenRouter's catalog too; `render.py` fails
  the build if a fallback names a missing group): `cheap` →
  `openrouter/nvidia/nemotron-3-nano-30b-a3b`, `smart` →
  `openrouter/google/gemma-4-31b-it`, `smarter` →
  `openrouter/z-ai/glm-5.3-flash`, `smartest` → `openrouter/z-ai/glm-5.3`
  then `openrouter/moonshotai/kimi-k3`; the five ids are also `model_name`
  groups, callable directly for testing. A 429 cools the Ollama deployment
  down immediately (per-deployment, `cooldown_time: 60`; `num_retries: 1` — a
  limit is not fixed by retrying), the request fails over to the OpenRouter
  id in order, and the primary is re-probed when the cooldown expires — a
  refreshed subscription returns traffic on its own. Same-model matching, so
  fallback turns keep the tier's capability class. Correspondingly **no
  profile declares `fallback_model` any more** (see §"Agent runtime
  invariants"): re-routing the tier via OpenRouter, same quality, replaced
  the escalation chain. NOT covered, on purpose: the `firecrawl` group (its
  two free members fail over within the group; no fallback to a paid path)
  and the `ollama/*` wildcard (single passthrough, no `default_fallbacks` —
  a wildcard id must not acquire a silent paid path). Which backend served a
  request is observable in the response's `model` field and the
  `x-litellm-model-api-base`/`x-litellm-model-id` headers, plus litellm's
  cooldown lines in `docker logs litellm`. Shipped in the same change:
  `litellm_settings.drop_params: true` — Honcho's `nomic-embed-text` calls
  4xxed on OpenAI-client default `encoding_format: float`, which the ollama
  provider rejects.
- **The `firecrawl` group is NOT a tier: OpenRouter free models ONLY**
  (`google/gemma-4-31b-it:free`, `nvidia/nemotron-3-super-120b-a12b:free`) —
  Ollama Cloud strips `response_format: json_schema` (so /v1/extract and v2
  json-format scrapes returned `json: null`), while OpenRouter passes it
  through and SmartScrape extraction works. It is also the shape to copy for
  any other lane that can never see private data.
- `litellm.env`: `LITELLM_MASTER_KEY`, `OLLAMA_API_KEY`,
  `OPENROUTER_API_KEY` (create at https://openrouter.ai/keys),
  `OPENROUTER_FREE_KEY` (the `firecrawl` group's second key), the gateway's
  `DATABASE_URL` (DB-backed since 2026-10-06), and the admin-UI SSO block:
  `PROXY_BASE_URL`, `GENERIC_CLIENT_ID`/`_SECRET` (Zitadel OIDC app), the
  three `GENERIC_*_ENDPOINT`s (the issuer's OIDC discovery values),
  `GENERIC_USER_ID_ATTRIBUTE=sub`, `ALLOWED_EMAIL_DOMAINS`.
- `litellm-db.env` (paired with the above — one generated `DATABASE_URL`
  password): `POSTGRES_USER=litellm`, `POSTGRES_PASSWORD`,
  `POSTGRES_DB=litellm`. See `secrets/litellm-db.env.example`.
- `hermes-main.env`: `LITELLM_API_KEY` (the master key), `FIRECRAWL_API_KEY`
  (must equal `TEST_API_KEY` in `firecrawl.env`), `HONCHO_API_KEY` (any
  non-empty value while honcho-api runs no-auth; must match honcho-api if
  auth is enabled), `OPENAI_API_KEY` + `OPENAI_BASE_URL` (mirror the LiteLLM
  endpoint for Hermes' registry-based fallbacks — `hermes chat`'s first-run
  gate only inspects registry env vars, never config.yaml's
  `custom_providers`, and exits with setup guidance without them even though
  the gateway resolves the provider fine), `DISCORD_BOT_TOKEN` +
  `DISCORD_ALLOWED_USERS` (gateway), GitHub App vars (below), and
  `PROFILE_<NAME>_*` lines for the team profiles. **It does NOT carry
  `AUXILIARY_*` model pins, and must not grow them back** — see §"Auxiliary
  side tasks" for the four that were dead weight there until 2026-10-04.
- **`hermes-main.env` is the LAUNCH profile's env, and Hermes deletes its
  non-global names from every other profile's cron child.** The child env is
  built as `strip_launch_profile_env(build_subprocess_env(...))`
  (`cron/scheduler.py`): every name found in the launch profile's `.env`
  (`/opt/data/.env`) is removed unless `_is_global_env` marks it global
  (`tools/environments/local.py`). A routed profile's `no_agent` SCRIPT child
  then sees neither the launch `.env` nor its own — nothing re-loads a script
  child's profile env (an agent child does, `served_profile_child_env`).
  Observed: `TEAM_OWNER`, `TEAM_OWNER_ORGS`, `TEAM_ORG_DEV_BOT_<ORG>` sat in
  this file and were silently stripped from the reviewer's job — **71
  consecutive exit-64 failures** (`team-queue.sh: owner must not be empty`)
  while the developer's survived by luck, because the strip runs WITHOUT the
  job's own `profile_home` and keyed off the PREVIOUS dispatch's override
  (dev 136/1, reviewer 95/71 that day). A queue failing this way looks
  exactly like a quiet one. The entrypoint therefore FILTERS the `TEAM_*`
  family out of the root `.env` copy — complete, because compose injects the
  same file as container env, so the vars still reach every script. **Rule:
  a var read by a cron job's SCRIPT must not live in this file** — put it in
  the stack `environment:` (komodo `resources.toml`, mirrored in
  `mise.toml`). The per-profile `.env` copies KEEP their `TEAM_*` lines —
  those homes are not the launch home.
- `firecrawl.env`: `TEST_API_KEY`, `POSTGRES_*`, `OPENAI_API_KEY` +
  `OPENAI_BASE_URL` (LiteLLM) + `MODEL_NAME=firecrawl` (LLM extract/generate).
- `honcho.env`: `LLM_OPENAI_API_KEY` + `LLM_OPENAI_BASE_URL` (LiteLLM — bare
  `OPENAI_API_KEY` is NOT read; every default model config reuses the client
  built from these two), per-section `*_MODEL_CONFIG__MODEL` overrides
  (deriver, summaries, dream, dialectic levels — defaults point at OpenAI
  models this gateway does not serve, so all are pinned to TIER NAMES), and
  the embedding block: `EMBEDDING_MODEL_CONFIG__*` → LiteLLM's
  `nomic-embed-text` entry → the stack-local `ollama` service (768 dims;
  Ollama Cloud has **no embeddings endpoint**) + `EMBEDDING_VECTOR_DIMENSIONS=768`.
  Optional `HONCHO_POSTGRES_PASSWORD`. The section split follows the
  measured work, not the lane's name: **volume lanes on `cheap`** (the
  deriver runs on every message; `minimal` dialectic is 1 tool round, 2
  tools, 250 tokens out), **reasoning lanes on `smart`** (dream
  deduction/induction: 12- and 10-iteration agentic loops over the whole
  memory graph, 8192 tokens out; summaries are the text surfaced to the
  agent; dialectic `low`/medium/high/max are 5/2/4/10-round tool loops —
  `low` moved off `cheap` 2026-10-04: it is the DEFAULT level for every
  query and the most demanding prompt in the stack). Every lane except
  `summary` requires tool calling, and the deriver additionally requires
  structured JSON — which no Ollama-backed lane honours — hence
  `DERIVER_MODEL_CONFIG__STRUCTURED_OUTPUT_MODE=json_object` (verified: 0 →
  3 facts). That line, the peer pin and the recall-side tuning are the story
  of §"Honcho memory (what recall actually does)" — read it before changing
  anything here. **Raising the DERIVER is the single biggest spend AND
  quality lever** — the one line to change if memory extraction still looks
  thin.

## Stack particulars (hard-won)

The stack is deliberately right-sized **small** — upstream defaults assume a
real server and will starve a small host into crash-loops. Do not "fix" the
small numbers in the compose files without checking the host's actual
resources.

- **litellm is DB-backed, and the admin UI is the Zitadel-SSO surface.**
  Since 2026-10-06 the gateway runs a dedicated Postgres (`compose/
  litellm.compose.yml` service `litellm-db`, volume `litellm-db-data`,
  password auth via `/etc/hermes/litellm-db.env` — NOT trust auth like
  honcho-db; the DB holds every API credential) and wires the shared Valkey
  as Redis at logical DB **/3** via `REDIS_HOST/PORT/DB`. `DATABASE_URL` +
  the SSO env (`GENERIC_*`, `PROXY_BASE_URL`) live in `litellm.env`. Prisma
  migrations run during the gateway's own boot — the first DB-backed boot
  takes longer, the 180s `start_period` covers it; rollback to DB-less =
  remove `DATABASE_URL` from `litellm.env` and redeploy. The admin UI is the
  gateway's own process (same port 4000: `/ui`, callback `/sso/callback`),
  logged in via a Zitadel OIDC application (LiteLLM's generic-OIDC client —
  free for up to 5 SSO users on this version). `general_settings.
  disable_env_credential_login: true` turns off the env-credential login path
  (UI_USERNAME/UI_PASSWORD and the master-key fallback) — UI login is SSO
  plus each DB account's own password; **the master key is API-only from
  then on** and never works in the UI login box. Response caching stays OFF
  (`litellm_settings.cache` unset) — Redis serves the gateway's internal
  state only; do not enable `cache: true` without deciding the trade-off
  deliberately. The image is a thin build over upstream (`docker/litellm/
  Dockerfile` FROMs the multi-arch `ghcr.io/berriai/litellm:main-latest` —
  the versioned `main-v1.x.y` tags are amd64-only; pre-pull the base on the
  host before the first build and re-pull on gateway upgrades).
- **Nothing may start before litellm is SERVING, not merely alive.** The
  gateway binds its port only after app startup completes, and startup
  fetches the provider catalogue (observed ~1–2 min here, during which
  `curl http://litellm:4000/...` is connection-refused). So `compose/
  litellm.compose.yml` healthchecks `/health/liveliness` (the one endpoint
  needing no auth; the image has no curl, so the probe is python), and every
  gateway-calling service — `hermes-main`, `honcho-api`, `honcho-deriver`,
  `firecrawl-api` — depends on it `condition: service_healthy`. Two
  consequences: a container freshly deployed may sit in `created` for that
  boot (correct, not stuck); if litellm never turns healthy, none of those
  services start at all — the ordering is the point, and `start_period`
  (180s) covers the boot needed. Gateway state: `docker inspect <c> --format
  '{{.State.Health.Status}}'`.
- **firecrawl**: the real concurrency knobs are `NUQ_WORKER_COUNT=1`
  (`NUM_WORKERS_PER_QUEUE` only affects the legacy worker),
  `MAX_CONCURRENT_JOBS=2`, `CRAWL_CONCURRENT_REQUESTS=2`,
  `BROWSER_POOL_SIZE=1`; playwright has a memory-only limit (a `cpus` limit
  above the host's core count is unschedulable). **Env var names churn
  between releases** — when bumping `FIRECRAWL_VERSION`, diff `compose/
  firecrawl.compose.yml` against upstream's `docker-compose.yaml` for the
  new tag. Known trap: **`HOST` must stay `0.0.0.0`** (the default
  `localhost` binds IPv6 loopback only — the in-container probe and the
  published port both ECONNREFUSED, restart-looping forever). **The broker
  is LavinMQ, not rabbitmq (since 2026-09-22)** — `compose/lavinmq.
  compose.yml` serves `cloudamqp/lavinmq` under the `firecrawl-rabbitmq`
  alias: drop-in AMQP 0-9-1, idles at tens of MB, guest/guest
  (network-internal, no published ports). A broker cannot simply be dropped:
  NuQ's *scrape* path is optional-AMQP (unset `NUQ_RABBITMQ_URL` → Postgres
  LISTEN/NOTIFY), but the *extract* lane has no fallback — its producer and
  consumer throw without a broker and crash-loop the whole API harness, and
  `/v1/extract` is load-bearing here (SmartScrape). NATS is not an option
  (Firecrawl speaks AMQP; a rewire is upstream work). Missing-broker
  signature: `extract-worker failed with exit code 1` / "Can't accept
  connection due to RAM/CPU load" — restart churn, not real load. The
  upstream `rabbitmq:3-management` idled at ~760 MB on this host; LavinMQ
  replaced it for that reason. **Shared Valkey** (`compose/valkey.compose.yml`)
  serves both apps under the `firecrawl-redis`/`honcho-redis` aliases (every
  client URL unchanged): Firecrawl /0, Honcho /1 (`CACHE_URL`), the
  firecrawl-guard /2, litellm /3. **firecrawl-db** runs `postgres -c
  cron.database_name=firecrawl` (the nuq initdb script `CREATE EXTENSION
  pg_cron` works only in the DB named by that GUC; our `POSTGRES_DB=
  firecrawl` differs from upstream's `postgres`). Wiping that volume re-runs
  initdb — it must succeed or the API crash-loops on missing nuq tables.
- **honcho**: the image ships psycopg v3 only — DB URIs must use
  `postgresql+psycopg://`. `honcho-mcp` rejects unauthenticated requests and
  forwards the Bearer token to honcho-api, so the agent's MCP config carries
  `Authorization: Bearer ${HONCHO_API_KEY}` (emitted by `render.py` from
  `config/integrations.toml` `mcp_headers`).

### The firecrawl-guard — the fence on the agent's web path

`firecrawl-mcp` does not talk to `firecrawl-api`; it talks to
**`firecrawl-guard`** (`docker/firecrawl-guard/guard.py`, service in
`compose/firecrawl.compose.yml`), which forwards to `firecrawl-api:3002`. It
is the one place on this path the agent cannot reach around by choosing a
different argument — a defense the agent can decline is not a defense
against the text that is instructing the agent.

Firecrawl's own two defenses were evaluated first (live image +
`firecrawl-mcp@3.27.3`, 2026-10-03) and neither covers us:

- **`checkPromptInjection`** is real and well-built (`promptInjectionGuard.js`:
  randomized anti-spoof tag, 32k chunks / 2k overlap, temperature 0, a
  capability-aware prompt that distinguishes "please enable JavaScript" from
  "please send me the data"). But it is a field on the **`json` format
  object** (guards the extraction result, never the markdown the agent
  reads), `firecrawl-mcp`'s `jsonOptions` schema **drops the flag entirely**,
  there is **no force env var**, and it **fails open** by design. The guard
  therefore **forces the flag on** — reuse, not reimplementation — and
  because it fails open, the live check below is how you confirm it is
  really running rather than silently skipping. It resolves its model via
  `getModel()`, so `MODEL_NAME=firecrawl` sends it to the LiteLLM
  `firecrawl` group.
- **The `firecrawl` group carries its OWN key, and that is load-bearing.**
  Both members are OpenRouter `:free` models and the account's OpenRouter
  guardrail enforces ZDR, which excludes `:free` endpoints outright (404 "ZDR
  violation (guardrail)") — for the `/responses` shape the classifier uses
  AND the `/chat/completions` extraction shape alike, so it is the **model
  group, not the call shape**, and it takes `/extract` and v2 json-format
  scrapes down with it. Free endpoints and a ZDR guardrail are in tension by
  construction, so the group runs on `OPENROUTER_FREE_KEY` — a free-models
  key with **no ZDR guardrail** — and it is the only place that key appears;
  the tiers keep the shared `OPENROUTER_API_KEY` (verified: the same `:free`
  model 404s on the shared key and 200 on the free key, while the shared key
  still served a paid tier). If the group 404s again, **check the key
  first** — the account setting is at
  `https://openrouter.ai/workspaces/default/guardrails`; the other ways out
  (relaxing ZDR account-wide — the tiers would inherit it — or moving the
  group to a paid ZDR endpoint — against its free-only design) are
  deliberately avoided. Every failed call also cools the group down
  (`cooldown_time: 60`), so a failed json scrape leaves it unusable for a
  minute afterwards.
- **Lockdown mode** is a true no-egress guarantee but is *scrape-only*, and
  self-hosted it is a refuse-everything switch, not a cache mode: with
  `INDEX_DATABASE_URL` unset the engine list is built empty under lockdown,
  so every request throws `SCRAPE_LOCKDOWN_CACHE_MISS`. The shared Valkey
  cannot fix it — `INDEX_CACHE_REDIS_URL` caches index lookups (into a
  Firecrawl index Postgres that does not exist here), not content. A
  cache-backed "lockdown" has to live in the guard; that is what
  `FIRECRAWL_EGRESS=cache-only` is.

What the guard does, in the order the bytes travel:

- **Policy injection** — forces `checkPromptInjection: true` onto every
  `json` format in a scrape (a caller's explicit value is left alone).
- **Egress filter** (fail-CLOSED) — refuses a fetch aimed at the stack's own
  service names or a private/loopback/link-local/metadata address (SSRF into
  `litellm`, `honcho-api`, `firecrawl-db`, `169.254.169.254`), and one whose
  URL or body carries a distinctive credential shape (`sk-`, `ghp_`,
  `github_pat_`, `xox*`, `AKIA`, `AIza`, JWT, PEM, `Bearer`). 403 with a
  readable error naming the rule. **Headers are never scanned** — the
  `Authorization` header is the agent's own Firecrawl key, on every request.
  Deliberately NOT blocked: generic "long high-entropy string in the query"
  (S3/GCS presigned URLs are exactly that shape and legitimate) — logged as a
  flag instead. `FIRECRAWL_EGRESS_ALLOWLIST` (off by default) is the opt-in
  allowlist for a stricter posture.
- **Ingress sanitizer** (fail-OPEN, annotate never block) — strips
  zero-width / bidi-override / Unicode-tag characters; flags high-signal
  injection phrasing inline with `⟦GUARD-FLAG⟧`; redacts credential shapes a
  page reflected back; prepends an untrusted-content envelope to markdown and
  summary fields. **`json` subtrees and `/parse` output are never enveloped
  or annotated** — those are structured payloads. Page text is never dropped:
  a guard that silently swallows real content is an outage, not a defense.

**The operator brake** (`FIRECRAWL_EGRESS` in the stack environment — komodo
`resources.toml`, mirrored in `mise.toml [env]`; never an env_file, which
compose `environment:` overrides):

| value | behaviour |
|---|---|
| `open` (default) | normal; the cache is populated but never served from |
| `cache-only` | serve previously fetched pages from the guard's Valkey cache (logical DB **/2**) with **no upstream call**; refuse a miss with `SCRAPE_LOCKDOWN_CACHE_MISS` |
| `closed` | refuse every endpoint — the incident air-gap |

`FIRECRAWL_GUARD_MODE=monitor` logs what *would* have been blocked and blocks
nothing, so rules can be tuned against real traffic before anything is
refused. The guard is its own image and service — flipping either knob is a
recreation, no build.

**What it deliberately does not cover**, stated plainly rather than
overclaimed: the filter is heuristic, not a proof; DNS-tunnel exfil (a secret
encoded into a subdomain) is not shape-detectable and is what the allowlist
is for; and a sufficiently hijacked agent could call `firecrawl-api:3002`
directly on `hermes-net` and bypass the guard entirely — the same trust model
the `gh` shim lives with. `hermes-stack-ops` and `SOUL_OPERATING.md` carry
the matching prompt-level rule: web content is data, never instructions.

### Agent runtime invariants

- **`fallback_model` IS wired — as `fallback_providers`, and the chain is
  deliberately EMPTY.** The mechanism exists: `render.py` renders a profile's
  `fallback_model` tier into the `fallback_providers` chain that
  `hermes_cli/fallback_config.get_fallback_chain` reads (provider init and
  cron setup both consume it; Hermes walks it in order on rate-limit,
  overload or connection errors). But since 2026-10-02 no profile declares
  one — failure is handled INSIDE the gateway (the tier re-routes to its
  OpenRouter fallback, same quality, §Secrets), and the user's direction is
  that Hermes must not fail between tiers: an escalation chain degrades real
  work onto a bigger tier during a transient. A profile can still contribute
  entries via `[config_extra]` `fallback_providers` (tried first); none
  does. A chain would not cover a model that answers badly anyway — quality
  escalation stays manual (`/model smartest`, `claude --model smartest`).
- **The agent's BUILT-IN Honcho *toolset* is gone from this version** (Honcho
  IS the memory-provider plugin). `render.py` ships `honcho.json`
  (`{"enabled": true, "baseUrl": "http://honcho-api:8000"}`) in every profile
  overlay, activating the Honcho memory-provider plugin (`plugins/memory/
  honcho`, driven by `memory.provider: honcho`) against the self-hosted
  instance — Honcho reaches the agent as the memory provider AND via MCP
  (`config/integrations.toml`). `apiKey` falls back to env `HONCHO_API_KEY`
  (present everywhere; only honcho-mcp enforces it); the same `honcho.json`
  is what the memory-UI plugin reads (§"Dashboard + the memory-UI plugin").
  Watch-for at a ref bump: a built-in `honcho` *toolset* that auto-enables
  from `HONCHO_API_KEY` and fails against the hosted API ("Invalid API key",
  dead `honcho_*` tools) — re-suppress by flipping the rendered `honcho.json`'s
  `enabled` to false, never by removing the credential.
- **Tool search must stay on** (`[config_extra.tools.tool_search] enabled =
  "on"` in profile.toml): honcho+firecrawl MCP ship 66 schemas ≈ 18k tokens —
  without it, every turn pins past the compaction threshold before any
  history exists. tool_search (progressive disclosure) defers MCP schemas
  behind `tool_search`/`tool_describe`/`tool_call` bridges; core built-ins
  never defer. `config/models.toml` states each TIER's TRUE provider window
  explicitly (Hermes' catalogue probe can't resolve ids through the litellm
  base_url and falls back to 256k for everything — verify via `POST ollama.
  com/api/show` → `model_info.*.context_length`, or `mise run
  check-model-windows`). It is the window of whatever backend serves that
  tier, so **it is in lockstep with `config/litellm.yaml`**: repoint a tier
  there and this value moves in the same change. Never set it below the
  provider's: v2026.9.14 hard-rejects under 64K (`MINIMUM_CONTEXT_LENGTH`
  raise in `agent/agent_init.py`); `render.py` fails the build on that, and
  on a tier with no matching `model_name` group on the gateway (the one way
  the indirection fails silently otherwise). Tiers emit into the rendered
  config's **`model_overrides`** block — `agent/model_metadata.
  get_model_context_length` consults it at resolution step 0b, ahead of every
  probe and the 256k fallback. That makes `models.toml` the one source of
  truth for three consumers: the profile's own model
  (`model.context_length`), the cheap lane / aux models / any `/model`
  switch (`model_overrides`), and the `claude` wrapper's
  `CLAUDE_CODE_MAX_CONTEXT_TOKENS`. Declare a TIER there before using it — an
  undeclared window is not guessed.
- **Context compaction is a PERCENTAGE of the window, set to use it**
  (`STACK_COMPRESSION_DEFAULTS` in render.py, merged into every profile,
  overridable via `[config_extra.compression]`): `threshold: 0.80`,
  `threshold_tokens: null`, `target_ratio: 0.50`. Upstream's absolute
  `256000` cap bound this stack to a ~256K trigger even on 1M tiers (every
  long session sat in a ~50K-256K band — the agent's own reasoning folded
  into a ~20% summary a quarter of the way into the window). With
  `threshold_tokens: null` (the documented ratio-only opt-out) the trigger is
  `threshold` × the model's OWN window (`agent/context_compressor.py`
  `_compute_threshold_tokens`) — one percentage meaning the same thing on
  every tier: ~800K on 1M, ~205K on the planner's 256K. `render.py` fails the
  build on a `threshold` outside (0, 1), a `target_ratio` outside [0.10,
  0.80], or a non-positive `threshold_tokens`. **The cost is real and is the
  point**: a long turn processes up to 80% of the window — a deliberate
  tokens-for-retention trade; dial the percentages back if spend matters
  more than continuity.
- **Multiplexing boot noise is benign**: with `GATEWAY_MULTIPLEX_PROFILES`
  on, the tool registry's check_fns probe at gateway boot before any profile
  secret scope exists and fail closed with `UnscopedSecretError` — three
  WARNING tracebacks (discord tool / homeassistant / web_api) per start, log
  noise only. Real turns run scoped and re-probe. Worry only if the warning
  appears on a turn AFTER startup — that would be a genuine lost-scope case.
- **render.py stamps `_config_version`** into every rendered config.yaml,
  derived at build time from the base image's `DEFAULT_CONFIG` (render runs
  under the image venv, so `hermes_cli` imports there). Without it, the
  Docker boot-time migration warns "predates version 12" on every boot; the
  resolver's read-time behavior (legacy `custom_providers` list form) is
  unchanged.
- **Volume ownership is self-healed by the entrypoint** (`chown -R` to the
  runtime UID before its first privilege drop) — upstream's stage2 chown only
  runs after the wrapper's exec, so an unwritable volume would kill the
  wrapper first. Don't remove that chown.

### Auxiliary side tasks (which model each side task actually runs on)

Hermes routes its side tasks — compression, title generation, vision,
memory-query rewrite, smart approval, MCP sampling, a per-feature tail —
through one resolver, and **the model for a task is a field on the task in
config.yaml**: `auxiliary.<task>.{provider, model}`, read by
`auxiliary_client._get_auxiliary_task_config` / `_resolve_task_provider_model`
(priority: explicit call args > that config > `auto`). **`auto` means "my
main model for side tasks too"** — an unpinned lane rides the profile's
primary (the reviewer's is the top tier).

**The env-var pins this repo once documented do not exist.** Until 2026-10-04
`hermes-main.env` carried four `AUXILIARY_*_MODEL` pins the docs asserted
were real; the image reads **none** of them — the only aux names it consults
in the environment are `AUXILIARY_VISION_*`, `AUXILIARY_VIDEO_MODEL`,
`AUXILIARY_APPROVAL_*` — and two of the four named tasks that don't exist
(`session_search`, `web_extract` are tools, not aux LLM lanes). Measured
live: exporting all four changed nothing, `session_model_usage` was 100%
`smarter` for a week. Keep the two mechanisms straight: a wrong env pin fails
silently, the rendered config is validated at build time — and neither
mechanism grows back in `hermes-main.env`.

Routing is declared once, in `render.py`'s **`STACK_AUX_MODELS`** (task →
tier alias), rendered into every profile's `auxiliary` block as
`{provider, model}` — the same shape `smart_model_routing.cheap_model` uses,
so base_url/key ride the `custom_providers` entry and no profile repeats an
id. A profile may override a single task via `[config_extra.auxiliary.<task>]`
(a bare tier name, or a table merged over the declared block — `{model =
"cheap"}` alone is valid). `render.py` fails the build on: a task key not in
`KNOWN_AUX_TASKS` (Hermes ignores unknown keys — a typo'd knob does nothing),
a lane pointed at a non-tier, and a compression lane whose declared window
is smaller than the profile primary's (checked on the merged block, so no
profile override walks past it — compaction summarises up to 80% of the
primary's window).

Current pins, and why only these: **compression → `smarter`** (needs
intelligence AND a window ≥ the profile's own), **title_generation →
`cheap`** (one call per fresh session, a handful of tokens), **memory_query_rewrite
→ `cheap`** (mechanical, 8s timeout; idle — the Honcho memory provider runs
`query_rewrite` off). Deliberately NOT pinned, so they inherit the primary —
the safe default, free while unused: **vision** (must land on an
image-capable model; `smartest` has none), **mcp** (sampling is arbitrary
server-directed generation), **approval** (timeout only; `approvals.mode` is
`off`), **skills_hub** (no call site in this image), and the unwired tail
(`curator`, `monitor`, `goal_judge`, `triage_specifier`, `kanban_*`,
`profile_describer`, `tts_audio_tags`, `moa_*`, `review`/`background_review`
— the last disabled). Re-check the aux task set at each HERMES_REF bump:
`python3 -c "from hermes_cli.config_defaults import DEFAULT_CONFIG;
print(sorted(DEFAULT_CONFIG['auxiliary']))"` under the image venv. The live
check against the deployed config is in the `hermes-ops-runbook` skill's
verification checklist.

### Honcho memory (what recall actually does)

Honcho's behaviour splits across two surfaces that are easy to confuse: the
**Honcho-side lanes** (which model derives/summarises/answers —
`secrets/honcho.env`) and the **plugin side** (when recall fires, how long it
waits, how much it injects — each profile's `honcho.json`, rendered by
render.py). Two independent defects were making recall look broken
(measured 2026-10-04 from the live plugin source, `honcho-db`, and 504
stored-turn blocks):

**1. The deriver could not produce JSON, so there was almost nothing to
recall.** The deriver asks for typed extraction (`response_model=
PromptRepresentation, json_mode=True`) and **every Ollama-backed lane on this
gateway ignores `response_format: json_schema`** (measured: `cheap`
truncates, `smart` returns markdown-fenced prose — the schema changes
nothing). Honcho's pydantic parse rejects, retries 3×, parks the job. The
evidence: 70 errored `representation` queue rows (65 `ValidationError: Invalid
JSON … PromptRepresentation`), 28 `explicit`-only documents covering ~2.7% of
messages, zero deductive/inductive ever. Fix = Honcho's own mode for
json_schema-less providers:
`DERIVER_MODEL_CONFIG__STRUCTURED_OUTPUT_MODE=json_object` (schema injected
into the prompt, result repaired downstream; verified by replaying the
deriver's exact call: 0 facts → 3 correct facts, same `cheap` tier, no extra
spend). The `DREAM_*` lanes deliberately carry nothing: they call with
`tools=` and no `response_model` (`src/dreamer/specialists.py`), so the mode
does not apply — and they have never run here, needing the ≥50 documents the
broken deriver never produced. **Watch them the first time they fire.**

**2. The plugin threw away recall it had already paid for.** A real dialectic
call takes **90–270 s**; the plugin's HTTP timeout defaulted to **30 s** and
`session_context.py` caught the timeout and **returned `""`** — 90 such
WARNINGs in `agent.log` — while each failure also widened the empty-streak
backoff (up to 8× the cadence), so recall decayed toward never firing. The
rendered `honcho.json` now carries: `timeout: 120` (injection is
asynchronous — a longer ceiling costs no turn latency);
`dialecticReasoningLevel` / `reasoningLevelCap: minimal` (auto-injection is
capped at `dialecticMaxChars: 1200`, so buying a 90–210 s 5-round `low` loop
every turn only feeds the cap; an explicit `honcho_reasoning` tool call
still picks its own level and returns in full); `logging: true` — the
per-turn injection audit at `~/.honcho/injection.log` records reason and
payload, and is the only way to answer "is recall working?" from data rather
than inference (it was off, which is why all of this had to be reconstructed
from the database).

**3. Three of five profiles had no memory at all — by identity, not
failure.** With no declared `peerName` the peer is whatever the transport
supplies: a Discord message carries one, a **cron / Bot-Chat / CLI turn
carries none**, and on those the plugin raises `HonchoPeerUnresolvedError`,
injects "Honcho memory is off for this session", and stores nothing. The
team profiles are cron-driven: **327 of the 504 blocks ever injected were
that notice** (release 274/274, reviewer 48/48, developer 163/168);
`honcho_release` as a workspace did not even exist. Every profile now
renders `peerName` + `pinUserPeer: true` — correct here because the stack is
single-user behind `DISCORD_ALLOWED_USERS` (pinning is warned against only
on a *shared* gateway) — which also unblocks the `MEMORY.md`/`USER.md` →
Honcho seeding the plugin skips while no owner peer is declared. **The value
is an identifier and does not belong in this public repo**: it travels the
`BOOT_PLACEHOLDERS` path as `@@HONCHO_USER_PEER@@`, resolved at boot from
`HONCHO_USER_PEER` in `/etc/hermes/hermes-main.env` (unset → `""` → the old
transport-identity behaviour, reported on stderr). Set it to the peer id the
transport already supplies (your Discord user id), **not** a friendly name —
a different string is a different peer, and the two memories split.

**4. Derivation is BATCHED, so memory legitimately lags.** The deriver claims
a representation work unit only once it holds
`REPRESENTATION_BATCH_WORK_UNIT_TARGET_TOKENS` (512) or its oldest item is
older than `REPRESENTATION_BATCH_MAX_AGE_SECONDS` (**1800 s**), unless
`FLUSH_ENABLED` (`queue_manager.get_and_claim_work_units`). A quiet chat
becomes memory up to ~30 min later; a lone test message sits unprocessed —
not a stall. `pending_items` on the deriver's metrics endpoint is the honest
measure. Do not "fix" it by lowering the batch size without weighing the
deriver call each batch triggers (measured: 45 s, 2 facts).

The checks — plugin status/peer, the `injection.log` audit, the deriver
queue with expected counts, one timed live recall — live in the
**hermes-ops-runbook** skill (`.claude/skills/hermes-ops-runbook/SKILL.md`),
alongside the full post-deploy verification checklist. The deriver's queue
is the one that was silently broken (70 errored representation rows).

### Discord

Enabled by the mere presence of `DISCORD_BOT_TOKEN` in the env
(`gateway/config.py::_apply_env_overrides` — config.yaml carries no platform
state, so the render's `platforms` list only documents/env-examples the
vars). The bot MUST have "Message Content Intent" AND "Server Members
Intent" toggled in the developer portal — the adapter requests both and
discord.py refuses to connect without them. `DISCORD_ALLOWED_USERS`
(comma-separated user IDs; usernames resolve via the Members intent) gates
who the bot answers; empty = anyone who mentions it.
`DISCORD_REQUIRE_MENTION` defaults true. The entrypoint syncs the mounted
env file into `$HERMES_HOME/.env` on every boot (the runtime user can't read
the root-owned host mount) and loads that volume copy with `override=True` —
the mounted file is the source of truth; runtime writes to `$HERMES_HOME/.env`
last only until the next container restart.

- **Team channels go in the NESTED `[config_extra.platforms.discord.extra]`
  block, never the top-level `discord:` form — the nesting is load-bearing.**
  The public top-level form is translated by the plugin hook (`adapter.py`
  `_apply_yaml_config`) into process-global `os.environ`, first-writer-wins,
  and all five profiles share ONE gateway process under
  `GATEWAY_MULTIPLEX_PROFILES` — a public-form write leaks to any profile
  that doesn't set the same key itself. The whole mention/threading family
  behaves this way (`require_mention`, `thread_require_mention`,
  `bots_require_inline_mention`, `auto_thread`, `reactions`,
  `history_backfill[_limit]` — env-bridged without the `_skip_env_bridge`
  guard #72348 added for the channel/allow gates); the nested key reaches
  `PlatformConfig.extra`, which `_discord_require_mention` reads FIRST.
- Each team profile sets, in that nested block, `allowed_channels =
  ["<its channel id>"]` + `require_mention = false` — its bot answers every
  message in its own channel with no @mention, and nowhere else. Release →
  `#releases` (`DISCORD_CHANNEL_RELEASE`); the default profile → `#hermes` +
  `#hermes-home` (the unrouted channels; ids from `DISCORD_CHANNEL_MAIN`
  and `DISCORD_HOME_CHANNEL`). `allowed_channels` is load-bearing
  (require_mention is profile-wide) and does NOT widen authorization —
  `DISCORD_ALLOWED_USERS` stays the gate; `_is_allowed_user` falls back to
  channel-scoped access only when no user/role allowlist exists.
- Deliberately NOT `free_response_channels`: that also makes upstream skip
  auto-threading (`skip_thread = ... or is_free_channel`), killing the
  thread-per-request the team workflow relies on. `require_mention = false`
  skips only the mention gate.
- **Threads** work: the adapter auto-threads (`DISCORD_AUTO_THREAD`, default
  true) and the reply follows into the thread. An agent-opened thread is the
  deferred `discord` tool's `create_thread` action (`tool_search` →
  `tool_call`); agents get no send-message tool, so posting into a thread
  outside the auto-thread flow is `hermes send --to discord:<channel>:<thread>`.
  Creating one needs CREATE_PUBLIC_THREADS + SEND_MESSAGES_IN_THREADS *in
  that channel*: a channel overwrite beats the guild-level grant, so the
  invite integer carrying those bits (`scripts/set-team-discord-tokens.py`)
  is necessary but not sufficient. Diagnose with `python3
  scripts/discord-thread-doctor.py`.
- Scripting the Discord REST API from the container: bare `urllib`
  User-Agents get Cloudflare-blocked with `error 1010` (set a real UA
  string), and bot DMs fail with 403/code 50278 "no mutual guilds" when the
  recipient's server-DM privacy setting blocks server members — @mention in
  a server channel pings them instead.
- **Each team profile runs its own Discord bot**
  (`PROFILE_<NAME>_DISCORD_BOT_TOKEN`); a profile left on the main token is
  refused by the gateway ("same credential — refusing to start the
  duplicate") and stays dormant.

### GitHub access

Skills-based, not an integration: the agent's `github-*` skills drive `gh`
CLI + git, and the image installs gh (pinned tarball — rebuild required to
bump). Both modes are env-driven from hermes-main.env; the entrypoint
re-runs the config on every start and sets a default commit identity from
`GH_GIT_NAME`/`GH_GIT_EMAIL`. **Every profile holds TWO credential sets: the
personal App, and one org-owned App PER ORG it serves (any number of orgs),
routed by repo owner.**

- **GitHub App (preferred)**: `GITHUB_APP_ID` + `GITHUB_APP_INSTALLATION_ID`
  are the only GitHub vars (PEM at `/etc/hermes/github-app-<profile>.pem` —
  root:<host-group> 640, bind-mounted read-only at `/run/hermes-pem/`, the
  file must exist before deploy). Every profile has its own app. The
  entrypoint copies the PEM into the runtime-owned tool-home
  (`$HERMES_HOME/home/`) and exports `GITHUB_APP_PRIVATE_KEY_PATH` itself —
  the env file never names the path, because s6 services can't read the host
  mount. Installation tokens last 1h, so git's credential helper routes
  through gh's stored token (`gh auth git-credential`) and a background
  refresher re-runs `gh auth login --with-token` every 30 min. skills_hub
  has native app support too (priority PAT → gh → app).
- **Org Apps**: `GITHUB_APP_ID_<ORG>` / `PROFILE_<NAME>_GITHUB_APP_ID_<ORG>`
  (plus `_INSTALLATION_ID_`, `_GH_GIT_NAME_`, `_GH_GIT_EMAIL_` org-suffixed
  variants) declare the org set; PEMs install as
  `/etc/hermes/github-app-<orgslug>-<profile>.pem` (no compose change — the
  whole env dir is mounted at `/run/hermes-pem`). The entrypoint syncs each
  tool-home's NON-secret descriptor `<tool_home>/org-creds/<orgslug>.env` +
  PEM copy (one per org, discovered from the env vars themselves — any
  number of orgs, no per-org code) — helpers read FILES, not env, because
  Hermes strips credential env vars from tool subprocesses
  (GHSA-rhgp-j443-p4rf). Org token minting is lazy + cached (`gh-org-token`,
  ~45-min cache in `org-creds/<slug>.token`); a boot mint per org per
  profile fails loudly. An org with ids but no installation id or no PEM is
  skipped with a boot warning.
- **Routing: `/usr/local/bin/gh` is a SHIM** (real binary `gh-real`) that
  picks the org token when it can resolve the invocation's target owner to
  one with a descriptor, from three sources in order: a `-R`/`--repo`
  argument (every spelling gh accepts), a `gh api` ENDPOINT PATH
  (`repos/<owner>/…`, `orgs/<owner>` — `gh api` takes no `-R`, so from a
  scratch dir the path is the only signal), or the cwd's git origin.
  `gh auth *` and `GH_TOKEN`-set calls always pass through. **A 403 "Resource
  not accessible by integration" on an org repo means the PERSONAL token
  went out — not that a permission is missing** (the personal App has no
  installation on the org, while its public-repo reads still succeed, so the
  write 403s and a public-repo probe "confirms" a gap that is not there).
  The granted set is only readable with a USER token (`gh api
  /orgs/<org>/installations`; the App's own token 404s regardless). Offline
  coverage: `scripts/test-gh-shim.sh` stubs `gh-real` via the shim's
  `GH_REAL` seam (`mise run test`).
- **git credential routing**: git's single helper is
  `git-credential-hermes.sh` (`credential.https://github.com.helper` +
  `useHttpPath=true`): org remote → org token; otherwise it replays the
  request into `gh auth git-credential` (personal). useHttpPath=true is
  load-bearing — without it git sends no path and the router cannot see the
  owner (per-URL credential keys were rejected: git's urlmatch path compare
  is case-sensitive, GitHub owners are case-insensitive).
- **The shim's LABEL GATE** (before exec'ing gh-real, and ABOVE the
  `GH_TOKEN` passthrough — a preset token, e.g. a queue script's forced call
  or a `gh-org-token` mint, cannot route around it): a `gh issue edit|create`
  that SETs a `review/*` label, or a `gh pr edit|create` that SETs a
  `status/*` label, is refused — stderr + exit 1, gh-real never runs,
  naming the undo (`--remove-label`) and the correct shape. This is the
  label families' object rule (§"Routing work to a profile") enforced at the
  one hop every credentialed call passes through. Every label flag spelling
  (incl. `-l`, comma lists); `type/*` is legal on both objects; `--remove-label`
  is never gated (the undo of a misfile is itself a wrong-family remove);
  hard block, never auto-correct (the shim cannot know which PR closes which
  issue). For the **reviewer profile** it additionally refuses every
  `gh issue edit|close|reopen` (card moves route to planner via
  `@hermes-planner`; comments stay open). It fails OPEN for every profile
  that is not the reviewer: the family gate is object-kind-based and applies
  everywhere regardless. `gh api` label writes are the declared NON-gate
  (the endpoint scanner cannot know which argv members are flag values) —
  the queues' `!! FOREIGN LABEL` guard stays the net for the REST spelling.
  Covered offline in `scripts/test-gh-shim.sh`.
- **The shim's BODY GATE** — inline `--body`/`-b` on `gh issue|pr create|edit`
  is refused, in every flag spelling, for every profile (shape-based, not
  role-based), above the `GH_TOKEN` passthrough. A quoted multi-line
  `--body` is a SHELL argument: the shell expands it before gh runs — a
  backtick code span becomes command substitution and the body arrives as
  that command's stdout. Observed: five issue bodies corrupted because the
  shipped `mach` binary is on PATH (a fleet table landed where the word
  `mach` belonged; `systemctl`, `.deb`, `MACH_STATE_DIR` substituted empty,
  leaving blanks mid-sentence), plus a second layer through a Python
  `"""…"""` literal (`$\rightarrow$` → `\r`). The shim cannot detect that
  damage — by gate time the substitution has happened — so it refuses the
  SHAPE and names `--body-file`, which cannot be got wrong. Deliberately NOT
  gated: `gh issue|pr comment --body` (a one-line comment is legitimately
  inline) and `gh api -f body=…` (the shell does not re-scan an expansion).
  An already-corrupted body is repaired by re-reading it, not merely
  avoided. (`scripts/test-gh-shim.sh`, `R3 …`; the planner's authoring and
  the release skill's failure-filing moved to `--body-file` in the same
  change.)
- **The shim's CI GATE** — a write that ASSERTS a verdict on a PR is refused
  while a check is red or still running: `gh pr edit <PR#> --add-label
  review/ready` (the handoff), `--add-label review/approved`, the
  `gh pr review <PR#> --approve` that IS the GitHub approval, and
  `gh pr merge`. It is the one gate making a network call (`pr checks --json
  bucket`; no jq dependency), which is why owner resolution sits ABOVE the
  `GH_TOKEN` passthrough — a preset token is the documented way to force an
  org token, so a gate below that line would fence nothing. It **fails
  open**, deliberately: only a positively observed red/running check
  refuses — "no checks reported", an unknown bucket, an API error or an
  unparseable answer pass, because a gate that blocks on "I could not tell"
  reads as a permission problem. A **rejection is never gated** (`review/changes`,
  `--request-changes`, the `review/ready` → `review/in-progress` claim swap)
  — a red PR must always be sendable back. The half no gate can do is the
  waiting, so the skills carry it: `gh pr checks <PR#> --watch` before
  handoff, a checks read before the verdict, and a green local run
  explicitly overridden by a red CI (the disagreement is the finding).
  Pinned by `scripts/test-gh-shim.sh` (`R4 …`) + `scripts/test-team-labels.sh`
  §2c. `mergeStateStatus` is NOT a CI read — a ruleset without status-check
  requirements leaves a red job in no field of it; key on `gh pr checks`.
- **Commit identity**: org worktrees commit as the org bot — `git-repo.sh
  worktree` sets `user.name`/`user.email` in the worktree's own
  `config.worktree` (needs `extensions.worktreeConfig`, enabled idempotently;
  without it the set would land in the bare repo's common config and leak
  across sessions).
- **PAT fallback**: `GH_TOKEN` authenticates gh natively; git routes through
  `gh auth git-credential`. Prefer a fine-grained PAT scoped to the specific
  repos (Contents/Issues/Pull requests read+write).

### Contribution requirements (DCO) — the gate a test run cannot see

A target repo can require the **Developer Certificate of Origin**: a
`Signed-off-by:` line per commit matching its author or committer, checked
by a CI job. The failure that shape invites is invisible locally — the rule
lives in `CONTRIBUTING.md` and `.github/workflows/`, files the developer has
no reason to open while implementing, nothing mechanical added the trailer,
and a policy job is the one gate a local `mise run test` cannot reproduce
(the observed result: a PR green on lint/test/e2e, failing only sign-off).
Compliance has two halves, and the read alone is what failed before:

1. **The read.** `team-developer` reads the target repo's own rules —
   `AGENTS.md`/`CLAUDE.md` PLUS the contribution requirements
   (`CONTRIBUTING.md`, `LICENSE`, the jobs in `.github/workflows/`) — as
   soon as the worktree exists and before implementing anything, treats them
   as binding, and reads `gh pr checks` for **every** job, not only the ones
   a local run mirrors.
2. **The hook.** `docker/hermes/git-hooks/prepare-commit-msg` (baked at
   `/opt/hermes-git-hooks/`, chmod 0755), installed by the entrypoint as
   each tool-home's **global `core.hooksPath`** — the only scope reaching
   every runtime-cloned repo AND every worktree (worktrees share their
   common dir's hooks, so a per-repo install could not cover one).

The hook is deliberately **conditional**: it adds a sign-off only when the
repo carries DCO evidence (`Signed-off-by` / "Developer Certificate of
Origin" in a `CONTRIBUTING*` file or anywhere under `.github/`), so repos
that never asked keep byte-identical messages. Identity resolves through
`git var GIT_COMMITTER_IDENT` at commit time — the org bot in an org
worktree, the profile's own App elsewhere, nothing hardcoded. Skips merge
commits (exempt from the checks it mirrors) and any message already carrying
a sign-off (idempotent). **Every path exits 0** — a hook that aborts a
commit to protect a trailer would be a worse bug than the missing trailer,
and CI is the real enforcement. Three give-ups, stated plainly: a set
`core.hooksPath` bypasses a repo's own `.git/hooks` (not cloned, normally
empty anyway); `--no-verify` skips it; detection is in-repo only, so DCO
enforced purely by branch protection or an outside app is invisible — that
is what the documented read is for.

### The pre-push hook — the developer's publish path is git-publish.py, never git push

The same `core.hooksPath` install carries `docker/hermes/git-hooks/pre-push`,
which **refuses a `git push` to any GitHub remote from every profile's
tool-home**. Reason (compressed from a four-review-round incident): pushes
are unsigned forever from a bot identity, each push eventually became a full
branch rewrite (a forced `git-publish.py` replay), each rewrite dismissed
every standing approval, and the human re-approved byte-identical content.
The refusal (stderr + exit 1, gh-real never run) names `git-publish.py` and
the one escape, `HERMES_ALLOW_PUSH=1`; it applies to every github.com URL
spelling and passes non-GitHub remotes through. Its philosophy is
deliberately NOT the DCO hook's never-fail one: a pushed branch has no
in-place repair, so refusing at the moment of misuse is the lesser cost.
`--no-verify` skips it like any hook; `git-publish.py` is unaffected (it
publishes through the git-data API, not a push). Both hooks are pinned
offline by `scripts/test-git-hooks.sh` (`mise run test`), including the
real-commits DCO cases whose live probes are in the `hermes-ops-runbook`
skill.

### The merge gates a green CI cannot see (signed commits, resolved threads)

A ruleset can gate a merge on conditions **no workflow job reports**: a PR
can be green on every check, approved by reviewer and user, and still sit
`mergeStateStatus: BLOCKED` (the observed one, four review rounds, with
dco/lint/test/e2e passing). The read that catches it is `gh pr view <PR#>
--json mergeable,mergeStateStatus` — `BLOCKED` with everything green means a
rule, not a test, and a `BLOCKED` PR looks exactly like a quiet queue from
every other angle. These gates are release's to clear — the release lane
reads them back before emitting a merge (§"Routing work to a profile"); the
reviewer's job ends at the verdict plus a statement of what it left unmet.

- **`required_code_owner_review` — the human gate, the only thing that
  releases a PR.** A real GitHub approval from a login in the repo's
  `CODEOWNERS` — not the reviewer's `review/approved` label (which arrives
  hours earlier), not a comment, not a relayed Discord message. This is why
  `team-onboarding` REQUIRES the rule per repo: without it nothing makes a
  PR's approval a human owner's, and the release lane's own CODEOWNERS check
  is only an approximation of a ruleset. App tokens cannot set branch
  protection or rulesets (owner-only) — expect it to land as a user
  checklist item, loudly, never silently.
- **`required_signatures` — and why the developer can never `git push` past
  it.** Requirements are evaluated at merge time, on the commits the test
  merge introduces, so unsigned head-branch commits block a squash merge
  even though GitHub would sign the final squash commit (docs say so
  explicitly; a squash-only repo does not escape it). A GitHub App cannot
  satisfy this by pushing: a bot user has no account settings, so no GPG/SSH
  key can be registered, and the only commit GitHub verifies for an App is
  one it creates itself through the API with no author, committer or
  signature field (the observed PR's four commits were `verified=false,
  reason=unsigned` — unfixable by pushing harder). Publish path: **`git-publish.py`**
  (`docker/hermes/`) replays the branch's local commits as API-created ones
  — blobs → trees → commits → ref — preserving every message, diff, file
  mode (100755), symlink and delete, and re-pointing each `Signed-off-by:`
  at the identity GitHub actually stamps. Nothing moves until proven: the
  ref updates only after the App identity is read back from the first
  created commit (a disagreement re-creates the chain once, cached) and the
  commit reports `verified`. Verified-from-first-commit is not cosmetic: the
  DCO hook's trailer names the WORKTREE's git config, which can be a
  different bot from the token a push would route through (a kept
  cross-App trailer fails DCO *while being signed* — the observed bug). An
  existing branch of unsigned commits is **repaired, not re-committed**:
  `git-publish.py --replay-from origin/main --force` (a rewrite — same
  re-approval cost as any force-push). The publish path is now also
  mechanically the only one: the pre-push hook refuses bot pushes outright.
- **`required_review_thread_resolution`.** Resolving a finding's thread is
  part of fixing it, and belongs to the developer — in the same turn it
  publishes the fix, with a reply saying what changed. The reviewer opens
  threads and re-reads them; it never resolves the developer's work for it.
  The one thread that is the reviewer's own is a finding raised **with its
  own approving verdict** (a nit it chooses not to block on): the developer
  never gets another turn for that, so the reviewer puts it in the summary
  comment or resolves it as it raises it — a nit left open beside an
  approval is a merge gate nobody can clear.

Two App capabilities carry both halves, neither needs a code change to
grant: creating commit objects is `contents: write` (every team App has
it), and a thread mutation is accepted from an App that did NOT open the
thread as long as it can write to the repo (verified 2026-09-26 — nine of
the reviewer's threads resolved with the developer's ORG installation
token). Routing trap: a `graphql` endpoint names no owner, so the shim
cannot route it and the PERSONAL token goes out — the personal App has no
org installation, and the mutation fails in a way that reads exactly like a
missing permission. Force it: `GH_TOKEN="$(gh-org-token <orgslug>)" gh api
graphql …`. Both halves are pinned offline by `scripts/test-git-publish.sh`
(`mise run test`; no Docker, no network): a stubbed `gh` implements the
git-data API against a REAL bare repo, checking tree identity against the
worktree, preserved modes and symlink, the delete, the re-pointed trailer
AND the commit that must not acquire one, the identity correction and its
cache, and every refusal (default branch, merge commit, unforced rewrite)
with nothing published — failing the run if any commit payload carries
author/committer/signature (the omission is what makes commits verifiable)
or if a skill tells an agent to `git push`.

### Security tuning (guard friction)

This stack's agents live in `terminal`, and three guard behaviours blocked
the script-shaped work we *want* them to do, so all three were loosened
deliberately.

1. **`tools/approval_detection.py` source patch** (was `tools/approval.py`
   before v2026.9.14) — `docker/hermes/patches/`, applied in the Dockerfile
   with `git apply` (the base image has no `patch` binary; `git apply` works
   outside a repo, which matters because `.dockerignore` drops `.git`).
   Upstream hardline-blocks any command whose grep-operand scanner surfaces
   a word it cannot tokenize — which happens whenever `grep` appears inside
   a quoted `$(...)` (the common `sed -n "$(grep -n 'x' f | cut -d: -f1),+45p" f`
   shape). The block is unconditional (no `--yolo`, approval mode, or
   `command_allowlist` reaches it) and was the single largest source of
   blocked calls, every one a false positive. The patch skips an
   unparseable operand instead of failing the whole command, fail-closed
   (skipping only declines to mask text as data, which the hardline path
   discards anyway). Deleting it later is signalled by the build (§"Bumping
   HERMES_REF").
2. **Tirith pre-approvals, config only — Tirith itself stays ON.**
   `render.py` seeds `command_allowlist` with `tirith:<rule_id>` keys for
   every profile; `approval_detection.py` loads that list at module import,
   and a Tirith finding's approval key is `tirith:<rule_id>`, so listing a
   key permanently auto-approves that one rule. The twelve seeded rules are
   the ones that actually fired on this stack's legitimate work (mined from
   `tirith audit stats --format json` → `top_rules`, Sep 2026):
   `analysis_incomplete` (the `$(...)` / dynamic-command shape),
   `plain_http_to_sink` (internal HTTP services), `mass_file_deletion`
   (worktree/build churn — the most aggressive inclusion and the first to
   drop if the ransomware-shaped burst check is wanted back; the
   unconditional hardline floor still blocks `rm -rf /` either way),
   `curl_pipe_shell`, `pipe_to_interpreter`, `blast_find_delete`,
   `trailing_dot_whitespace` + `schemeless_to_sink` (cosmetic findings on
   benign compound commands like `cd /opt/data/mach && go build ./...`),
   `data_exfiltration` (the komodo-ops skill's internal-API POST shape),
   `interpreter_suspicious_inline_exec` (`python -c`), `lookalike_tld`
   (go.dev), `archive_extract`. Deliberately NOT seeded:
   `credential_file_sweep`, `sensitive_env_export` (credential reads /
   secret exports stay gated), and hermes' own recursive-delete pattern (an
   rm -rf prompt with an "Always" option is click-once-per-host). Extend the
   list by hand from the audit stats, never wholesale.
   `render.py` also raises `auxiliary.approval.timeout` to 60s stack-wide
   (upstream 30s, retried once): smart approval's aux call goes through
   litellm → Ollama Cloud, and when it times out twice the gate escalates to
   a human button even though the model would have approved — the model's
   latency, not its verdict, was deciding. Inert while `mode: off`; kept as
   the value to restore if the posture is dialled back.
3. **The unattended lanes are opened right up** (`render.py` →
   `STACK_APPROVAL_DEFAULTS`, merged into every profile, overridable via
   `[config_extra.approvals]`). Upstream's defaults for the unattended lanes
   are `deny`, and upstream's own comment on `single_query_mode` names the
   failure: an unanswered approval "waits the full timeout then fails
   closed, so the agent is forced to work around the block (often via
   `execute_code`)" — observed live: the developer's cron lane (in `-q`)
   hard-blocked heredoc execution, `SQL DELETE without WHERE`, Tirith HIGH
   findings, and the agent fell back to `execute_code` 102 times in one
   33-minute turn. So: `mode: off` (= `--yolo`) plus `cron_mode` /
   `single_query_mode` / `unattended_mode: approve`, with `approvals.deny`
   holding only the permanently-destructive set — root/home recursive
   deletes, `--no-preserve-root`, block-device writes, force-push, docker
   volume/stack deletion. **What this gives up, stated plainly:** Tirith
   still scans and logs, but with `mode: off` a finding gates nothing —
   `command_allowlist` is belt-and-braces, not the control. Credential
   *reads* stay permitted on purpose (this file's own checklist reads
   `/etc/hermes/litellm.env`). The deny list is deliberately TIGHT: the
   stack's own jobs delete things (mktemp dirs, pruned worktree session
   dirs under `/opt/data/worktrees`), and a blanket `*rm -rf*` would break
   `prune-repos.sh` and teach the next operator to delete the list. Dial
   back with `mode: smart` (re-arms the guardian for HIGH/CRITICAL).
   `render.py` fails the build on a `mode`/`*_mode` value the container
   would reject, and on an empty `deny` entry (an empty glob blocks nothing
   while looking like a guard).

### Dashboard + the memory-UI plugin (both shipped DISABLED)

The official image already carries a web dashboard as an s6 service
(`docker/s6-rc.d/dashboard/{run,finish}`) and a plugin system. Both are
deployed here but OFF; flipping either on is a config/env change with no
rebuild. The dashboard is PRIVILEGED — it edits `.env`, serves config and
session APIs, and can restart the gateway — which is why the plumbing is
shipped but the defaults are inert.

- **Enablement contract.** `HERMES_DASHBOARD=1` in the container
  environment is the only gate (no config.yaml enable key); bind is
  `HERMES_DASHBOARD_HOST=0.0.0.0` in-container (needed for publishing) and
  the port publishes as `127.0.0.1:${HERMES_DASHBOARD_HOST_PORT:-9119}:9119`
  — host loopback only. The real boundary is upstream's fail-closed auth
  gate (a non-loopback bind REQUIRES an auth provider;
  `HERMES_DASHBOARD_INSECURE=1` is accepted but ignored) plus the loopback
  publish. **The flag lives ONLY in the stack environment** (komodo
  `resources.toml`, mirroring mise.toml [env] locally): compose
  `environment:` overrides env_file, so setting `HERMES_DASHBOARD` in
  `hermes-main.env` is a dead value — the #1 operator mistake here. The
  host-side port var is deliberately `HERMES_DASHBOARD_HOST_PORT`, NOT
  `HERMES_DASHBOARD_PORT` — the upstream name is the CONTAINER-side listen
  port and would break the mapping.
- **Auth.** Basic auth (`HERMES_DASHBOARD_BASIC_AUTH_USERNAME/_PASSWORD/
  _SECRET` in `/etc/hermes/hermes-main.env`; templates and generation
  commands in `secrets/hermes-main.env.example`) with an optional OIDC
  block. **Flipping the flag on without the three basic-auth vars fails
  closed**: `start_server` errors at startup and the dashboard s6 slot
  restart-loops (repeated `[dashboard]` startup errors in `docker logs
  hermes-main`; the rest of the container is unaffected). Set credentials
  BEFORE flipping the flag.
- **The no-rebuild flip procedure**: (1) fill the three auth vars in
  `/etc/hermes/hermes-main.env`; (2) set `HERMES_DASHBOARD = "1"` in
  komodo/resources.toml (locally: mise.toml [env]); (3) Resource Sync +
  DeployStack — image unchanged, recreation only; (4) verify (the
  `hermes-ops-runbook` skill's checklist). Reverse = set back to `"0"`.
- **The memory-UI plugin is vendored, seeded, and GitOps-owned.**
  `xraysight/hermes-memory-ui` (read-only Memory inspection UI: built-in
  MEMORY.md/USER.md + provider sections; Honcho read through each profile's
  own rendered `honcho.json`) is cloned at BUILD time from a pinned full
  SHA (`ARG HERMES_MEMORY_UI_REF`; v0.6.2 =
  `97cc937e49517dbd9e55cf10717da55d9024c29c`), staged in `/tmp`, installed
  into `/overlay/plugins/` AFTER the render (never pre-create
  `/overlay/plugins` earlier — the render's arrange loop would sweep it into
  `/overlay/profiles/plugins`). `bootstrap-profiles.sh` (`seed_plugins`)
  exact-replaces it into EVERY profile home's `plugins/` on every boot: a
  runtime `hermes plugins update` (or hand-edit) is overwritten next boot,
  and a runtime `hermes plugins enable` is reverted when the overlay
  overwrites `config.yaml` — both knobs are git-side. The plugin declares no
  capabilities and its root `__init__.py` is a deliberate no-op, so headless
  vendoring needs no consent prompt.
- **Enabling the plugin** (config change, no code rebuild): add to
  `config/profiles/default/profile.toml` — `[config_extra.plugins]` /
  `enabled = ["hermes-memory-ui"]` → PR → cache-hit rebuild → deploy. The
  recreation restarts dashboard AND gateway, satisfying upstream's rule that
  plugin_api routes mount only at process startup (`/api/dashboard/plugins/rescan`
  exists for hand-poked setups this GitOps layout doesn't need). Discovery
  is an opt-in allow-list — an absent `plugins` key enables nothing — and
  render.py FAILS the build on an enabled-but-not-vendored name
  (`STACK_VENDORED_PLUGINS`). Enable in the DEFAULT profile (the dashboard
  process runs with `HERMES_HOME=/opt/data`); per-profile data via
  `?profile=<name>`.
- **Plugin upgrade = bump the pin in one place**: resolve the new tag to
  its full SHA (`git ls-remote https://github.com/xraysight/hermes-memory-ui
  <tag>`), update `ARG HERMES_MEMORY_UI_REF` and the `version:` grep in the
  same layer, PR, merge (the clone layer onward re-runs; config-only pushes
  keep it cached). The Dockerfile's rev-parse assertion is the integrity
  check; if a build host ever rejects fetch-by-SHA, the comment documents
  the tag-clone fallback.

### Steering the profiles' working style

`config/SOUL_OPERATING.md` is appended to **every** rendered profile's
`SOUL.md` by `render.py` — one source, all five profiles. SOUL.md rides the
system prompt on every turn (unlike a skill, lazily loaded), so always-on
behaviour belongs there; the per-profile SOUL.md stays the role document.
The block covers:

- **Think before acting** — read the real file/config/response rather than
  reasoning from the name; pick the shape before the first call; when two
  approaches both look right, choose one and say what it traded away; never
  report a state change that was not read back (the same rule
  `team-conventions` enforces for GitHub handoffs).
- **Turn count is the cost** — 3+ shell/file operations for one goal → one
  call; a chain with logic between the calls → `execute_code`; a shell chore
  (git, builds, `gh`, docker, tests) → write a script with `write_file` and
  run it by path (also the friction-free path past the approval guards);
  never inline a big payload (heredocs, giant one-liners, nested `$(...)`
  are what the scanners mis-parse). This half exists because the terminal
  tool's own description steers work AWAY from shell, turning one pipeline
  into three or four turns; `execute_code` is the tool built to collapse
  that.
- **Subagents** (`delegate_task`) where only the conclusion should return —
  with the freshness rule (a child knows nothing about the conversation),
  the verify-the-summary rule, and the local concurrency bound.
- **Background jobs** — `terminal(background=True, notify_on_complete=True)`
  in-session; a scheduled job only for work that outlives the session, and
  then self-cleaning.

### Delegation + background jobs (enabled 2026-09-15)

`delegation` and `cronjob` were removed from the team profiles'
`agent.disabled_toolsets` (their fences left the team roles no way to reason
in fresh context or watch something over time).

- **Bounds are stack-wide**: `STACK_DELEGATION_DEFAULTS` in `render.py`,
  merged into every profile's top-level `delegation:` block exactly like
  `STACK_CRON_DEFAULTS` / `memory` / `auxiliary`, overridable per profile
  via `[config_extra.delegation]`. Values: `max_concurrent_children: 2`,
  `max_spawn_depth: 1` (flat — children are leaves), `worktree_isolation: false`.
- **Check upstream defaults against the CODE, not the prose.** In
  `hermes_cli/config_defaults.py::DEFAULT_CONFIG["delegation"]`,
  `max_concurrent_children` defaults to **10** (upstream's own docs say 3 —
  both wrong) and `worktree_isolation` is not a default key. Re-verify at a
  HERMES_REF bump; the docs have been wrong on both counts.
- **`worktree_isolation` must stay OFF.** Agents already work in a
  per-session worktree; enabling it nests the child's worktree at
  `<session-worktree>/.worktrees/subagent-<id>`, `gitignores` it into the
  SESSION worktree's own `.gitignore` (dirtying the parent's tree), and puts
  the child's branch in the SHARED central object store rather than
  session-scoped.
- **A child inherits the parent's `disabled_toolsets`**
  (`delegate_tool_toolsets.py`) — a profile fence is also a child fence, and
  `delegation` in that list removes `delegate_task` from the profile AND
  every child. A child can never gain a capability the parent lacks (no
  `toolsets` schema param; `_build_children` hardcodes inheritance). Leaf
  children additionally lose `clarify`, `memory`, `send_message` and
  `cronjob_manage` — a subagent can never schedule or ask a human.
- **`cron.allow_agent_scheduling` stays at its default (false)** — it gates
  only whether an agent *running inside* a cron job receives the `cronjob`
  toolset (`cron/scheduler.py::_resolve_cron_disabled_toolsets`, loop
  prevention), NOT the tool in a normal gateway session — so
  `agent.disabled_toolsets` remains the reliable fence. Do not "fix" a
  cron-job-cannot-schedule report by flipping it.
- **Agent-created jobs are self-cleaning by policy** (SOUL_OPERATING + the
  skill): a job an agent creates removes itself once its condition resolves;
  a *persistent* watchdog must be declared in `config/cron.toml` via a PR.
  Names prefixed `team: ` stay the reconciler's alone, so nothing an agent
  creates is ever pruned for it — which is exactly why it must clean up
  after itself.

## Agent self-management (skills + control-plane access)

Skills ship in two tiers — **stack-wide** (`config/skills/`, merged into
EVERY rendered profile by render.py) and **per-profile**
(`config/profiles/<name>/skills/`, same-named skills win). Currently:
`hermes-stack-ops`, this stack's operating manual for the agents (config is
GitOps-rendered, never hand-edit `/opt/data/config.yaml`; LiteLLM is the
only LLM path; GitHub App usage; central git repos + per-session worktrees;
Discord gotchas; small-host constraints; cron/kanban availability), and
`komodo-ops`, per-profile in the default profile — it drives the Komodo API
from inside the container at `http://komodo-core-1:9120` (komodo-core joins
the external `hermes_net`) with the auth header bind-mounted read-only at
`/etc/komodo-auth-header` (host path `/home/ubuntu/.komodo-auth-header`,
overridable via the stack env var `KOMODO_AUTH_HEADER_MOUNT`). **That mount
is not readable by the agent** — 600, owned by the host user while s6
services run as UID 10000 — so `-H @/etc/komodo-auth-header` dies with
`curl: option -H: error encountered when reading a file` and reads to an
agent as "the API key is broken" (it is not; check with `sudo` on the host
before touching the key). The entrypoint does for this what it does for the
App PEMs — copies it into the runtime-owned home on every boot
(`$HERMES_HOME/home/komodo-auth-header`, 600) — and `KOMODO_AUTH_HEADER` is
the var to use: `-H @$KOMODO_AUTH_HEADER`. Default profile only,
deliberately: the control-plane credential is not copied into the team
profiles' homes. The Komodo API key is created in the UI and, as of this
writing, does not expire (`expires: 0` — verify with `read/ListApiKeys`).
**The var is declared in compose, not exported by the entrypoint**, and that
is load-bearing: s6-overlay starts services from
`/run/s6/container_environment`, so an `export` in the entrypoint is
invisible to the gateway and every tool subprocess (it looked correct,
logged correctly, and reached nothing). Config belongs in the container
`environment:`, files belong in the entrypoint. The default profile's knob
set: deploy stacks, run builds, re-apply the resource sync — but NOT change
control-plane resources (that's the komodo repo, human-reviewed via push).

**A SECOND, separate control plane: `<org>/komodo`.** Its own core, servers
and key (no shared state with the homelab one). The release profile is the
only role that drives it, with the identical plumbing —
`KOMODO_ALT_AUTH_HEADER_MOUNT` on the host mounting
`/etc/komodo-alt-auth-header`, the entrypoint copying it into release's home
(`$HERMES_HOME/profiles/release/home/komodo-alt-auth-header`, 600), and
`KOMODO_ALT_AUTH_HEADER` declared in the container `environment:`. Use
`-H @$KOMODO_ALT_AUTH_HEADER`; the same unreadable-mount symptom applies.
The agent's boundary there is tighter: it writes **exactly one Komodo
Variable** (the released image tag for the stack it is releasing) and runs
`DeployStack` on that one stack — everything else (declaring the stack, its
compose file, variables) is the komodo repo, human-reviewed. **`TEAM_RELEASE_*`
is read by `release-queue.sh`, so it lives in the stack `environment:`
(komodo `resources.toml` + `mise.toml`), never in `hermes-main.env`** — the
launch profile's non-global env is stripped from a cron child (§Secrets).
`TEAM_RELEASE_STATE_DIR` is declared explicitly because a cron child's
`HERMES_HOME` is not guaranteed to be the profile home.

**`claude` (Claude Code) is a wrapper, documented for every profile** (usage
lives in the `hermes-stack-ops` skill + a shape-ladder in SOUL_OPERATING).
The role split is the part that matters: **writing the code directly is the
default** (read → `patch` / `write_file`, a script by path for shell-shaped
work); `claude` is for a genuinely multi-file change and read-only code
questions whose reasoning should not land in your context; `delegate_task`
reasons in fresh context; `execute_code` does mechanical bulk. (Naming
`claude` the *implementation* tool for the developer was wrong on two
counts: it runs the same tier the profile already runs, and a synchronous
multi-minute run does not fit the cron lane's bounded delivery window — the
developer had launched it five times ever.)

- **The wrapper passes `--dangerously-skip-permissions`** (unless the caller
  passed a permission flag of their own, the argv opens with a subcommand —
  `mcp`, `config`, `update`, `doctor`, … — or is `--help`/`--version`).
  Print mode cannot prompt, so its default denies every write; the "fix"
  once recorded in the developer's memory (`--permission-mode acceptEdits`)
  is wrong because each permission-mode call goes through Claude Code's
  classifier — a billed extra model call a third-party gateway cannot serve
  (Claude Code here only ever talks to LiteLLM; the wrapper prints that
  incompatibility itself). Same posture as the profiles' own tools
  (`STACK_APPROVAL_DEFAULTS`: `mode: off`) — the agent harness is never held
  to a stricter rule than the agent driving it, and **no skill may tell an
  agent to pass a permission flag** (it suppresses the default). Pinned by
  `scripts/test-claude-wrapper.sh` (`mise run test`) against a stubbed
  `claude-real`, asserting the argv including double-pass and subcommand
  passthrough.
- **The wrapper tells Claude Code the real context window.** Without
  `CLAUDE_CODE_MAX_CONTEXT_TOKENS` the catalogue describes none of the tier
  names and 200k is assumed — auto-compaction five times too early on 1M
  tiers. The wrapper resolves the window for the model that actually runs
  (a caller's `--model` wins for the window as well as the model, so the
  two never disagree) from `model_overrides` via `claude-model-resolve.py
  --window`; an undeclared window is left **unset**, not guessed
  (compacting early is wasteful; claiming a window the provider does not
  have overruns it). The `unrecognized_model` stderr line survives (about
  the catalogue, not the window) — cosmetic. What the wrapper DOES hardcode
  is the gateway: it refuses to run unless `model.provider` is `litellm` and
  posts to `http://litellm:4000` — renaming that provider in
  `providers.toml` or moving its base_url is also an edit to
  `docker/hermes/claude`, otherwise it degrades to stock claude, which fails
  on missing Anthropic auth.
- **The Claude Code installer resolves the platform package itself**
  (rewritten 2026-09-15). Since the 2.1.x cutover, the ~230 MB native binary
  ships in a per-platform package (`@anthropic-ai/claude-code-linux-arm64`,
  `package/claude`) that postinstall copies over a stub — and both fetchers
  still pulled `package/bundle/cli.js`, a path that no longer exists, so
  every install failed (silently: message on stderr, `exit 0` — the
  §"Scheduled jobs" stdout rule exists because of this) and `claude-real`
  froze while the daily update job reported ok. Both scripts now resolve the
  platform package (`uname -m` → arm64/x64; musl probed via
  `/lib/ld-musl-*.so.1`), extract `package/claude`, run it for `--version`,
  and only then rename it over `claude-real`; a forced failure prints,
  exits 1, and leaves the previous binary intact. Watch `claude --version`
  if the update job ever reports but never changes the version.

### Central git repos + per-session worktrees

All git repos live in ONE central store on the shared volume — a bare clone
per repo at `/opt/data/repos/<host>/<owner>/<repo>.git`. Nobody works in the
bare repos and no profile/session clones privately; work happens in
per-SESSION worktrees under `/opt/data/worktrees/<session-slug>/` (the slug
comes from `HERMES_SESSION_KEY`, bridged into every tool subprocess — one
messaging session = one slug, stable across its turns). The `git-repo.sh`
helper (baked at `/usr/local/bin/git-repo.sh`) manages both: `ensure`
(idempotent bare clone), `worktree <url> [branch] [dest]` (session checkout;
auto-creates a session branch `s/<slug>` when the requested branch is
checked out elsewhere), `list`, and `prune --days N` — run weekly via
`docker/hermes/prune-repos.sh` (a no-agent cron job), with the daily
`docker/hermes/refresh-repos.sh` fetch sweep keeping the branch mirrors
current. Both live in `docker/hermes/` because they are cron JOB scripts —
render.py validates a declared job's script against that directory, and the
reconciler seeds it from `/usr/local/bin/`. Overrides:
`HERMES_REPOS_DIR` / `HERMES_WORKTREES_DIR`. Everything is runtime-uid-owned
(every profile reaches the same store); git's worktree model provides the
isolation (one branch, one checkout).

## Provisioning per-profile identities (GitHub Apps + Discord bots)

Occasional, machine-side procedures — the inventory table (one App + one
Discord bot per profile), the App-manifest and Discord-token scripts with
their SSH deploy contract, org-App runs, and the `Activating a new profile`
steps — live in the **hermes-ops-runbook** skill. Two invariants stated
here because they govern every session: every profile has its OWN bot
identity in GitHub and Discord and must never share or impersonate
another's; and PEMs and bot tokens are secret — never echoed, committed, or
routed through a shell history or chat transcript (the ids live as
`PROFILE_<NAME>_*` in `/etc/hermes/hermes-main.env`).

### The planner decides; it does not enumerate

The planner's spec is the only place a design decision can be made: the
developer has no channel to the user, so **any choice left open in an issue
body will be made silently, by the developer, in the planner's name.** "End
the open questions" is the job; listing them is not a plan. (Observed: three
"flesh out issue N" rounds left one issue shipping "use WiX **or a
similar**" verbatim, another contradicting itself between sections, and a
third silently reversing `systemctl enable --now` → `enable` with no
migration story — each revision re-decided, so the body was a snapshot of
the last draft, not the record the developer was relying on.)

Three changes hold, all in the planner's own files
(`config/profiles/planner/SOUL.md`, `.../team-planner/SKILL.md`):

- **`## Decisions` is a required body section** — a table of every decision
  the work depends on, with choice, why, and *who* decided (planner or
  user). It is what lets the developer tell "settled" from "I may still
  pick".
- **An unresolved alternative is a defect**, listed by shape: `or similar`,
  `e.g.` where it names the thing to build, `TBD`, a path/env var/flag not
  read back from the code, two sections that disagree, a silent reversal of
  an earlier revision. Before `status/ready` the planner re-reads and greps
  the body for those markers; each hit is decided or asked.
- **The approval round ends in a question** the planner actually needs
  answered, with its own recommendation attached — a summary of work just
  done is not a round.

Body payloads are `--body-file`-only (§"GitHub access", the BODY GATE — the
inline spelling is what corrupted those issue bodies).

### Routing work to a profile: labels, never assignees

**GitHub App bot identities cannot be issue/PR assignees.** A platform rule
about the *assignee's* account type, not credentials — assigning a bot fails
with 403 from any token; the cheap probe is `GET /repos/{owner}/{repo}/
assignees/{login}` → 204 assignable / 404 not. So the assignee field is
unused by design and the team routes by **label**: `status/ready` IS the
handoff (planner sets it, developer claims by swapping to
`status/in-progress`). Do not "fix" with a PAT or machine user. Bots
*authoring* issues/PRs works fine (why the reviewer's author-filtered
searches were never the problem).

**Three label families, and the OBJECT is half the rule.** `status/*`
(`status/backlog|ready|in-progress|in-review|blocked|done`) belongs on
**issues**, planner's and developer's — plus release in exactly one case: a
bug the release pipeline finds is filed `type/bug` **+ `status/ready`** so
the developer's queue sees it immediately (a production bug must not wait
for the planner to route it). `review/*` (`review/ready|in-progress|changes|approved`)
belongs on **pull requests** — the developer adds `review/ready` as the
handoff and drops `review/changes` on a re-handoff; everything else is the
reviewer's. `type/*` (`type/bug|security|feature|chore|breaking`) is legal
on BOTH objects by design — it classifies the CHANGE, not the handoff, which
is why the foreign-label guard must never flag it. Planner sets an issue's
type (required on every issue it creates); the developer carries it onto the
PR and adds `type/breaking` when incompatible. `type/*` is also the
release's version input (highest wins: breaking→major, feature→minor,
else→patch) and the **bug-first** mechanism: the developer's queue lanes run
`status/in-progress,type/bug` → `status/ready,type/bug` → the plain lanes
(repeated comma-separated labels mean AND; the lane order is the priority
order). An item with no type still flows — it is just not hoisted, and
contributes a patch (`!! TYPE MISSING` says so).

Each queue polls ONE family on ONE object kind, so a wrong-family label
takes the item out of BOTH queues at once while it still looks busy
(observed 2026-09-25: the reviewer's verdict steps said "Card → In
Progress" and the card IS `status/in-progress` on a label-mechanism repo,
while the developer put `review/ready` on the issue — the issue then carried
no `status/*` at all, so neither queue could see it, and the two profiles
traded it every 5-minute tick until the stack was paused in Komodo — which
is also how the user stops a live agent loop: pause the `hermes` stack in
Komodo, and a deploy resumes it).

What holds now, each enforced mechanically (see §"GitHub access" for the
gates' exact behavior):

- **The write site is fenced**: the gh shim's label gate refuses a
  wrong-object label edit before gh-real runs, and refuses every
  `gh issue edit|close|reopen` from the reviewer profile. The refusal is the
  teaching moment at the moment of misuse; the `!! FOREIGN LABEL` guard's
  role narrows to the spellings no gate covers (`gh api`).
- **A handoff is a SWAP, never a bare removal** (`team-conventions`: one
  command, both flags). The gates refuse a wrong-family SET, but a bare
  `--remove-label` that adds nothing leaves the item carrying no `status/*`
  at all — in no lane at either end, still looking busy (observed: the
  issue sat laneless for hours with an approved PR waiting, and the
  reviewer's `@hermes-planner` card request went unanswered — **the planner
  has no self-pull queue**, a GitHub mention reaches it only if it is in a
  session anyway).
- **Ownership is stated once**, in the shared `team-conventions` skill
  ("The routing labels" — the fifteen labels with added-by/removed-by
  columns; a profile writes only its own family). The reviewer never writes
  a `status/*` label and never runs `gh issue edit` at all: it judges on the
  PR and names the card state it implies to planner (`@hermes-planner` — the
  developer's roadblocks use the same intake), and the developer moves the
  issue to `status/in-review` at handoff. Skills name their object
  explicitly (`<ISSUE#>` vs `<PR#>`) — the two numbers for one work item
  differ and are joined only by `Closes #N`.
- **The queues report a misfiled label** (`!! FOREIGN LABEL`):
  `docker/hermes/team-queue.sh` scans its own object kind once per owner
  (one unfiltered search, filtered client-side — repeating `--label` means
  AND, so per-label checks would multiply a 5-minute tick's calls), and
  prints a **deduped** incident naming the item, the label, and the command
  that undoes it (including the card restore, `status/ready` via an issue
  edit, for an issue left with no `status/*` at all). It rides the delivery
  the profile's agent already reads, needs no agent turn, and changes no
  exit code. Two placement rules make that real (the first version got both
  wrong): the scan runs **inside the owner loop**, per owner with that
  owner's token — post-loop code exits early on a credential fault and that
  incident is deduped, so anything after it would never run again for any
  owner; and it keeps its **own dedupe slot**
  (`team-queue-<slug>-foreign.state`, not the shared `team-queue-<slug>.state` —
  a standing unrelated incident in the shared slot would silence the guard
  or be silenced by it). Both slots are cleared by a healthy run, so a fault
  that returns is reported again. One operational caveat: a HUMAN running
  `team-queue.sh --verbose` to check the guard consumes the dedupe slot like
  any run and eats the agent's wake for that incident.
- **Reachability, not just logic, is tested**: `scripts/test-team-labels.sh`
  (`mise run test`) runs under the container's own `/bin/sh` as well as
  locally; one case asserts a finding still appears when an owner's
  credentials fail. It pins the whole protocol: every `--add-label`/
  `--remove-label` command in the skills targets its family's object (logical
  lines, continuations joined — a real two-line handoff checked as one),
  every `status/…`/`review/…` literal is one of the ten, and the guard fires
  / names the undo / dedupes / goes silent on clean state against a stubbed
  gh (the card-restore OUTPUT is asserted, interpolated per item — a repo
  slug contains the `/` that breaks a naive sed). `run_queue` pins
  `TEAM_OWNER_ORGS` empty: compose injects the stack env into every process,
  so an ambient value would leak in and add a credential-less owner.

`team-queue.sh` (baked at `/usr/local/bin/team-queue.sh`) wraps the
developer's self-pull **with a loud failure mode** — an empty search and a
broken search are indistinguishable downstream. Exit codes are the contract:
`0` healthy (work or a genuine `QUEUE EMPTY`), `2` query failed, `3` blind
search (token or scope), `4` nothing carries the `hermes-team` topic, `5` an
onboarded repo is missing the routing label. **2–5 are incidents to surface,
not idle states.** Grep new skills for the colon form before shipping:
`--flag:value` does not exist in gh search syntax; it is `--flag value`.

**One degraded state is deliberately NOT an incident: an unresolvable author
filter.** `author:<login>` for an unknown/unviewable user fails the WHOLE
query — a bot whose App lost its installations takes the entire queue down
with it (observed: every reviewer run died as `QUEUE BROKEN` for ~6h while
its org half was healthy). So the PR search is retried WITHOUT the filter
when the filtered one fails — a wider net is recoverable, a dead queue is
not — announced once (deduped) as `AUTHOR FILTER DROPPED`: fix the login, or
unset it deliberately. The filters are DECLARED, never assumed —
`TEAM_OWNER_DEV_BOT` for the personal owner, `TEAM_ORG_DEV_BOT_<ORG>` per
org; neither set = no filter. A login compiled into the script cannot be
fixed by an operator (the old hardcoded default announced a fault about a
working queue) — **no bot login appears as a `:-` default anywhere in the
script**, enforced by the test suite. The widening fallback remains only for
a *declared* filter going stale.

**The release lane (`release-queue.sh`, `--kind releases`)** polls
`review/approved`, but **`gh search prs --review approved` is NOT the human
gate** — a GitHub App's approval sets review state `APPROVED` too, and the
reviewer bot approves before the human looks (observed: bot APPROVED
~9 hours before the code owner's approval). So the queue reads the reviews
BACK (`GET /pulls/{n}/reviews`, `user.type != "Bot"`) and requires the MOST
RECENT non-bot review to be `APPROVED` by a login in the repo's `CODEOWNERS`
(fetched with `Accept: application/vnd.github.raw`, no base64 decode). An
item that fails is **dropped, never emitted** — a PR waiting on a human must
cost zero tokens — and named only under `--verbose` (`AWAITING HUMAN`). The
same script grows a per-repo **triage** pass: a `v*` tag with no published
release, a `release.yml` run that concluded badly, and a published release
that is not what the agent's own state file records as deployed. A run still
IN FLIGHT is deliberately not a finding (the resumable "waiting on CI"
state; includes a run with an EMPTY `conclusion` — the jq classifies it
in-flight because awk's field splitting collapses the empty slot). Findings
use their own dedupe slot plus a first-seen epoch (`TEAM_RELEASE_RETRY_TTL`,
6h) — a stalled release is unattended work and a delivery lost to a restart
must not read as a resolution — and the dedupe key is the FINDING IDS,
never the message text (prose is not stable tick-to-tick; keying on it
re-delivers unchanged work mid-TTL).

**The bot-chat delivery timeout is 900s stack-wide** (`render.py` →
`cron.bot_chat_delivery_timeout_seconds`): a bot-chat delivery runs a full
agent turn synchronously inside the job's execution, and on timeout expiry
the child is KILLED mid-turn (it was 3600s — unbounded against a `*/5`
self-pull: a delivery running an hour stacked up to 12 overlapping wakes).
900 clears the longest legitimate turn this host runs while bounding the
backlog to ~3 ticks; per-item serialisation is the one-session-per-item
gate below.

`GH_TOKEN` is absent from a cron script's environment (subprocess env is
credential-stripped by design) — fine, because the profile's `gh` is already
logged in as its own App installation
(`/opt/data/profiles/<name>/home/.config/gh/hosts.yml`). The same child-env
construction ALSO strips the launch profile's non-global `.env` names — the
sharper trap for script-read vars (§Secrets, "`hermes-main.env` is the
LAUNCH profile's env").

**The queues are resume-first, and that is load-bearing.** The self-pull
defaults to `status/in-progress` THEN `status/ready` (`review/…` likewise):
a cron job passes no arguments to its script, so the default IS the
behavior, and an item a profile already claimed is its own unfinished work —
an interrupted turn (deploy restart, timeout) leaves it claimed, hence no
longer `ready`, hence invisible to a ready-only queue, half-done forever.
In-flight first means a restart resumes rather than orphans; the worktree
makes that cheap (the session slug is stable across cron wakes, so the
interrupted turn's branch and uncommitted changes are still on disk under
`/opt/data/worktrees/`).

**One session per work item — the queue YIELDS, it does not compete**
(`docker/hermes/team-session.py`, called by `team-queue.sh`; documented in
its header). Before `team-queue.sh` emits, every item is checked against the
profile's own live sessions and **dropped if a live session already holds
it** — and if that leaves nothing, the script prints nothing and exits 0, so
no bot-chat turn is spawned at all: a cron session with nothing to do exits
without working. `--gate any` means a previous delivery still in flight also
holds its item — what actually stops the next tick stacking a second wake.
The check is per ITEM (a live session on one issue never fences a
newly-routable issue elsewhere). Liveness is `sessions.last_activity_at`,
refreshed by Hermes on every stream chunk — deliberately NOT a claim file or
heartbeat, because a heartbeat the agent must remember to send goes stale
during exactly the long turn it needs to cover. It expires after
`TEAM_SESSION_TTL` (600s default), so an interrupted turn does not fence its
item forever. A missing/unreadable `state.db` is exit 2 = gate DARK: items
still flow, a deduped incident says so (a guard that silently stopped
guarding looks exactly like a quiet week). The other direction is a
`SOUL_OPERATING.md` rule: a chat session finding a live unattended turn on
an item **confers for an update** — `python3 /usr/local/bin/team-session.py
--gate agent --item owner/repo#N` — instead of starting a competing pass.

**Work-item Discord threads (`team-thread.sh`).** One thread per work item,
in the calling profile's own channel, kept open until the PR is **merged**.
Auto-threading only fires on inbound Discord messages, so the thread is
created explicitly; the item→thread mapping persists under
`$HERMES_HOME/cache/threads/` (each cron wake is a fresh session with no
chat context). `team-thread.sh sweep` (called from the queue script,
token-free) turns "issue closed" (`Closes #N` on merge) into "thread
archived" — a thread cannot be stranded open just because the agent never
woke again. Bot token and channel derive from the profile's own
`$HERMES_HOME`, so each role posts as its own bot and sweeps its OWN
(threads are owned by the bot that created them).

## Scheduled jobs are GitOps-declared (`config/cron.toml`)

Every cron job is declared in **`config/cron.toml`**, rendered per profile
by `render.py` into `<overlay>/cron.json`, and reconciled into that
profile's cron store at container boot by `docker/hermes/cron-reconcile.py`
(invoked from `bootstrap-profiles.sh`). Hand-creating a job with
`hermes cron` is the same mistake as hand-editing `/opt/data/config.yaml`:
it survives until the next boot, then the reconciler overwrites it.

- **The store is runtime state, so it is reconciled, never copied.**
  `$HERMES_HOME/cron/jobs.json` holds run history, failure streaks,
  `next_run_at` and per-job notepads — overwriting it from the image on each
  deploy would reset all of that, so the reconciler drives the `hermes cron`
  CLI to create/edit in place. A job whose stored config already matches the
  declaration is left completely untouched.
- **`hermes cron create` exits 0 even when it fails** (prints `Failed to
  create job: …` on stdout). The reconciler therefore verifies every
  create/edit/prune by READING THE STORE BACK and reports a failure when the
  change did not land. A status code is not evidence — the same lesson as a
  job script printing success on stderr with `exit 0`.
- **Matching is by name** — `render.py` rejects duplicate `(profile, name)`
  pairs at build time (a duplicate would edit the wrong job). Names are
  namespaced `team: ` and `--prune` only ever removes that prefix, so a job
  an AGENT created for itself is never deleted.
- **Job scripts are validated against `docker/hermes/` at build time.** A
  `no_agent` job whose script is missing is "unrunnable" and the scheduler
  **auto-pauses** it at the first tick — a typo'd script name fails
  `mise run validate` instead of becoming a dead job in production. At boot
  the script is seeded from `/usr/local/bin/` into `<profile>/scripts/` (the
  scheduler refuses a script outside `$HERMES_HOME/scripts`), chowned to the
  profile home's owner when boot runs as root — a root-owned scripts dir is
  unwritable to the ticker, which would create the job and then never fire
  it.
- Deleting a job from `config/cron.toml` DOES take effect: an empty spec
  still runs the prune pass.
- **Delivery targets.** `deliver = "bot-chat:<profile>"` — wake that
  profile's agent with the output as a message it responds to (the
  self-pull queues' handover). `deliver = "discord:<chat_id>"` — post into
  a channel as the owning profile's bot, used by the three housekeeping
  jobs (`team: claude code update` 04:37, `team: weekly worktree prune`
  Mon 05:00, `team: daily repo refresh` 06:00 → **#hermes-home**,
  `DISCORD_HOME_CHANNEL`: no decision for an agent to make, so waking one
  would be a wasted turn; this OUTBOUND send is not covered by the
  adapter-drops-own-messages rule, which is about INBOUND delivery).
  `deliver = "local"` — save, deliver nothing (`origin` is meaningless for a
  declared job — there was no originating chat). The housekeeping jobs are
  **silent when healthy** (empty stdout = no message) and **exit non-zero on
  a real failure**, so the scheduler's deduped failure notice reaches
  #hermes-home. `DISCORD_HOME_CHANNEL` (in `/etc/hermes/hermes-main.env`;
  template in `secrets/hermes-main.env.example`) also points the *gateway's
  own* system messages there — restart/shutdown notices, the connect-time
  warning, any `all`/`home` routing — and, unlike the mention/threading
  family, does not touch the team channels' fence.
- **A job script's diagnostics belong on STDOUT, and a failure must exit
  non-zero.** A `no_agent` job delivers stdout verbatim and **discards
  stderr** — a failure printed to stderr is a failure nobody sees, and
  `exit 0` on top of it makes the run record `ok` (how `claude-update.sh`
  reported success for weeks while `claude-real` sat frozen at 2.1.267).
- The three housekeeping jobs were once hand-seeded, un-prefixed and
  undeclared — the whole failure mode this section exists to prevent (they
  survived only in one profile's store; a volume rebuild would have lost
  them silently). The complete set of conditions for a job to be recreatable
  from the repo alone: declared in `config/cron.toml`, `team: `-prefixed
  (so `--prune` owns it), script in the Dockerfile COPY list. Verified by
  `mise run render` (`build/default/cron.json` carries all three).
- **The self-pull jobs are `no_agent` scripts, deliberately.** stdout is
  delivered verbatim and **empty stdout is silent** — no message, no agent
  turn, no tokens; the 5-minute poll is free, the agent wakes only when
  there is work. Incidents print once and are deduped via a state file — a
  persistent fault wakes the team once instead of every tick.
- **`deliver` must NAME the profile (`bot-chat:<name>`).** Bare `bot-chat`
  ("the job's own profile") spawns `hermes chat` with no profile argument
  inheriting the firing scheduler's `HERMES_HOME` — and under
  `GATEWAY_MULTIPLEX_PROFILES` every profile's ticker shares the gateway
  process, whose `HERMES_HOME` is the DEFAULT profile. `bot-chat:<name>`
  passes `-p <name>` AND drops `HERMES_HOME` from the child env, so the turn
  really runs as the named profile.
- **A cron wake is a work item, not a conversation — every wake starts a
  FRESH session** (2026-10-04, patch 4 in `docker/hermes/patches/`). The
  delivery used to hand the turn to the profile's canonical "Bot Chat"
  session (`-c "Bot Chat" --create-if-missing`), so every wake accumulated
  into one transcript replayed in full each time (observed: 700+ messages /
  ~150k tokens of history per turn after three weeks). The delivery now
  titles each wake uniquely so a fresh session mints per wake. **Interactive
  Discord chat is unchanged** (the adapter's per-thread store — a different
  path). Consequence: a work item interrupted mid-turn is re-delivered by
  the resume-first queue into a FRESH context — the agent re-derives from
  the durable state (issue/PR body, the session worktree, memory) rather
  than from its own prior turn; those durable stores are the real state
  machine. (Release-queue specifics: §"Routing work to a profile".)

## Local development (this repo)

Local runs use **mise** (not Makefile): `mise run up`, `mise run logs`,
`mise run chat`, `mise run down`, `mise run validate`,
`mise run check-updates`. `mise.toml [env]` holds the version pins and
`HERMES_ENV_DIR`; per-machine overrides go in gitignored `mise.local.toml`.
After editing anything in `config/`, open a PR — the Docker build runs
render.py itself, so there is NO committed `build/` output to keep in sync.
Preview a render without building: `mise run render` (writes ./build/,
gitignored). Note: local compose runs get a project named after the parent
dir, not `hermes` — the Komodo deployment on the host is the real one.

A gateway-config change and the env edit it implies are two separate acts
(`/etc/hermes/*.env` is operator-owned, outside the repo's atomicity): a
value left on a raw `ollama/<id>` still routes through the wildcard but
loses its declared window — showing up as compression sizing wrong and
`claude` leaving `CLAUDE_CODE_MAX_CONTEXT_TOKENS` unset. Update the env file
in the same change that deploys the gateway config.

`hermes doctor` inside the container reports warnings for Hermes' *built-in*
honcho/vision integrations — expected and benign: this stack wires Honcho
via MCP, and vision just needs system deps the container lacks.