---
name: komodo-ops
description: Manage the Komodo GitOps control plane — deploy stacks, build images, sync resources
version: 1.0.0
metadata:
  hermes:
    tags: [komodo, docker, deploy, gitops]
    category: devops
---

# Komodo control-plane operations

Everything running on the homelab host is managed by the Komodo control
plane (Core API + Periphery). You (the agent) can drive it directly — you
are on the same docker network as Komodo Core.

## When to Use

- Deploy or inspect a stack (hermes, cloudflared, openwebui)
- Trigger an image build (hermes-agent, honcho, honcho-mcp)
- Re-apply the resource sync (resources.toml in the <owner>/komodo repo)
- Check whether a deploy/build succeeded and what it changed

## Procedure

Core API is at `http://komodo-core-1:9120`. Auth is a header file mounted
read-only at `/etc/komodo-auth-header` (contains `X-API-KEY: ...` — never
print its value). All calls are POST with JSON bodies:

```bash
curl -s -X POST http://komodo-core-1:9120/<read|write|execute>/<Variant> \
  -H @/etc/komodo-auth-header -H "Content-Type: application/json" -d '<json>'
```

`<Variant>` is case-sensitive. The most useful ones:

- `read/ListStacks {}` / `read/ListBuilds {}` — inventory
- `read/GetStack {"stack":"<id-or-name>"}` — `info.deployed_hash` is the
  commit the stack last deployed; `info.state` is health
- `read/GetStackActionState {"id":"<stack-id>"}` — in-flight op check
- `read/GetUpdate {"id":"<oid>"}` — result of an execute op (logs + status)
- `execute/DeployStack {"stack":"<name>"}` — deploy (returns update oid)
- `execute/RunBuild {"build":"<name>"}` — build an image
- `execute/RunProcedure {"procedure":"<name>"}` — run a procedure
  (e.g. `rebuild-hermes-agent` = build hermes-agent + litellm, then deploy
  the stack; `rebuild-honcho` = build honcho, honcho-mcp, then deploy)
- `execute/RunSync {"sync":"komodo"}` — re-apply <owner>/komodo resources.toml
- `read/ExportAllResourcesToToml {}` — resources.toml as Komodo sees it

Get ids via List calls; GetStack also accepts a name.

## Rules

1. **Image changes are build-then-deploy** (`run_build = false`): a stack
   deploy never rebuilds. Normal flow needs no manual steps — the <owner>/
   hermes push webhook fires the `rebuild-hermes-agent` procedure
   (sequential stages: RunBuild hermes-agent → RunBuild litellm →
   DeployStack). Only fall back to manual `RunBuild` → `DeployStack` when
   a webhook was missed (stack busy, core down) or for the honcho images
   (`rebuild-honcho` procedure, manual).
2. **Verify what actually deployed**: `GetStack` → `info.deployed_hash`
   must equal the pushed commit. Deploys can be silent no-ops (compose
   config unchanged) and webhook deliveries can 200-but-skip (Komodo busy
   or restarting); builds can race a push (builds git-pull at start — a
   push landing mid-build builds the OLD commit).
3. **"Resource is busy"** = a concurrent op holds the stack. Wait ~60–90s,
   retry. Never force.
4. **Exited(0) containers mark a stack unhealthy** — Komodo ignores exit
   codes. One-shot jobs must be listed in the stack config's
   `ignore_services` (the `hermes` stack does this for `ollama-init`).
5. **The host is 1 CPU / 6 GB.** Never run more than one build at a time,
   and prefer no parallel bulk work while builds run.
6. Control-plane config changes go through the **<owner>/komodo repo**
   (resources.toml + deploy/komodo.compose.yaml), not the UI, and sync on
   push. Stack repos deploy themselves on push (GitHub webhook → DeployStack).

## Pitfalls

- `DeployStack` is a no-op for services whose compose config didn't change.
  Container config files (gateway litellm.yaml, agent overlay rendered at
  build time into /overlay) are baked into images (final COPY layers), so
  a config-only push invalidates the image's config layer → new image ID
  → the deploy recreates that service. The env files (/etc/hermes/*.env)
  ride compose's
  env_file hashing the same way. If a deploy recreated nothing but behavior
  needed a restart, something upstream (dockerfile paths, mount points)
  regressed — investigate, don't paper over it with manual restarts.
- `read/GetStack` returns `environment` as a raw string, not a list.
- Webhook deploys can race each other — check `GetStackActionState` before
  firing a manual `DeployStack`.
- ListUpdates/GetUpdate response shapes vary (dict wrapper vs list); inspect
  the JSON shape before scripting.

## Verification

After any deploy: `GetStack` → `deployed_hash` matches your push and
`info.state` is not `unhealthy`. After a build: `GetUpdate` on the build's
oid → status `Complete`, and the build's `info.built_hash` equals your
commit.