---
name: hermes-stack-ops
description: How this agent's own stack works — config source of truth, gateway, verification
version: 1.2.0
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
config changes recreate the litellm container on deploy.

**The models are four TIER NAMES, and they are what you send**: `cheap`
(nemotron-3-nano:30b, 256k — the cheap-turn router, the light side tasks,
and every Honcho consumer), `smart` (gemma4:cloud, 256k — the planner's
everyday tier), `smarter` (glm-5.3-flash, 1M — the default, developer and
release profiles, and compression), `smartest` (glm-5.3, 1M — judgment work and
opt-in escalation; no vision). The tiers are defined in
`config/models.toml` (name + TRUE context window); WHICH BACKEND SERVES
EACH ONE is `config/litellm.yaml` alone, so pointing a tier at another
provider is an edit to that file and nothing else. Because the tier names
are the names the gateway actually serves, they are also what works on the
command line: `/model smarter`, `/model cheap`, `/model smartest` mid-session
all resolve (the old alias names never did — they existed only in the repo).

`render.py` FAILS THE BUILD when a tier has no group on the gateway, and
turns each tier into the rendered config's `model_overrides` block — the one
line Hermes (the cheap lane, the aux models, any `/model` switch) and the
`claude` wrapper both read, so the window is never guessed. Repoint a tier
at a differently-windowed model and its `context_length` must move in the
same change; `mise run check-model-windows` verifies the pair against the
provider's own API (`POST https://ollama.com/api/show` ->
`model_info.*.context_length` — third-party catalogues get these wrong).
Hermes hard-rejects windows below 64k, and a stated window larger than
reality breaks compaction. Raw `ollama/<id>` ids still resolve through the
gateway's wildcard passthrough, but they have NO declared window: promote a
model to a tier before relying on it.

**Memory is Honcho via MCP** (`mcp_honcho_*` tools) — the built-in Honcho
integration is deliberately disabled (overlay `honcho.json`). Web work goes
through Firecrawl MCP (`mcp_firecrawl_*`). Most MCP tool schemas are
deferred behind the `tool_search`/`tool_describe`/`tool_call` bridges — use
them rather than expecting every tool visible up front.

**Browser tools (`browser_exec`) run on a local headless Chromium
sidecar**, not on a desktop Chrome (there is none in a container). The
image supervises one via s6 (`chromium-cdp` service — the Playwright
headless shell baked into the base image) serving CDP on
`127.0.0.1:9333`, and the rendered config points `browser.cdp_url` at
it, so the harness attaches through `BU_CDP_URL` automatically. If
browser calls fail with "chrome-not-running" or a CDP connection error,
check the sidecar: `s6-svstat /run/service/chromium-cdp` (or `curl -s
127.0.0.1:9333/json/version`). The service is toggled by
`HERMES_CHROMIUM_CDP` in compose; the data dir is
`/opt/data/chromium-cdp` (safe to wipe while the service is down —
it's just a profile cache).

**GitHub is a GitHub App** (installed as
`hermes-main[bot]`): `gh` is already authed and git already routes
credentials through gh (`gh auth git-credential`) — just use `gh` and
`git` normally. The entrypoint's background refresher keeps gh's stored
installation token fresh (boot + every 30 min; tokens last 1h).

**TWO credential sets per profile: personal App + org Apps, routed by
repo owner.** Every profile ALSO holds one GitHub App per org it works
with (any number of orgs — e.g. `acmecorp-hermes-*[bot]` for an org
"Acme Corp"), and the stack picks the token automatically:

- **`gh` is a shim** (the real CLI is `/usr/local/bin/gh-real`). It
  picks the ORG token when it can resolve the invocation's target owner
  to an org the profile has credentials for, and passes through
  otherwise. Three owner sources, in this order:
  1. a `-R`/`--repo` argument (every spelling gh accepts: `-R x/y`,
     `-R=x/y`, `-Rx/y`, `--repo x/y`), or a `gh repo <sub> owner/repo`
     positional;
  2. **for `gh api`, the ENDPOINT PATH** — `repos/<owner>/…` or
     `orgs/<owner>`. `gh api` accepts no `-R` at all (gh rejects the
     flag: `unknown shorthand flag: 'R'`), so when your cwd is a scratch
     dir — where REST payload files get written — the path is the only
     owner signal the call carries. Put the owner in the path and it
     routes from anywhere;
  3. the cwd git repo's origin.
  `gh auth *` and any call with `GH_TOKEN` set are ALWAYS passthrough.
- **A 403 `Resource not accessible by integration` on an org repo is a
  TOKEN question before it is a permission question.** The personal App
  has no installation on the org, and on a *public* repo its reads still
  succeed — so a write 403s while `gh api repos/<org>/<public-repo>` looks
  fine, which is exactly how a correct installation gets reported as a
  missing permission. Check, in this order:
  1. does the call carry owner context at all (path, `-R`, or cwd)? If
     not, re-run it as `GH_TOKEN="$(gh-org-token <orgslug>)" gh api …`;
  2. probe with a **PRIVATE** org repo read — 200 under the org token,
     404 under the personal one. A public repo proves nothing;
  3. read the GRANTED permissions with a USER token:
     `gh api /orgs/<org>/installations --jq '.installations[] | {app_slug,permissions}'`.
     The App's own token cannot read that endpoint (404 either way).
  Only if (3) shows the permission genuinely absent is it an owner-side
  fix. `mise run test` exercises this routing offline; the shim's own
  header carries the same note.
- **Cross-owner searches are the one sharp edge**: from inside an org
  worktree, `gh search` runs under the ORG token and CANNOT see
  personal repos (and vice versa from a personal worktree), and a
  search's `--owner` is a filter the shim does not route on (one search
  can span owners). For an ad-hoc cross-owner search, set the token
  yourself: `GH_TOKEN="$(gh-org-token <orgslug>)" gh search …`.
  The self-pull queue scripts already do this per owner
  (`TEAM_OWNER_ORGS`).
- **git routes through `git-credential-hermes.sh`**: an org-owned
  remote gets the org token; anything else replays into
  `gh auth git-credential` (personal, unchanged). No action needed —
  push/fetch to an org remote just works, and commits in org worktrees
  carry the org bot identity (git-repo.sh sets it per-worktree from the
  org descriptor).
- **Tokens are cached** at `$HOME/org-creds/<org>.token` and reused for
  ~45 min; the entrypoint re-mints at boot. If an app is
  re-installed (new installation id) the cache invalidates itself; a
  stale one after a PEM rotation is cleared by deleting
  `<slug>.token`.

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
  helper creates a session branch `s/<slug>` instead — publish it with
  `git-publish.py` (see below), not `git push`.
- **Publishing: `git-publish.py`, never `git push`.** A repo can require
  signed commits, and a GitHub App's commits are only verified when
  GitHub creates them server-side through the API — a pushed commit
  never is, and unsigned commits block the MERGE even when every check
  is green. `git-publish.py` replays the branch's commits as
  API-created ones (same messages, same diffs, same file modes), so they
  come back `verified: true`. It refuses anything it cannot prove and
  never pushes the default branch. Repair an existing branch of unsigned
  commits with `git-publish.py --replay-from origin/<base> --force`.
- `git-repo.sh list` shows all repos + worktrees; `git-repo.sh prune
  --days 30` (weekly) removes worktrees that are CLEAN (no uncommitted
  or untracked changes) or DIRTY but idle > N days — dirty-but-recent
  worktrees are always kept. `HERMES_REPOS_DIR` / `HERMES_WORKTREES_DIR`
  override the locations.

### Claude Code (`claude`) — available to EVERY profile

`claude` is not the developer's tool; every profile has it. It is the
shape for **writing or changing code** — reach for it instead of editing
files one tool call at a time. It is a wrapper (baked in
`docker/hermes/claude*`, copied to `/opt/data/tools/claude-hermes/` at
boot) around a volume-installed `claude-real` native binary (the
`@anthropic-ai/claude-code-linux-arm64` platform package, symlinked into
`/opt/data/bin` and `/usr/local/bin`).

Every invocation re-reads the rendered `config.yaml` for `$HERMES_HOME` —
so each profile gets its own model — and pins Claude Code to exactly the
model Hermes is running (`model.default`, a tier name like `smarter`),
routed through the LiteLLM gateway via
`ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN` (`$LITELLM_API_KEY`) — never
Anthropic directly, and never a hardcoded model id. The cheap-model slot
(`ANTHROPIC_SMALL_FAST_MODEL`) follows `smart_model_routing.cheap_model`.
An explicit `--model` flag always wins; without gateway creds it degrades
to stock claude.

It also sets **`CLAUDE_CODE_MAX_CONTEXT_TOKENS`** to the running model's
real window, out of the config's `model_overrides` block (which
`render.py` emits from every `context_length` in `config/models.toml`).
Claude Code's own model catalogue describes none of these tier names, so
without this it assumes **200k** and auto-compacts a 1M-context session
five times too early. The window follows the model, `--model` included —
never the profile default — and a model the config does not declare
leaves the variable unset rather than guessed. So: **a new model needs an
entry in `config/models.toml`** (id + true window) before you can run it
here; that one line serves Hermes' own resolution, the cheap/auxiliary
lanes, and `claude`.

**Driving it**

- One-shot (preferred): `claude -p '<task>' --max-turns 10`, run in the
  project worktree. Put the acceptance criteria in the task text.
- Multi-turn / iterative: `tmux new-session -d -s cc …`, driven with
  send-keys / capture-pane.
- A hard multi-step refactor may opt up a tier: `--model smartest` instead
  of the profile's default (`smarter` for the default, developer and
  release profiles).
- In claude's shell, `claude_model` prints the active model;
  `/opt/data/tools/claude-hermes/claude-model-resolve.py <config.yaml>`
  prints provider + primary + cheap model for a given profile, and
  `… --window <model-id> <config.yaml>` prints the window the wrapper will
  export for that model (exit 1 = not declared, so no window will be set).
- **You stay accountable for what lands.** After it finishes, read
  `git diff`, run the repo's tests/lint yourself, and commit under your
  own identity. A `claude` run is a claim until you have verified it.
- **When NOT to use it**: `claude` writes code. For reasoning whose
  intermediate output should stay out of your context, use
  `delegate_task` (below); for a mechanical multi-step shell/file job,
  `execute_code` is cheaper.

**Updates are NOT pinned**: the entrypoint provisions the registry's
`latest` at boot (idempotent), and the declared no-agent cron job
`team: claude code update` (script `claude-update.sh`, daily 4:37am)
swaps `claude-real` atomically when the registry moves. Silent when up to
date. Model/config changes reach the wrapper on the next container start
(config re-apply); until then pass `--model <id>` explicitly.

**The installer's shape is load-bearing.** Since the 2.1.x cutover the
wrapper package `@anthropic-ai/claude-code` ships only `install.cjs` + a
`bin/claude.exe` stub; the ~230 MB native binary lives in a per-platform
package (`@anthropic-ai/claude-code-linux-arm64` here) at
`package/claude`. The old installer fetched `package/bundle/cli.js` from
the wrapper tarball — a path that had stopped existing — so **every**
install failed (boot included) and `claude-real` sat frozen for weeks.
The installer now resolves the platform package itself, extracts
`package/claude`, runs it for `--version`, and only then renames it over
`claude-real`. If you ever need to debug it: a failing install prints its
reason on **stdout** and exits non-zero, deliberately — a `no_agent` job
discards stderr, and a failure hidden on stderr is a failure that reports
`ok` forever.

**Expected noise**: `unrecognized_model` from Claude Code on any tier name
or `ollama/*` id — cosmetic; it is talking to the gateway, not Anthropic. (If you
instead see its *auto-compact* notice — "keeps this session within 200k
tokens (the context window it assumes)" — the window lookup did not apply:
the model is missing from `config/models.toml`, or you bypassed the wrapper
by calling `claude-real` directly.) `--max-turns` is print-mode-only
(prevents runaways).

### Subagents (`delegate_task`) — fresh context, isolated

Enabled for every profile. Spawns a child with its own context and its own
terminal; only its final summary returns to the parent.

- **Bounds on this stack** (`STACK_DELEGATION_DEFAULTS` in render.py;
  a profile may override one key via `[config_extra.delegation]`):
  `max_concurrent_children: 2` (upstream code default is **10** — this
  host is deliberately small, and a batch is where a run's tokens
  concentrate); `max_spawn_depth: 1` (flat — children are leaves and never
  get `delegate_task` back); and `worktree_isolation: false`, which is
  deliberate — see below.
- **A child knows nothing about your conversation.** Paths, the exact
  error, what you already ruled out — all of it goes in `goal` + `context`.
- **Leaf children cannot** call `delegate_task`, `clarify`, `memory`,
  `send_message`, or `cronjob_manage`. They keep `execute_code`. So a
  subagent can never schedule anything, and can never ask a human.
- **A child inherits the parent's `disabled_toolsets`** (delegate_tool_
  toolsets.py) — a profile's fence is therefore also its children's fence,
  and the model cannot grant a child a capability the parent lacks (the
  schema has no `toolsets` parameter).
- **Durability**: delegation is process-local — a restart does not resume a
  running child. Work that must survive a restart is a scheduled job.
- **Verify the summary.** A child's report is a claim; read the diff or run
  the test before you build on it.

**Why `worktree_isolation` stays OFF here.** It is not an upstream default
key, and on this stack it actively misbehaves — because agents already work
inside a per-session git worktree (`git-repo.sh`), not a plain clone:

- Subagent worktrees would nest at
  `<session-worktree>/.worktrees/subagent-<id>`, and
  `_ensure_gitignore_entry()` appends `.worktrees/` to the **session
  worktree's own** `.gitignore` — a working-tree modification in the
  parent's tree, which the agent's next commit can sweep in.
- A child's branch is created off the session HEAD but lives in the
  **shared central object store**, so `hermes-subagent/*` branches are
  visible to every profile and session instead of staying session-scoped,
  and are lost only when `prune-repos.sh` removes the session dir.

Children share the parent's cwd instead, which is already the session's
worktree — the isolation this stack needs, it already has.

### Background jobs

- **In-session, long-running**: `terminal` with `background=True` and
  `notify_on_complete=True`. The completion re-enters the conversation —
  do not poll it.
- **Beyond the session, or recurring**: the `cronjob` toolset
  (`cronjob_manage`) is enabled for every profile. Two rules, enforced by
  policy rather than by the tool:
  - **Self-cleaning only.** A job you create removes itself once its
    condition resolves — `cronjob_manage` with `action="remove"` on its own
    id, then answer (upstream: a job may remove itself and still report its
    final response). Never leave a standing recurring job behind; that is
    unattended spend forever.
  - **A persistent watchdog goes through the repo.** A permanent schedule
    belongs in `config/cron.toml` in `<owner>/hermes` — rendered per
    profile, reconciled at boot, reviewed in a PR. Ask for it. Names
    prefixed `team: ` are the reconciler's and the only ones it prunes;
    anything you create is yours and will never be removed for you, which
    is precisely why it must clean up after itself.
- **A job runs in a fresh session with no chat context**, and its FINAL
  RESPONSE is what gets delivered — prompts must be self-contained and
  cannot ask questions.
- **Script-only (`no_agent`) jobs cost zero tokens**: stdout is delivered
  verbatim and empty output is silence. Prefer that shape; wake an agent
  only when there is a decision to make.
- **If you write a job script, its diagnostics go on STDOUT and a real
  failure exits non-zero.** stderr is discarded, so `echo … >&2` in a job
  script is the same as deleting the message — and `exit 0` on a failure
  is worse, because the run records `ok` and the job cheerfully redelivers
  the wrong thing forever. That exact combination (`package/bundle/cli.js`
  gone, failure on stderr, `exit 0`) hid a completely broken Claude Code
  installer for weeks. Exit non-zero and the scheduler delivers its own
  failure notice, deduped per signature.
- **Delivery targets**: `bot-chat:<profile>` wakes that profile's agent
  (use it when a decision is needed — always name the profile);
  `discord:<chat_id>` posts into a channel as an outbound message (the
  "adapter drops the bot's own messages" rule is about INBOUND, so it does
  not apply) — that is what the stack's own housekeeping jobs use to
  report to **#hermes-home** (`DISCORD_HOME_CHANNEL`). `local` saves
  without delivering. `DISCORD_HOME_CHANNEL` is the same channel, and is
  what the gateway's own system messages (restart/shutdown notices,
  connect-time warnings) route to.
- **`cron.allow_agent_scheduling` stays false** (the upstream default), so
  an agent *running inside* a cron job cannot schedule further jobs. That
  is loop prevention, not a restriction on you — it does not gate the
  toolset in a normal gateway session.
- A job's `model`/`provider` are deliberately not agent-settable; do not
  try to point unattended spend at a different model.

## Pitfalls

- Host resources are limited. Bulk crawling, parallel builds, or many
  concurrent background tasks starve sibling containers. Keep background
  work serialized; check the host's actual CPU/memory before raising
  any right-sized limit.
- Discord REST scripting needs a real browser-like `User-Agent` header —
  bare urllib gets Cloudflare `error 1010`. Bot DMs fail (403 code 50278)
  when the recipient blocks server-member DMs — @mention in a server
  channel instead.
- Discord threads: the adapter auto-threads an @mention by default
  (`DISCORD_AUTO_THREAD`), and the reply follows into the thread. A
  *free-response* channel skips that (`skip_thread = ... or
  is_free_channel`) — which is why the team channels use
  `allowed_channels` + `require_mention = false` instead. Agents get no
  send-message tool, so a thread opened deliberately takes the deferred
  `discord` tool (`tool_search` → `tool_call`, action `create_thread`)
  and `hermes send --to discord:<channel>:<thread>` to post into it.
  Creation needs CREATE_PUBLIC_THREADS + SEND_MESSAGES_IN_THREADS *in
  that channel*: a channel overwrite beats the guild-level grant, so
  holding the bits at guild level is not enough. MANAGE_THREADS is only
  for managing other people's threads. Diagnose from the host with
  `python3 scripts/discord-thread-doctor.py`.
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
