# AGENTS.md — hermes (agent stack, deployed by Komodo)

A GitOps-managed [Hermes agent](https://github.com/NousResearch/hermes-agent)
stack: the agent in Docker (a thin build over the official
`nousresearch/hermes-agent` image — one container hosting ALL profiles under
its s6 supervision), its configuration rendered at image-build time from
small declarative files (`config/` → `render.py` → `/overlay/<profile>`), plus
[Honcho](https://github.com/plastic-labs/honcho) (memory),
[Firecrawl](https://docs.firecrawl.dev/contributing/self-host) (web), and a
[LiteLLM](https://docs.litellm.ai/) proxy (the stack's single LLM gateway) as
sibling containers. Everything runs on the homelab host under **Komodo
GitOps** — read [the komodo repo's AGENTS.md](https://github.com/<owner>/komodo)
for the control plane, API cheatsheet, and deploy mechanics. This file covers
this stack's particulars.

## Deployment model

Deployed as the Komodo Stack **`hermes`** (server `homelab`): one compose
project merging all four files, cloned from this repo at deploy time.

- **The compose project name is `hermes`** — all named volumes are prefixed
  `hermes_*` (agent state, honcho Postgres/Redis, firecrawl
  db/redis/rabbitmq). Do not rename the stack; the volumes hold live data.
- **Push to `main` = build + deploy** (GitHub webhook → the Komodo
  **`rebuild-hermes-agent` procedure**: stage 1 `RunBuild` on the
  `hermes-agent` Build, stage 2 `RunBuild` on the `litellm` Build, stage 3
  `DeployStack` on this stack — defined in the komodo repo's
  `resources.toml`). Stages run sequentially, so image changes are picked
  up on the same push instead of needing a separate build + deploy.
  Config/compose-only pushes cost a Dockerfile cache-hit build (~1 min).
- **Container config files are baked into images — deploys restart them
  intelligently.** `config/litellm.yaml` is COPYed into the `litellm:main`
  image, and the agent image is a thin build over the OFFICIAL
  `nousresearch/hermes-agent:<ref>` image whose build renders `config/` →
  `/overlay/<profile>` (the render.py run happens inside `docker build`,
  so there is no committed `build/` output; both are the Dockerfile's
  final layers, from a repo-root build context). A config-only push
  therefore invalidates just that final COPY layer → new image ID → the
  deploy's `compose up` recreates the affected service. This is the
  auto-restart path: no bind-mounted config files (whose content changes
  compose can't see), no reloader sidecar, no manual restarts. A deploy
  is still a no-op for services whose image and compose config didn't
  change — check `docker inspect <container> --format
  '{{.State.StartedAt}}'` to confirm a recreation actually happened.
- Changes to `/etc/hermes/*.env` on the host DO trigger recreation on the next
  deploy (compose hashes env_file contents).

## Images are built by Komodo Builds — never compose build

The stack runs with `run_build = false` and `auto_pull = false`; the images
`hermes-agent:v2026.8.31`, `litellm:main`, `honcho:main`, and
`honcho-mcp:main` are produced by four **Build** resources defined in the
komodo control plane repo (`builder = "homelab"`). The `hermes-agent` and
`litellm` Builds use a **repo-root build context** (`build_path = "."`) —
the Dockerfiles COPY `docker/hermes/*`, `config/` + `render.py` (rendered
inside the build), and `config/litellm.yaml` from it (see `.dockerignore`
for what's excluded).
Therefore:

- **Dockerfile, installer, or baked-config changes are picked up
  automatically**: the push webhook runs the `rebuild-hermes-agent`
  procedure (build hermes-agent → build litellm → deploy, in order).
  Manual equivalent when needed:
  1. push the change to this repo
  2. `execute/RunBuild {"build":"hermes-agent"}` (or `litellm` / `honcho` /
     `honcho-mcp`)
  3. `execute/DeployStack {"stack":"hermes"}`
  Use the manual path if the webhook was missed (stack busy / core down) —
  check `GetStack` → `info.deployed_hash` after any push; a webhook delivery
  can 200 but skip if Komodo is mid-operation or restarting.
- Honcho builds pull from the **public upstream repo** (plastic-labs/honcho,
  branch `main`) — `honcho:main` is rebuilt upstream-first. The
  **`rebuild-honcho`** procedure (run it manually via
  `execute/RunProcedure {"procedure":"rebuild-honcho"}` — no webhook) builds
  honcho, then honcho-mcp, then deploys this stack; sequential stages keep
  the builds off the host concurrently.

### Bumping HERMES_REF (the update checklist)

Update the pinned ref in **all** of: the `hermes-agent` Build's `image_tag` AND
`build_args`, the stack `environment` in the komodo repo's resources.toml,
and the compose/mise defaults here (`mise.toml [env]`; the Dockerfile ARG
defaults through compose, so only mise.toml needs the edit), plus
`render.py`'s `_FALLBACK_CONFIG_VERSION` (only affects local preview
renders — the build-time stamp is derived from the base image). The ref is now
the FROM tag of the official base image — the official image publishes
per-release, so a ref bump both upgrades the agent code and refreshes the
supervision tree. **Also re-check the source patches** in
`docker/hermes/patches/` — they are anchored to upstream line numbers, so a
ref bump is exactly when they break. You will not have to guess: an
already-fixed patch reverse-applies and the build prints a NOTICE telling
you to delete it, while a moved anchor FAILS the build
(§Security tuning (guard friction)). Then RunBuild → DeployStack, and always verify
`hermes mcp test honcho` + `hermes mcp test firecrawl` against the new
image — Hermes' MCP SDK pin is where HTTP-transport breakage has landed
before (mcp 2.x renamed `streamablehttp_client`; refs from v2026.8.31
onward support 2.x natively, so the old `mcp<2` Dockerfile pin was
dropped at that bump).

## Secrets

Runtime secrets live in root-owned files on the host —
`/etc/hermes/*.env` (mode 640, root:ubuntu), mounted read-only into
Periphery, wired via the stack `environment` `HERMES_ENV_DIR=/etc/hermes`.
Templates are in `secrets/*.env.example`; nothing secret is ever committed.
Key wiring to keep consistent:

- **Every LLM in the stack goes through the LiteLLM proxy**
  (`http://litellm:4000`, `compose/litellm.compose.yml` +
  `config/litellm.yaml`). The proxy holds the real upstream keys —
  `OLLAMA_API_KEY` (Ollama Cloud, the key Open WebUI uses) and
  `OPENROUTER_API_KEY` (OpenRouter free models) — in `litellm.env`, and
  routes each model name among its group members (latency-based, with
  fallbacks). An `ollama/*` wildcard entry serves every other Ollama
  Cloud model unprefixed-of-config (callable as `ollama/<model-id>`,
  expanded in `/v1/models` from the provider's own list via
  `litellm_settings.check_provider_endpoint`), so new Ollama Cloud
  releases need no config change. The apps authenticate with the proxy's
  master key
  (`LITELLM_MASTER_KEY` in `litellm.env`), mirrored into each app's env
  file as `LITELLM_API_KEY` / `LLM_OPENAI_API_KEY` / `OPENAI_API_KEY` —
  same value everywhere. Model selection follows a four-tier policy,
  defined as aliases in `config/models.toml` (windows are the values
  Ollama Cloud reports, verified via `POST ollama.com/api/show`):
  **baseline** = `glm-5.3-flash` (1M window) — agent primary/hermes chat,
  and also the tier for targeted tasks needing intelligence AND a big
  window (aux compression); **elevated** = `glm-5.3` (1M) — hard
  reasoning/multi-step work, opt in via `/model elevated` or a profile's
  model, and the baseline's failure fallback; **nano** =
  `nemotron-3-nano:30b` (256k) — low-intelligence tier with a large
  window, wired as `smart_model_routing`'s cheap lane (short/simple
  turns) and the light aux side tasks (session search, web extract,
  skills hub); **ultra** = `nemotron-3-ultra` (256k) — some-intelligence
  tier for small-context targeted work; Honcho's LLM consumers (deriver,
  summaries, dialectic, dream — `*_MODEL_CONFIG__MODEL` envs) run here.
  All Ollama Cloud IDs are addressed as `ollama/<id>` (the wildcard
  route). Firecrawl's LLM features (`MODEL_NAME`) run on the `firecrawl`
  group,
  which is **OpenRouter free models ONLY** (`google/gemma-4-31b-it:free`,
  `nvidia/nemotron-3-super-120b-a12b:free`) — this FIXES the old
  schema-bound extraction gap: Ollama Cloud strips
  `response_format: json_schema`, so /v1/extract and v2 json-format
  scrapes returned `json: null`; OpenRouter passes json_schema through,
  so SmartScrape extraction works.
- `litellm.env`: `LITELLM_MASTER_KEY` (generate: `openssl rand -hex 32`),
  `OLLAMA_API_KEY`, `OPENROUTER_API_KEY` (free tier — create at
  https://openrouter.ai/keys).
- `hermes-main.env`: `LITELLM_API_KEY` (the master key), the
  `AUXILIARY_*` overrides (BASE_URL=http://litellm:4000),
  `FIRECRAWL_API_KEY` (must equal `TEST_API_KEY` in `firecrawl.env`),
  `HONCHO_API_KEY` (any non-empty value while honcho-api runs no-auth; must
  match honcho-api if auth is enabled). `OPENAI_API_KEY` +
  `OPENAI_BASE_URL` mirror the LiteLLM endpoint for Hermes'
  registry-based fallbacks — `hermes chat`'s first-run gate only inspects
  registry env vars (never config.yaml's `custom_providers`) and exits
  with setup guidance without them, even though the gateway resolves the
  provider fine. Also: `DISCORD_BOT_TOKEN` + `DISCORD_ALLOWED_USERS`
  (gateway), `GH_TOKEN` + optional `GH_GIT_NAME`/`GH_GIT_EMAIL`
  (GitHub — see below).
- `firecrawl.env`: `TEST_API_KEY`, `POSTGRES_*`, `OPENAI_API_KEY` +
  `OPENAI_BASE_URL` (LiteLLM) + `MODEL_NAME=firecrawl` (LLM extract/generate).
- `honcho.env`: `LLM_OPENAI_API_KEY` + `LLM_OPENAI_BASE_URL` (LiteLLM;
  bare `OPENAI_API_KEY` is NOT read — Honcho uses `LLM_`-prefixed settings,
  and every default model config reuses the client built from these two),
  per-section `*_MODEL_CONFIG__MODEL` overrides (deriver,
  summaries, dream, dialectic levels — defaults point at OpenAI models
  Ollama Cloud doesn't serve), and the embedding block:
  `EMBEDDING_MODEL_CONFIG__*` → LiteLLM's `nomic-embed-text` entry, which
  proxies to the stack-local `ollama` service (768 dims; Ollama Cloud has
  **no embeddings endpoint**) + `EMBEDDING_VECTOR_DIMENSIONS=768`.
  Optional `HONCHO_POSTGRES_PASSWORD`.

## Stack particulars (hard-won)

The stack is deliberately right-sized **small** — upstream defaults for
these stacks assume a real server and will starve a small host into
crash-loops. Do not "fix" the small numbers in the compose files without
checking the host's actual resources:

- **litellm**: the proxy runs DB-less (no `DATABASE_URL`) — fine for pure
  routing; key management/budgeting features need a DB and are unused here.
  The image is a thin build over upstream: `docker/litellm/Dockerfile`
  FROMs the multi-arch `ghcr.io/berriai/litellm:main-latest` (the
  versioned `main-v1.x.y` tags are amd64-only — check the host's
  architecture) and COPYs `config/litellm.yaml` — pre-pull the base on
  the host before the first build
  (`docker pull ghcr.io/berriai/litellm:main-latest`); gateway upgrades
  re-pull the base, then rebuild via the procedure.
  `routing_strategy: latency-based-routing` picks the
  lowest-latency member of a group; Ollama Cloud is typically fastest, so
  it wins the mixed groups and OpenRouter free is the resilience fallback.
  The `firecrawl` group is OpenRouter-only by design (json_schema).
- **firecrawl**: `NUQ_WORKER_COUNT=1` (the real knob — `NUM_WORKERS_PER_QUEUE`
  only affects the legacy worker), `MAX_CONCURRENT_JOBS=2`,
  `CRAWL_CONCURRENT_REQUESTS=2`, `BROWSER_POOL_SIZE=1`; playwright has a
  memory-only limit (a `cpus` limit above the host's core count is
  unschedulable).
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
- **Tool search must stay on** (`[config_extra.tools.tool_search]`
  `enabled = "on"` in profile.toml): honcho+firecrawl MCP ship 66 tool
  schemas ≈ 18k tokens — on a small context window that pins every turn
  past the 50% compaction threshold before any history exists.
  tool_search (progressive disclosure, shipped v2026.8.31) defers MCP
  schemas behind `tool_search`/`tool_describe`/`tool_call` bridges.
  Core built-in tools never defer. `config/models.toml` states each
  model's TRUE provider window explicitly (Hermes' catalogue probe can't
  resolve IDs through the litellm base_url — it falls back to 256k for
  everything — verify the actual model). Verify via
  `POST ollama.com/api/show` → `model_info.*.context_length`. Never set a
  window below the provider's: v2026.8.31 hard-rejects anything under 64K
  (`MINIMUM_CONTEXT_LENGTH` raise in `agent/agent_init.py`).
- **hermes-agent image**: a thin build FROM the official
  `nousresearch/hermes-agent:<ref>` image — code, venv, launcher, Node
  runtime, and the s6 supervision tree are all upstream's problem now;
  don't re-implement or patch around them here. The venv is uv-managed
  (no pip; use `uv pip install --python <venv>/bin/python`).
  Volume ownership is self-healed by the entrypoint (`chown -R` to the
  runtime UID before its first privilege drop) — upstream's stage2 chown
  only runs after our wrapper's exec, so an unwritable volume would kill
  the wrapper first (the 2026-09-07 restart loop). Don't remove that
  chown.
- **render.py stamps `_config_version`** into every rendered config.yaml,
  derived at build time from the base image's `DEFAULT_CONFIG` (render
  runs under the image's own venv `python3`, so `hermes_cli` imports
  there; local preview falls back to the pinned constant — keep it in
  sync at ref bumps). Without the stamp the schema reads as 1 and the
  Docker boot-time migration (`scripts/docker_config_migrate.py`, whose
  check lacks the CLI's fresh-minimal-config carve-out) warns the config
  "predates version 12" on every boot. The resolver still reads the
  legacy `custom_providers` list form at read time, so stamping never
  changes resolution.
- **Multiplexing boot noise is benign**: with `GATEWAY_MULTIPLEX_PROFILES`
  on, the tool registry's availability check_fns probe at gateway boot
  before any profile secret scope exists and fail closed with
  `UnscopedSecretError` — three WARNING tracebacks (discord tool /
  homeassistant / web_api) per start, purely log noise. Real turns run
  scoped and re-probe (tools are not lost); upstream PR #100709
  reclassifies these to debug. Only worry if the warning appears on a
  turn AFTER startup — that would be a genuine lost-scope case.
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
  defaults true (responds to @mentions and DMs only). The entrypoint
  syncs the mounted env file into `$HERMES_HOME/.env` on every boot (the
  runtime user can't read the root-owned host mount), and
  `load_hermes_dotenv` loads that volume copy with `override=True` — the
  mounted file is the source of truth, and runtime writes to
  `$HERMES_HOME/.env` last only until the next container restart.
  Two gotchas when scripting the Discord REST API from
  the container: bare `urllib` User-Agents get Cloudflare-blocked with
  `error 1010` (set a real UA string), and bot DMs fail with
  403/code 50278 "no mutual guilds" when the recipient's server-DM
  privacy setting blocks server members — @mention in a server channel
  pings them instead. **Each team profile runs its own Discord bot**
  (`PROFILE_<NAME>_DISCORD_BOT_TOKEN`); a profile left on the main token
  is refused by the gateway ("same credential — refusing to start the
  duplicate") and stays dormant. See
  §Provisioning per-profile identities.
- **GitHub access** is skills-based, not an integration: the agent's
  `github-*` skills drive `gh` CLI + git, and the image installs gh
  (pinned tarball — rebuild required to bump). Auth mode in use:
  **GitHub App** (app 4860240, installed as `hermes-main[bot]`,
  all repos). Both modes are env-driven from hermes-main.env; the
  entrypoint re-runs the config on every start and sets a default commit
  identity from `GH_GIT_NAME`/`GH_GIT_EMAIL`:
  - **GitHub App (preferred)**: `GITHUB_APP_ID` +
    `GITHUB_APP_INSTALLATION_ID` are the only GitHub vars in the env file
    (PEM at `/etc/hermes/github-app-<profile>.pem` — the default profile
    uses `github-app-main.pem`; root:ubuntu 640, bind-mounted read-only
    at `/run/hermes-pem/`, the file must exist before deploy). **Every
    profile now has its own app** — see
    §Provisioning per-profile identities for the inventory and for how to
    add one for a new profile. The entrypoint copies the PEM into the
    runtime-owned tool-home (`$HERMES_HOME/home/`) and exports
    `GITHUB_APP_PRIVATE_KEY_PATH` itself — the env file never names the
    path, because s6 services couldn't read the host mount anyway.
    Installation tokens last 1h, so git's credential helper routes
    through gh's own stored token (`gh auth git-credential`), and a
    background refresher re-runs `gh auth login
    --with-token` every 30 min. Hermes' skills hub has native app support
    too (tools/skills_hub.py `GitHubAuth`, priority PAT → gh → app).
  - **PAT fallback**: `GH_TOKEN` authenticates gh natively; git routes
    through `gh auth git-credential`. Prefer a fine-grained PAT scoped
    to the specific repos (Contents/Issues/Pull requests read+write).

### Security tuning (guard friction)

This stack's agents live in `terminal`, and two guard behaviours were
blocking the script-shaped work we *want* them to do, so both were loosened
deliberately (2026-09-12). Baseline measured from the live `state.db`: 1066
of 1164 terminal commands were newline-free one-liners, 22 came back
blocked, 91 carried an approval note.

1. **`tools/approval.py` source patch** — `docker/hermes/patches/`, applied
   in the Dockerfile with `git apply` (the base image has no `patch`
   binary; `git apply` works outside a repo, which matters because
   `.dockerignore` drops `.git`).
   Upstream hardline-blocks any command whose grep-operand scanner surfaces
   a word it cannot tokenize — which is what happens whenever `grep`
   appears inside a quoted `$(...)`, i.e. the very common
   `sed -n "$(grep -n 'x' f | cut -d: -f1),+45p" f`. The block is
   unconditional (no `--yolo`, approval mode, or `command_allowlist`
   reaches it) and reported ~150-byte commands as *"command parser limit or
   malformed executable payload"*. It was the single largest source of
   blocked calls — 9 of them saved under `/opt/data/cache/blocked-scripts/`,
   every one a false positive. The patch skips an unparseable operand
   instead of failing the whole command, and is fail-closed: skipping only
   declines to *mask* text as data, and the hardline path discards the
   masked variant anyway (it uses only the malformed flag).
   **Deleting it later is signalled by the build**: if upstream adopts the
   fix the patch reverse-applies and the build prints a NOTICE instead of
   failing; if upstream only moves the code the build FAILS, so an
   unpatched image is never shipped silently.
2. **Tirith pre-approvals, config only — Tirith itself stays ON.**
   `render.py` seeds `command_allowlist` with `tirith:<rule_id>` keys for
   every profile. `approval.py` loads that list at *module import*
   (`tools/approval.py:5971`), and a Tirith finding's approval key is
   `tirith:<rule_id>`, so listing a key permanently auto-approves that one
   rule. The six seeded rules are the ones that actually fired on this
   stack's own legitimate work: `analysis_incomplete` (the `$(...)` /
   dynamic-command shape), `plain_http_to_sink` (our internal HTTP
   services), `mass_file_deletion` (worktree/build churn),
   `curl_pipe_shell`, `pipe_to_interpreter`, `blast_find_delete`.
   `tirith:mass_file_deletion` is the most aggressive inclusion and the
   first to drop if the ransomware-shaped burst check is wanted back — the
   unconditional hardline floor still blocks `rm -rf /` either way.
   Extend by hand from `tirith audit stats --format json` → `top_rules`.
   Note `approvals.mode` is the default `smart`, so heredoc / `-e -c`
   patterns already auto-approve; only Tirith's HIGH/CRITICAL findings were
   demanding a human.

### Steering profiles toward scripts

`config/SOUL_OPERATING.md` is appended to **every** rendered profile's
`SOUL.md` by `render.py` — one source, all four profiles. SOUL.md rides the
system prompt on every turn, unlike a skill (lazily loaded), so always-on
behaviour belongs there; the per-profile SOUL.md stays the role document.

The block tells each profile: 3+ shell/file operations for one goal → **one
call**; a chain with logic between the calls (filter, branch, loop, retry,
reduce output before it reaches context) → **`execute_code`**; a shell chore
(git, builds, `gh`, docker, tests) → **write a script with `write_file`
and run it by path** — which is also the friction-free path past both guards
above; and never inline a big payload (heredocs, giant one-liners, nested
`$(...)` are what the scanners mis-parse).

Why it was needed: the terminal tool's own description steers work *away*
from shell — *"Do NOT use cat/head/tail (use read_file), grep/rg/find/ls
(use search_files), sed/awk (use patch)"* — which turns one shell pipeline
into three or four separate tool calls, one turn each. `execute_code` is the
tool built to collapse exactly that (*"collapsing multi-step tool chains
into a single inference turn"*) and was sitting at 118 of 2264 calls.
Target baseline to beat: **1.12 calls/turn, 81% of turns a single call,
50.5% exactly one `terminal` call, runs up to 29 consecutive single-command
turns.**

## Agent self-management (skills + control-plane access)

Skills ship in two tiers:

- **Stack-wide** (`config/skills/`) — merged into EVERY rendered profile
  by render.py. Currently: `hermes-stack-ops`, this stack's operating
  manual (config is GitOps-rendered, never hand-edit
  `/opt/data/config.yaml`; LiteLLM is the only LLM path; GitHub App
  usage; central git repos + per-session worktrees; Discord gotchas;
  small-host constraints; cron/kanban availability).
- **Per-profile** (`config/profiles/<name>/skills/`) — same-named skills
  win over the stack-wide ones. Currently: `komodo-ops` ships only in
  the default profile — it drives the Komodo API from inside the
  container at `http://komodo-core-1:9120` (komodo-core joins the
  external `hermes-net` network, per the komodo repo's compose) with the
  auth header mounted read-only at `/etc/komodo-auth-header` (host path
  `/home/ubuntu/.komodo-auth-header`, overridable via the stack
  `environment` var `KOMODO_AUTH_HEADER`). It can deploy stacks, run
  builds, and re-apply the resource sync — but NOT change control-plane
  resources (that's the komodo repo, human-reviewed via push).

### Central git repos + per-session worktrees

All git repos live in ONE central store on the shared volume — a bare
clone per repo at `/opt/data/repos/<host>/<owner>/<repo>.git`. Nobody
works in the bare repos and no profile/session clones privately; work
happens in per-SESSION worktrees under `/opt/data/worktrees/<session-slug>/`
(the slug comes from `HERMES_SESSION_KEY`, bridged into every tool
subprocess — one messaging session = one slug, stable across its turns).
The `git-repo.sh` helper (baked at `/usr/local/bin/git-repo.sh`) manages
both: `ensure` (idempotent bare clone), `worktree <url> [branch] [dest]`
(session checkout; auto-creates a session branch `s/<slug>` when the
requested branch is checked out elsewhere), `list`, and `prune --days N`
(drop session dirs idle > N days, then `git worktree prune` — run
weekly via `scripts/prune-repos.sh`, scheduled as a no-agent cron job).
Overrides: `HERMES_REPOS_DIR` / `HERMES_WORKTREES_DIR`. Everything is
runtime-uid-owned, so every profile reaches the same store; git's
worktree model provides the isolation (one branch, one checkout).

Consequence of the network attachment: the hermes stack must be deployed
before komodo-core can start with it (`hermes_net` is declared external in
komodo's compose).

## Provisioning per-profile identities (GitHub Apps + Discord bots)

Every profile has its OWN bot identity in both GitHub and Discord — the
team roles must be distinguishable from one another and from the main
agent, and must never share or impersonate another's. Both halves need one
manual step that no API can perform; the two scripts in `scripts/` wrap
everything around it.

Inventory (all four provisioned and verified live):

| Profile | GitHub App | App ID | Discord bot | Bot ID |
|---|---|---|---|---|
| default | `hermes-main` | 4860240 | Hermes Main | 1546241126980391063 |
| planner | `hermes-planner` | 4921863 | Hermes Planner | 1548360503150248116 |
| developer | `hermes-dev` | 4921866 | Hermes Developer | 1548361258653319338 |
| reviewer | `hermes-reviewer` | 4921867 | Hermes Reviewer | 1548361448038866954 |

Installation IDs, git identities, and bot tokens live in
`/etc/hermes/hermes-main.env` as `PROFILE_<NAME>_*`. App and bot IDs are
not secret, but **PEMs and bot tokens are**: never echo them, never commit
them, and route them through the scripts below rather than a shell history
or a chat transcript.

### GitHub App for a new profile — `scripts/create-github-apps.py`

GitHub has **no API to create an App** and `gh` cannot do it. The App
Manifest flow is the only automatable path, and it needs the account
owner's browser: the script serves the manifest from a local HTTP server,
auto-submits it to `github.com/settings/apps/new`, catches GitHub's
redirect, and exchanges the temporary code for the App's id + private key
at `POST /app-manifests/{code}/conversions`. Its `setup_url` catches the
post-install redirect, so the installation id is captured without anyone
reading it off a URL.

Two clicks per app — **Create GitHub App**, then **Install** with "All
repositories". Run it where the browser is:

    python3 scripts/create-github-apps.py [profile ...]   # default: the 3 team profiles

Artifacts land in gitignored `build/github-apps/`: the PEM (mode 600),
`results.json`, `env-lines.txt`, and `host-install.sh`. Then on the host,
run `host-install.sh` (installs each PEM as root:ubuntu 640 into
`/etc/hermes/`) and append `env-lines.txt` to
`/etc/hermes/hermes-main.env`. Re-running is safe — an existing App name
fails at GitHub's own name check before anything is created.

### Bot token for a new team profile — `scripts/set-team-discord-tokens.py`

Run **on the host**. It prompts for each team bot token with hidden input
(`getpass`), so no token reaches a shell history, a process list, or a
chat transcript, and it validates every token against Discord *before*
writing. It refuses a token Discord rejects, the main bot's token (which
re-creates the duplicate-credential refusal), a user token, or one already
entered for a different role. It then rewrites the
`PROFILE_<NAME>_DISCORD_BOT_TOKEN` lines in `/etc/hermes/hermes-main.env`
(idempotent — existing lines are replaced) and prints each bot's invite
URL, carrying the main bot's permission integer.

Create the applications first at
https://discord.com/developers/applications. On each one's Bot tab enable
**Message Content** AND **Server Members** — the adapter requests both and
discord.py refuses to connect without them (enable Presence too, to match
the existing bots). A bot token works as soon as the app exists, but the
bot is not *in* the guild until someone authorizes the invite URL.

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

## Local development (this repo)

Local runs use **mise** (not Makefile): `mise run up`, `mise run logs`,
`mise run chat`, `mise run down`, `mise run validate`, `mise run check-updates`.
`mise.toml [env]` holds the version pins and `HERMES_ENV_DIR`; per-machine
overrides go in gitignored `mise.local.toml`.

After editing anything in `config/`, just `git commit && git push` — the
Docker build runs render.py itself, so there is NO committed `build/` output
to keep in sync (the old "commit the build/ output" step is gone). To preview
a render without building: `mise run render` (writes ./build/, gitignored,
never committed). Note: local compose runs get a project named after the
parent dir, not `hermes` — the Komodo deployment on the host is the real one.

## Verification checklist (after any deploy)

```bash
docker ps --format '{{.Names}}\t{{.Status}}' | grep -E 'hermes|honcho|firecrawl|ollama'
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3002/v0/health/readiness   # 200
docker exec hermes-main hermes mcp test honcho      # Connected, ~31 tools
docker exec hermes-main hermes mcp test firecrawl   # tools discovered
# Gateway: /v1/models should list the explicit entries PLUS the live
# Ollama Cloud catalogue (as ollama/<id>) — if it instead returns a
# swarm of openai/… names, check_provider_endpoint isn't taking effect.
curl -s http://127.0.0.1:4000/v1/models \
  -H "Authorization: Bearer $(sudo cat /etc/hermes/litellm.env | grep ^LITELLM_MASTER_KEY= | cut -d= -f2)" \
  | python3 -c 'import json,sys; print(*(m["id"] for m in json.load(sys.stdin)["data"]), sep="\n")'
```

`hermes doctor` inside the container reports warnings for Hermes' *built-in*
honcho/vision integrations — expected and benign; this stack wires Honcho via
MCP instead, and vision just needs system deps the container lacks.