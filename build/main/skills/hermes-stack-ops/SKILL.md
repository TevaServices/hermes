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
+ a stack-local ollama (embeddings). State persists in the `hermes-main-data`
volume at `/data`.

## When to Use

- Anything about your own configuration, model routing, tools, or memory
- Diagnosing why a tool, model, or platform (Discord) misbehaves
- Deciding what changes need a deploy vs what you can change live

## Procedure

**Configuration is GitOps — the repo is the source of truth, not you.**
`/data/config.yaml` is a rendered copy of the git repo `<owner>/hermes`
(`config/` → `render.py` → `build/main/`), re-applied from the read-only
`/overlay` mount at every container start. NEVER hand-edit `/data/config.yaml`
or write auth into `/data/.env` — both are overwritten or shadowed.
Config/model/tool changes: edit `config/` in the repo → `mise run render` →
push → deploy (the `komodo-ops` skill covers deploy mechanics). The overlay
only re-applies on container start, so a deploy that doesn't recreate the
container needs a restart to pick it up.

**Every LLM call goes through LiteLLM** (`http://litellm:4000`) — never
call provider APIs directly; you don't have their keys. Model aliases live
in the repo's `config/models.toml`: `smart` (mistral-large-3:675b, primary),
`fast` (gpt-oss:20b, simple-turn router), `frontier` (glm-5.3, opt-in),
`coder` (kimi-k2.7-code). `context_length` there states each model's TRUE
provider window — verify with `POST https://ollama.com/api/show`
(`model_info.*.context_length`); Hermes hard-rejects windows below 64k, and
a stated window larger than reality breaks compaction.

**Memory is Honcho via MCP** (`mcp_honcho_*` tools) — the built-in Honcho
integration is deliberately disabled (overlay `honcho.json`). Web work goes
through Firecrawl MCP (`mcp_firecrawl_*`). Most MCP tool schemas are
deferred behind the `tool_search`/`tool_describe`/`tool_call` bridges — use
them rather than expecting every tool visible up front.

**GitHub is a GitHub App** (app 4860240, installed as
`hermes-main[bot]`): `gh` is already authed and git already carries
a credential helper — just use `gh` and `git` normally. A fresh
installation token (1h TTL) is minted per git op by
`/usr/local/bin/github-app-token.sh`; never store tokens.

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
`/data/logs/gateway.log` tail for `✓ discord connected` and no repeated
warnings; the Komodo stack `hermes` should be `running` (see `komodo-ops`).
`hermes doctor` warnings about the *built-in* honcho/vision integrations
are expected and benign for this stack.