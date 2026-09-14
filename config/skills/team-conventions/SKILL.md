---
name: team-conventions
description: Shared conventions for the household agile SaaS team (GitHub-first workflow, identity, cross-referencing, repos)
version: 1.0.0
metadata:
  hermes:
    tags: [team, workflow, github, conventions]
    category: devops
---

# Team conventions (all roles — planner / developer / reviewer)

The team is a GitHub-first agile pipeline: **GitHub is the system of
record; Discord is for discussion.** Three Hermes profiles (planner,
developer, reviewer) work as visible, distinct identities.

## Identities

| Role | GitHub App | Discord | Powers |
|---|---|---|---|
| planner | `hermes-planner[bot]` | own bot, `#planning` | issues, boards, specs; Read-only code |
| developer | `hermes-dev[bot]` | own bot, `#dev` | commits, **draft** PRs; never merges |
| reviewer | `hermes-reviewer[bot]` | own bot, `#reviews` | reviews, marks ready, **merges** |

Never impersonate another role. Sign Discord updates with your role.
Git commits carry the role's own git identity (configured by the
entrypoint from the profile env).

## The workflow

1. **Idea** (Discord, from the user) → planner writes the **issue** (goal,
   acceptance criteria, design decisions) → planner comments the issue
   link back into the Discord thread.
2. **Ready** → planner routes the issue to developer by moving it to
   `status/ready`. **The label is the handoff** — GitHub App bot
   identities cannot be assigned issues or PRs (403 /
   `cannot be assigned to issues or pull requests`, for every bot, no
   token change fixes it), so the assignee field is unused by design.
   Developer claims the issue by swapping to `status/in-progress`.
3. **Implementation** → developer works a branch, opens a **draft PR
   early** (`Closes #N`), keeps the issue updated via comments, moves
   the board item through its columns (see boards below).
4. **Roadblock** → developer decides unilaterally, documents the
   decision in the PR/issue, hands the information to planner via a
   GitHub comment `@hermes-planner` (planner may surface it to
   the user on Discord; developer never messages the user directly).
5. **Review** → developer marks the PR ready (`gh pr ready`) AND labels
   it `review/ready` — **the label is the handoff**, because bot
   identities cannot be requested as PR reviewers (the request is
   rejected, and the REST form silently drops it). Reviewer claims it by
   swapping to `review/in-progress`, then runs the gates
   (`team-reviewer` skill): pass = approve + `review/approved` +
   request the user's review; fail = "Request changes" + `review/changes`
   with issues explained, back to developer. A developer fix re-adds
   `review/ready` — that re-add is what wakes the reviewer again, so
   never merge a fix silently.
6. **Human gate** → the user reviews → reviewer merges (only reviewer
   merges) or routes the user's flags back to developer.
7. Issue auto-closes via `Closes #N`; reviewer/board updates status to
   Done.

## Boards and status labels

- **Org repos** (GitHub App can manage org Projects): each onboarded
  repo gets its own Project with the standard column set
  `Backlog → Ready → In Progress → In Review → Blocked → Done`.
- **Personal-account repos** (App tokens cannot manage user-owned
  Projects): use the **status label set** instead:
  `status/backlog`, `status/ready`, `status/in-progress`,
  `status/in-review`, `status/blocked`, `status/done` — same lifecycle,
  same semantics. The onboarding procedure creates the label set and
  records which mechanism the repo uses.
- Moving items through columns/labels is planner's job (developer and
  reviewer do it for their own cards when a self-serve step is natural,
  e.g. developer sets In Progress when starting a card).

### The routing labels (these ARE the queues)

Nothing in this team is routed by assignment or review request — both
are impossible for App bot identities. Each handoff is a label that the
receiving role polls and then *consumes*, which is also what stops a
queue from re-serving the same item every tick:

| Label | On | Means | Owner moves it to |
|---|---|---|---|
| `status/ready` | issue | routed to developer | `status/in-progress` (on claim) |
| `status/blocked` | issue | needs a decision | — (planner/the user) |
| `review/ready` | PR | routed to reviewer | `review/in-progress` (on claim) |
| `review/changes` | PR | back with developer | re-add `review/ready` when fixed |
| `review/approved` | PR | waiting on the user | — (reviewer merges on approval) |

The onboarding procedure creates this whole set per repo; a missing one
is a real fault (work routed there goes invisible), which the queue
scripts report rather than silently showing an empty queue.

## Surfaces the team does NOT touch (user-owned)

Some changes are deliberately outside every team identity. This is a
policy choice, not a limitation to route around — do not look for a
token trick, a different App, or an API path. Both of these already have
a mechanism; use it.

- **`.github/workflows/*`** — GitHub refuses to create or update a
  workflow file from an App token that lacks the `workflows` permission,
  and **no team App has it, on purpose**: a workflow file runs arbitrary
  code with the repo's secrets, so granting it would widen what a
  compromised or confused agent could do. A push that touches one is
  rejected server-side (`refusing to allow a GitHub App to create or
  update workflow … without 'workflows' permission`) and there is no API
  way to change an App's own permissions — `PATCH /app` is 404; it is an
  owner-only UI action.
  **So: an item that needs CI/workflow changes is the user's to land.**
  Write the proposed file content into the issue (or the work-item
  thread) so it can be reviewed and applied verbatim, label the issue
  `blocked`, and say plainly that it is waiting on the user. Do **not**
  commit it to a branch and attempt the push — it cannot succeed, and the
  turn is better spent. Everything else about the item is still yours:
  the design, the content, the review.
- **Branch protection** (see the registry) — similarly owner-only.

## Never report a state change you have not verified

Every handoff here is a GitHub state change — a label swap, `gh pr ready`,
a comment. **Read it back before you report it.**

A status message claiming work that did not land is worse than a failure,
because the queues ARE the labels: a label that never applied is
indistinguishable from "nothing to do", so the pipeline stalls silently
while the transcript says it succeeded. This has already happened — a
turn reported *"review/ready label added"* while the PR was still a draft
with no labels, and the reviewer, correctly idle, looked like the
problem. The developer's own queue now prints `!! HANDOFF INCOMPLETE` for
exactly this state; if you see that line, it is describing your previous
turn, not someone else's.

Read back after each handoff, and compare with what you intended:

```bash
gh issue view <n> --repo <owner/repo> --json labels --jq '[.labels[].name]|join(",")'
gh pr view    <n> --repo <owner/repo> --json isDraft,labels
```

`gh issue edit` / `gh pr edit` print a URL on success but do **not** fail
loudly when the change was a no-op — a URL is not evidence. If the
read-back disagrees with what you claim, say so on the work-item thread
and fix it. "I could not confirm X" is a useful report; "X is done" when
it is not costs the team a whole cycle.

## Cross-referencing

- Discord ↔ GitHub: Discord messages carry `owner/repo#123` links;
  GitHub comments that summarize a Discord discussion end with
  `(from Discord thread <message link>)`.
- Always name the repo (`owner/repo#123`), never a bare `#123` — the
  team works across many repos and multiple orgs.
- The repo registry (see `team-onboarding`) is the source of truth for
  which repos are under the team's workflow and their settings.

## Discord channels and threads

Each role's channel is **yours alone**: `allowed_channels` +
`require_mention = false` (in `config/profiles/<role>/profile.toml`,
under the nested `[config_extra.platforms.discord.extra]` block) means
your bot answers every message there with no @mention, and ignores every
other channel — including your teammates'. An @mention elsewhere will not
reach you; cross-role traffic goes through GitHub, per the workflow above.

A request in your channel **gets its own auto-created thread** (named from
the message), and your reply lands in it — so do the work in that thread:
that is where the issue link goes back ("planner comments the issue link
back into the Discord thread"). These are not "free-response" channels:
free-response suppresses auto-threading, which would cost you the thread.

Note that auto-threading only fires on an **inbound** message. The team
agents are woken by their cron self-pull, which injects into the profile's
Bot Chat — there is no inbound Discord message, so there is no thread to
inherit. Work items get one explicitly, via `team-thread.sh` (see
`team-developer` / `team-reviewer`): one thread per work item, opened when
the item is claimed, kept open until the PR is **merged**, and archived
automatically when the merge closes the issue. A thread is a work item's
home, not a per-turn scratchpad — do not close it at handoff.

**Post with the helpers, never with a hand-rolled request.** Use
`team-thread.sh post "<key>" "…"` for a work item's thread, or
`hermes send --to discord:<channel>` for the channel. Specifically, do
**not** read a token out of `$HERMES_HOME/.env` with `grep … | head -1`
and call the Discord REST API yourself. That is not a shortcut, it is a
trap: `.env` files can contain more than one definition of a key (a
profile's file inherits the default profile's own vars), and a
first-match reader silently picks the wrong one. It has already caused a
developer status line to be posted into `#dev` by the **main** bot —
a wrong-identity post that looked like it worked. The helpers resolve
credentials the same way the runtime does, so they cannot drift.

To open a thread yourself (a second topic in one request), use the
`discord` tool — it is deferred behind tool search, so it is not in your
tool list until you look for it:

1. `tool_search` — e.g. `"create discord thread"` returns `discord`.
2. `tool_call` — `{name: "discord", arguments: {action: "create_thread",
   channel_id: "<channel id>", name: "<thread name>"}}`; add `message_id`
   to anchor it to an existing post. It returns the `thread_id`.

Agents get **no send-message tool** (outbound platform messaging is not
model-driven upstream), and your turn's reply lands in the channel, not in
a thread you opened mid-turn — so post *inside* it with the CLI from
`terminal`:

    hermes send --to discord:<channel_id>:<thread_id> "<your post>"

It resolves credentials from the active profile's `$HERMES_HOME/.env`, so
it should speak as your own bot — confirm the first post shows your role's
bot before relying on it.

If creation fails, Discord's reason is relayed verbatim — usually
`Bot lacks CREATE_PUBLIC_THREADS in this channel, or cannot view it.` That
is a server-side permission, not something to retry: say so in the channel
instead of working around it (host-side check:
`python3 scripts/discord-thread-doctor.py`).

## Multi-installation tokens

The team's GitHub Apps are installed per account/org. Token env vars
are installation-keyed (`GH_TOKEN_<OWNER>`, `GH_TOKEN_<ORG>`, …); pick
the token matching the repo's owner (see `team-github-token` in each
role's profile skills). The stack entrypoint provisions these from the
host env file; never read provider keys directly.