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

## Deployment model

Deployed as the Komodo Stack **`hermes`** (server `<your-komodo-server>`): one compose
project merging all files under `compose/`, cloned from this repo at deploy
time. **The compose project name is `hermes`** — all named volumes are
prefixed `hermes_*` (agent state, honcho Postgres, firecrawl
db, the shared valkey + lavinmq volumes) and hold live data; do not rename the stack. The stack
must be deployed before komodo-core can start with it (`hermes_net` is
declared external in komodo's compose).

- **Merging a PR to `main` = build + deploy** (GitHub webhook → the Komodo
  `rebuild-hermes-agent` procedure: build `hermes-agent` → build `litellm`
  → deploy `hermes`, sequentially, defined in the komodo repo's
  `resources.toml`). Honcho images are built upstream-first via the
  `rebuild-honcho` procedure (`execute/RunProcedure {"procedure":"rebuild-honcho"}`
  — no webhook; sequential stages keep the builds off the host concurrently).
  Config/compose-only changes cost a Dockerfile cache-hit build (~1 min).
- **`main` is protected — land every change through a squash-merged PR.**
  The `Main` ruleset rejects direct pushes, force-pushes and branch
  deletion, requires the commits that land to carry verified signatures, and
  permits only squash merges; a `Release tags` ruleset blocks moving or
  deleting a `v*` tag. The webhook fires on the *push* a squash merge
  produces, so "merge = deploy" is literally the same event — but a
  `git push origin main` from a working copy fails with `GH013` ("Changes
  must be made through a pull request"). Push your branch and open a PR.
- **Images are built by Komodo Builds — never compose build** (the stack
  runs `run_build = false`; images `hermes-agent:v2026.9.24`, `litellm:main`,
  `honcho:main`, `honcho-mcp:main`, `builder = "<your-builder>"`). The
  `hermes-agent` and `litellm` Builds use a **repo-root build context**
  (`build_path = "."`) — the Dockerfiles COPY `docker/hermes/*`, `config/` +
  `render.py` (rendered inside the build), and `config/litellm.yaml` (see
  `.dockerignore`). Manual equivalent when the webhook was missed: merge,
  then `execute/RunBuild` per build, then
  `execute/DeployStack {"stack":"hermes"}` — and check
  `GetStack` → `info.deployed_hash`; a webhook delivery can 200 but skip if
  Komodo is mid-operation or restarting.
- **Config is baked into images, so deploys restart intelligently.** A
  config-only change invalidates just the final COPY layer → new image →
  the deploy's `compose up` recreates only the affected service. No
  bind-mounted config files (whose content changes compose can't see), no
  reloader sidecar, no manual restarts. Never hand-edit a container's
  config in place. A deploy is a no-op for services whose image and compose
  config didn't change — check
  `docker inspect <container> --format '{{.State.StartedAt}}'` to confirm a
  recreation actually happened. Changes to `/etc/hermes/*.env` on the host
  DO trigger recreation on the next deploy (compose hashes env_file
  contents).
- The agent image is a thin build FROM the official
  `nousresearch/hermes-agent:<ref>` image — code, venv, launcher, Node, and
  the s6 supervision tree are upstream's problem; don't re-implement or
  patch around them here. The venv is uv-managed (no pip; use
  `uv pip install --python <venv>/bin/python`).

### Bumping HERMES_REF (the update checklist)

The ref is the FROM tag of the official base image (publishes per-release,
so a bump upgrades both agent code and the supervision tree). Update it in
**all** of: the `hermes-agent` Build's `image_tag` AND `build_args`, the
stack `environment` in the komodo repo's resources.toml, `mise.toml [env]`
(the Dockerfile ARG defaults flow through compose, so only mise.toml needs
the edit), and `render.py`'s `_FALLBACK_CONFIG_VERSION` (local preview
renders only — the build-time stamp is derived from the base image). A ref
bump is exactly when the source patches in `docker/hermes/patches/` break —
their anchors are upstream line numbers; the build fails loudly if an
anchor moved, and an already-adopted patch reverse-applies with a NOTICE
telling you to delete it (so an unpatched image is never shipped silently).
Then RunBuild → DeployStack, and always verify `hermes mcp test honcho` +
`hermes mcp test firecrawl` against the new image — Hermes' MCP SDK pin is
where HTTP-transport breakage has landed before (mcp 2.x renamed
`streamablehttp_client`; refs from v2026.8.31 onward support 2.x natively,
so the old `mcp<2` Dockerfile pin was dropped at that bump).

## Secrets

Runtime secrets live in root-owned files on the host —
`/etc/hermes/*.env` (mode 640, `root:<host-group>`), mounted read-only into
Periphery, wired via the stack `environment` `HERMES_ENV_DIR=/etc/hermes`.
Templates are in `secrets/*.env.example`; nothing secret is ever committed,
echoed, or routed through a shell history or chat transcript.

- **Every LLM in the stack goes through the LiteLLM proxy**
  (`http://litellm:4000` + `config/litellm.yaml`). The proxy holds the real
  upstream keys (`OLLAMA_API_KEY` for Ollama Cloud — the key Open WebUI
  uses — and `OPENROUTER_API_KEY` for free models, both in `litellm.env`)
  and routes each model name among that group's members
  (`router_settings.routing_strategy: latency-based-routing` — inert for the
  single-member tiers, meaningful the moment one has two deployments, which
  is also when "same capability class" starts to matter: a fallback with a
  smaller window silently breaks long-context work). An `ollama/*` wildcard
  serves every other Ollama Cloud model (callable as `ollama/<model-id>`,
  expanded in `/v1/models` from the provider's own list via
  `litellm_settings.check_provider_endpoint`), so a model can be tried
  before it is promoted to a tier — but a wildcard id has NO declared
  window (models.toml declares windows per TIER), so it is not something an
  agent should rely on. Apps authenticate with the master key
  (`LITELLM_MASTER_KEY`, generate with `openssl rand -hex 32`), mirrored
  into each app's env as `LITELLM_API_KEY` / `LLM_OPENAI_API_KEY` /
  `OPENAI_API_KEY` — same value everywhere.
- **`config/litellm.yaml` is the backend file; the apps only ever send one
  of four TIER NAMES.** `cheap` / `smart` / `smarter` / `smartest` are
  LiteLLM `model_name` groups, and everything under a group's
  `litellm_params` — provider, upstream model id, `api_base`, key, extra
  params, extra members — is the implementer's to point anywhere. That is
  the abstraction: moving a tier to another provider, or swapping the
  backend behind it, is an edit to this file and NOTHING else. Current
  backends (windows are the values Ollama Cloud reports, verified via
  `POST ollama.com/api/show` and re-checkable with
  `mise run check-model-windows`):
  **cheap** = `nemotron-3-nano:30b` (256k; `smart_model_routing`'s cheap
  lane for short/simple turns, the light aux side tasks — session search,
  web extract, skills hub — and Honcho's VOLUME lanes: the deriver, which
  runs on every message, plus the minimal/low dialectic levels),
  **smart** = `gemma4:cloud` (256k, vision; the planner profile, and
  Honcho's REASONING lanes: dream deduction/induction, summaries, and the
  medium/high/max dialectic levels),
  **smarter** = `glm-5.3-flash` (1M, vision; the default and developer
  profiles, and aux compression — the one lane that needs intelligence AND
  a big window),
  **smartest** = `glm-5.3` (1M, **no vision**; the reviewer, plus the
  opt-in `/model smartest` escalation — kimi-k3 is the drop-in swap if the
  top tier ever needs to accept images).
  Because the tier names ARE the gateway's model names, `/model cheap`,
  `/model smart`, `/model smarter` and `/model smartest` all genuinely
  resolve mid-session — the old alias names could not (they lived only in
  this repo and never reached the gateway).
  Exception: the `firecrawl` group is NOT a tier and is **OpenRouter free
  models ONLY** (`google/gemma-4-31b-it:free`,
  `nvidia/nemotron-3-super-120b-a12b:free`) — Ollama Cloud strips
  `response_format: json_schema` (so /v1/extract and v2 json-format scrapes
  returned `json: null`), while OpenRouter passes json_schema through and
  SmartScrape extraction works. It is also the shape to copy for any other
  lane that can never see private data.
- `litellm.env`: `LITELLM_MASTER_KEY`, `OLLAMA_API_KEY`,
  `OPENROUTER_API_KEY` (free tier — create at https://openrouter.ai/keys).
- `hermes-main.env`: `LITELLM_API_KEY` (the master key), the `AUXILIARY_*`
  overrides (BASE_URL=http://litellm:4000), `FIRECRAWL_API_KEY` (must equal
  `TEST_API_KEY` in `firecrawl.env`), `HONCHO_API_KEY` (any non-empty value
  while honcho-api runs no-auth; must match honcho-api if auth is enabled),
  `OPENAI_API_KEY` + `OPENAI_BASE_URL` (mirror the LiteLLM endpoint for
  Hermes' registry-based fallbacks — `hermes chat`'s first-run gate only
  inspects registry env vars, never config.yaml's `custom_providers`, and
  exits with setup guidance without them even though the gateway resolves
  the provider fine), `DISCORD_BOT_TOKEN` + `DISCORD_ALLOWED_USERS`
  (gateway), GitHub App vars (below), and `PROFILE_<NAME>_*` lines for the
  team profiles.
- `firecrawl.env`: `TEST_API_KEY`, `POSTGRES_*`, `OPENAI_API_KEY` +
  `OPENAI_BASE_URL` (LiteLLM) + `MODEL_NAME=firecrawl` (LLM
  extract/generate).
- `honcho.env`: `LLM_OPENAI_API_KEY` + `LLM_OPENAI_BASE_URL` (LiteLLM —
  bare `OPENAI_API_KEY` is NOT read; Honcho uses `LLM_`-prefixed settings
  and every default model config reuses the client built from these two),
  per-section `*_MODEL_CONFIG__MODEL` overrides (deriver, summaries, dream,
  dialectic levels — defaults point at OpenAI models this stack's gateway
  does not serve, so all of them are pinned to TIER NAMES), and the
  embedding block: `EMBEDDING_MODEL_CONFIG__*` → LiteLLM's
  `nomic-embed-text` entry, which proxies to the stack-local `ollama`
  service (768 dims; Ollama Cloud has **no embeddings endpoint**) +
  `EMBEDDING_VECTOR_DIMENSIONS=768`. Optional `HONCHO_POSTGRES_PASSWORD`.
  The section split follows the work: **volume lanes on `cheap`** (the
  deriver runs on every message, and minimal/low dialectic is light by
  construction), **reasoning lanes on `smart`** (dream deduction/induction,
  summaries, and the medium/high/max dialectic levels). Raising the DERIVER
  is the single biggest spend lever here — and the biggest quality lever;
  it is the one line to change if memory extraction looks thin.

## Stack particulars (hard-won)

The stack is deliberately right-sized **small** — upstream defaults for
these stacks assume a real server and will starve a small host into
crash-loops. Do not "fix" the small numbers in the compose files without
checking the host's actual resources.

- **litellm** runs DB-less (no `DATABASE_URL`) — fine for pure routing;
  key management/budgeting features need a DB and are unused here. The
  image is a thin build over upstream (`docker/litellm/Dockerfile` FROMs
  the multi-arch `ghcr.io/berriai/litellm:main-latest` — the versioned
  `main-v1.x.y` tags are amd64-only; pre-pull the base on the host before
  the first build and re-pull on gateway upgrades).
- **Nothing may start before litellm is SERVING, not merely alive.** The
  gateway binds its port only after app startup completes, and startup
  fetches the provider catalogue (`check_provider_endpoint`) — observed ~1–2
  minutes on this host, during which `curl http://litellm:4000/...` is
  connection-refused. So `compose/litellm.compose.yml` declares a
  healthcheck on `/health/liveliness` (the one health endpoint that needs no
  auth; the image has no curl, so the probe is python), and every service
  that calls the gateway — `hermes-main`, `honcho-api`, `honcho-deriver`,
  `firecrawl-api` — depends on it with `condition: service_healthy`. Two
  consequences worth knowing: a container started right after a deploy may
  sit in `created` for the length of that boot, which is correct rather than
  stuck; and if litellm never becomes healthy, none of those services start
  at all — the ordering is the point, and the probe's `start_period` (180s)
  covers the boot that is actually needed. `docker inspect <c> --format
  '{{.State.Health.Status}}'` is how to check the gateway's own state.
- **firecrawl**: the real concurrency knobs are `NUQ_WORKER_COUNT=1`
  (`NUM_WORKERS_PER_QUEUE` only affects the legacy worker),
  `MAX_CONCURRENT_JOBS=2`, `CRAWL_CONCURRENT_REQUESTS=2`,
  `BROWSER_POOL_SIZE=1`; playwright has a memory-only limit (a `cpus`
  limit above the host's core count is unschedulable). **Env var names
  churn between releases** — when bumping `FIRECRAWL_VERSION`, diff
  `compose/firecrawl.compose.yml` against upstream's `docker-compose.yaml`
  for the new tag; known trap: **`HOST` must stay `0.0.0.0`** (the default
  `localhost` binds IPv6 loopback only — the in-container harness probe and
  the published port both get ECONNREFUSED, restart-looping forever).
  **The broker is LavinMQ, not rabbitmq (changed 2026-09-22):** upstream's
  `rabbitmq:3-management` idled at ~760 MB on this host (564 MB of
  quorum-queue ETS with every queue empty), but a broker cannot simply be
  dropped: NuQ's *scrape* path is optional-AMQP (unset `NUQ_RABBITMQ_URL`
  → Postgres `LISTEN/NOTIFY`, `services/worker/nuq.ts`), yet the *extract*
  lane has no fallback — `services/extract-queue.ts` (producer) and
  `services/extract-worker.ts` (consumer) throw without it, and a missing
  broker crash-loops the whole API harness. `/v1/extract` is load-bearing
  here (SmartScrape), so `compose/lavinmq.compose.yml` provides
  `cloudamqp/lavinmq` under the `firecrawl-rabbitmq` alias — drop-in AMQP
  0-9-1, idles at tens of MB, guest/guest (network-internal, no published
  ports). NATS is not an option (Firecrawl speaks AMQP; a rewire is
  upstream work). The `firecrawl-api` restart-loop signature for a missing
  broker is `extract-worker failed with exit code 1` / "Can't accept
  connection due to RAM/CPU load" (restart churn, not a real load
  problem).
  **Shared Valkey** (`compose/valkey.compose.yml`) serves both apps:
  the `firecrawl-redis`/`honcho-redis` aliases keep every client URL
  unchanged; Firecrawl uses logical DB /0, Honcho /1 (`CACHE_URL` in
  the honcho compose).
  **firecrawl-db** runs `postgres -c cron.database_name=firecrawl` because
  the nuq-postgres initdb script `CREATE EXTENSION pg_cron`, which only
  works in the DB named by that GUC; our `POSTGRES_DB=firecrawl` differs
  from upstream's `postgres`. Wiping that volume re-runs initdb — it must
  succeed or the API crash-loops on missing nuq tables.
- **honcho**: the image ships psycopg v3 only — DB URIs must use
  `postgresql+psycopg://`. `honcho-mcp` rejects unauthenticated requests
  and forwards the Bearer token to honcho-api, so the agent's MCP config
  carries `Authorization: Bearer ${HONCHO_API_KEY}` (emitted by `render.py`
  from `config/integrations.toml` `mcp_headers`).

### Agent runtime invariants

- **`fallback_model` IS wired — as `fallback_providers`.** `render.py`
  renders a profile's `fallback_model` tier into the `fallback_providers`
  chain that `hermes_cli/fallback_config.get_fallback_chain` reads, which the
  agent's provider init and the cron setup both consume: Hermes walks the
  chain, in order, when the primary fails with rate-limit, overload or
  connection errors. The entry carries only what the resolver reads —
  `provider`, `model`, `base_url`, and `key_env` (the credential is named by
  env var and read through the active profile's secret scope; an inline
  `api_key` would put a key in a config file, which this stack never does).
  A profile can contribute entries of its OWN via `[config_extra]`
  `fallback_providers`; those are tried first, then the declared tier.
  Note what this does NOT cover: a model that answers but answers badly.
  Failover is for transport/rate-limit failures, so escalating for quality is
  still manual (`/model smartest`, or `claude --model smartest`).
- **The agent's BUILT-IN Honcho *toolset* is gone from this agent
  version** (the `honcho` toolset was removed — Honcho IS the memory
  provider plugin). What exists now: `render.py` ships `honcho.json`
  (`{"enabled": true, "baseUrl": "http://honcho-api:8000"}`) in every
  profile overlay, which activates the **Honcho memory-provider plugin**
  (`plugins/memory/honcho`, driven by `memory.provider: honcho` in the
  rendered config) against the stack's self-hosted instance — Honcho
  reaches the agent as the memory provider AND through MCP
  (config/integrations.toml). The `apiKey` falls back to env
  `HONCHO_API_KEY` (present in every container's env; only honcho-mcp
  enforces it). The same `honcho.json` is what the memory-UI dashboard
  plugin reads (see §"Dashboard + the memory-UI plugin"). If a
  future HERMES_REF ever reintroduces a built-in honcho *toolset*
  integration that auto-enables from `HONCHO_API_KEY` and fails against
  the hosted API ("Invalid API key") with dead `honcho_*` tools on the
  surface, that is the failure mode to re-suppress — by flipping the
  rendered `honcho.json`'s `enabled` to false, not by removing the
  credential.
- **Tool search must stay on** (`[config_extra.tools.tool_search]`
  `enabled = "on"` in profile.toml): honcho+firecrawl MCP ship 66 tool
  schemas ≈ 18k tokens — on a small context window that pins every turn
  past the 50% compaction threshold before any history exists. tool_search
  (progressive disclosure) defers MCP schemas behind
  `tool_search`/`tool_describe`/`tool_call` bridges; core built-in tools
  never defer. `config/models.toml` states each TIER's TRUE provider window
  explicitly (Hermes' catalogue probe can't resolve IDs through the litellm
  base_url and falls back to 256k for everything — verify the actual model
  via `POST ollama.com/api/show` → `model_info.*.context_length`, or
  `mise run check-model-windows`). It is the window of whatever backend
  currently serves that tier, so **it is in lockstep with
  `config/litellm.yaml`**: repoint a tier at a differently-windowed model
  there and this value moves in the same change. Never set it below the
  provider's: v2026.9.14 hard-rejects anything under 64K
  (`MINIMUM_CONTEXT_LENGTH` raise in `agent/agent_init.py` — render.py now
  fails the build on it, so that lands at build time, not container start).
  `render.py` also fails the build when a tier has no matching `model_name`
  group on the gateway, which is the one way this indirection fails
  silently otherwise. It emits every tier into the rendered config's
  **`model_overrides`** block — the upstream key for per-provider+model
  windows, which `agent/model_metadata.get_model_context_length` consults
  at resolution step 0b, ahead of every probe and the 256k fallback
  (verified live against the running image). That makes `models.toml` the
  one source of truth for all three consumers: the profile's own model
  (`model.context_length`), the cheap lane / auxiliary models / any `/model`
  switch (`model_overrides`), and the `claude` wrapper's
  `CLAUDE_CODE_MAX_CONTEXT_TOKENS` (below). Declare a TIER there before
  using it — an undeclared window is not guessed.
- **Multiplexing boot noise is benign**: with `GATEWAY_MULTIPLEX_PROFILES`
  on, the tool registry's availability check_fns probe at gateway boot
  before any profile secret scope exists and fail closed with
  `UnscopedSecretError` — three WARNING tracebacks (discord tool /
  homeassistant / web_api) per start, purely log noise. Real turns run
  scoped and re-probe (tools are not lost). Only worry if the warning
  appears on a turn AFTER startup — that would be a genuine lost-scope
  case.
- **render.py stamps `_config_version`** into every rendered config.yaml,
  derived at build time from the base image's `DEFAULT_CONFIG` (render runs
  under the image's own venv `python3`, so `hermes_cli` imports there).
  Without the stamp the schema reads as 1 and the Docker boot-time
  migration (`scripts/docker_config_migrate.py`, whose check lacks the
  CLI's fresh-minimal-config carve-out) warns the config "predates version
  12" on every boot. The resolver still reads the legacy `custom_providers`
  list form at read time, so stamping never changes resolution.
- **Volume ownership is self-healed by the entrypoint** (`chown -R` to the
  runtime UID before its first privilege drop) — upstream's stage2 chown
  only runs after our wrapper's exec, so an unwritable volume would kill
  the wrapper first. Don't remove that chown.

### Discord

Enabled by the mere presence of `DISCORD_BOT_TOKEN` in the env
(gateway/config.py `_apply_env_overrides` — config.yaml carries no platform
state, so the render's `platforms` list only documents/env-examples the
vars). The bot MUST have "Message Content Intent" AND "Server Members
Intent" toggled in the Discord developer portal — the adapter requests both
and discord.py refuses to connect without them. `DISCORD_ALLOWED_USERS`
(comma-separated user IDs; usernames also work, resolved via the Members
intent) gates who the bot answers; empty = anyone who mentions it.
`DISCORD_REQUIRE_MENTION` defaults true (responds to @mentions and DMs
only). The entrypoint syncs the mounted env file into `$HERMES_HOME/.env`
on every boot (the runtime user can't read the root-owned host mount) and
loads that volume copy with `override=True` — the mounted file is the
source of truth; runtime writes to `$HERMES_HOME/.env` last only until the
next container restart.

- **Team channels go in the NESTED `[config_extra.platforms.discord.extra]`
  block, never the top-level `discord:` form — the nesting is
  load-bearing, not style.** The public top-level form is translated by the
  plugin hook (`adapter.py` `_apply_yaml_config`) into process-global
  `os.environ` values, first-writer-wins, and all four profiles share one
  gateway process under `GATEWAY_MULTIPLEX_PROFILES` — so a public-form
  write leaks to any profile that doesn't set the same key itself. The
  whole mention/threading family behaves this way (`require_mention`,
  `thread_require_mention`, `bots_require_inline_mention`, `auto_thread`,
  `reactions`, `history_backfill`, `history_backfill_limit` are all
  env-bridged without the `_skip_env_bridge` guard #72348 added for the
  channel/allow gates); the nested key reaches `PlatformConfig.extra`,
  which `_discord_require_mention` reads FIRST.
- Each team profile sets, in that nested block,
  `allowed_channels = ["<its channel id>"]` + `require_mention = false`, so
  its bot answers every message in its own channel with no @mention — and
  nowhere else. The default profile sets the same pair for `#hermes` +
  `#hermes-home` (the unrouted channels; their ids come from
  `DISCORD_CHANNEL_MAIN` and `DISCORD_HOME_CHANNEL`). `allowed_channels` is load-bearing
  (require_mention is profile-wide, so without the fence the bot would
  answer in every channel it can see) and does NOT widen authorization —
  `DISCORD_ALLOWED_USERS` stays the gate; `_is_allowed_user` falls back to
  channel-scoped access only when no user/role allowlist exists.
- Deliberately NOT `free_response_channels`: a free-response channel sets
  `is_free_channel`, which upstream also uses to skip auto-threading
  (`skip_thread = ... or is_free_channel`), killing the thread-per-request
  the team workflow relies on. `require_mention = false` skips only the
  mention gate.
- **Threads** work: the adapter auto-threads (`DISCORD_AUTO_THREAD`, default
  true) and the reply follows into the thread. An agent-opened thread is
  the deferred `discord` tool's `create_thread` action (`tool_search` →
  `tool_call`); agents get no send-message tool, so posting into a thread
  outside the auto-thread flow is `hermes send --to
  discord:<channel>:<thread>`. Creating one needs CREATE_PUBLIC_THREADS +
  SEND_MESSAGES_IN_THREADS *in that channel*: a channel overwrite beats the
  guild-level grant, so the invite integer carrying those bits
  (`scripts/set-team-discord-tokens.py`) is necessary but not sufficient.
  Diagnose with `python3 scripts/discord-thread-doctor.py`.
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

Skills-based, not an integration: the agent's `github-*` skills drive
`gh` CLI + git, and the image installs gh (pinned tarball — rebuild
required to bump). Both modes are env-driven from hermes-main.env; the
entrypoint re-runs the config on every start and sets a default commit
identity from `GH_GIT_NAME`/`GH_GIT_EMAIL`.

**Every profile can hold TWO credential sets: the personal App (for
bcross repos) and one org-owned App PER ORG it works with (any number of
orgs, e.g. `acmecorp-hermes-*[bot]` for an org "Acme Corp"), routed by
repo owner.**

- **GitHub App (preferred)**: `GITHUB_APP_ID` +
  `GITHUB_APP_INSTALLATION_ID` are the only GitHub vars in the env file
  (PEM at `/etc/hermes/github-app-<profile>.pem` — root:<host-group> 640,
  bind-mounted read-only at `/run/hermes-pem/`, the file must exist before
  deploy). **Every profile has its own app** (see below). The entrypoint
  copies the PEM into the runtime-owned tool-home (`$HERMES_HOME/home/`)
  and exports `GITHUB_APP_PRIVATE_KEY_PATH` itself — the env file never
  names the path, because s6 services couldn't read the host mount anyway.
  Installation tokens last 1h, so git's credential helper routes through
  gh's own stored token (`gh auth git-credential`), and a background
  refresher re-runs `gh auth login --with-token` every 30 min. Hermes'
  skills hub has native app support too (tools/skills_hub.py `GitHubAuth`,
  priority PAT → gh → app).
- **Org Apps**: `GITHUB_APP_ID_<ORG>` / `PROFILE_<NAME>_GITHUB_APP_ID_<ORG>`
  (plus `_INSTALLATION_ID_`, `_GH_GIT_NAME_`, `_GH_GIT_EMAIL_` org-suffixed
  variants) declare the org set; PEMs install as
  `/etc/hermes/github-app-<orgslug>-<profile>.pem` (no compose change —
  the whole env dir is mounted at `/run/hermes-pem`). The entrypoint
  syncs each tool-home's NON-secret descriptor
  `<tool_home>/org-creds/<orgslug>.env` + PEM copy (one descriptor per
  org, discovered from the env vars themselves — the entrypoint handles
  any number of orgs with no per-org code) — the helpers read
  files, not env, because Hermes strips credential env vars from tool
  subprocesses (GHSA-rhgp-j443-p4rf). Org token minting is lazy + cached
  (`gh-org-token`, ~45-min cache in `org-creds/<slug>.token`); a boot
  mint per org per profile fails loudly. An org with ids but no
  installation id or no PEM is skipped with a boot warning.
- **Routing**: `/usr/local/bin/gh` is a SHIM (real binary `gh-real`) that
  picks the org token when `-R`/cwd resolves to an owner with a
  descriptor — `gh auth *` and `GH_TOKEN`-set calls always pass through.
  git's single credential helper is `git-credential-hermes.sh`
  (`credential.https://github.com.helper` + `useHttpPath=true`): org
  remote → org token; otherwise it replays the request into
  `gh auth git-credential` (personal, unchanged). useHttpPath=true is
  load-bearing — without it git sends no path and the router cannot see
  the owner (verified against git 2.54; per-URL credential config keys
  were rejected because git's urlmatch path compare is case-sensitive
  while GitHub owners are case-insensitive).
- **Commit identity**: org worktrees commit as the org bot —
  `git-repo.sh worktree` sets `user.name`/`user.email` in the worktree's
  own `config.worktree` (needs `extensions.worktreeConfig`, which it
  enables idempotently; without it the config would land in the bare
  repo's common config and leak across sessions).
- **PAT fallback**: `GH_TOKEN` authenticates gh natively; git routes through
  `gh auth git-credential`. Prefer a fine-grained PAT scoped to the
  specific repos (Contents/Issues/Pull requests read+write).

### Security tuning (guard friction)

This stack's agents live in `terminal`, and two guard behaviours blocked
the script-shaped work we *want* them to do, so both were loosened
deliberately.

1. **`tools/approval_detection.py` source patch** (was
   `tools/approval.py` before v2026.9.14) — `docker/hermes/patches/`,
   applied
   in the Dockerfile with `git apply` (the base image has no `patch`
   binary; `git apply` works outside a repo, which matters because
   `.dockerignore` drops `.git`). Upstream hardline-blocks any command
   whose grep-operand scanner surfaces a word it cannot tokenize — which
   happens whenever `grep` appears inside a quoted `$(...)` (the very
   common `sed -n "$(grep -n 'x' f | cut -d: -f1),+45p" f` shape). The
   block is unconditional (no `--yolo`, approval mode, or
   `command_allowlist` reaches it) and it was the single largest source of
   blocked calls, every one a false positive. The patch skips an
   unparseable operand instead of failing the whole command, and is
   fail-closed: skipping only declines to *mask* text as data, and the
   hardline path discards the masked variant anyway. **Deleting it later
   is signalled by the build** (see the HERMES_REF checklist).
2. **Tirith pre-approvals, config only — Tirith itself stays ON.**
   `render.py` seeds `command_allowlist` with `tirith:<rule_id>` keys for
   every profile. `approval_detection.py` loads that list at *module import*, and a
   Tirith finding's approval key is `tirith:<rule_id>`, so listing a key
   permanently auto-approves that one rule. The twelve seeded rules are the
   ones that actually fired on this stack's own legitimate work (mined from
   the live tirith audit log, Sep 2026):
   `analysis_incomplete` (the `$(...)` / dynamic-command shape),
   `plain_http_to_sink` (our internal HTTP services),
   `mass_file_deletion` (worktree/build churn), `curl_pipe_shell`,
   `pipe_to_interpreter`, `blast_find_delete`, `trailing_dot_whitespace` +
   `schemeless_to_sink` (cosmetic findings on benign compound commands like
   `cd /opt/data/mach && go build ./...`), `data_exfiltration` (the
   komodo-ops skill's internal-API POST shape),
   `interpreter_suspicious_inline_exec` (`python -c`), `lookalike_tld`
   (go.dev), `archive_extract`. `tirith:mass_file_deletion` is the most
   aggressive inclusion and the first to drop if the ransomware-shaped burst
   check is wanted back — the unconditional hardline floor still blocks
   `rm -rf /` either way. Deliberately NOT seeded: `credential_file_sweep`
   and `sensitive_env_export` (reading credentials / exporting secrets stays
   gated), and hermes' own recursive-delete pattern (rm -rf prompts stay as
   the safety net; a prompt with an "Always" option is click-once-per-host).
   Extend by hand from `tirith audit stats --format json` → `top_rules`. Note
   `approvals.mode` is the default `smart`, so heredoc / `-e -c` patterns
   already auto-approve; only Tirith's HIGH/CRITICAL findings were
   demanding a human. Render.py also raises `auxiliary.approval.timeout`
   to 60s stack-wide (upstream default 30s, retried once): smart approval's
   aux call goes through litellm → Ollama Cloud, and when that call times
   out twice the gate escalates to a human button even though the model
   would have approved — the model's latency, not its verdict, was deciding.

### Dashboard + the memory-UI plugin (both shipped DISABLED)

The official image already carries a web dashboard as an s6 service
(`docker/s6-rc.d/dashboard/{run,finish}` — same always-declared, env-gated
shape as this stack's chromium-cdp slot) and a plugin system. Both are
deployed here but OFF; flipping either on is a config/env change with no
rebuild. The dashboard is PRIVILEGED — it edits `.env`, serves config and
session APIs, and can restart the gateway — which is why the plumbing is
shipped but the defaults are inert.

- **Enablement contract.** `HERMES_DASHBOARD=1` in the container
  environment is the only gate (no config.yaml enable key); bind is
  `HERMES_DASHBOARD_HOST=0.0.0.0` in-container (Docker port publishing
  needs it; also the upstream default) and the port publishes as
  `127.0.0.1:${HERMES_DASHBOARD_HOST_PORT:-9119}:9119` — host loopback
  only, like firecrawl's API. The real boundary is upstream's fail-closed
  auth gate (a non-loopback bind REQUIRES an auth provider —
  `HERMES_DASHBOARD_INSECURE=1` is accepted but ignored, June 2026
  hardening) plus the loopback publish. **The flag lives ONLY in the
  stack environment** (`komodo/resources.toml` hermes-agents
  `environment`, mirroring mise.toml [env] locally): compose
  `environment:` overrides env_file, so setting `HERMES_DASHBOARD` in
  `hermes-main.env` is a dead value — the #1 operator mistake here. The
  host-side port var is deliberately `HERMES_DASHBOARD_HOST_PORT`, NOT
  `HERMES_DASHBOARD_PORT` — the upstream name is the CONTAINER-side
  listen port and would break the mapping.
- **Auth.** Basic auth (`HERMES_DASHBOARD_BASIC_AUTH_USERNAME/_PASSWORD/
  _SECRET` in `/etc/hermes/hermes-main.env`; templates and generation
  commands in `secrets/hermes-main.env.example`) with an optional OIDC
  block. **Flipping the flag on without the three basic-auth vars fails
  closed**: `start_server` errors at startup and the dashboard s6 slot
  restart-loops — the rest of the container is unaffected, and the
  symptom is repeated `[dashboard]` startup errors in `docker logs
  hermes-main`. Set the credentials BEFORE flipping the flag.
- **The no-rebuild flip procedure**: (1) fill the three auth vars in
  `/etc/hermes/hermes-main.env`; (2) set `HERMES_DASHBOARD = "1"` in
  komodo/resources.toml (locally: mise.toml [env]); (3) Resource Sync +
  DeployStack — the image is unchanged, this is recreation only; (4)
  verify (checklist below). Reverse = set back to `"0"`.
- **The memory-UI plugin is vendored, seeded, and GitOps-owned.**
  `xraysight/hermes-memory-ui` (read-only Memory inspection UI: built-in
  MEMORY.md/USER.md + provider sections; Honcho read through each
  profile's own rendered `honcho.json` — no extra wiring) is cloned at
  BUILD time from a pinned full SHA (`ARG HERMES_MEMORY_UI_REF` in
  docker/hermes/Dockerfile; v0.6.2 =
  `97cc937e49517dbd9e55cf10717da55d9024c29c`), staged in `/tmp`, and
  installed into `/overlay/plugins/` AFTER the render (never pre-create
  `/overlay/plugins` earlier — the render's arrange loop would sweep it
  into `/overlay/profiles/plugins`). `bootstrap-profiles.sh`
  (`seed_plugins`) exact-replaces it into EVERY profile home's
  `plugins/` on every boot: a runtime `hermes plugins update` (or
  hand-edit) is overwritten next boot, and a runtime `hermes plugins
  enable` is reverted when the overlay overwrites `config.yaml` — both
  knobs are git-side. The plugin declares no capabilities and its root
  `__init__.py` is a deliberate no-op, so headless vendoring needs no
  consent prompt.
- **Enabling the plugin (config change, no code rebuild)**: add to
  `config/profiles/default/profile.toml` —
  `[config_extra.plugins]` / `enabled = ["hermes-memory-ui"]` → PR →
  cache-hit rebuild → deploy. The container recreation restarts the
  dashboard AND the gateway, which satisfies the upstream rule that
  plugin_api routes mount only at process startup (the
  `/api/dashboard/plugins/rescan` endpoint exists for hand-poked setups
  this GitOps layout doesn't need). Discovery is an opt-in allow-list —
  an absent `plugins` key enables nothing — and render.py FAILS the
  build on an enabled-but-not-vendored name
  (`STACK_VENDORED_PLUGINS`), the same fail-loud shape as the tier and
  cron-script checks. Enable it in the DEFAULT profile (the dashboard
  process runs with `HERMES_HOME=/opt/data`); per-profile data is
  selected with `?profile=<name>`, and the plugin reads each profile's
  own `honcho.json`.
- **Plugin upgrade = bump the pin in one place**: resolve the new tag
  to its full SHA (`git ls-remote https://github.com/xraysight/hermes-memory-ui <tag>`
  or the GitHub API), update `ARG HERMES_MEMORY_UI_REF` and the
  `version:` grep in the same layer, PR, merge (the clone layer onward
  re-runs; config-only pushes keep it cached). The Dockerfile's
  rev-parse assertion is the integrity check; if a build host ever
  rejects fetch-by-SHA, the comment documents the tag-clone fallback.

### Steering the profiles' working style

`config/SOUL_OPERATING.md` is appended to **every** rendered profile's
`SOUL.md` by `render.py` — one source, all four profiles. SOUL.md rides the
system prompt on every turn, unlike a skill (lazily loaded), so always-on
behaviour belongs there; the per-profile SOUL.md stays the role document.

The block covers four things:

- **Think before acting** — read the real file/config/response rather than
  reasoning from the name; pick the shape before the first call; when two
  approaches both look right, choose one and say what it traded away; and
  never report a state change that was not read back (the same rule
  `team-conventions` enforces for GitHub handoffs).
- **Turn count is the cost** — 3+ shell/file operations for one goal → **one
  call**; a chain with logic between the calls (filter, branch, loop, retry,
  reduce output before it reaches context) → **`execute_code`**; a shell
  chore (git, builds, `gh`, docker, tests) → **write a script with
  `write_file` and run it by path** — which is also the friction-free path
  past the approval guards; never inline a big payload (heredocs, giant
  one-liners, nested `$(...)` are what the scanners mis-parse).
- **Subagents** (`delegate_task`) where only the conclusion should return —
  with the freshness rule (a child knows nothing about the conversation),
  the verify-the-summary rule, and the local concurrency bound.
- **Background jobs** — `terminal(background=True, notify_on_complete=True)`
  in-session; a scheduled job only for work that outlives the session, and
  then self-cleaning.

Why the scripting half was needed: the terminal tool's own description
steers work *away* from shell ("do NOT use cat/head/tail — use read_file,
grep/rg/find/ls — use search_files, sed/awk — use patch"), which turns one
shell pipeline into three or four separate tool calls, one turn each.
`execute_code` is the tool built to collapse exactly that and was underused
relative to that baseline.

### Delegation + background jobs (enabled 2026-09-15)

`delegation` and `cronjob` were removed from the three team profiles'
`agent.disabled_toolsets`; the default profile already had both. Their
fences said "teammates are dispatched via GitHub self-pull queues" and
"digests run as scheduler jobs in the default profile" — which left the
team roles with no way to reason in fresh context or to watch something
over time.

- **Bounds are stack-wide**: `STACK_DELEGATION_DEFAULTS` in `render.py`,
  merged into every profile's top-level `delegation:` block exactly like
  `STACK_CRON_DEFAULTS` / `memory` / `auxiliary`, and overridable per
  profile via `[config_extra.delegation]`. Values:
  `max_concurrent_children: 2`, `max_spawn_depth: 1` (flat — children are
  leaves), `worktree_isolation: false`.
- **Check upstream defaults against the CODE, not the prose.** In
  `hermes_cli/config_defaults.py::DEFAULT_CONFIG["delegation"]`,
  `max_concurrent_children` defaults to **10** (upstream's own
  `tools/AGENTS.md` says 3 and the website says 3 — both wrong), and
  `worktree_isolation` is not a default key at all. Re-verify at a
  HERMES_REF bump; the docs have been wrong on both counts.
- **`worktree_isolation` must stay OFF here.** It assumes a plain clone, but
  agents already work in a per-session worktree: the child's worktree nests
  at `<session-worktree>/.worktrees/subagent-<id>`,
  `_ensure_gitignore_entry()` appends `.worktrees/` to the SESSION
  worktree's own `.gitignore` (dirtying the parent's tree, where the next
  commit can sweep it in), and the child's branch lands in the SHARED
  central object store rather than staying session-scoped.
- **A child inherits the parent's `disabled_toolsets`**
  (`delegate_tool_toolsets.py`), so a profile fence is also a child fence —
  and `delegation` in that list removes `delegate_task` from the profile
  *and* from every child it could spawn. A child can never gain a
  capability the parent lacks: the schema has no `toolsets` parameter and
  `_build_children` hardcodes inheritance. Leaf children additionally lose
  `clarify`, `memory`, `send_message` and `cronjob_manage`, so a subagent
  can never schedule or ask a human.
- **`cron.allow_agent_scheduling` stays at its default (false)** — it gates
  only whether an agent *running inside* a cron job receives the `cronjob`
  toolset (`cron/scheduler.py::_resolve_cron_disabled_toolsets`, loop
  prevention). It does NOT gate the tool in a normal gateway session, so
  `agent.disabled_toolsets` remains the reliable stack-side fence. Do not
  "fix" a cron-job-cannot-schedule report by flipping it.
- **Agent-created jobs are self-cleaning by policy** (SOUL_OPERATING + the
  skill): a job an agent creates removes itself once its condition
  resolves; a *persistent* watchdog must be declared in `config/cron.toml`
  via a PR instead. Names prefixed `team: ` stay the reconciler's alone, so
  nothing an agent creates is ever pruned for it — which is exactly why it
  must clean up after itself.
- **`claude` (Claude Code) is documented for every profile, not just
  developer.** The wrapper was always on PATH for all of them (symlinked at
  `/opt/data/bin/claude`, model resolved from each profile's own
  `$HERMES_HOME/config.yaml`), but the usage instructions lived only in
  `team-developer`. The canonical contract now lives in the stack-wide
  `hermes-stack-ops` skill, with a "writing code → `claude`" entry in the
  SOUL_OPERATING shape ladder, so planner and reviewer reach for it too.
  The role split is the part that matters: `claude` writes code,
  `delegate_task` reasons in fresh context, `execute_code` does mechanical
  bulk.
- **The wrapper tells Claude Code the real context window (2026-09-15).**
  It exported `ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN` and pinned the
  model, but never `CLAUDE_CODE_MAX_CONTEXT_TOKENS` — and Claude Code's
  own model catalogue describes none of the tier names, so it assumed
  **200k** and would auto-compact a 1M-context session five times too
  early (its own stderr said so: "auto-compact keeps this session within
  200k tokens (the context window it assumes)"). The wrapper now resolves
  the window for the model that actually runs — a caller's `--model` wins
  over the profile's primary, for the window as well as the model, so the
  two can never disagree — from `model_overrides`, which `claude-model-
  resolve.py --window` reads out of the same rendered config that supplies
  the model. A window the config does not declare is left **unset** rather
  than guessed: compacting early is wasteful, claiming a window the
  provider does not have overruns it. Verified live on the host: the
  200k warning is present on a stock invocation and absent through the
  wrapper, and `--model smartest` correctly yields 1048576 while `smart`
  yields 262144. The `unrecognized_model` stderr line
  survives (it is about the catalogue, not the window) — still cosmetic.
  What the wrapper DOES hardcode is the gateway itself: it refuses to run
  unless `model.provider` is `litellm` and posts to `http://litellm:4000`.
  Backends change behind the gateway and need nothing here, but renaming
  that provider in `providers.toml` or moving its base_url is also an edit
  to `docker/hermes/claude` — otherwise it degrades to stock claude, which
  then fails on missing Anthropic auth.
- **The Claude Code installer had to be rewritten (2026-09-15).** Since
  the 2.1.x cutover `@anthropic-ai/claude-code` is no longer a CLI bundle:
  the wrapper package ships `install.cjs` + a `bin/claude.exe` stub, and
  the ~230 MB native binary lives in a per-platform package
  (`@anthropic-ai/claude-code-linux-arm64`, `libc: ['glibc']`,
  `package/claude`) that its postinstall copies over the stub.
  `claude-update.sh` and `claude-provision.sh` both fetched
  `package/bundle/cli.js` from the wrapper tarball — a path that stopped
  existing — so **every** install failed, boot included, and `claude-real`
  was frozen at 2.1.267 (Sep 9). Both now resolve the platform package
  themselves (`uname -m` → arm64/x64, musl probed via
  `/lib/ld-musl-*.so.1`), extract `package/claude` onto the volume, run it
  for `--version`, and only then rename it over `claude-real`. Verified
  live: 2.1.100-stub → 2.1.273 in 19s, and a forced failure printed to
  stdout, exited 1, and left the previous binary intact. The install
  failure had also been **invisible by construction** — message on stderr,
  `exit 0` — which the new scripts fix; see the cron section below.

## Agent self-management (skills + control-plane access)

Skills ship in two tiers — **stack-wide** (`config/skills/`, merged into
EVERY rendered profile by render.py) and **per-profile**
(`config/profiles/<name>/skills/`, same-named skills win over the
stack-wide ones). Currently: `hermes-stack-ops`, this stack's operating
manual for the agents themselves (config is GitOps-rendered, never
hand-edit `/opt/data/config.yaml`; LiteLLM is the only LLM path; GitHub App
usage; central git repos + per-session worktrees; Discord gotchas;
small-host constraints; cron/kanban availability), and `komodo-ops`,
per-profile in the default profile — it drives the Komodo API from inside
the container at `http://komodo-core-1:9120` (komodo-core joins the
external `hermes_net` network, per the komodo repo's compose) with the auth
header bind-mounted read-only at `/etc/komodo-auth-header` (host path
`/home/ubuntu/.komodo-auth-header`, overridable via the stack `environment`
var `KOMODO_AUTH_HEADER_MOUNT`). **That mount is not readable by the agent**
— it is 600 and owned by the host user while the s6 services run as UID
10000, so `-H @/etc/komodo-auth-header` dies with `curl: option -H: error
encountered when reading a file` and reads to an agent as "the API key is
broken" (it is not; check with `sudo` on the host before touching the key).
The entrypoint does for this what it does for the App PEMs — copies it into
the runtime-owned home on every boot (`$HERMES_HOME/home/komodo-auth-header`,
600) — and `KOMODO_AUTH_HEADER` is the var to use: `-H @$KOMODO_AUTH_HEADER`.
Default profile only, deliberately: `komodo-ops` is its skill and the
control-plane credential is not copied into the team profiles' homes. The
Komodo API key itself is created in the UI and, as of this writing, does not
expire (`expires: 0` — verify with `read/ListApiKeys`).
**The var is declared in compose, not exported by the entrypoint**, and that
distinction is load-bearing: s6-overlay starts services from
`/run/s6/container_environment`, so an `export` in the entrypoint is invisible
to the gateway and to every tool subprocess (it looked correct, logged
correctly, and reached nothing — verified by reading the gateway process's
environment). Config belongs in the container `environment:`, files belong in
the entrypoint. It can deploy stacks, run builds,
and re-apply the resource sync — but NOT change control-plane resources
(that's the komodo repo, human-reviewed via push).

### Central git repos + per-session worktrees

All git repos live in ONE central store on the shared volume — a bare clone
per repo at `/opt/data/repos/<host>/<owner>/<repo>.git`. Nobody works in
the bare repos and no profile/session clones privately; work happens in
per-SESSION worktrees under `/opt/data/worktrees/<session-slug>/` (the slug
comes from `HERMES_SESSION_KEY`, bridged into every tool subprocess — one
messaging session = one slug, stable across its turns). The `git-repo.sh`
helper (baked at `/usr/local/bin/git-repo.sh`) manages both: `ensure`
(idempotent bare clone), `worktree <url> [branch] [dest]` (session
checkout; auto-creates a session branch `s/<slug>` when the requested
branch is checked out elsewhere), `list`, and `prune --days N` (drop
session dirs idle > N days, then `git worktree prune` — run weekly via
`docker/hermes/prune-repos.sh`, scheduled as a no-agent cron job; and the
`fetch` sweep that keeps the local branch mirrors current runs daily via
`docker/hermes/refresh-repos.sh`). Both live in `docker/hermes/` because
they are cron JOB scripts — `render.py` validates a declared job's script
against that directory, and the reconciler seeds it from
`/usr/local/bin/`. Overrides:
`HERMES_REPOS_DIR` / `HERMES_WORKTREES_DIR`. Everything is
runtime-uid-owned, so every profile reaches the same store; git's worktree
model provides the isolation (one branch, one checkout).

## Provisioning per-profile identities (GitHub Apps + Discord bots)

Every profile has its OWN bot identity in both GitHub and Discord — the
team roles must be distinguishable from one another and from the main
agent, and must never share or impersonate another's. Both halves need one
manual step that no API can perform; the scripts in `scripts/` wrap
everything around them.

Inventory (one App and one Discord bot per profile):

| Profile | GitHub App (default name) | Discord bot |
|---|---|---|
| default | `hermes-main` | Hermes Main |
| planner | `hermes-planner` | Hermes Planner |
| developer | `hermes-dev` | Hermes Developer |
| reviewer | `hermes-reviewer` | Hermes Reviewer |

The App names above are the DEFAULT (`<prefix>-<role>`); override per profile
with `PROFILE_<NAME>_GH_APP_NAME` — GitHub App names are globally unique, so a
collision is fixed that way. App ids and installation ids do not exist until
you create the Apps: `scripts/create-github-apps.py` prints the `PROFILE_*`
lines to paste into the env file.

Installation IDs, git identities, and bot tokens live in
`/etc/hermes/hermes-main.env` as `PROFILE_<NAME>_*`. App and bot IDs are
not secret, but **PEMs and bot tokens are**: never echo them, never commit
them, and route them through the scripts below rather than a shell history
or a chat transcript.

- **GitHub App for a new profile** (`scripts/create-github-apps.py`): GitHub
  has no API to create an App and `gh` cannot do it; the App Manifest flow
  is the only automatable path and needs the account owner's browser. The
  script serves the manifest from a local HTTP server, auto-submits it to
  `github.com/settings/apps/new`, catches GitHub's redirect, and exchanges
  the temporary code for the App's id + private key — its `setup_url`
  catches the post-install redirect so the installation id is captured
  without anyone reading it off a URL. Two clicks per app: **Create GitHub
  App**, then **Install** with "All repositories". Run
  `python3 scripts/create-github-apps.py [profile ...]` where the browser
  is (default: the 3 team profiles). Artifacts land in gitignored
  `build/github-apps/` (PEM mode 600, `results.json`, `env-lines.txt`,
  `host-install.sh`); then on the host run `host-install.sh` (installs each
  PEM as root:<host-group> 640 into `$HERMES_ENV_DIR/`) and append `env-lines.txt` to
  `/etc/hermes/hermes-main.env`. Re-running is safe — an existing App name
  fails at GitHub's own name check before anything is created.
- **Org Apps** (`create-github-apps.py --org <ORG>`): same flow, but the
  manifests POST to the org's settings URL (browser must be logged in
  with admin on the org) and EVERYTHING lands in
  `build/github-apps/<orgslug>/` with org-slug'd PEM names
  (`github-app-<orgslug>-<profile>.pem`, `env-lines-<orgslug>.txt`,
  `host-install-<orgslug>.sh`) — a second run can never clobber the
  personal artifacts. The org App-NAME prefix defaults to
  `<orgslug>-hermes` (e.g. `acmecorp-hermes-planner`) — deliberately
  different from the personal names, because App names are globally
  unique and the personal ones are taken; override with `--prefix` or
  `HERMES_APP_PREFIX_<ORGUC>`, per profile with
  `PROFILE_<NAME>_GH_APP_NAME_<ORGUC>`. The env lines are the
  ORG-SUFFIXED vars plus `TEAM_ORG_DEV_BOT_<ORGUC>` (the org author
  filter for the self-pull queues — add the org to `TEAM_OWNER_ORGS` to
  make the queues actually poll it). Run it ONCE PER ORG, any number of
  orgs. Pass `main` on the command line to include the default
  profile's org app — the org run for the full team is:
  `python3 scripts/create-github-apps.py --org <ORG> main planner developer reviewer`
- **Bot token for a new team profile**
  (`scripts/set-team-discord-tokens.py`, run **on the host**): prompts for
  each team bot token with hidden input (`getpass`) and validates every
  token against Discord *before* writing. It refuses a token Discord
  rejects, the main bot's token (which re-creates the
  duplicate-credential refusal), a user token, or one already entered for a
  different role. It rewrites the `PROFILE_<NAME>_DISCORD_BOT_TOKEN` lines
  in `/etc/hermes/hermes-main.env` (idempotent) and prints each bot's
  invite URL carrying the main bot's permission integer. Create the
  applications first at https://discord.com/developers/applications and
  enable **Message Content** AND **Server Members** (plus Presence, to
  match the existing bots) on each one's Bot tab. A bot token works as soon
  as the app exists, but the bot is not *in* the guild until someone
  authorizes the invite URL.

### Activating a new profile

1. Create both identities with the scripts above.
2. Land the credentials in `/etc/hermes/hermes-main.env`
   (`PROFILE_<NAME>_GITHUB_APP_ID`, `_GITHUB_APP_INSTALLATION_ID`,
   `_GH_GIT_NAME`, `_GH_GIT_EMAIL`, `_DISCORD_BOT_TOKEN`).
3. Point the profile's Discord channel at it: add a route under
   `[config_extra.gateway.profile_routes]` in the default profile's
   `profile.toml`. Unrouted channels keep the default agent's behavior.
4. Commit + deploy, then verify in the logs — the entrypoint logs
   `gh authed via GitHub App (home=…, app id=…)` per profile, and the
   gateway logs `[Discord] Connected as <bot>` plus
   `✓ discord connected (profile: <name>)`.

### Routing work to a profile: labels, never assignees

**GitHub App bot identities cannot be issue/PR assignees.** This is a
platform rule about the *assignee's* account type, not about credentials —
assigning a bot fails with 403 from any token, including the repo owner's
own user token and PAT; assigning a human works. The cheap probe is
`GET /repos/{owner}/{repo}/assignees/{login}` → 204 assignable / 404 not.
So the assignee field is unused by design and the team routes by **label**:
`status/ready` IS the handoff (planner sets it, developer claims by
swapping to `status/in-progress`). Do not "fix" this with a PAT or a
machine user. Bots *authoring* issues/PRs works fine, which is why the
reviewer leg (`gh search prs --author 'hermes-dev[bot]'`) was never
affected.

`team-queue.sh` (baked at `/usr/local/bin/team-queue.sh`) wraps the
developer's self-pull **with a loud failure mode**, because an empty search
and a broken search are indistinguishable downstream. Exit codes are the
contract: `0` healthy (work or a genuine `QUEUE EMPTY`), `2` query failed,
`3` blind search (token or scope), `4` nothing carries the `hermes-team`
topic, `5` an onboarded repo is missing the routing label. **2–5 are
incidents to surface, not idle states.** Grep new skills for the colon
form before shipping them — `--flag:value` does not exist in gh search
syntax; it is `--flag value`.

## Scheduled jobs are GitOps-declared (`config/cron.toml`)

Every cron job is declared in **`config/cron.toml`**, rendered per profile
by `render.py` into `<overlay>/cron.json`, and reconciled into that
profile's cron store at container boot by `docker/hermes/cron-reconcile.py`
(invoked from `bootstrap-profiles.sh`). Hand-creating a job with
`hermes cron` is the same mistake as hand-editing `/opt/data/config.yaml`:
it survives until the next boot, then the reconciler overwrites it.

- **The store is runtime state, so it is reconciled, never copied.**
  `$HERMES_HOME/cron/jobs.json` holds run history, failure streaks,
  `next_run_at` and per-job notepads — overwriting it from the image on
  each deploy would reset all of that, so the reconciler drives the
  `hermes cron` CLI to create/edit in place. A job whose stored config
  already matches the declaration is left completely untouched.
- **`hermes cron create` exits 0 even when it fails** (it prints
  `Failed to create job: …` on stdout). The reconciler therefore verifies
  every create/edit/prune by **reading the store back** and reports a
  failure when the change did not land. A status code is not evidence.
- **Matching is by name**, which is why `render.py` rejects duplicate
  `(profile, name)` pairs at build time — a duplicate would edit the wrong
  job. Names are namespaced `team: `; `--prune` only ever removes that
  prefix, so a job an AGENT created for itself is never deleted.
- **Job scripts are validated against `docker/hermes/` at build time.** A
  `no_agent` job whose script is missing is "unrunnable", and the scheduler
  **auto-pauses** it at the first tick — so a typo'd script name fails
  `mise run validate` instead of becoming a dead job in production. At boot
  the script is seeded from `/usr/local/bin/` into `<profile>/scripts/`
  (the scheduler refuses a script outside `$HERMES_HOME/scripts`), chowned
  to the profile home's owner when boot runs as root — a root-owned scripts
  dir is unwritable to the ticker, which would create the job and then
  never fire it.
- Deleting a job from `config/cron.toml` DOES take effect: an empty spec
  still runs the prune pass, so removal is not the one edit that silently
  never applies.
- **Delivery targets, and the two kinds of job.** The declared jobs split
  by what should happen when they speak:
  - `deliver = "bot-chat:<profile>"` — **wake that profile's agent** with
    the output as a message it responds to. For handovers (the two
    self-pull queues). ALWAYS name the profile — see below.
  - `deliver = "discord:<chat_id>"` — **post into a channel** as the
    owning profile's bot. Used by the three housekeeping jobs
    (`team: claude code update` 04:37, `team: weekly worktree prune`
    Mon 05:00, `team: daily repo refresh` 06:00), which report to
    **#hermes-home** (`DISCORD_HOME_CHANNEL`): there is no decision for an
    agent to make, so waking one would be a wasted turn. This is an
    OUTBOUND send — the "the adapter drops the bot's own messages" rule
    that rules out bot-chat-by-Discord is about INBOUND delivery, so it
    does not apply here.
  - `deliver = "local"` — save, deliver nothing. `origin` is meaningless
    for a job declared here (there was no originating chat).
  - All three housekeeping jobs are **silent when healthy** (empty stdout
    = no message), and all three **exit non-zero on a real failure**, so
    the scheduler's own deduped failure notice reaches #hermes-home.
- **A job script's diagnostics belong on STDOUT, and a failure must exit
  non-zero.** A `no_agent` job delivers stdout verbatim and **discards
  stderr**, so a failure printed to stderr is a failure nobody sees — and
  `exit 0` on top of it makes the run record `ok`, which is how
  `claude-update.sh` reported success every day for weeks while
  `claude-real` sat frozen at 2.1.267 (see "Claude Code" below).
- **`DISCORD_HOME_CHANNEL`** — set to your `#hermes-home` channel id — (in
  `/etc/hermes/hermes-main.env`; template in
  `secrets/hermes-main.env.example`) points the *gateway's own* system
  messages at the same channel — restart/shutdown notices
  (`PlatformConfig.gateway_restart_notification`, default true), the
  connect-time warning, and any job delivered with `all`/`home` routing.
  Setting `home_channel` from env is not part of the env-bridged
  mention/threading family that leaks across profiles under
  `GATEWAY_MULTIPLEX_PROFILES`, so it does not touch the team channels'
  `allowed_channels`/`require_mention` fence.
- **The three housekeeping jobs were once hand-seeded, un-prefixed, and
  undeclared** (`claude-code-update`, `weekly git worktree prune`, `daily
  central repo refresh`, all `deliver = origin`). That is the failure mode
  this whole section exists to prevent: they survived only in the default
  profile's store, `claude-update.sh` was not even in the image's
  `/usr/local/bin` seed set, and a volume rebuild would have lost all
  three silently. They are now declared above, `team: `-prefixed (so
  `--prune` owns them), and their scripts are in the Dockerfile's COPY
  list — which is the complete set of conditions for a job to be
  recreatable from the repo alone. Verified by `mise run render`:
  `build/default/cron.json` carries all three.
- **The self-pull jobs are `no_agent` scripts, deliberately.** A
  `no_agent` job delivers its script's stdout verbatim and **empty stdout
  is silent** — no message, no agent turn, no tokens. That is what makes a
  5-minute poll affordable: the poll is free and the agent wakes only when
  there is work. Incidents are printed **once and then deduped** via a
  state file, so a persistent fault wakes the team a single time instead of
  every tick.
- **`deliver` must NAME the profile (`bot-chat:<name>`).** Bare `bot-chat`
  is documented as "the job's own profile", but on this stack the delivery
  spawns `hermes chat` with no profile argument, the child inherits the
  firing scheduler's `HERMES_HOME` — and under `GATEWAY_MULTIPLEX_PROFILES`
  every profile's ticker shares the gateway process, whose `HERMES_HOME` is
  the DEFAULT profile. `bot-chat:<name>` passes `-p <name>` **and drops
  `HERMES_HOME` from the child env**, so the turn really runs as the named
  profile.
- **The bot-chat delivery timeout is raised to 3600s stack-wide**
  (`render.py` → `cron.bot_chat_delivery_timeout_seconds`). A bot-chat
  delivery runs a full agent turn synchronously inside the job's execution,
  and the upstream default of 600s does not merely warn — on expiry the
  child is KILLED mid-turn. Holding the execution open also serialises the
  5-minute poll against a running turn, so the next tick cannot stack a
  second wake on work already in flight.
- `GH_TOKEN` is absent from a cron script's environment (subprocess env is
  credential-stripped by design) — that is fine, because the profile's `gh`
  is already logged in as its own App installation
  (`/opt/data/profiles/<name>/home/.config/gh/hosts.yml`).
- **The queues are resume-first, and that is load-bearing.** The self-pull
  defaults to `status/in-progress` THEN `status/ready` (and
  `review/in-progress` THEN `review/ready`), because a cron job passes no
  arguments to its script, so the default IS the behaviour. An item a
  profile already claimed is its own unfinished work — an interrupted turn
  (a deploy restart, a timeout) leaves it claimed, hence no longer `ready`,
  hence invisible to a ready-only queue, and the work would sit half-done
  forever. In-flight first means a restart resumes rather than orphans. The
  worktree makes that cheap: the session slug is stable across cron wakes,
  so the interrupted turn's branch and uncommitted changes are still on
  disk under `/opt/data/worktrees/`.
- **Work-item Discord threads (`team-thread.sh`).** One thread per work
  item, in the calling profile's own channel, kept open until the PR is
  **merged**. Auto-threading only fires on inbound Discord messages, so the
  thread is created explicitly rather than inherited. The mapping is
  persisted under `$HERMES_HOME/cache/threads/` because each cron wake is a
  fresh session with no chat context. Lifetime is enforced by
  `team-thread.sh sweep`, called from the queue script (token-free, no
  agent turn): the merge closes the issue (`Closes #N`), and sweep turns
  "issue closed" into "thread archived" — a thread cannot be stranded open
  just because the agent never woke again. The bot token and channel are
  derived from the profile's own `$HERMES_HOME`, so each role posts as its
  own bot; threads are owned by the bot that created them, which is why
  each profile sweeps its OWN.

## Local development (this repo)

Local runs use **mise** (not Makefile): `mise run up`, `mise run logs`,
`mise run chat`, `mise run down`, `mise run validate`, `mise run check-updates`.
`mise.toml [env]` holds the version pins and `HERMES_ENV_DIR`; per-machine
overrides go in gitignored `mise.local.toml`.

After editing anything in `config/`, push a branch and open a PR (see the
deployment model above — `main` is protected) — the Docker build runs
render.py itself, so there is NO committed `build/` output to keep in sync
(the old "commit the build/ output" step is gone). To
preview a render without building: `mise run render` (writes ./build/,
gitignored, never committed). Note: local compose runs get a project named
after the parent dir, not `hermes` — the Komodo deployment on the host is
the real one.

## Verification checklist (after any deploy)

```bash
docker ps --format '{{.Names}}\t{{.Status}}' | grep -E 'hermes|honcho|firecrawl|ollama'
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3002/v0/health/readiness   # 200
docker exec hermes-main hermes mcp test honcho      # Connected, ~31 tools
docker exec hermes-main hermes mcp test firecrawl   # tools discovered
# Discord threads: every bot thread-capable in every routed channel (add
# --probe to create + archive a real thread). Named problems say whether
# the bit is missing at guild level or denied by a channel overwrite.
python3 scripts/discord-thread-doctor.py            # all ✓, exit 0
# Gateway: /v1/models should list the four tier names (cheap, smart,
# smarter, smartest) PLUS the live Ollama Cloud catalogue (as ollama/<id>) —
# if it instead returns a swarm of openai/… names, check_provider_endpoint
# isn't taking effect.
curl -s http://127.0.0.1:4000/v1/models \
  -H "Authorization: Bearer $(sudo cat /etc/hermes/litellm.env | grep ^LITELLM_MASTER_KEY= | cut -d= -f2)" \
  | python3 -c 'import json,sys; print(*(m["id"] for m in json.load(sys.stdin)["data"]), sep="\n")'
# One real request per tier name — 200 each, and litellm's log names the
# upstream model that actually served it.
for m in cheap smart smarter smartest; do printf '%-9s ' "$m"; \
  curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:4000/v1/chat/completions \
    -H "Authorization: Bearer $(sudo cat /etc/hermes/litellm.env | grep ^LITELLM_MASTER_KEY= | cut -d= -f2)" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"$m\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":5}"; done
# Tiers' declared windows vs the provider's own API (host-side, needs the
# internet but no key) — the ONLY check that can catch litellm.yaml and
# models.toml drifting apart.
mise run check-model-windows                        # all ok, exit 0
# Dashboard plumbing (true in BOTH states): the vendored plugin is seeded
# into the default home, and the loopback port behaves per the gate.
docker exec hermes-main test -f /opt/data/plugins/hermes-memory-ui/dashboard/manifest.json \
  && echo "memory-ui vendored"
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:${HERMES_DASHBOARD_HOST_PORT:-9119}/
#   disabled (default): 000 — connection refused, nothing listens. Expected.
#   enabled: 30x redirect to the login page or 401. A 200 WITHOUT a
#   session means the auth gate is NOT engaged — investigate immediately.
docker logs hermes-main 2>&1 | grep -i '\[dashboard\]' | tail -5   # no auth-provider errors
```

Org GitHub Apps (after landing the org env vars + PEMs):

```bash
# Descriptors + warm token caches exist per tool-home, runtime-uid owned
docker exec hermes-main ls -la /opt/data/home/org-creds/ \
  /opt/data/profiles/developer/home/org-creds/
docker exec hermes-main sh -c 'for f in /opt/data/home/org-creds/*.token; do head -1 "$f"; done'
#   -> "<installation_id> <expiry>" per org; expiry > now + 50 min
# Boot log: one "org creds for <ORG> ->" line + one "org token ok for <slug>"
# line per (tool-home, org); a FAILED line means org repos are unreachable.
docker logs hermes-main 2>&1 | grep -E 'org (creds|token)' | tail -12
# Git router: an org remote pulls with the ORG token (no prompt), a personal
# remote still works, an unknown owner falls through
docker exec -e HOME=/opt/data/home hermes-main \
  git ls-remote https://github.com/<org>/<private-repo>.git HEAD
# gh shim: org target -> org token; auth/GH_TOKEN always passthrough
docker exec -e HOME=/opt/data/home hermes-main gh api repos/<org>/<repo> --jq .full_name
docker exec hermes-main gh auth status          # shim passthrough
```

Mid-session, `/model cheap`, `/model smart`, `/model smarter` and
`/model smartest` all resolve — the tier names ARE the gateway's model
names, which the old alias names never were.

A gateway-config change and the env edit it implies are two separate acts
(`/etc/hermes/*.env` is operator-owned and outside the repo's atomicity): a
value left on a raw `ollama/<id>` still ROUTES through the wildcard but
loses its declared window, which shows up as compression sizing wrong and
`claude` leaving `CLAUDE_CODE_MAX_CONTEXT_TOKENS` unset. Update the env file
in the same change that deploys the gateway config.

`hermes doctor` inside the container reports warnings for Hermes'
*built-in* honcho/vision integrations — expected and benign; this stack
wires Honcho via MCP instead, and vision just needs system deps the
container lacks.