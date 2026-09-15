# AGENTS.md — hermes (agent stack, deployed by Komodo)

A GitOps-managed [Hermes agent](https://github.com/NousResearch/hermes-agent)
stack: one container (a thin build over the official
`nousresearch/hermes-agent` image) hosting ALL profiles under its s6
supervision, its configuration rendered at image-build time from small
declarative files (`config/` → `render.py` → `/overlay/<profile>`), plus
[Honcho](https://github.com/plastic-labs/honcho) (memory),
[Firecrawl](https://docs.firecrawl.dev/contributing/self-host) (web), and a
[LiteLLM](https://docs.litellm.ai/) proxy (the stack's single LLM gateway).
Everything runs on the homelab host under **Komodo GitOps** — read
[the komodo repo's AGENTS.md](https://github.com/<owner>/komodo) for the
control plane, API cheatsheet, and deploy mechanics.

## Deployment model

Deployed as the Komodo Stack **`hermes`** (server `homelab`): one compose
project merging all files under `compose/`, cloned from this repo at deploy
time. **The compose project name is `hermes`** — all named volumes are
prefixed `hermes_*` (agent state, honcho Postgres/Redis, firecrawl
db/redis/rabbitmq) and hold live data; do not rename the stack. The stack
must be deployed before komodo-core can start with it (`hermes_net` is
declared external in komodo's compose).

- **Push to `main` = build + deploy** (GitHub webhook → the Komodo
  `rebuild-hermes-agent` procedure: build `hermes-agent` → build `litellm`
  → deploy `hermes`, sequentially, defined in the komodo repo's
  `resources.toml`). Honcho images are built upstream-first via the
  `rebuild-honcho` procedure (`execute/RunProcedure {"procedure":"rebuild-honcho"}`
  — no webhook; sequential stages keep the builds off the host concurrently).
  Config/compose-only pushes cost a Dockerfile cache-hit build (~1 min).
- **Images are built by Komodo Builds — never compose build** (the stack
  runs `run_build = false`; images `hermes-agent:v2026.8.31`, `litellm:main`,
  `honcho:main`, `honcho-mcp:main`, `builder = "homelab"`). The
  `hermes-agent` and `litellm` Builds use a **repo-root build context**
  (`build_path = "."`) — the Dockerfiles COPY `docker/hermes/*`, `config/` +
  `render.py` (rendered inside the build), and `config/litellm.yaml` (see
  `.dockerignore`). Manual equivalent when the webhook was missed: push,
  then `execute/RunBuild` per build, then
  `execute/DeployStack {"stack":"hermes"}` — and check
  `GetStack` → `info.deployed_hash`; a webhook delivery can 200 but skip if
  Komodo is mid-operation or restarting.
- **Config is baked into images, so deploys restart intelligently.** A
  config-only push invalidates just the final COPY layer → new image →
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
`/etc/hermes/*.env` (mode 640, root:ubuntu), mounted read-only into
Periphery, wired via the stack `environment` `HERMES_ENV_DIR=/etc/hermes`.
Templates are in `secrets/*.env.example`; nothing secret is ever committed,
echoed, or routed through a shell history or chat transcript.

- **Every LLM in the stack goes through the LiteLLM proxy**
  (`http://litellm:4000` + `config/litellm.yaml`). The proxy holds the real
  upstream keys (`OLLAMA_API_KEY` for Ollama Cloud — the key Open WebUI
  uses — and `OPENROUTER_API_KEY` for free models, both in `litellm.env`)
  and routes each model name among group members
  (`routing_strategy: latency-based-routing`, with fallbacks; Ollama Cloud
  is typically fastest, so it wins mixed groups and OpenRouter free is the
  resilience fallback). An `ollama/*` wildcard serves every other Ollama
  Cloud model (callable as `ollama/<model-id>`, expanded in `/v1/models`
  from the provider's own list via `litellm_settings.check_provider_endpoint`),
  so new Ollama Cloud releases need no config change. Apps authenticate
  with the master key (`LITELLM_MASTER_KEY`, generate with
  `openssl rand -hex 32`), mirrored into each app's env as
  `LITELLM_API_KEY` / `LLM_OPENAI_API_KEY` / `OPENAI_API_KEY` — same value
  everywhere.
- Model selection follows a four-tier policy defined as aliases in
  `config/models.toml` (windows are the values Ollama Cloud reports,
  verified via `POST ollama.com/api/show`): **baseline** = `glm-5.3-flash`
  (1M window; agent primary/hermes chat, and targeted tasks needing
  intelligence AND a big window, e.g. aux compression), **elevated** =
  `glm-5.3` (1M; hard reasoning/multi-step work, opt in via `/model
  elevated` or a profile's model, and the baseline's failure fallback),
  **nano** = `nemotron-3-nano:30b` (256k; `smart_model_routing`'s cheap
  lane for short/simple turns + light aux side tasks: session search, web
  extract, skills hub), **ultra** = `nemotron-3-ultra` (256k;
  small-context targeted work; Honcho's LLM consumers run here). Exception:
  the `firecrawl` group is **OpenRouter free models ONLY**
  (`google/gemma-4-31b-it:free`, `nvidia/nemotron-3-super-120b-a12b:free`) —
  Ollama Cloud strips `response_format: json_schema` (so /v1/extract and v2
  json-format scrapes returned `json: null`), while OpenRouter passes
  json_schema through and SmartScrape extraction works.
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
  dialectic levels — defaults point at OpenAI models Ollama Cloud doesn't
  serve), and the embedding block: `EMBEDDING_MODEL_CONFIG__*` → LiteLLM's
  `nomic-embed-text` entry, which proxies to the stack-local `ollama`
  service (768 dims; Ollama Cloud has **no embeddings endpoint**) +
  `EMBEDDING_VECTOR_DIMENSIONS=768`. Optional `HONCHO_POSTGRES_PASSWORD`.

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
- **firecrawl**: the real concurrency knobs are `NUQ_WORKER_COUNT=1`
  (`NUM_WORKERS_PER_QUEUE` only affects the legacy worker),
  `MAX_CONCURRENT_JOBS=2`, `CRAWL_CONCURRENT_REQUESTS=2`,
  `BROWSER_POOL_SIZE=1`; playwright has a memory-only limit (a `cpus`
  limit above the host's core count is unschedulable). **Env var names
  churn between releases** — when bumping `FIRECRAWL_VERSION`, diff
  `compose/firecrawl.compose.yml` against upstream's `docker-compose.yaml`
  for the new tag; known traps: `RABBITMQ_URL` was renamed
  `NUQ_RABBITMQ_URL`, and **`HOST` must stay `0.0.0.0`** (the default
  `localhost` binds IPv6 loopback only — the in-container harness probe and
  the published port both get ECONNREFUSED, restart-looping forever).
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

- **The agent's BUILT-IN Honcho integration must stay off**: it
  auto-enables from the mere presence of `HONCHO_API_KEY` in the
  environment, then fails against the *hosted* Honcho API ("Invalid API
  key") and leaves dead `honcho_*` tools on the surface. `render.py` ships
  an `honcho.json` (`{"enabled": false}`) in every profile overlay to
  suppress it — Honcho reaches the agent through MCP only. The banner's
  "Skipping MCP toolset alias 'honcho'" is cosmetic: the built-in toolset
  owns the alias, but the MCP tools register as `mcp_honcho_*` in the
  hermes-* umbrella toolsets regardless.
- **Tool search must stay on** (`[config_extra.tools.tool_search]`
  `enabled = "on"` in profile.toml): honcho+firecrawl MCP ship 66 tool
  schemas ≈ 18k tokens — on a small context window that pins every turn
  past the 50% compaction threshold before any history exists. tool_search
  (progressive disclosure) defers MCP schemas behind
  `tool_search`/`tool_describe`/`tool_call` bridges; core built-in tools
  never defer. `config/models.toml` must state each model's TRUE provider
  window explicitly (Hermes' catalogue probe can't resolve IDs through the
  litellm base_url and falls back to 256k for everything — verify the
  actual model via `POST ollama.com/api/show` →
  `model_info.*.context_length`). Never set a window below the provider's:
  v2026.8.31 hard-rejects anything under 64K
  (`MINIMUM_CONTEXT_LENGTH` raise in `agent/agent_init.py`).
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
  `#hermes-home` (the unrouted channels: `1510637179267973220`,
  `1548351069707567144`). `allowed_channels` is load-bearing
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

- **GitHub App (preferred)**: `GITHUB_APP_ID` +
  `GITHUB_APP_INSTALLATION_ID` are the only GitHub vars in the env file
  (PEM at `/etc/hermes/github-app-<profile>.pem` — root:ubuntu 640,
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
- **PAT fallback**: `GH_TOKEN` authenticates gh natively; git routes through
  `gh auth git-credential`. Prefer a fine-grained PAT scoped to the
  specific repos (Contents/Issues/Pull requests read+write).

### Security tuning (guard friction)

This stack's agents live in `terminal`, and two guard behaviours blocked
the script-shaped work we *want* them to do, so both were loosened
deliberately.

1. **`tools/approval.py` source patch** — `docker/hermes/patches/`, applied
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
   every profile. `approval.py` loads that list at *module import*, and a
   Tirith finding's approval key is `tirith:<rule_id>`, so listing a key
   permanently auto-approves that one rule. The six seeded rules are the
   ones that actually fired on this stack's own legitimate work:
   `analysis_incomplete` (the `$(...)` / dynamic-command shape),
   `plain_http_to_sink` (our internal HTTP services),
   `mass_file_deletion` (worktree/build churn), `curl_pipe_shell`,
   `pipe_to_interpreter`, `blast_find_delete`. `tirith:mass_file_deletion`
   is the most aggressive inclusion and the first to drop if the
   ransomware-shaped burst check is wanted back — the unconditional
   hardline floor still blocks `rm -rf /` either way. Extend by hand from
   `tirith audit stats --format json` → `top_rules`. Note
   `approvals.mode` is the default `smart`, so heredoc / `-e -c` patterns
   already auto-approve; only Tirith's HIGH/CRITICAL findings were
   demanding a human.

### Steering profiles toward scripts

`config/SOUL_OPERATING.md` is appended to **every** rendered profile's
`SOUL.md` by `render.py` — one source, all four profiles. SOUL.md rides the
system prompt on every turn, unlike a skill (lazily loaded), so always-on
behaviour belongs there; the per-profile SOUL.md stays the role document.

The block tells each profile: 3+ shell/file operations for one goal → **one
call**; a chain with logic between the calls (filter, branch, loop, retry,
reduce output before it reaches context) → **`execute_code`**; a shell
chore (git, builds, `gh`, docker, tests) → **write a script with
`write_file` and run it by path** — which is also the friction-free path
past both guards above; and never inline a big payload (heredocs, giant
one-liners, nested `$(...)` are what the scanners mis-parse).

Why it was needed: the terminal tool's own description steers work *away*
from shell ("do NOT use cat/head/tail — use read_file, grep/rg/find/ls —
use search_files, sed/awk — use patch"), which turns one shell pipeline
into three or four separate tool calls, one turn each. `execute_code` is
the tool built to collapse exactly that and was underused relative to that
baseline.

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
header mounted read-only at `/etc/komodo-auth-header` (host path
`/home/ubuntu/.komodo-auth-header`, overridable via the stack
`environment` var `KOMODO_AUTH_HEADER`). It can deploy stacks, run builds,
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
`scripts/prune-repos.sh`, scheduled as a no-agent cron job). Overrides:
`HERMES_REPOS_DIR` / `HERMES_WORKTREES_DIR`. Everything is
runtime-uid-owned, so every profile reaches the same store; git's worktree
model provides the isolation (one branch, one checkout).

## Provisioning per-profile identities (GitHub Apps + Discord bots)

Every profile has its OWN bot identity in both GitHub and Discord — the
team roles must be distinguishable from one another and from the main
agent, and must never share or impersonate another's. Both halves need one
manual step that no API can perform; the scripts in `scripts/` wrap
everything around them.

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
  PEM as root:ubuntu 640 into `/etc/hermes/`) and append `env-lines.txt` to
  `/etc/hermes/hermes-main.env`. Re-running is safe — an existing App name
  fails at GitHub's own name check before anything is created.
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
- **The self-pull jobs are `no_agent` scripts, deliberately.** A
  `no_agent` job delivers its script's stdout verbatim and **empty stdout
  is silent** — no message, no agent turn, no tokens. That is what makes a
  5-minute poll affordable: the poll is free and the agent wakes only when
  there is work. `deliver = "bot-chat"` injects into the job's OWN
  profile's Bot Chat as a message the agent responds to; delivering to the
  profile's Discord channel would NOT work, because the Discord adapter
  drops the bot's own messages. Incidents are printed **once and then
  deduped** via a state file, so a persistent fault wakes the team a single
  time instead of every tick.
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

After editing anything in `config/`, just `git commit && git push` — the
Docker build runs render.py itself, so there is NO committed `build/` output
to keep in sync (the old "commit the build/ output" step is gone). To
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
# Gateway: /v1/models should list the explicit entries PLUS the live
# Ollama Cloud catalogue (as ollama/<id>) — if it instead returns a
# swarm of openai/… names, check_provider_endpoint isn't taking effect.
curl -s http://127.0.0.1:4000/v1/models \
  -H "Authorization: Bearer $(sudo cat /etc/hermes/litellm.env | grep ^LITELLM_MASTER_KEY= | cut -d= -f2)" \
  | python3 -c 'import json,sys; print(*(m["id"] for m in json.load(sys.stdin)["data"]), sep="\n")'
```

`hermes doctor` inside the container reports warnings for Hermes'
*built-in* honcho/vision integrations — expected and benign; this stack
wires Honcho via MCP instead, and vision just needs system deps the
container lacks.