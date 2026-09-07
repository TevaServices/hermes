---
name: team-planner
description: Planner role procedure — issue authoring, per-repo boards, standup/sprint cadence, roadblock intake
version: 1.0.0
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

## Assigning developer work

Issue → Ready, then assign `hermes-dev[bot]`:

```bash
gh issue edit owner/repo#N --add-assignee hermes-dev[bot]
```

Developer discovers assigned work via its self-pull cron; no Discord
ping is needed (a `#dev` post announcing the handoff is courteous and
expected for non-trivial specs).

## Roadblock intake

When developer comments a roadblock decision
(`@hermes-planner` mention):

1. Read the decision + context; validate the design impact.
2. If user feedback is needed: post on Discord (`#planning`) with the
   issue link and a clear question, or comment on the issue tagging
   `@the user` — the choice is yours; label the channel accordingly.
   The decision stands (developer's unilateral call) unless the user
   overrides; record either way in the issue.
3. If it changes the design: update the issue body (GitHub = system of
   record) before developer resumes.

## Daily standup digest (weekdays ~09:00 ET, cron)

Aggregate across ALL onboarded repos (search-based, no per-board crawl):

1. Merged yesterday: `gh search prs --merged:">=YYYY-MM-DD" --owner <account>` per installation
   (repeat per account with the right token).
2. In flight: open PRs (draft + ready) by team bots; issues in
   Ready/In Progress (label- or board-based per repo registry).
3. Blocked/needs-user: anything tagged `blocked` or `status/blocked`,
   plus open questions to the user.
4. Today: top of each repo's Ready column/label.
5. Post to Discord `#planning` (≤ 30 lines, repo-prefixed references).

## Weekly sprint review (Fri ~16:00 ET, cron)

1. Collect the week's merged PRs, closed issues, and carry-over.
2. Write a sprint-log issue in the most-active repo (label
   `sprint-log`), summarizing per repo.
3. Discord `#planning`: 5–10 line summary + link to the log issue.

## Repo onboarding

Run the `team-onboarding` skill — planner owns it end to end.