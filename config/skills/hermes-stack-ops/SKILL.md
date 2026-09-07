---
name: hermes-stack-ops
description: How this agent's own stack works — config source of truth, gateway, verification
version: 1.0.0
metadata:
  hermes:
    tags: [hermes, docker, litellm, self]
    category: devops
---

# This stack's operating manual (for the agent living in it)

You run as the `hermes-main` container of the Komodo Stack `hermes`:
Hermes agent + Honcho (memory) + Firecrawl (web) + LiteLLM (LLM gateway)
+ a stack-local ollama (embeddings). State persists in the
`hermes-main-data` volume at `/opt/data`. The image is a thin build over
the OFFICIAL `nousresearch/hermes-agent` image: one container hosts ALL
Hermes profiles under its s6 supervision (the default profile's gateway
multiplexes for the container; named profiles register their own slots).

## When to Use

- Anything about your own configuration, model routing, tools, or memory
- Diagnosing why a tool, model, or platform (Discord) misbehaves
- Deciding what changes need a deploy vs what you can change live
- Adding or changing a Hermes profile (they are declarative in the repo)

## Procedure

**Configuration is GitOps — the repo is the source of truth, not you.**
`/opt/data/config.yaml` is a rendered copy of the git repo `<owner>/hermes`
(`config/` → `render.py` run INSIDE the image build → baked `/overlay`),
applied to the profile dir at every container start by the entrypoint.
NEVER hand-edit `/opt/data/config.yaml` or write auth into
`/opt/data/.env` — both are overwritten or shadowed.
Config/model/tool changes: edit `config/` in the repo → push (no render
step — the Docker build renders) → deploy (the `komodo-ops` skill covers
deploy mechanics). A config change ships end-to-end on its own: the push
invalidates the image's overlay COPY layer, the rebuild emits a new image
ID, and the deploy recreates this container on the image change — no
manual restart needed.

**Every LLM call goes through LiteLLM** (`http://litellm:4000`) — never
call provider APIs directly; you don't have their keys. The gateway's
config (`config/litellm.yaml`) is baked into the `litellm:main` image;
config changes recreate the litellm container on deploy. Model aliases
live in the repo's `config/models.toml`: `baseline` (glm-5.3-flash, 1M
window — primary/simple work), `elevated` (glm-5.3, hard tasks + failure
fallback), `nano` (nemotron-3-nano:30b, cheap-turn router + light side
tasks), `ultra` (nemotron-3-ultra, Honcho's consumers). Ollama Cloud
models are addressed as `ollama/<id>` — the gateway's `ollama/*` wildcard
route. New Ollama Cloud models need no gateway config; add an alias (with
the TRUE context window) to models.toml to use one. Verify windows with
`POST https://ollama.com/api/show` (`model_info.*.context_length`); Hermes
hard-rejects windows below 64k, and a stated window larger than reality
breaks compaction.

**Memory is Honcho via MCP** (`mcp_honcho_*` tools) — the built-in Honcho
integration is deliberately disabled (overlay `honcho.json`). Web work goes
through Firecrawl MCP (`mcp_firecrawl_*`). Most MCP tool schemas are
deferred behind the `tool_search`/`tool_describe`/`tool_call` bridges — use
them rather than expecting every tool visible up front.

**GitHub is a GitHub App** (app 4860240, installed as
`hermes-main[bot]`): `gh` is already authed and git already routes
credentials through gh (`gh auth git-credential`) — just use `gh` and
`git` normally. The entrypoint's background refresher keeps gh's stored
installation token fresh (boot + every 30 min; tokens last 1h).

**Git repos live centrally — worktree per session, never clone.**
One bare clone per repo sits in `/opt/data/repos/<host>/<owner>/<repo>.git`
(shared object store, no working tree — never commit there). Work happens
in per-SESSION worktrees under `/opt/data/worktrees/<session-slug>/<repo>/`
(the slug derives from `HERMES_SESSION_KEY`, which the gateway bridges into
every tool subprocess, so two sessions never share a checkout). Use the
baked helper — do NOT `git clone` into your own space:
- `git-repo.sh worktree <git-url> [branch] [dest]` → prints your session's
  checkout path (idempotent central clone + worktree add).
- If the branch is already checked out in another session's worktree, the
  helper creates a session branch `s/<slug>` instead — push it with
  `git push origin HEAD:<branch>`.
- `git-repo.sh list` shows all repos + worktrees; `git-repo.sh prune
  --days 7` (weekly) removes session dirs idle > N days and prunes the
  bare repos' worktree admin. `HERMES_REPOS_DIR` / `HERMES_WORKTREES_DIR`
  override the locations.

## Pitfalls

- Host is 1 CPU / 6 GB. Bulk crawling, parallel builds, or many concurrent
  background tasks starve every sibling container. Keep background work
  serialized.
- Discord REST scripting needs a real browser-like `User-Agent` header —
  bare urllib gets Cloudflare `error 1010`. Bot DMs fail (403 code 50278)
  when the recipient blocks server-member DMs — @mention in a server
  channel instead.
- Commit attribution defaults to `hermes-agent <hermes-agent@localhost>`;
  the human's identity is not configured — don't impersonate it.
- Scheduled tasks (cron) are available: the scheduler is embedded in this
  gateway. Results can deliver to `discord` or `discord:#person`.
  Script-only jobs (`--no-agent`) cost zero tokens — prefer them for pure
  watchdogs. Don't enable `cron.allow_agent_scheduling` chains casually.
- Kanban is available (dispatcher already embedded) — if used on this host,
  cap `kanban.max_in_progress` low (1–2) in profile.toml config_extra.

## Verification

After any config deploy: `hermes mcp test honcho` and
`hermes mcp test firecrawl` must both report Connected; check
`/opt/data/logs/gateways/default/current` (per-profile s6 gateway log)
and `docker logs hermes-main` for `✓ discord connected` and no repeated
warnings; the Komodo stack `hermes` should be `running` (see
`komodo-ops`).
`hermes doctor` warnings about the *built-in* honcho/vision integrations
are expected and benign for this stack.