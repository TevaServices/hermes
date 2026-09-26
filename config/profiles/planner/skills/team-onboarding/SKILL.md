---
name: team-onboarding
description: Onboard a repo into the team workflow — topic tag, board or labels, branch protection, CI, registry entry
version: 1.0.0
metadata:
  hermes:
    tags: [team, onboarding, github]
    category: devops
---

# Repo onboarding (planner owns; runs on request)

Load `team-conventions` + `team-github-token` first. Onboarding marks a
repo as **under development by this team** and wires the workflow. Work
through this checklist IN ORDER; record every outcome in the registry
issue (step 8). Degrade gracefully: a step that the token can't perform
(403) becomes a checklist item for the user — onboarding never silently
skips.

## Steps

1. **Topic tag (the "under development" marker).** Replace the repo's
   topics, adding `hermes-team`:
   ```bash
   gh api -X PUT repos/<owner>/<repo>/topics \
     -H "Accept: application/vnd.github+json" \
     -f topics[]=<existing1> -f topics[]=<existing2> -f topics[]=hermes-team
   ```
   Read existing topics FIRST and re-send them all — this endpoint
   replaces the full set. Requires admin write: if it 403s (App tokens
   hold `contents`/`administration` only where granted), hand the exact
   command to the user to run, and mark the registry entry
   `topic:manual`. The tag is what `gh search repos --topic hermes-team`
   uses to enumerate the team's repos everywhere (digests, sweeps).

2. **Status mechanism.** Org repo → create a Project named
   `<repo> board` with the standard columns
   (`Backlog → Ready → In Progress → In Review → Blocked → Done`),
   record its number. Personal-account repo → create the label set
   (`status/backlog, status/ready, status/in-progress,
   status/in-review, status/blocked, status/done`) — App tokens cannot
   manage user-owned Projects; say so in the registry entry.
   ```bash
   gh label create status/ready --repo <owner>/<repo> \
     --color 0E8A16 --description "Ready for implementation"
   # … repeat for the other five
   ```
   **Also create the routing labels for the PR side** — they are the
   reviewer's queue and the fix-loop signal, not decoration (see
   `team-conventions` → "The routing labels"):
   ```bash
   gh label create review/ready --repo <owner>/<repo> \
     --color 1D76DB --description "Ready for review (reviewer's queue)"
   gh label create review/in-progress --repo <owner>/<repo> \
     --color FBCA04 --description "Review in progress"
   gh label create review/changes --repo <owner>/<repo> \
     --color D93F0B --description "Changes requested — back with developer"
   gh label create review/approved --repo <owner>/<repo> \
     --color 0E8A16 --description "Approved — awaiting the user"
   ```
   A repo onboarded without these will stall the review loop silently:
   the queue scripts report the missing label rather than showing an
   empty queue, which is deliberate.

   **Also create the type labels** — the release version bump is inferred
   from them and the developer's queue hoists `type/bug` ahead of features,
   so a repo without them cannot be released properly:
   ```bash
   gh label create type/bug      --repo <owner>/<repo> \
     --color D73A4A --description "Defect — patch release"
   gh label create type/security --repo <owner>/<repo> \
     --color B60205 --description "Security-motivated — patch release unless it also carries breaking/feature"
   gh label create type/feature  --repo <owner>/<repo> \
     --color A2EEEF --description "New capability — minor release"
   gh label create type/chore    --repo <owner>/<repo> \
     --color C5DEF5 --description "Maintenance — patch release"
   gh label create type/breaking --repo <owner>/<repo> \
     --color 5319E7 --description "Incompatible change — major release"
   ```

   **These fifteen are the whole protocol — no others.** `status/*` lives
   on issues and `review/*` on PRs, one profile-family each; **`type/*` is
   legal on both**, because it classifies the change rather than handing it
   off (see `team-conventions` → "The routing labels" and its type table).
   A bare `blocked`, a second `in-progress` spelling, or a `review/*` label
   applied to an issue is drift, not a variant: the queues poll exact
   names, so anything that does not match is invisible work.

3. **Branch protection on `main`** — needs Administration write; on 403
   it becomes a manual checklist item:
   ```bash
   gh api -X PUT repos/<owner>/<repo>/branches/main/protection \
     --input - <<'JSON'
   {
     "required_status_checks": {"strict": true, "contexts": ["ci"]},
     "enforce_admins": false,
     "required_pull_request_reviews": {
       "required_approving_review_count": 1,
       "require_code_owner_reviews": true,
       "dismiss_stale_reviews": true
     },
     "required_conversation_resolution": true,
     "restrictions": null,
     "allow_force_pushes": false,
     "allow_deletions": false
   }
   JSON
   ```
   Repos without CI yet: drop the `required_status_checks` block until
   the CI step lands, then tighten.

   **The code-owner review is the release gate, not a nicety.** Without
   `require_code_owner_reviews` there is nothing making a PR's approval a
   *human owner's*, and the release lane's own CODEOWNERS check is only an
   approximation of the ruleset. A repo that cannot get this set must be
   recorded as `codeowners:manual` and raised with the user — never
   silently accepted, because the release agent will then be merging on a
   gate weaker than the one the team believes it has. App tokens cannot set
   branch protection at all (owner-only), so expect this to be a checklist
   item.

4. **CI workflow.** If the repo has no `.github/workflows/ci.yml`,
   open a PR (planner cannot push to a new branch — open a draft PR
   from a branch developer creates, or have developer do it; simplest:
   write the issue `owner/repo#N "Add CI"` and route it to developer by
   labelling it `status/ready` — the label is the handoff, since App
   bots cannot be assignees).

5. **Verify team App access.** With the reviewer App's token for this
   installation, confirm the App can read the repo; with the dev App's
   token, confirm it can open a draft PR (use an existing branch; close
   the test PR after). On 403: the App isn't installed on that
   account/org — checklist item for the user (install links in
   `team-conventions`).

6. **AGENTS.md check** — read the repo's `AGENTS.md`/`CLAUDE.md`
   deliberately and summarize its rules into the registry entry (the
   stack's injection scanner may false-positive on repo docs; a
   deliberate read is fine).

6b. **CODEOWNERS must exist.** The release gate is a code owner's approval,
   and with no `CODEOWNERS` file there is no code owner to approve:

   ```bash
   gh api repos/<owner>/<repo>/contents/.github/CODEOWNERS \
     -H 'Accept: application/vnd.github.raw'
   ```

   A 404 is a blocking item for the user (it needs a human decision about
   who owns the repo), not something to invent. Record
   `codeowners: <ok|manual>`.

6c. **Release instructions are a REQUIREMENT.** The release agent follows
   the target repo's own releasing procedure, so the repo must document
   one — where the release is triggered from, how the version is chosen,
   what the process publishes, and any one-time setup (a signing secret, a
   package registry). For mach that is `README.md` §Releasing: push a `v*`
   tag, and GitHub Actions publishes attested binaries and multi-arch
   images.

   **A repo with no release instructions is not fully onboarded and cannot
   receive releases.** Record where they are (`release: README.md
   §Releasing`) or, if absent, open an issue for the developer to write
   them and say plainly that releases are blocked on it. Do not infer a
   release process, and do not let this one degrade to a note — it is the
   one onboarding step the release agent cannot work around.

7. **Registry entry.** Update the pinned registry issue in this
   profile's pinned-issue store (the registry issue lives in
   `<owner>/hermes` as issue labeled `team-registry` — find it with
   `gh search issues --repo <owner>/hermes --label team-registry`).
   Entry format:
   ```markdown
   - **<owner>/<repo>** — topic: hermes-team (auto|manual) · status:
     <project #|labels> · protection: <on|manual> · codeowners: <ok|manual> ·
     CI: <yes|issue #N> · release: <doc path|issue #N|none> · version:
     <tag scheme> · internal: <yes|no> · apps: <ok|missing-<account>> ·
     notes: <AGENTS.md rules, conventions>
   ```

8. **Discord announcement** (`#planning`): one line — repo onboarded,
   status mechanism, anything manual the user must do.