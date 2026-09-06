# AGENTS.md — hermes (agent stack, deployed by Komodo)

A GitOps-managed [Hermes agent](https://github.com/NousResearch/hermes-agent)
stack: the agent in Docker, its configuration rendered from small declarative
files (`config/` → `render.py` → `build/<profile>/`), plus
[Honcho](https://github.com/plastic-labs/honcho) (memory) and
[Firecrawl](https://docs.firecrawl.dev/contributing/self-host) (web) as sibling
containers. Everything runs on the homelab host under **Komodo GitOps** —
read [the komodo repo's AGENTS.md](https://github.com/<owner>/komodo) for the
control plane, API cheatsheet, and deploy mechanics. This file covers this
stack's particulars.

## Deployment model

Deployed as the Komodo Stack **`hermes`** (server `homelab`): one compose
project merging all three files, cloned from this repo at deploy time.

- **The compose project name is `hermes`** — all named volumes are prefixed
  `hermes_*` (agent state, honcho Postgres/Redis, firecrawl
  db/redis/rabbitmq). Do not rename the stack; the volumes hold live data.
- **Push to `main` = deploy** (GitHub webhook → DeployStack). A deploy is a
  no-op for services whose compose config didn't change — check
  `docker inspect <container> --format '{{.State.StartedAt}}` to confirm a
  recreation actually happened.
- The rendered overlay (`build/main/`) is **committed** and bind-mounted into
  the agent container at `/overlay:ro`. Because it's a bind mount, its file
  contents update live on deploy even when the container isn't recreated —
  but the entrypoint only re-applies the overlay on container start.
- Changes to `/etc/hermes/*.env` on the host DO trigger recreation on the next
  deploy (compose hashes env_file contents).

## Images are built by Komodo Builds — never compose build

The stack runs with `run_build = false` and `auto_pull = false`; the images
`hermes-agent:v2026.3.23`, `honcho:main`, and `honcho-mcp:main` are produced
by three **Build** resources defined in the komodo control plane repo
(`builder = "homelab"`). Therefore:

- **Dockerfile or installer changes are NOT picked up by a stack deploy.**
  Run the build, then redeploy:
  1. push the change to this repo
  2. `execute/RunBuild {"build":"hermes-agent"}` (or `honcho` / `honcho-mcp`)
  3. `execute/DeployStack {"stack":"hermes"}`
- Honcho builds pull from the **public upstream repo** (plastic-labs/honcho,
  branch `main`) — `honcho:main` is rebuilt upstream-first; re-run its Build
  to pick up Honcho changes, then DeployStack.

### Bumping HERMES_REF (the update checklist)

Update `v2026.3.23` in **all** of: the `hermes-agent` Build's `image_tag` AND
`build_args`, the stack `environment` in the komodo repo's resources.toml,
and the compose/mise defaults here (`mise.toml [env]`, `docker/hermes/Dockerfile`
`ARG`). Then RunBuild → DeployStack. Also re-test the `mcp>=1.2.0,<2` pin in
the Dockerfile: the installer has no upper bound on `mcp`, and 2.x renamed
`streamablehttp_client`, which breaks Hermes' HTTP MCP transport. A newer
Hermes ref may support mcp 2.x — drop the pin only after
`hermes mcp test honcho` passes against the new image.

## Secrets

Runtime secrets live in root-owned files on the host —
`/etc/hermes/*.env` (mode 640, root:ubuntu), mounted read-only into
Periphery, wired via the stack `environment` `HERMES_ENV_DIR=/etc/hermes`.
Templates are in `secrets/*.env.example`; nothing secret is ever committed.
Key wiring to keep consistent:

- **Every LLM in the stack uses the Ollama Cloud key Open WebUI uses**
  (`OLLAMA_API_KEY` in `hermes-main.env`, `OPENAI_API_KEY` in `honcho.env`
  and `firecrawl.env` — same value everywhere). Model selection follows
  least-costly-while-effective: agents run `gpt-oss:120b` (`smart` alias,
  32k context cap) as primary — effective at tool calling — with
  `smart_model_routing` sending short/simple turns to `gpt-oss:20b`
  (`fast` alias); Honcho's LLM consumers (deriver, summaries, dialectic,
  dream — `*_MODEL_CONFIG__MODEL` envs) all run on `gpt-oss:20b` —
  background/structured work where the smallest model is fully effective.
  Firecrawl's LLM features (`MODEL_NAME`) run on `gpt-oss:20b`, with one
  known gap: **schema-bound extraction (/v1/extract, v2 json format)
  cannot work over Ollama Cloud** — ollama.com strips
  `response_format: json_schema`, so no cloud model fills Firecrawl's
  SmartScrape envelope and those calls return `json: null` + warning.
  Prompt-only LLM paths (deep-research, llms-txt) work. Hermes' auxiliary
  side tasks
  (via `AUXILIARY_*_{BASE_URL,API_KEY,MODEL}` env overrides) run
  `gpt-oss:20b`. `glm-5.3` remains available as the `frontier` alias — opt
  in per-profile; it burns heavy thinking tokens.
- `hermes-main.env`: `OLLAMA_API_KEY`, the `AUXILIARY_*` overrides,
  `FIRECRAWL_API_KEY` (must equal `TEST_API_KEY` in `firecrawl.env`),
  `HONCHO_API_KEY` (any non-empty value while honcho-api runs no-auth; must
  match honcho-api if auth is enabled). `OPENAI_API_KEY` +
  `OPENAI_BASE_URL` mirror the Ollama Cloud endpoint for Hermes'
  registry-based fallbacks — `hermes chat`'s first-run gate only inspects
  registry env vars (never config.yaml's `custom_providers`) and exits
  with setup guidance without them, even though the gateway resolves the
  provider fine. Also: `DISCORD_BOT_TOKEN` + `DISCORD_ALLOWED_USERS`
  (gateway), `GH_TOKEN` + optional `GH_GIT_NAME`/`GH_GIT_EMAIL`
  (GitHub — see below).
- `firecrawl.env`: `TEST_API_KEY`, `POSTGRES_*`, `OPENAI_API_KEY` +
  `OPENAI_BASE_URL` + `MODEL_NAME` (LLM extract/generate).
- `honcho.env`: `LLM_OPENAI_API_KEY` + `LLM_OPENAI_BASE_URL` (Ollama Cloud;
  bare `OPENAI_API_KEY` is NOT read — Honcho uses `LLM_`-prefixed settings,
  and every default model config reuses the client built from these two),
  per-section `*_MODEL_CONFIG__MODEL=gpt-oss:20b` overrides (deriver,
  summaries, dream, dialectic levels — defaults point at OpenAI models
  Ollama Cloud doesn't serve), and the embedding block:
  `EMBEDDING_MODEL_CONFIG__*` → the stack-local `ollama` service with
  `nomic-embed-text` (768 dims; Ollama Cloud has **no embeddings endpoint**)
  + `EMBEDDING_VECTOR_DIMENSIONS=768`. Optional `HONCHO_POSTGRES_PASSWORD`.

## Stack particulars (hard-won)

The host is **1 CPU / 6 GB** — upstream defaults for these stacks assume a
real server and will starve it into crash-loops (load was ~15 before
right-sizing). Do not "fix" the small numbers in the compose files:

- **firecrawl**: `NUQ_WORKER_COUNT=1` (the real knob — `NUM_WORKERS_PER_QUEUE`
  only affects the legacy worker), `MAX_CONCURRENT_JOBS=2`,
  `CRAWL_CONCURRENT_REQUESTS=2`, `BROWSER_POOL_SIZE=1`; playwright has a
  memory-only limit (a `cpus: 2` limit is unschedulable on a 1-CPU host).
- **firecrawl env var names churn between releases.** When bumping
  `FIRECRAWL_VERSION`, diff `compose/firecrawl.compose.yml` against upstream's
  `docker-compose.yaml` for the new tag. Known traps: `RABBITMQ_URL` was
  renamed `NUQ_RABBITMQ_URL`; **`HOST` must stay `0.0.0.0`** (the default
  `localhost` binds IPv6 loopback only — the in-container harness probe and
  the published port both get ECONNREFUSED, restart-looping forever).
- **firecrawl-db** runs `postgres -c cron.database_name=firecrawl` because
  the nuq-postgres initdb script `CREATE EXTENSION pg_cron`, which only works
  in the DB named by that GUC; our `POSTGRES_DB=firecrawl` differs from
  upstream's `postgres`. Wiping that volume re-runs initdb — it must succeed
  or the API crash-loops on missing nuq tables.
- **honcho**: the image ships psycopg v3 only — DB URIs must use
  `postgresql+psycopg://`. `honcho-mcp` rejects unauthenticated requests and
  forwards the Bearer token to honcho-api, so the agent's MCP config carries
  `Authorization: Bearer ${HONCHO_API_KEY}` (emitted by `render.py` from
  `config/integrations.toml` `mcp_headers`).
- **The agent's BUILT-IN Honcho integration must stay off**: it
  auto-enables from the mere presence of `HONCHO_API_KEY` in the
  environment, then fails against the *hosted* Honcho API ("Invalid API
  key") and leaves dead `honcho_*` tools on the surface. `render.py`
  ships an `honcho.json` (`{"enabled": false}`) in every profile overlay
  to suppress it — Honcho reaches the agent through MCP only. The banner
  still prints "Skipping MCP toolset alias 'honcho'" — cosmetic: the
  built-in toolset owns the alias, but the MCP tools register as
  `mcp_honcho_*` in the hermes-* umbrella toolsets regardless.
- **hermes-agent image**: the v2026.3.x installer with `--skip-setup` lands
  the code+venv under `/root/.hermes/hermes-agent` with NO launcher — the
  Dockerfile symlinks the venv `hermes` onto PATH, and the venv is uv-managed
  (no pip; use `/root/.local/bin/uv pip install --python <venv>/bin/python`).
- **Discord gateway** (`platforms = ["discord"]` in the main profile):
  enabled by the mere presence of `DISCORD_BOT_TOKEN` in the env
  (gateway/config.py `_apply_env_overrides` — config.yaml carries no
  platform state, so the render's `platforms` list only documents/env-
  examples the vars). The bot MUST have "Message Content Intent" AND
  "Server Members Intent" toggled in the Discord developer portal —
  the adapter requests both and discord.py refuses to connect without
  them. `DISCORD_ALLOWED_USERS` (comma-separated user IDs; usernames
  also work, resolved via the Members intent) gates who the bot
  answers; empty = anyone who mentions it. `DISCORD_REQUIRE_MENTION`
  defaults true (responds to @mentions and DMs only). Runtime writes
  resolved env (token + resolved allowlist) back into
  `$HERMES_HOME/.env`, and `load_hermes_dotenv` loads it with
  `override=True` — that file SHADOWS the compose-injected env for any
  key it holds. Two gotchas when scripting the Discord REST API from
  the container: bare `urllib` User-Agents get Cloudflare-blocked with
  `error 1010` (set a real UA string), and bot DMs fail with
  403/code 50278 "no mutual guilds" when the recipient's server-DM
  privacy setting blocks server members — @mention in a server channel
  pings them instead.
- **GitHub access** is skills-based, not an integration: the agent's
  `github-*` skills drive `gh` CLI + git, and the image installs gh
  (pinned arm64 tarball — rebuild required to bump). `GH_TOKEN` (in
  hermes-main.env) authenticates everything: gh reads it natively, and
  entrypoint.sh wires git's github.com credential helper through
  `gh auth git-credential` so the token never touches disk — /root is
  ephemeral, the entrypoint re-runs the config on every start.
  entrypoint.sh also sets a default commit identity from
  `GH_GIT_NAME`/`GH_GIT_EMAIL`. Prefer a fine-grained PAT scoped to the
  specific repos (Contents/Issues/Pull requests read+write).

## Local development (this repo)

Local runs use **mise** (not Makefile): `mise run render`, `mise run up`,
`mise run logs`, `mise run chat`, `mise run down`, `mise run validate`,
`mise run check-updates`. `mise.toml [env]` holds the version pins and
`HERMES_ENV_DIR`; per-machine overrides go in gitignored `mise.local.toml`.
After editing anything in `config/`, run `mise run render` and **commit the
`build/` output** — Komodo deploys from git, so an unrendered edit never
ships. Note: local compose runs get a project named after the parent dir, not
`hermes` — the Komodo deployment on the host is the real one.

## Verification checklist (after any deploy)

```bash
docker ps --format '{{.Names}}\t{{.Status}}' | grep -E 'hermes|honcho|firecrawl'
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3002/v0/health/readiness   # 200
docker exec hermes-main hermes mcp test honcho      # Connected, ~31 tools
docker exec hermes-main hermes mcp test firecrawl   # tools discovered
```

`hermes doctor` inside the container reports warnings for Hermes' *built-in*
honcho/vision integrations — expected and benign; this stack wires Honcho via
MCP instead, and vision just needs system deps the container lacks.