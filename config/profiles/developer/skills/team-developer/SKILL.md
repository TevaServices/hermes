---
name: team-developer
description: Developer role procedure — self-pull work discovery, worktree discipline, draft PRs, roadblock protocol
version: 1.1.0
metadata:
  hermes:
    tags: [team, developer]
    category: devops
---

# Developer procedure

Load `team-conventions` + `team-github-token` first.

## Self-pull: finding work (the cron runs this query)

Assigned, open issues with no linked PR yet:

```bash
gh search issues --assignee:hermes-dev[bot] --state:open \
  --is:issue --limit 30 --json repository,number,title,url,labels
```

Run it per installation/account with that account's token
(`GH_TOKEN_<ACCOUNT>`; see `team-github-token`). Exclude issues whose
repo+number already has an open PR authored by you
(`gh search prs --author:hermes-dev[bot] --state:open`) — that
guard prevents double-starting on cron re-wakes. Pick by priority:
board In Progress first, then Ready, oldest first. Post one line to
`#dev` when you pick work up.

If the cron handed you a specific issue in its prompt, start there —
the query above is the fallback.

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
4. When defensible: `gh pr ready` — reviewer picks it up from its
   self-pull queue. Move the card to In Review (or ask planner to).
5. "Request changes" from reviewer → fix on the same branch (the PR
   re-opens as draft), re-verify, `gh pr ready` again. Comment what
   changed per point if the fix is non-obvious.

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