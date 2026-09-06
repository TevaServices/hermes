# hermes

A GitOps-managed [Hermes agent](https://github.com/NousResearch/hermes-agent) stack:
the agent in Docker, its configuration rendered from small declarative files, and
[Honcho](https://github.com/plastic-labs/honcho) (memory) + [Firecrawl](https://docs.firecrawl.dev/contributing/self-host)
(web) as sibling containers — all deployed and kept up to date on a Linux host by
[Komodo](https://komo.do).

```
                    git push (this repo)
                          │ webhook
                          ▼
                   Komodo Core (Resource Sync + Procedure)
                          │
                          ▼
              Linux host — Periphery agent
   ┌────────────────────────────────────────────────────────┐
   │  docker network: hermes-net                             │
   │                                                        │
   │  hermes-main ──── MCP ────► honcho-mcp ──► honcho-api    │
   │  (hermes-researcher …)          honcho-deriver          │
   │      │  MCP                    honcho-db, honcho-redis  │
   │      ▼                                                 │
   │  firecrawl-mcp (in-agent, stdio) ──► firecrawl-api       │
   │         firecrawl-playwright / redis / rabbitmq / db    │
   └────────────────────────────────────────────────────────┘
```

## Why this shape

| Requirement | How it's met |
|---|---|
| Install Hermes agent via Docker | `docker/hermes/Dockerfile` runs the official installer at a pinned ref; agent state persists in a volume |
| Overlay config / profiles | `config/` + `render.py` → per-profile overlays in `build/<profile>/`, applied on every container start |
| Keep install + config up to date | version pins in `mise.toml` `[env]` (+ Komodo stack env); push → webhook → rebuild/redeploy. `scripts/check-updates.sh` reports drift |
| GitOps on the Linux host | Komodo Resource Sync applies `komodo/resources.toml`; Stacks deploy the compose files from this repo ([komodo/README.md](komodo/README.md)) |
| Easy model/provider config | providers and models are two small TOML files; profiles pick models by alias — no hand-editing Hermes' config.yaml |
| Honcho + Firecrawl in containers | `compose/honcho.compose.yml`, `compose/firecrawl.compose.yml`, wired into each agent as MCP servers via `config/integrations.toml` |

## Repo layout

```
mise.toml               tools (python, uv), build variables ([env]), all tasks
config/
  providers.toml        LLM endpoints + API-key env names (no keys here)
  models.toml           short aliases -> provider/model IDs
  integrations.toml     Honcho / Firecrawl (and any other MCP) wiring
  profiles/<name>/      per-agent model choice, platforms, SOUL.md, skills/
render.py               compiles config/ -> build/<profile>/ (config.yaml, .env.example)
build/<profile>/        rendered overlay (COMMITTED — periphery deploys from
                        git and mounts it into the agent container)
docker/hermes/          agent image (official installer at pinned ref) + entrypoint
compose/                three stacks: hermes, honcho, firecrawl (shared hermes-net)
secrets/                *.env.example templates (real files never committed)
komodo/                 Resource Sync definitions + setup guide
scripts/                bootstrap-host.sh, check-updates.sh
```

## How configuration works (the abstraction)

You never touch a Hermes config file. Three small files describe everything,
and `mise run render` compiles them into what the agent reads:

- **`config/providers.toml`** — every endpoint Hermes can reach: base URL
  (empty = provider default), API mode, and *which env var name* holds its key.
- **`config/models.toml`** — memorable aliases (`fast`, `smart`, `coder`, …)
  mapped to provider-specific model IDs.
- **`config/profiles/<name>/profile.toml`** — one agent: `model = "smart"`,
  `integrations = ["honcho", "firecrawl"]`, gateway platforms, and an optional
  `[config_extra]` passthrough for anything Hermes-specific. `SOUL.md` sits
  beside it.

Switching an agent from Claude on OpenRouter to a local Ollama model is a
one-line diff in one TOML file, then `mise run render && git commit && git push` —
the running agent picks it up on next deploy (the entrypoint re-applies the
overlay on every start).

## Quickstart (local)

Requires: Docker and [mise](https://mise.jdx.dev/) (≥2025). Everything else —
Python 3.12, uv — is provided by `mise.toml` `[tools]` automatically.

```bash
mise trust                       # once, after cloning
cp secrets/hermes-main.env.example secrets/hermes-main.env   # fill in real keys
cp secrets/honcho.env.example secrets/honcho.env
cp secrets/firecrawl.env.example secrets/firecrawl.env
mise run up                       # render -> network -> build & start all three stacks
mise run logs                    # watch it come up
```

Hermes runs headless in `gateway` mode (messaging platforms configured in the
profile). To chat in a terminal instead: `mise run chat`.

Diagnostics: `docker exec -it hermes-main hermes doctor`.

## Deploying to the Linux host with Komodo

Full walkthrough in [komodo/README.md](komodo/README.md). Short version:

1. `sudo ./scripts/bootstrap-host.sh` on the host — creates `/etc/hermes/*.env`
   (fill in keys) and the `hermes-net` docker network.
2. Point `komodo/resources.toml` at your fork and your Komodo server name.
3. Create a Resource Sync against this repo, run it once.
4. Add the git webhook (Resource Sync + the `deploy-changed-stacks` Procedure).

From then on: **push to `main` = deploy**. Komodo redeploys only the stacks whose
files changed; agent memory, sessions, and skills live in volumes and survive.

## mise: tools, build variables, and tasks

`mise.toml` is the project's single entrypoint:

- **`[tools]`** — Python 3.12 (render.py needs 3.11+ for stdlib `tomllib`) and
  uv, pinned and installed by mise per-project. No system-wide installs.
- **`[env]`** — every *build-time* variable docker compose interpolates:
  the upstream version pins (`HERMES_REF`, `HONCHO_VERSION`,
  `FIRECRAWL_VERSION`), and `HERMES_ENV_DIR` (absolute, via the
  `{{config_root}}` template) pointing at the secrets directory. mise exports
  these to all tasks; compose reads them from the process environment.
- **`[tasks]`** — `render`, `validate`, `up`, `down`, `ps`, `logs`, `chat`,
  `pull`, `net`, `check-updates`, `clean`. `mise tasks` lists them; `mise run
  up` runs render + net first via task dependencies.

Per-machine overrides go in `mise.local.toml` (gitignored), e.g.:

```bash
mise set TZ=UTC
mise set HERMES_ENV_DIR=/etc/hermes
mise set FIRECRAWL_PORT=3002
```

**Secrets note**: API keys and bot tokens are *runtime* container secrets, not
build variables — compose deliberately never interpolates them (see the
`env_file` design notes in the compose files). They live in env files under
`$HERMES_ENV_DIR` (templates in `secrets/`), which mise points compose at.
Build-time variables and the secrets-dir location itself, however, are all
mise-provided. Komodo deployments don't run mise — they get the same variables
from the Stack `environment` in `komodo/resources.toml` instead.

## Keeping up to date

```bash
mise run check-updates   # pins vs upstream (hermes/honcho/firecrawl)
```

- **Hermes / Honcho / Firecrawl**: bump the pin in `mise.toml` `[env]` (and the
  matching `environment` value in `komodo/resources.toml`), commit, push. The
  webhook triggers rebuild/redeploy with all state preserved.
- **Firecrawl caveat**: its self-host stack's env var names change between
  releases — when bumping, diff `compose/firecrawl.compose.yml` against
  upstream's `docker-compose.yaml` for the new tag.
- **In-place Hermes updates** (skip-the-rebuild alternative): the compose file
  documents the `HERMES_UPDATE_ON_START` + code-volume opt-in, which uses
  Hermes' own `hermes update`.

## Security notes

- No secrets in git — ever. `secrets/*.env.example` are templates; real files
  live in `/etc/hermes` (mode 600) on the host and are mounted into containers.
- Nothing is published to the public internet by default: Firecrawl's API binds
  to `127.0.0.1`, Honcho's API isn't published at all, and both are reached by
  agents over the internal `hermes-net` bridge.
- Self-host Honcho defaults to `POSTGRES_HOST_AUTH_METHOD=trust` (upstream
  default) and self-host Firecrawl runs with `USE_DB_AUTHENTICATION=false` —
  acceptable only on trusted networks; both compose files point at the knobs to
  tighten.
- Mounting `/var/run/docker.sock` into an agent (for its Docker terminal backend)
  grants it host-level power — the compose file keeps that commented out.

## Verification checklist for a new host

- [ ] `mise run validate` passes locally and `mise run render` output looks right
- [ ] `hermes-main` starts; `docker logs hermes-main` shows the gateway connecting
- [ ] `docker exec -it hermes-main hermes doctor` is green
- [ ] Agent's Honcho MCP tools respond (`honcho-mcp` reachable over hermes-net)
- [ ] Agent can scrape a page via Firecrawl (`curl 127.0.0.1:3002/v0/health/readiness`)

## Sources

- Hermes Agent: [repo](https://github.com/NousResearch/hermes-agent) ·
  [configuration](https://hermes-agent.nousresearch.com/docs/user-guide/configuration) ·
  [MCP config](https://hermes-agent.nousresearch.com/docs/reference/mcp-config-reference) ·
  [profiles](https://hermes-agent.nousresearch.com/docs/user-guide/profile-distributions)
- Komodo: [compose stacks](https://komo.do/docs/deploy/compose) ·
  [resource sync](https://komo.do/docs/automate/sync-resources) ·
  [monorepo discussion](https://github.com/moghtech/komodo/discussions/264)
- Honcho: [repo](https://github.com/plastic-labs/honcho) ·
  [self-hosting](https://honcho.dev/docs/v3/contributing/self-hosting)
- Firecrawl: [self-host](https://docs.firecrawl.dev/contributing/self-host) ·
  [MCP server](https://github.com/firecrawl/firecrawl-mcp-server)