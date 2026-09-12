---
name: team-developer
description: Developer role procedure — self-pull work discovery, worktree discipline, draft PRs, roadblock protocol
version: 1.2.0
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
# find routed work — run per installation/account with that account's
# token (GH_TOKEN_<ACCOUNT>; see team-github-token)
team-queue.sh

# claim the issue you picked (same turn, BEFORE starting work)
gh issue edit owner/repo#N --remove-label status/ready \
  --add-label status/in-progress
```

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
its exit code as the signal.**

- `exit 0` + `QUEUE EMPTY` — genuinely nothing routed. Idle is correct.
- `exit 0` + issues — claim one and work it.
- `exit 2` / `3` / `4` / `5` — **an incident, not an idle state.** The
  script says which: query failure, blind search (token/scope), nothing
  onboarded, or a repo missing the routing label. Post the script's own
  message to `#dev` the same turn. Do not report "no work available".

If you ever find yourself with an empty queue across every repo while
planner believes it has routed you work, that discrepancy **is** the
bug — say so on `#dev` instead of waiting for the next cron wake.

## Worktree discipline

```bash
git-repo.sh worktree https://github.com/<owner>/<repo> <default-branch>
```

- Branch per issue: `git checkout -b <issue#>-<slug>` inside the
  worktree.
- Never commit in the bare repo, never clone privately, never push to
  `main`.
- Read the repo's `AGENTS.md`/`CLAUDE.md` deliberately before the first
  commit there and follow its rules (the stack's injection scanner may
  false-positive on repo docs — a deliberate read is fine).

## Implementation = Claude Code (`claude`)

Write code by driving the `claude` CLI (Claude Code), not by editing
files tool-by-tool yourself. It is pre-wired in this container:

- Same model as this profile: the wrapper reads this profile's rendered
  `config.yaml` and pins `--model` to it (baseline tier today), routed
  through the LiteLLM gateway — never Anthropic directly, never a
  hardcoded model id. For a hard multi-step refactor you may opt up with
  `--model ollama/glm-5.3` (elevated tier); an explicit `--model` always
  wins. Run
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

1. Open the draft PR EARLY (first meaningful commit):
   `gh pr create --draft --fill --base main`.
2. Commit with your own identity; small, conventional commits.
3. Verify before marking ready: tests, lint, type checks — whatever the
   repo's CI runs, run locally. If CI exists, watch it green.
4. **Hand off to reviewer — the LABEL is the handoff, not a review
   request.** Bot identities cannot be requested as PR reviewers
   (`gh pr edit --add-reviewer 'hermes-reviewer[bot]'` fails with
   "GraphQL: Could not resolve user"; the REST endpoint returns 201 and
   silently drops it). `gh pr ready` alone only clears the draft flag —
   the reviewer polls `review/ready`, so both are needed:

   ```bash
   gh pr ready <n> --repo owner/repo
   gh pr edit <n> --repo owner/repo --add-label review/ready
   ```

   Reviewer claims it by swapping the label to `review/in-progress`, so
   a PR still carrying `review/ready` is unreviewed and untouched. Move
   the card to In Review (or ask planner to).
5. `review/changes` from reviewer → fix on the same branch (the PR
   re-opens as draft), re-verify, then hand off AGAIN: `gh pr ready` plus
   `gh pr edit --add-label review/ready --remove-label review/changes`.
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