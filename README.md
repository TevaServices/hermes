# hermes

A GitOps-managed [Hermes agent](https://github.com/NousResearch/hermes-agent) stack:
the agent in Docker, its configuration rendered from small declarative files, and
[Honcho](https://github.com/plastic-labs/honcho) (memory) + [Firecrawl](https://docs.firecrawl.dev/contributing/self-host)
(web) + [LiteLLM](https://docs.litellm.ai/) (LLM gateway) as sibling containers —
all deployed and kept up to date on a Linux host by [Komodo](https://komo.do).

```
           merge a PR to main (this repo)
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
   │                                 honcho-deriver          │
   │      │  MCP                    honcho-db                │
   │      ▼                                                 │
   │  firecrawl-mcp (in-agent, stdio) ──► firecrawl-api       │
   │         firecrawl-playwright / db                       │
   │                                                        │
   │  shared: valkey (aliases: firecrawl-redis, honcho-redis) │
   │  hermes-main / honcho / firecrawl ──► litellm ──►       │
   │    Ollama Cloud / OpenRouter free, one group per tier   │
   └────────────────────────────────────────────────────────┘
```

## Why this shape

| Requirement | How it's met |
|---|---|
| Install Hermes agent via Docker | `docker/hermes/Dockerfile` is a thin build over the official `nousresearch/hermes-agent:<ref>` image (pinned ref; s6 supervision included); agent state persists in a volume |
| One container, all profiles | the official image's s6 supervision hosts every profile as a supervised gateway service — the docs' recommended deployment model |
| Overlay config / profiles | `config/` + `render.py` are compiled INTO the image at build time (`/overlay/<profile>`), applied to profile dirs on every container start |
| Keep install + config up to date | the pin in `mise.toml` `[env]` is both the FROM tag and the config baseline; merge to `main` → webhook → rebuild/redeploy. `scripts/check-updates.sh` reports drift |
| GitOps on the Linux host | Komodo Resource Sync applies `komodo/resources.toml`; Stacks deploy the compose files from this repo ([komodo/README.md](komodo/README.md)) |
| Easy model/provider config | the agent names one of four gateway tiers (`cheap`/`smart`/`smarter`/`smartest`); which provider serves a tier is `config/litellm.yaml` alone, so swapping backends never touches a profile or an env file |
| Honcho + Firecrawl in containers | `compose/honcho.compose.yml`, `compose/firecrawl.compose.yml`, wired into each agent as MCP servers via `config/integrations.toml` |
| One LLM gateway for every app | `compose/litellm.compose.yml` + `config/litellm.yaml` — LiteLLM serves the four tiers (routing each among its members, latency-based) and passes the rest of the Ollama Cloud catalogue through a wildcard |

## Repo layout

```
mise.toml               tools (python, uv), build variables ([env]), all tasks
config/
  litellm.yaml          the gateway's config — the four model tiers
                        (cheap/smart/smarter/smartest) and the backend each
                        one points at: the file you swap for YOUR provider
  providers.toml        LLM endpoints + API-key env names (no keys here)
  models.toml           the tier names + each one's TRUE context window
  integrations.toml     Honcho / Firecrawl (and any other MCP) wiring
  skills/               stack-wide skills (merged into EVERY profile)
  profiles/default/     the ROOT profile (one agent): model choice, platforms,
                        SOUL.md, skills/
  profiles/planner/     team PM+design agent (issues, boards, specs; Discord #planning)
  profiles/developer/   team implementation agent (draft PRs, never merges; #dev)
  profiles/reviewer/    team quality gate (reviews, merges after human gate; #reviews)
render.py               compiles config/ -> /overlay/<profile> at image build
                        time (no committed build output)
docker/hermes/          thin image over the official agent image + entrypoint
compose/                four stacks: hermes, honcho, firecrawl, litellm (shared hermes-net)
secrets/                *.env.example templates (real files never committed)
komodo/                 Resource Sync definitions + setup guide
scripts/                host setup + credential/diagnostic helpers
                        (bootstrap-host.sh, create-github-apps.py,
                        set-team-discord-tokens.py, discord-thread-doctor.py)
                        + container cron shims (prune-repos.sh, refresh-repos.sh)
```

## The agile SaaS team (planner / developer / reviewer)

Three named Hermes profiles work as a GitHub-first agile team — **GitHub
is the system of record, Discord is the discussion surface**. The
`team-conventions` skill (config/skills/, shared by every profile)
defines the workflow: idea → issue → routed developer (label
`status/ready` — GitHub App bots cannot be assignees) → **draft PR** →
reviewer gates (`team-reviewer`) → human gate (the user) → reviewer
merges. Repos join the workflow via the planner's `team-onboarding`
skill (adds the `hermes-team` topic tag, a per-repo board or status
label set, branch protection, CI).

Enforcement is identity-based, not trust-based: each role is its own
GitHub App (least-privilege permission set, PEM at
`/etc/hermes/github-app-<profile>.pem`) and its own Discord bot token
(`PROFILE_<NAME>_*` entries in hermes-main.env, mapped by the
entrypoint into each profile's own `.env`). planner cannot push
(Read-only code + issue/project writes); developer cannot merge
(branch protection + no merge rights); reviewer merges only after
the user's approval. The default profile's `gateway.profile_routes` sends
each team channel to its profile, and each role's channel is its **own**
(per-profile `platforms.discord.extra`: `allowed_channels` +
`require_mention = false`): the bot answers there without being @mentioned
and ignores the others. `#hermes` and `#hermes-home` stay with the default
agent, fenced to those two and likewise mention-free. A
request in a team channel gets its own auto-created thread, so the issue
link comes back in that thread — see the `team-conventions` skill.

## How configuration works (the abstraction)

You never touch a Hermes config file. A few small files describe everything,
and render.py compiles them into what the agent reads — at IMAGE BUILD time:

- **`config/litellm.yaml`** — the gateway's own config, and the ONE place a
  model backend is chosen. It serves four tier names — `cheap`, `smart`,
  `smarter`, `smartest` — and everything under each group's `litellm_params`
  is yours to point anywhere: provider, upstream model id, base URL, key,
  extra params, or several members per tier for load-balancing and failover.
  Swapping Ollama Cloud for OpenAI, Anthropic or a local vLLM is an edit to
  this file alone.
- **`config/models.toml`** — the same tiers, as the AGENT side sees them: the
  gateway name plus the model's TRUE context window. render.py emits the
  window into the agent's `model_overrides` so context is sized correctly
  (too small compacts early, too large overruns the provider), and it FAILS
  THE BUILD if a tier here has no group on the gateway. Repointing a tier at
  a differently-windowed model means moving this value with it;
  `mise run check-model-windows` verifies the pair against the provider's
  own API.
- **`config/providers.toml`** — every endpoint Hermes can reach: base URL
  (empty = provider default), API mode, and *which env var name* holds its key.
- **`config/profiles/<name>/profile.toml`** — one agent: `model = "smarter"`,
  `integrations = ["honcho", "firecrawl"]`, gateway platforms, and an optional
  `[config_extra]` passthrough for anything Hermes-specific. `SOUL.md` sits
  beside it.

Switching an agent's model is a one-line diff — to a different tier, or to a
different backend behind that tier with no profile change at all — then a PR:
the image rebuild renders the new overlay, the deploy recreates the
container, and the entrypoint applies the overlay to the profile dir on
start.

## Before you deploy: the values you must set

Nothing in this repo is pinned to one person's accounts. Everything that
varies per deployment is either a documented placeholder (`<owner>`) or an
environment variable. This is the complete list — work through it once.

**In git (edit these, they are your fork's config):**

| What | Where |
|---|---|
| `<owner>` — the GitHub account owning your fork | `komodo/resources.toml` (repo fields), `config/SOUL_OPERATING.md` |
| **Your LLM backend: which provider serves each model tier** | `config/litellm.yaml` (the four groups; the keys they need live in `litellm.env`) |
| The tiers' context windows — keep in step with `litellm.yaml` | `config/models.toml` |
| Any other LLM endpoint Hermes could reach | `config/providers.toml` |
| Profile model choices (tier names) | `config/profiles/*/profile.toml` (`model = "..."`) |
| Which profiles exist, and their skills | `config/profiles/*/` |

**In the host env file (`$HERMES_ENV_DIR/hermes-main.env`, from
`secrets/hermes-main.env.example`):**

| Variable | What it is |
|---|---|
| `LITELLM_MASTER_KEY` | `openssl rand -hex 32`; mirrored into the apps' key vars |
| `OLLAMA_API_KEY`, `OPENROUTER_API_KEY` | keys for the backends `config/litellm.yaml` declares (Ollama Cloud for the four tiers, OpenRouter free for Firecrawl) |
| `TEAM_OWNER` | the GitHub account whose repos the team works on — the queue scripts refuse to run without it |
| `DISCORD_BOT_TOKEN`, `DISCORD_ALLOWED_USERS` | the default agent's bot |
| `DISCORD_HOME_CHANNEL` | where gateway system messages and the housekeeping jobs post |
| `DISCORD_CHANNEL_MAIN` / `_PLANNER` / `_DEVELOPER` / `_REVIEWER` | one per channel; each team profile answers only in its own |
| `PROFILE_<NAME>_DISCORD_BOT_TOKEN` | one bot per team profile (a profile left on the main token is refused) |
| `PROFILE_<NAME>_GITHUB_APP_ID` / `_INSTALLATION_ID` | per-profile GitHub App (see below) |
| `PROFILE_<NAME>_GH_APP_NAME` | only if the default App name `hermes-<role>` is taken on GitHub |
| `HONCHO_API_KEY` | any non-empty value while honcho-api runs no-auth |
| `FIRECRAWL_API_KEY` | must equal `TEST_API_KEY` in `firecrawl.env` |

**Credentials that need a one-time browser step** (both scripts wrap
everything around the manual click that no API can perform):

```bash
python3 scripts/create-github-apps.py --org <your-org>   # or omit --org for user-owned
sudo sh build/github-apps/host-install.sh                # installs the PEMs on the host
sudo python3 scripts/set-team-discord-tokens.py          # hidden input, validated against Discord
```

**Per-machine values:** `HERMES_ENV_DIR` (default `/etc/hermes`),
`HERMES_HOST_GROUP` (default `ubuntu` — the group owning the env files),
`TZ` (optional; the container runs UTC without it, which is what the cron
schedules in `config/cron.toml` are written against), and the Komodo server
name in `komodo/resources.toml`.

`mise run validate` checks the config; `mise run render` shows exactly what
the image will bake in.

## Quickstart (local)

Requires: Docker and [mise](https://mise.jdx.dev/) (≥2025). Everything else —
Python 3.12, uv — is provided by `mise.toml` `[tools]` automatically.

```bash
mise trust                       # once, after cloning
cp secrets/hermes-main.env.example secrets/hermes-main.env   # fill in real keys
cp secrets/honcho.env.example secrets/honcho.env
cp secrets/firecrawl.env.example secrets/firecrawl.env
cp secrets/litellm.env.example secrets/litellm.env
mise run up                       # build (renders config into the image) -> network -> start all four stacks
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

From then on: **merging a PR to `main` = deploy**. `main` is protected, so a
direct push is rejected and every change lands as a squash-merged PR; the
webhook fires on the push that merge produces, so the deploy path is unchanged.
Komodo redeploys only the stacks whose files changed; agent memory, sessions,
and skills live in volumes and survive.

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
  `pull`, `net`, `check-updates`, `check-model-windows`, `clean`. `mise tasks`
  lists them; `mise run up` runs render + net first via task dependencies.

Per-machine overrides go in `mise.local.toml` (gitignored), e.g.:

```bash
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
mise run check-updates         # pins vs upstream (hermes/honcho/firecrawl/litellm)
mise run check-model-windows   # each tier's declared window vs the provider's API
```

- **Hermes / Honcho / Firecrawl**: bump the pin in `mise.toml` `[env]` (and the
  matching `environment` value in `komodo/resources.toml`), then squash-merge the
  PR. The webhook triggers rebuild/redeploy with all state preserved.
- **LiteLLM**: public image, no Build resource — pull
  `ghcr.io/berriai/litellm:main-latest` on the host (the multi-arch tag;
  versioned tags are amd64-only — match the tag to the host's
  architecture) and redeploy. `auto_pull=false` pins the local image
  until re-pulled.
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

## License

MIT — see [LICENSE](LICENSE).

This repo contains configuration and scripts only. The images it deploys
carry their own licenses: the Hermes agent is MIT, Honcho and Firecrawl are
AGPL-3.0, Komodo is GPL-3.0, and LiteLLM is MIT with a separate enterprise
directory. Nothing here links against or vendors them.
