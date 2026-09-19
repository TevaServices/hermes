# Komodo GitOps setup

This repo *is* the deployment definition. Komodo ([komo.do](https://komo.do)) turns
pushes to it into deployments on the Linux host: Core watches the repo through a
**Resource Sync**, applies the Stack definitions in [`resources.toml`](resources.toml),
and each Stack clones this repo and runs its compose file on the host via the
Periphery agent.

```
 git push ──webhook──▶ Komodo Core
                        │ 1. Resource Sync: apply komodo/resources.toml
                        │ 2. Procedure "deploy-changed-stacks":
                        │      Pull Repo → Batch Deploy Stack If Changed ("*")
                        ▼
                 Periphery on the Linux host
                   ├── Stack hermes-agents   (compose/hermes.compose.yml)
                   ├── Stack hermes-honcho   (compose/honcho.compose.yml)
                   └── Stack hermes-firecrawl (compose/firecrawl.compose.yml)
```

## Prerequisites

- Komodo Core (with Mongo/SQLite) somewhere reachable, and the Periphery agent on
  the target Linux host. Install both via the official compose files:
  <https://komo.do/docs/deploy/compose>. Note the **MongoDB 5+ AVX requirement**
  on the Core host — use the FerretDB variant if your CPU lacks AVX.
- On the target host: `git` installed (compose builds the Honcho image from a git
  context, and Komodo clones this repo there too).
- This repo pushed to a git remote Komodo can reach.

## 1. Prepare the target host

Run on the Linux host (once):

```bash
sudo ./scripts/bootstrap-host.sh   # creates /etc/hermes secrets + hermes-net network
```

Fill in the generated `/etc/hermes/*.env` files with real keys (see
[`secrets/`](../secrets/) templates). Restrict access: `chmod 600 /etc/hermes/*.env`,
and make sure Periphery runs as a user that can read them and use Docker.

## 2. Edit `resources.toml`

Replace, in all three `[[stack]]` blocks:

- `<owner>/hermes` → your repo (and add `git_account` + a Komodo Git Account if private)
- `server = "<your-komodo-server>"` → your Periphery's Server name in Komodo
- `environment` → keep the version pins in sync with [`mise.toml`](../mise.toml) `[env]`
  (Komodo doesn't run mise, so the pins are repeated there), and set `TZ`

## 3. Create the Resource Sync

In Komodo: **ResourceSync → New** → point it at this repo, branch `main`, file/directory
`komodo/resources.toml`. Run the sync once — the Stacks, the `hermes-stack` Repo
resource, and (on first deploy) all three containers come up.

> Cross-check the TOML field names against your Komodo version's docs
> (<https://komo.do/docs/automate/sync-resources>) — the schema evolves.

## 4. Wire the webhook (push → deploy)

Create a Procedure in the UI, **"deploy-changed-stacks"**:

1. **Pull Repo** action — target the `hermes-stack` Repo resource.
2. **Batch Deploy Stack If Changed** — target stacks `*` (pattern).

Then add a webhook from your git provider (GitHub: content type `application/json`,
push events on `main`) to the Procedure's webhook URL, with the shared secret from
your Core's `KOMODO_WEBHOOK_SECRET`. Also enable the webhook on the **Resource Sync**
so definition changes (new stacks, edited pins in `resources.toml`) are applied on
push.

Why a Procedure instead of per-Stack webhooks: git-repo Stacks clone the whole repo
per deploy, which is wasteful in a monorepo — the pull-once, diff, deploy-changed
pattern is the [approach Komodo's maintainers recommend for monorepos](https://github.com/moghtech/komodo/discussions/264).
If a compose-only change ever doesn't deploy, run the Procedure manually from the UI
(this is the known caveat in [Komodo issue #1120](https://github.com/moghtech/komodo/issues/1120)).

## 5. Keeping things up to date

Two update paths — pick one per component (defaults below are the GitOps path):

| What | GitOps rebuild (default) | In-place |
|---|---|---|
| Hermes agent | bump `HERMES_REF` in `mise.toml` `[env]` **and** `resources.toml` → push → image rebuilds; agent state survives in `hermes-main-data` | `HERMES_UPDATE_ON_START=true` + code volume (see notes in [`compose/hermes.compose.yml`](../compose/hermes.compose.yml)) |
| Honcho | bump `HONCHO_VERSION` → push | — |
| Firecrawl | bump `FIRECRAWL_VERSION` → push | enable `auto_update` + `poll_for_updates` on the Stack to track newer image digests |

Run `mise run check-updates` locally (or `./scripts/check-updates.sh` from a
scheduled Komodo Action) to see how far your pins have drifted from upstream.

For version bumps that touch Firecrawl, diff your compose file against the
upstream `docker-compose.yaml` for that release — service/env changes between
releases are the main source of breakage (see the note at the top of
[`compose/firecrawl.compose.yml`](../compose/firecrawl.compose.yml)).

## Day-2 operations

- **Logs/status**: Komodo UI → Stacks → service logs, or `docker logs hermes-main`.
- **Config change**: edit `config/` or a `SOUL.md` → `mise run render` → commit → push →
  the compose files in the repo changed, so the Procedure redeploys; the entrypoint
  reapplies the overlay on container start.
- **Secrets change**: edit `/etc/hermes/<name>.env` on the host, then redeploy the
  stack (Procedure run, or `docker compose ... up -d --force-recreate` on the host).
- **Diagnostics**: `docker exec -it hermes-main hermes doctor`.