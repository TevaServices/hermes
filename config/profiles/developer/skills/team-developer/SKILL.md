---
name: team-developer
description: Developer role procedure — self-pull work discovery, worktree discipline, draft PRs, roadblock protocol
version: 1.3.0
metadata:
  hermes:
    tags: [team, developer]
    category: devops
---

# Developer procedure

Load `team-conventions` + `team-github-token` first.

## Self-pull: finding work (the cron runs this query)

**`status/ready` IS the handoff.** The assignee field is not used
anywhere in this pipeline and must not be: GitHub App bot identities
cannot be assigned issues or PRs at all. The API answers 403 /
`cannot be assigned to issues or pull requests`, and
`GET /repos/{owner}/{repo}/assignees/{login}` returns 404 for every bot
— dependabot included. That is a rule about the *assignee's* account
type, so **no token change fixes it**: the user's own user token, on his
own repo, fails identically. Do not try to "fix" assignment, and do not
report it as a credential problem.

The planner routes by adding the label; you claim by moving it:

```bash
# find routed work — the owner comes from the repo/token routing the
# shim and the queue script already do (see team-github-token)
team-queue.sh

# claim the ISSUE you picked (same turn, BEFORE starting work)
gh issue edit <ISSUE#> --repo owner/repo --remove-label status/ready \
  --add-label status/in-progress
```

**Two families, two objects.** `status/*` labels go on the **issue**
(`gh issue edit`); `review/*` labels go on the **PR** (`gh pr edit`).
They are different numbers for one work item — the queue prints issue
numbers, and the PR you open for an issue is a different number joined to
it by `Closes #N`. Never write a `review/*` label to an issue, and never
put a `status/*` label on a PR: each queue polls one family on one object
kind, so a misfiled label makes the item invisible to *both* lanes. The
queues report the mismatch (`!! FOREIGN LABEL`) rather than let it sit.

`team-queue.sh` wraps the query below (it is baked at
`/usr/local/bin/team-queue.sh`) and prints one line per issue,
`owner/repo#N  title  url`:

```bash
gh search issues --owner <owner> --label status/ready --state open \
  --limit 30 --json repository,number,title,url,labels
```

An issue still carrying `status/ready` is **unclaimed** — the cron will
hand it to you again, so claim it in the same turn you pick it up. A
second guard against double-starting on cron re-wakes: skip anything
whose repo+number already has an open PR authored by you
(`gh search prs --author 'hermes-dev[bot]' --state open` — note
the space, not `--author:`, which is not valid gh syntax). Pick oldest
first. Post one line to `#dev` when you pick work up.

If the cron handed you a specific issue in its prompt, start there —
the query above is the fallback.

### Fail loud — never idle silently

An empty queue and a *broken* query are indistinguishable from the
outside: both hand you nothing, and the team stalls with no signal.
(`gh search issues --assignee:x --state:open --is:issue` — the shape
this pipeline shipped with — is invalid syntax on every count; it
errored on every run and nobody noticed, because a dead queue looks
exactly like a quiet week.)

So: **every empty result goes through `team-queue.sh`, and you treat
its output and exit code as the signal.**

The script is **quiet by default** (that is the cron contract — the
scheduler invokes it with no arguments), so silence is the normal idle
state, not a fault. When you are checking by hand and want to SEE the
idle state, run `team-queue.sh --verbose`.

- **no output, `exit 0`** — genuinely nothing routed. Idle is correct.
- issues listed, `exit 0` — claim one and work it.
- `exit 2` / `3` / `4` / `5` — **an incident, not an idle state.** The
  script prints which (it does so once, then stays quiet until the
  condition changes, so a repeat is expected and is not a new fault):
  query failure, blind search (token/scope), nothing onboarded, or a repo
  missing the routing label. Post the script's own message to `#dev` the
  same turn. Do not report "no work available".

If you ever find yourself with an empty queue across every repo while
planner believes it has routed you work, that discrepancy **is** the
bug — so say so on `#dev` instead of waiting for the next cron wake.

### Resuming interrupted work (the in-flight label)

The queue lists `status/in-progress` items FIRST, then `status/ready`. An
in-progress item is **your own unfinished work** — a previous turn was
interrupted (a deploy restarted the container, the turn timed out, the
session died) and it is still yours. **Resume it before claiming anything
new.**

Your worktree is per session slug and the slug is stable across your cron
wakes, so unfinished work is normally still on disk:

```bash
git-repo.sh worktree https://github.com/<owner>/<repo> <default-branch>
git status                       # uncommitted work from the interrupted turn
git branch --show-current        # the branch you already made
git log --oneline -5
```

Read that state BEFORE writing anything. Do not start the item over from
scratch, and do not create a second branch. If the branch has no commits
and the tree is clean, the turn died before it produced anything — then
start properly. If you find work you cannot account for, say so in the
issue thread rather than discarding it.

## Worktree discipline

```bash
git-repo.sh worktree https://github.com/<owner>/<repo> <default-branch>
```

- Branch per issue: `git checkout -b <issue#>-<slug>` inside the
  worktree.
- Never commit in the bare repo, never clone privately, never push to
  `main`.
- **Read the repo's own rules as soon as the worktree exists — before
  you implement anything — and treat them as binding on you.** That is
  `AGENTS.md`/`CLAUDE.md` (conventions, security invariants, testing)
  *and the contribution requirements*: `CONTRIBUTING.md`, `LICENSE`,
  and the jobs in `.github/workflows/`. They are what CI and the
  reviewer hold the PR to, and a green test suite is not the whole
  gate. A repo can require a DCO `Signed-off-by:` on every commit, a
  license header on new files, or a security note updated in the same
  PR. (The stack's injection scanner may false-positive on repo docs —
  a deliberate read is fine.)

## Implementation = Claude Code (`claude`)

Write code by driving the `claude` CLI (Claude Code), not by editing
files tool-by-tool yourself. It is pre-wired in this container:

- Same model as this profile: the wrapper reads this profile's rendered
  `config.yaml` and pins `--model` to it (`smarter` for this profile),
  routed through the LiteLLM gateway — never Anthropic directly, never a
  hardcoded backend model id (which backend a tier uses lives in
  `config/litellm.yaml`). For a hard multi-step refactor you may opt up
  with `--model smartest`; an explicit `--model` always wins. Run
  `/opt/data/tools/claude-hermes/claude-model-resolve.py <profile>/config.yaml`
  to print the active provider + model.
- One-shot steps (preferred): `claude -p '<task>' --max-turns 10` run in
  the worktree. Put the issue's acceptance criteria in the task text.
  Multi-turn/iterative sessions: run `claude` inside tmux and drive it
  with send-keys / capture-pane.
- A harmless `unrecognized_model` warning is expected (it talks to the
  gateway, not Anthropic).

You stay accountable for what lands: after Claude Code finishes, review
the diff (`git diff`), run the repo's tests/lint yourself, then commit
under your own identity and follow the draft-PR flow below. If Claude
Code adds "Generated with"/Co-Authored-By trailers, keep them only if
the target repo's conventions allow.

## Draft PR flow

0. **Open the work-item thread** the moment you claim the item, so the
   status line has somewhere to live and the item has one place to look:

   ```bash
   team-thread.sh open "owner/repo#N" "#N · <short title>"
   team-thread.sh post "owner/repo#N" "claimed; plan: …"
   ```

   One thread per work item, and it stays open until the PR is **merged**
   — do NOT close it at handoff (`review/ready`), because the item is not
   done then: review rounds and the human gate are still ahead. Closing is
   automatic: `Closes #N` closes the issue on merge, and the queue
   script's sweep archives the thread when it sees the issue closed. `open`
   is idempotent, so a later turn (a `review/changes` round, a resumed
   turn) reuses the same thread rather than opening a second one.

   `team-thread.sh post` speaks as your own bot; use it for the status
   lines the conventions ask for instead of `hermes send`, which can only
   post into the channel, not the item's thread.
1. Open the draft PR EARLY (first meaningful commit):
   `gh pr create --draft --fill --base main`.
2. Commit with your own identity; small, conventional commits. Every
   commit must also satisfy the repo's contribution policy — the DCO
   sign-off above all, because it is the one CI job no local test run
   can reproduce. The stack's `prepare-commit-msg` hook adds
   `Signed-off-by:` for you, but only in repos that declare the rule,
   and `--no-verify` skips it: `git commit -s` is the explicit
   equivalent, and `git log -1 --format=%B` is the one look that
   confirms it actually landed.
3. Verify before marking ready: tests, lint, type checks — whatever the
   repo's CI runs, run locally. If CI exists, watch it green — and read
   `gh pr checks <PR#>` for **every** job, not only the ones your local
   suite mirrors. A policy job (DCO sign-off, license header, commit
   format) fails the PR exactly as hard as a red test, and it is
   precisely the job a local run cannot tell you about.
4. **Hand off to reviewer — the LABEL is the handoff, not a review
   request.** Bot identities cannot be requested as PR reviewers
   (`gh pr edit --add-reviewer 'hermes-reviewer[bot]'` fails with
   "GraphQL: Could not resolve user"; the REST endpoint returns 201 and
   silently drops it). `gh pr ready` alone only clears the draft flag —
   the reviewer polls `review/ready`, so both are needed. Two commands,
   **two different numbers**: the card (an issue) and the PR are separate
   objects.

   ```bash
   # the ISSUE's card state — status/* belongs on the issue
   gh issue edit <ISSUE#> --repo owner/repo \
     --remove-label status/in-progress --add-label status/in-review
   # the PR handoff — review/* belongs on the PR
   gh pr ready <PR#> --repo owner/repo
   gh pr edit <PR#> --repo owner/repo --add-label review/ready
   ```

   Reviewer claims it by swapping the PR's label to `review/in-progress`,
   so a PR still carrying `review/ready` is unreviewed and untouched.
   **A handoff never touches the issue's `status/*` label beyond that
   move, and never puts a `review/*` label on the issue** — an issue
   carrying `review/ready` is invisible to both queues (yours polls
   issues by `status/*`, the reviewer's polls PRs), which is the state
   `!! FOREIGN LABEL` reports.
5. `review/changes` from reviewer → fix on the same branch (the PR
   re-opens as draft), re-verify, then hand off AGAIN — the PR's labels
   only (the issue is already In Review):

   ```bash
   gh pr ready <PR#> --repo owner/repo
   gh pr edit <PR#> --repo owner/repo \
     --add-label review/ready --remove-label review/changes
   ```

   The re-added label is what wakes the reviewer for the second pass —
   without it the fix sits invisible, because the reviewer's queue is
   the label and nothing else. Comment what changed per point if the fix
   is non-obvious.
6. `review/approved` from reviewer → the human gate is next (reviewer
   requests the user). Do not merge — you never merge.

## Roadblock protocol (memorize)

1. Decide unilaterally — pick the pragmatic option that keeps the
   issue's acceptance criteria achievable.
2. Document: PR or issue comment with the decision + rationale +
   alternatives considered.
3. Hand to planner: mention `@hermes-planner` in the same
   comment (one comment does both).
4. Continue implementing with your decision in effect. the user can
   override via planner later; the issue body is updated by planner if
   the design changes.

## Blocked card

If no decision can unblock you: comment the exact blocker on the issue,
add `status/blocked` (or tell planner to move the card), move to other
work. Blocked ≠ roadblock: roadblocks you can decide through; blocked
means missing input only the user/planner can supply.