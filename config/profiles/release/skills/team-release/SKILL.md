---
name: team-release
description: Merge an approved PR, cut the release, deploy it to the internal environment through Komodo, and validate the running deployment
version: 1.0.0
metadata:
  hermes:
    tags: [team, release, deploy, komodo, github]
    category: devops
---

# Release (release owns; wakes from the self-pull queue)

Load `team-conventions` + `team-github-token` first. You are the only role
that merges, tags, deploys or validates. Read this whole skill before your
first release, and **read the target repo's own release instructions before
every release** — for mach that is README §Releasing. The repo's playbook
wins; a disagreement means this skill needs a PR, not that the repo is wrong.

## Self-pull: what woke you

```bash
release-queue.sh            # quiet by default; --verbose shows the idle state
```

It emits three kinds of line, and nothing else ever wakes you:

- **a PR item** (`owner/repo#N  title  url`) — labelled `review/approved`
  AND carrying a **human code-owner approval**. Already read back for you.
  Nothing to claim: a merge is atomic, and `team-session.py` has already
  dropped any item a live turn holds.
- **`!! RELEASE …`** — a stuck release: a `v*` tag with no published release,
  or a `release` workflow that concluded badly, or a published release that
  is not what the internal deployment records as running.
- **`!! TYPE MISSING` / `!! HANDOFF INCOMPLETE` / `!! FOREIGN LABEL`** —
  audit lines about the repos' state. They ride this delivery so nothing
  needs a turn of its own; act on them only when they are about the item you
  are working.

Post one line to `#releases` when you pick work up. A run with nothing to
report prints nothing and exits 0 — that is the design, not a fault.

## The internal deployment registry (the ONLY place this lives)

The target repo holds **nothing** about its internal deployment — not the
hostname, not the stack name, not the environment wiring. That is a
requirement, not a preference: the repos are public and the deployments are
internal.

**THIS REPO IS PUBLIC TOO.** So the per-repo mapping does not live here
either — this skill carries the PROCEDURE and nothing target-specific. The
mapping lives in your own state file on the volume:

```
${TEAM_RELEASE_STATE_DIR:-$HERMES_HOME/cache/release}/<owner>-<repo>.state
```

It is seeded once per repo (by the operator, from the Komodo side) and you
keep it current after every release. Read it before you act:

```bash
S="${TEAM_RELEASE_STATE_DIR:-$HERMES_HOME/cache/release}/$(printf '%s' "$R" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9' '-').state"
sed -n 's/^\(KOMODO_STACK\|KOMODO_VARIABLE\|INTERNAL_URL\|KOMODO_URL\|DEPLOYED_VERSION\)=/\1=/p' "$S"
```

**A repo with no state file has no internal deployment you may touch.** Say
so in `#releases` and stop — do not infer a stack name, a variable name or a
hostname, and do not write one into this repo, a commit message, or an issue.
The fields you will find there:

| field | what it is |
|---|---|
| `KOMODO_URL` | the alternate control plane's base URL |
| `KOMODO_STACK` | the stack name to `DeployStack` |
| `KOMODO_VARIABLE` | the image-tag variable to move |
| `KOMODO_HOST` | the Komodo server name the stack runs on |
| `KOMODO_CONTAINER` | the container whose image tag proves what is running |
| `INTERNAL_URL` | the public URL to validate against |
| `DEPLOYED_VERSION` | what is actually running (you keep this current) |

The stack's compose file and its declaration live in the **private** control
plane repo (`<org>/komodo`, `deploy/<app>/compose.yaml` +
`resources.toml`) — which is also why a release is a **Variable update +
DeployStack** and never a push to the app repo.

## 1. Gate read-back (before ANY merge)

```bash
PR=<number>; R=<owner>/<repo>
gh pr view "$PR" --repo "$R" \
  --json labels,isDraft,mergeable,mergeStateStatus,reviewDecision,headRefOid,state
gh api "repos/$R/pulls/$PR/reviews" \
  --jq '[.[] | select(.user.type != "Bot")] | sort_by(.submitted_at) | last
        | "\(.user.login)|\(.state)|\(.submitted_at)"'
gh pr checks "$PR" --repo "$R"
gh api "repos/$R/contents/.github/CODEOWNERS" -H 'Accept: application/vnd.github.raw'
```

Every one of these must hold:

- `review/approved` is present and the PR is not a draft;
- `mergeable` is `MERGEABLE` and `mergeStateStatus` is not `BLOCKED`;
- the **most recent non-bot review is `APPROVED`**, and its author appears in
  `CODEOWNERS`. Most-recent, not "any": a later changes-requested re-closes
  the gate. A bot's approval does not count — the reviewer bot approves hours
  before the human does, which is exactly why the queue reads this back.
- every check is green. `skipped`/`neutral` are fine; anything `pending`
  means wait; any `failure`/`cancelled`/`timed_out` means stop. **mach's
  `Main` ruleset has no required status checks**, so this is the only thing
  checking CI — look at every job, not just the ones a local run mirrors.
- zero unresolved review threads (a repo can require them, and that gate is
  invisible to CI).

On `BLOCKED`, name the rule rather than guess:

```bash
gh api "repos/$R/rules/branches/main" --jq '.[].type'
```

One rule is worth knowing by name: `require_extra_approval_for_unattributed_changes`
can demand a SECOND approval for an App-authored commit (`git-publish.py`
creates commits with no author), and the reviewer bot's approval does not
satisfy it. Ask the human and stop — never self-approve.

## 2. Merge

```bash
gh pr merge "$PR" --repo "$R" --squash --delete-branch
gh pr view "$PR" --repo "$R" --json mergedAt,mergeCommit,state   # READ IT BACK
```

Squash is the convention everywhere here (mach allows squash only). Then
post to `#releases`, and `@hermes-planner` so the card moves — do not write a
`status/*` label or edit the issue yourself.

## 3. Version: infer it from the labels

Take every PR merged since the last release, and use the highest bump:

| the merged PR carries | bump |
|---|---|
| `type/breaking` | **major** |
| `type/feature` | minor |
| `type/bug` | patch |
| `type/security` | patch |
| `type/chore` | patch |
| no `type/*` at all | patch — **and say so** |

`type/security` alone is a patch on purpose: the family is a taxonomy of
change CLASS, and a security fix is a fix. A security change that also breaks
compatibility carries `type/breaking` too (then major); one that adds
capability carries `type/feature` (then minor). `type/security` existing at
all is what makes the release notes say "this release contains a security fix".

```bash
gh release list -R "$R" --limit 1 --json tagName,publishedAt
gh pr list -R "$R" --state merged --limit 100 \
  --json number,title,labels,mergedAt,mergeCommit
```

Announce it **before tagging**, so a human can still object:

```
RELEASE PLAN  <owner>/<repo>  0.6.1 -> 0.7.0  (minor)
  #27 type/feature -> minor; #25,#22 unlabelled -> patch
  bump = highest of {breaking:major, feature:minor, else patch} = minor
```

**0.x policy (decide before the first breaking change).** Under the literal
mapping above, `type/breaking` at `0.6.x` yields `1.0.0`. Some teams keep the
major at 0 until 1.0 and bump the minor instead. This skill defaults to
literal; if the team prefers pre-1.0 semantics, that is a one-line change to
this section, not a judgement call in the moment.

## 4. Cut the release

The tag is the release trigger — mach's `release.yml` fires on `push: tags:
["v*"]`, runs a lint+test `gate`, then publishes six attested binaries and
the multi-arch images and creates the GitHub release.

```bash
TIP=$(gh api "repos/$R/commits/main" --jq .sha)     # the squash commit you just made
gh api -X POST "repos/$R/git/refs" \
  -f ref="refs/tags/v$VER" -f sha="$TIP"
gh api "repos/$R/git/ref/tags/v$VER" --jq '.object.sha'   # READ IT BACK
```

Never move or delete a tag: the `Release tags` ruleset forbids both, so
"fix the version" is only ever the NEXT tag. Tag once, correctly.

## 5. Watch the release workflow to completion

```bash
gh run list -R "$R" --workflow release.yml --limit 10 \
  --json databaseId,headBranch,status,conclusion,url
```

The run whose `headBranch` is your tag. Wait in bounded steps; a release
workflow takes minutes and the delivery cap is finite.

- **conclusion `success`** → the GitHub release exists. Verify it is not a
  draft and that its body names the image digests.
- **still running when your bound expires** → write `RELEASE_STATE=tagged` to
  the state file and **end the turn**. The triage lane re-wakes you on
  "tagged, not published" and you resume at step 6. This is the resumable
  path, not a failure.
- **`failure`/`cancelled`** → stop and escalate (see the end of this skill).

## 6. Verify the release's provenance

If the repo's release instructions say the release is attested, verify it
before deploying — a tampered artifact must not be what you ship. The repo's
own tooling does the check (for mach: the release carries
`mach-attestations.intoto.jsonl`, one DSSE envelope per binary with that
binary's sha256, and `mach-server verify-attestation` validates it against
the public key published in the release notes). Run it in your worktree
against the downloaded artifacts, and record the result in the state file.

## 7. Deploy to the internal environment (the alternate control plane)

Everything target-specific comes from your state file (see the registry
section) — the base URL, the stack name and the variable. Nothing here is
hardcoded, precisely so this public repo carries no deployment details.

```bash
AUTH=${KOMODO_ALT_AUTH_HEADER:-$HERMES_HOME/home/komodo-alt-auth-header}
K() { curl -sS -X POST -H "@$AUTH" -H 'Content-Type: application/json' -d "$2" \
        "$KOMODO_URL/$1"; }
# KOMODO_URL / KOMODO_STACK / KOMODO_VARIABLE read from the state file.

# 0. confirm the variable exists and is NOT secret (a secret cannot be read back)
K read/ListVariables '{}'
# 1. never fight a running operation
K read/GetStackActionState '{"id":"<stack id>"}'   # busy -> wait 60-90s, retry
# 2. move the pin
K write/UpdateVariableValue '{"variable":"'"$KOMODO_VARIABLE"'","value":"'"$VER"'"}'
# 3. READ IT BACK — a status code is not evidence
K read/ListVariables '{}'
# 4. deploy, then follow it
K execute/DeployStack '{"stack":"'"$KOMODO_STACK"'"}'
K read/GetUpdate '{"id":"<_id.$oid from the response>"}'
```

Notes that will otherwise cost you a turn:

- `write/UpdateVariableValue` takes `{variable,value}`; some docs show
  `{name,value}`. If the call errors naming the field, retry with `name` and
  record whichever worked in your state file — once, not every release.
- A `DeployStack` can collide with the komodo repo's own webhook-driven
  `DeployStackIfChanged` ("Resource is busy"). Check action state first, wait,
  never force.
- The Komodo variable must stay **non-secret**: the read-back is how you
  prove the write landed, and a secret variable cannot be read.
- **Do not touch any other Komodo variable, stack or resource.** The
  control plane is shared with humans; your write is exactly one variable on
  one stack.

## 8. Validate against the LIVE deployment

```bash
B="${INTERNAL_URL%/}"                                                 # from the state file
curl -fsS --max-time 10 "$B/healthz"                                  # -> ok
curl -s -o /dev/null -w '%{http_code}\n' "$B/ui"                      # -> 302
```

- `/healthz` returning `ok` (with a bounded retry while the container
  restarts) is liveness.
- `/ui` returning a **302 to the issuer** proves OIDC is wired. `404` means
  the three `MACH_OIDC_*` vars are not set — the routes are not registered at
  all. A 200 with no session would mean the auth gate is not engaged:
  investigate, do not report success.
- **The version is not in `/healthz`.** The authoritative read-back of what
  is RUNNING is the container's image tag (`KOMODO_HOST`/`KOMODO_CONTAINER`
  are in the state file too):

```bash
K read/InspectDockerContainer '{"server":"'"$KOMODO_HOST"'","container":"'"$KOMODO_CONTAINER"'"}'
#   -> Config.Image must end with ":<ver>"
```

Report honestly about what this covers: it proves the right image started and
that the UI is answering and gated. It does **not** prove a signed-in
operator's journey, because that needs an interactive Zitadel login you
cannot perform.

## 9. Record, then report

Write the state file **after each step**, not only at the end, so a killed
turn resumes. This file is also where the deployment mapping lives (never in
this repo — it is public):

```
REPO=<owner>/<repo>
KOMODO_URL=<control plane base url>      # seeded once
KOMODO_STACK=<stack name>                # seeded once
KOMODO_HOST=<host>                       # seeded once
KOMODO_CONTAINER=<container name>        # seeded once
KOMODO_VARIABLE=<image-tag variable>     # seeded once
INTERNAL_URL=<public url to validate>    # seeded once
LAST_RELEASE_TAG=vX.Y.Z
LAST_RELEASE_VERSION=X.Y.Z
LAST_MERGE_SHA=<sha>
LAST_BUMP=minor
LAST_BUMP_FROM=type/feature (#27)
DEPLOYED_VERSION=X.Y.Z
DEPLOYED_IMAGE=<registry>/<image>:X.Y.Z
DEPLOYED_DIGEST=sha256:…
DEPLOYED_AT=<iso8601>
KOMODO_UPDATE_ID=<id>
VALIDATION=ok|partial|failed
VALIDATION_DETAIL=/healthz=ok /ui=302 image=X.Y.Z
RELEASE_STATE=complete|tagged|released|deployed|failed:<what>
```

`DEPLOYED_VERSION` is what the queue's resume lane compares against the newest
published release, so it must be the version actually validated — never the
version you intended.

## When something fails

Open **one** issue in the repo that failed — `type/bug` + `status/ready`, so
the developer's queue picks it up (and hoists it ahead of features):

```bash
gh issue create -R "$R" \
  --title "release: <what failed> (<tag>)" \
  --label type/bug --label status/ready \
  --body "…tag, run URL, failing job, log excerpt, state file, and what I did NOT do…"
```

Then set `RELEASE_STATE=failed:<what>` in the state file, post one line to
`#releases`, and comment `@hermes-planner` so the card stays honest. Never
re-tag, never blind-redeploy, never call a partial validation a success.
