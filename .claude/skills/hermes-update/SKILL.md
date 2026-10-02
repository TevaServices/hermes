---
name: hermes-update
description: Upgrade the stack's pinned upstream Hermes agent release — check for a new release, check that release for known bugs, audit every Dockerfile source patch (still needed? still applies?), bump HERMES_REF in every pin, and open the update PR describing new features and relevant changes. Invoke explicitly as /hermes-update; never start this on your own.
argument-hint: "[<tag>] — bump to this ref instead of the newest release"
disable-model-invocation: true
---

# hermes-update — bump HERMES_REF and open the update PR

This skill runs the HERMES_REF bump choreography documented in this repo's
AGENTS.md (§"Bumping HERMES_REF (the update checklist)"). AGENTS.md is the
authoritative doc and always wins over this file — read it first if the
invocation is the first this session has seen. This file is the ordered,
fail-loud recipe; AGENTS.md is the why.

Scope: **the upstream Hermes agent base image only** (`<upstream-owner>/<upstream-repo>`
on GitHub — the repo, its releases, its issues). Honcho, Firecrawl and the
other pins are separate updates handled by `mise run check-updates` + their
own diff discipline; do not mix them into this PR.

One release == one PR in this repo, plus a **second, preceding PR in the
companion komodo control-plane repo** (a separate checkout — look for a
sibling of this repo's parent directory, typically named `komodo`; ask the
user for its path if you cannot find it). Sequencing matters and is not
politeness: the deploy pipeline's Build reads its `HERMES_REF` from the
komodo resources — the build args and stack environment override the
Dockerfile ARG — so merging a hermes-side-only bump **silently deploys the
old ref**, exactly the way this stack's AGENTS.md warns elsewhere about
drifted defaults. Land komodo first, or the update never happens and every
green check says it did.

Deployment specifics (which repos, which servers, which channels) live in
AGENTS.md and the deployed env files — never in this skill or the PR text.

## Procedure

Follow the steps strictly in order. If any step fails, report precisely and
stop — a half-bumped pin set is worse than an untouched one (see AGENTS.md
on lockstep).

### 0. Prepare — clean branches in BOTH repos

`main` is protected everywhere: PR-only, squash merges, verified
signatures. Never push to `main`, never force-push. Work must not ride
whatever feature branch the session happens to be on.

1. `git fetch origin && git status` in this repo. **Branch from `origin/main`**:
   `git checkout -b bump-hermes-ref-<tag-without-v> origin/main` (untracked
   files carry over; that is fine — do NOT commit anything else).
2. Same for the komodo checkout: branch from its `main`, e.g.
   `bump-hermes-ref-<tag-without-v>`.

### 1. Is there a new release at all?

```bash
mise run check-updates            # drift vs upstream main HEAD (context only)
gh release list --repo <upstream-owner>/<upstream-repo> --limit 5
```

The pin is a **release tag**, not main HEAD. If the pinned `HERMES_REF`
(currently read it from `mise.toml` `[env]`) equals the newest release:
report that in one line and stop. Behind main HEAD but no newer release is
intentional on this stack — do not bump to a non-release ref.

A release *newer* than the pin → continue. If the caller gave a `<tag>`
argument, bump to it (verify it exists and is a release tag).

### 2. Gather what's new (the PR description's raw material)

```bash
gh release view <new-tag> --repo <upstream-owner>/<upstream-repo>   # notes
gh api repos/<upstream-owner>/<upstream-repo>/compare/OLD_TAG...NEW_TAG --jq ...
```

Summarize the range, then read the files this stack actually touches. The
break-prone areas (each has a story in AGENTS.md — grep it for the current
state of each invariant):

- `tools/approval_detection.py` — **three of our patches target guard
  code; this file moving is the expected failure of a bump.**
- The Discord adapter (voice/platform code) — our other patches land here.
- `hermes_cli/config_defaults.py` — the config schema version (step 5).
- MCP SDK pin (`pyproject.toml` / `uv.lock` + the mcp client code) — the
  HTTP-transport breakage has landed at this exact pin before.
- `agent/agent_init.py` + context-length handling (`MINIMUM_CONTEXT_LENGTH`,
  `model_overrides` consumers) — our `config/models.toml` contract.
- The s6 supervision tree scripts — anything this stack's entrypoint
  wrapper or profile bootstrap interleaves with.

### 3. Check for known bugs in that release

```bash
gh search issues --repo <upstream-owner>/<upstream-repo> --state open --sort updated --limit 50 \
  --json number,title,labels -- <NEW_TAG>
gh search issues --repo <upstream-owner>/<upstream-repo> --state open --sort updated --limit 50 \
  --json number,title,labels --label bug
```

Cross-reference every issue opened or updated after the release date that
touches the areas from step 2. What you are looking for: regressions in
this stack's load-bearing paths (guard/approval code, MCP transports,
config migration, gateway/platform adapters) — not every open bug. The PR
carries a **Known bugs** section even when the search finds nothing ("none
found at search time" — a finding, not a blank).

### 4. Audit every patch — in a scratch clone, without Docker

```bash
d=$(mktemp -d) && cd "$d" &&
  git clone --filter=blob:none --no-checkout https://github.com/<upstream-owner>/<upstream-repo>.git u &&
  cd u && git fetch --quiet origin tag OLD_TAG tag NEW_TAG &&
  git worktree add tree-new NEW_TAG && git worktree add tree-old OLD_TAG
```

For each `docker/hermes/patches/*.patch`, from inside `tree-new`:

1. **Already adopted upstream?** `git apply --reverse --check <patch>` →
   if reverse applies cleanly, upstream now contains the fix → **delete
   the patch** (plus its numbered Dockerfile comment block). The build
   would otherwise NOTICE itself to death — AGENTS.md says so.
2. **Still applies?** `git apply --check <patch>` → if it fails, the
   anchor moved. Read the patched file at `NEW_TAG` and re-target the
   patch. Re-anchoring is surgical: keep the patch's narrative comment,
   verify the behavioral intent still makes sense against the new code,
   regenerate the diff. If the patched code was removed or
   restructured beyond the fix's shape, say so in the PR rather than
   hand-waving — the patch may be obsolete even when not adopted.
3. **Still needed as-is?** Files the patch touches that changed between
   `OLD_TAG` and `NEW_TAG` (`git diff OLD_TAG NEW_TAG -- <paths in the
   patch>`) need a re-read even when the patch applies — upstream may
   have implemented the same behavior differently.

Finish by updating the Dockerfile's patch commentary to match the final
set (the "N patches currently." count and the numbered blocks) — stale
counts there have the same smell as stale pins. Record the verdict per
patch; it goes into the PR as a table.

### 5. Make the bumps (both repos)

**This repo** (in its new branch):

| File | Edit |
|---|---|
| `mise.toml` `[env]` | `HERMES_REF = "<new-tag>"` — the authoritative pin |
| `docker/hermes/Dockerfile` | ARG default, and the FROM-pin comment if the count changed |
| `compose/hermes.compose.yml` | both `${HERMES_REF:-v…}` fallback defaults (build args + `image:` tag) |

AGENTS.md says only `mise.toml` strictly needs the edit (the ARG defaults
flow through from compose/mise), but the hard-coded fallbacks exist so a
plain run without that machinery doesn't silently build the old ref — keep
them in lockstep in the same commit.

**`render.py`** — set `_FALLBACK_CONFIG_VERSION` to the config schema
version at the `NEW_TAG` tree (find it in `hermes_cli/config_defaults.py`
in the scratch clone — the build-time stamp derives from the base image's
`DEFAULT_CONFIG`; this fallback exists so local `mise run render` previews
match). Leave the surrounding comment intact.

**komodo repo** (its own branch): per the checklist comment inside its
`resources.toml` — the `hermes-agent` build's `image_tag`, its
`build_args`, and the stack `environment` entry. Mirror the commit style
of that repo's history.

### 6. Validate before pushing

```bash
mise run validate   # render --check: tier names, cron scripts, placeholders
mise run render     # preview only — build/ is gitignored, never commit it
mise run test       # the offline suite (shim routing, label protocol, hooks…)
```

All three must pass. The patch audit from step 4 is the FROM-pin check;
`mise run validate` will not catch a moved patch anchor, and only this
audit or the real build will.

### 7. Open the PRs — komodo first

**komodo repo PR** (merge this one FIRST): title
`hermes stack: bump HERMES_REF to <tag>`; body cross-links the hermes PR.

**This repo's PR**: title `bump HERMES_REF to <tag>`. Description:

```markdown
## New in <tag>
<release-notes summary — features first, in plain language>

## Relevant to this stack
<the step-2 areas ACTUALLY touched, each with the invariant it affects,
per AGENTS.md — omit untouched ones>

## Patch audit
| Patch | Verdict | Action |
|---|---|---|

## Known bugs
<from step 3 — or "none found at search time (date)">

## Verification after merge (= build + deploy)
AGENTS.md §"Verification checklist": first `hermes mcp test honcho` +
`hermes mcp test firecrawl` against the new image (MCP SDK pin), then
`mise run check-model-windows`, then the standard stack-green check.
<if patches were re-anchored or deleted, name the extra watch here>
```

Commits carry the harness's Co-Authored-By trailer; the PR body its
attribution footer.

**Then stop.** Do not merge either PR, do not run any deploy procedure, do
not touch the live stack — merging is the user's act everywhere here, and
the merge IS the deploy. (Deploys also take minutes to settle; nothing
needs checking until the user has merged.)

### 8. Report

In chat: old → new tag, patch-audit verdict, known-bugs headline, both PR
links, and the one instruction the user needs: merge the komodo PR first.

## Guardrails

- **No secrets.** This skill touches version pins and public upstream
  data only. Never read, echo, or copy anything from env files or
  `/etc`-style host paths.
- **Two repos, two branches, two PRs** — never cross-commit, never assume
  they share remotes. The hermes PR merges second.
- **One commit's worth of intent per repo.** Bump + patch audit + comment
  updates land together; nothing else that happens to be dirty in a
  checkout travels along.
- **Keep this repo generic.** The skill, the PRs and any code it writes
  carry no organization- or deployment-specific names — AGENTS.md and the
  deployed env files are where those live.
- **A failed step is a stop.** Report what failed and where; let the user
  decide. Do not "fix" a moved anchor by weakening the patch, and do not
  skip the patch audit because the diff looked small.