---
name: team-planner
description: Planner role procedure — issue authoring, per-repo boards, standup/sprint cadence, roadblock intake
version: 1.1.0
metadata:
  hermes:
    tags: [team, planner, pm, design]
    category: devops
---

# Planner procedure (PM + design)

Load `team-conventions` first (workflow, identities, boards,
cross-referencing). This skill adds the planner's own procedures.

## Writing a work item (issue)

One issue = one coherent unit of work. Body template:

```markdown
## Goal
<one paragraph — what and why>

## Acceptance criteria
- [ ] <verifiable criterion>
- [ ] …

## Design
<data model / API shape / UI notes — every decision a developer needs.
Sibling issues are NOT visible to implementers; this section must be
self-sufficient.>

## Out of scope
- <explicitly deferred items>
```

- Label `status/backlog` or add to the repo Project's Backlog column on
  creation.
- the user's idea → issue link goes back to the Discord thread the same
  turn.

## Moving a card (per-repo board)

- Org repo with a Project: `gh project item-*` commands (board id is in
  the repo registry; see `team-onboarding`).
- Personal repo: move the status label
  (`status/backlog` → `status/ready` → …) with
  `gh issue edit <n> --remove-label … --add-label …`.

## Routing developer work

**The handoff is the label, not an assignee.** GitHub App bot
identities cannot be assigned issues or PRs at all — the API rejects it
with 403 / `cannot be assigned to issues or pull requests`, and
`GET /repos/{owner}/{repo}/assignees/{login}` returns 404 for every bot.
That is a rule about the *assignee's* account type, so **no token
change fixes it**: a user token on the owner's own repo, fails
identically. `--add-assignee hermes-dev[bot]` will always fail —
do not retry it, and do not report it as a credential problem.

Moving the issue to Ready *is* the routing: `status/ready` is
developer's queue.

```bash
gh issue edit <n> --repo owner/repo --add-label status/ready
```

Developer discovers routed work via its self-pull cron and claims it by
swapping the label to `status/in-progress`; no Discord ping is needed (a
`#dev` post announcing the handoff is courteous and expected for
non-trivial specs).

**Verify the label actually landed** before you consider the handoff
done:

```bash
gh issue view <n> --repo owner/repo --json labels --jq '.labels[].name'
```

The handoff is silent by design, so a label that failed to apply leaves
the issue sitting invisibly in the backlog — and an idle developer looks
exactly like a developer with nothing to do. If `status/ready` is
missing, that is the incident; fix it or raise it, don't move on.

## Reading code (read-only — use `claude`)

Your design sections must be self-sufficient, and they are only as good as
your understanding of the code they land in. You have read-only code
access, so **ask the codebase rather than reasoning from the issue text**:
"where does X live, how does Y currently work, what would Z touch" is a
question, not an implementation.

Drive `claude` in the project worktree in print mode with a question
(`claude -p '<question>' --max-turns 10`), and ask it to cite `file:line`.
It runs on your own model through the gateway; see `hermes-stack-ops` for
the wrapper's contract.

Two hard limits: **do not write code** — you design, developer implements —
and **do not commit**. If you want a second opinion on a design that spans
several files, `delegate_task` is the better shape (a child that reads the
code with fresh context and hands you a conclusion, instead of that reading
flooding your context).

## Roadblock intake

When developer comments a roadblock decision
(`@hermes-planner` mention):

1. Read the decision + context; validate the design impact.
2. If user feedback is needed: post on Discord (`#planning`) with the
   issue link and a clear question, or comment on the issue tagging
   `@<owner>` — the choice is yours; label the channel accordingly.
   The decision stands (developer's unilateral call) unless the user
   overrides; record either way in the issue.
3. If it changes the design: update the issue body (GitHub = system of
   record) before developer resumes.

## Daily standup digest (weekdays ~09:00 ET — NOT yet scheduled)

> These digests are **not** cron jobs today. The declared jobs in
> `config/cron.toml` are the two `no_agent` self-pull queues plus three
> token-free housekeeping scripts (Claude Code update, worktree prune,
> repo refresh); a digest is an agent job (it needs an inference turn), so
> scheduling it is a standing token cost that has not been approved. Run
> this procedure on request (`hermes cron run` will not help — there is no
> job).

Aggregate across ALL onboarded repos (search-based, no per-board crawl):

1. Merged yesterday: `gh search prs --owner <account> --merged ">=YYYY-MM-DD"` per installation
   (repeat per account with the right token).
2. In flight: open PRs (draft + ready) by team bots; issues in
   Ready/In Progress (label- or board-based per repo registry).
3. Blocked/needs-user: anything tagged `status/blocked`, plus open
   questions to the user.
4. Today: top of each repo's Ready column/label.
5. Post to Discord `#planning` (≤ 30 lines, repo-prefixed references).

## Weekly sprint review (Fri ~16:00 ET — NOT yet scheduled)

> Same as the standup: run on request; not a scheduled job today.

1. Collect the week's merged PRs, closed issues, and carry-over.
2. Write a sprint-log issue in the most-active repo (label
   `sprint-log`), summarizing per repo.
3. Discord `#planning`: 5–10 line summary + link to the log issue.

## Repo onboarding

Run the `team-onboarding` skill — planner owns it end to end.