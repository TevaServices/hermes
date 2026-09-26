---
name: team-conventions
description: Shared conventions for the agile SaaS team (GitHub-first workflow, identity, cross-referencing, repos)
version: 1.2.0
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
5. **Review** → developer moves the ISSUE to `status/in-review`, marks the
   PR ready (`gh pr ready`) and labels **the PR** `review/ready` — **the
   label is the handoff**, because bot identities cannot be requested as
   PR reviewers (the request is rejected, and the REST form silently
   drops it). Reviewer claims it by swapping the PR's label to
   `review/in-progress`, then runs the gates
   (`team-reviewer` skill): pass = approve + `review/approved` +
   request the user's review; fail = "Request changes" + `review/changes`
   with issues explained, back to developer. A developer fix re-adds
   `review/ready` — that re-add is what wakes the reviewer again, so
   never merge a fix silently. Each finding is one review **thread**, and
   the fix round that addresses a finding also RESOLVES its thread (see
   "Review threads" below) — a repo can require every conversation
   resolved before merge, and an open thread is then a merge gate no CI
   job reports.
6. **Human gate** → the user reviews → reviewer merges (only reviewer
   merges) or routes the user's flags back to developer.
7. Issue auto-closes via `Closes #N` on merge; planner moves the card to
   Done. (The close is the state change that matters; the label is
   bookkeeping, and it is not the reviewer's to write.)

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
- Moving items through columns/labels is planner's job. Developer moves
  its own card where a self-serve step is natural (it sets In Progress on
  claim, and In Review when it hands off). **Reviewer moves no card at
  all**: it judges on the PR and asks planner (see the routing-label
  rules below).

### The routing labels (these ARE the queues)

Nothing in this team is routed by assignment or review request — both
are impossible for App bot identities. Each handoff is a label that the
receiving role polls and then *consumes*, which is also what stops a
queue from re-serving the same item every tick:

| Label | On | Added by | Removed by |
|---|---|---|---|
| `status/backlog` | issue | planner | planner |
| `status/ready` | issue | planner (routing) | planner, developer (on claim) |
| `status/in-progress` | issue | developer (on claim) | developer (on handoff) |
| `status/in-review` | issue | developer (on handoff) | planner |
| `status/blocked` | issue | planner, developer | planner |
| `status/done` | issue | planner | planner |
| `review/ready` | PR | developer (handoff) | reviewer (on claim) |
| `review/in-progress` | PR | reviewer (on claim) | reviewer (on verdict) |
| `review/changes` | PR | reviewer (verdict) | developer (on re-handoff) |
| `review/approved` | PR | reviewer (verdict) | — (terminal) |

**Two families, two objects, and the object is half the rule.** The
`status/*` family belongs to ISSUES and the `review/*` family to PULL
REQUESTS — `gh issue edit` writes the first, `gh pr edit` the second,
and the two numbers for one work item are *different* (the issue and the
PR it is closed by). A `review/*` label on an issue and a `status/*`
label on a PR are both faults, not untidiness: each queue polls one
family on one object kind, so a misfiled label makes the work item
invisible to *both* lanes while it still looks busy. That happened here
(2026-09-25, an issue left carrying `review/ready` and no `status/*`),
it flip-flopped for hours, and the guard below is what reports it.

```bash
# which object am I writing?
#   status/*  -> the ISSUE      gh issue edit <ISSUE#> --add-label status/…
#   review/*  -> the PR         gh pr edit    <PR#>    --add-label review/…
# the PR for an issue (the reviewer's whole surface is the PR):
gh pr list --repo <owner>/<repo> --state open \
  --json number,body --jq '.[] | select(.body | test("(?i)closes #<ISSUE#>")) | .number'
```

**Who may write what.** A profile writes only what it owns:

- `status/*` is **planner's and developer's**. Planner routes and keeps
  the board honest; developer claims, hands off, and flags blocked.
- `review/*` is **developer's to hand off and reviewer's to judge**:
  developer adds `review/ready` and drops `review/changes`; everything
  else in the family — claim, verdict, and the `review/ready` removal on
  claim — is the reviewer's.
- **The reviewer never writes a `status/*` label and never edits an
  issue.** A review is judged on the PR; the card is not the reviewer's
  to move. When a verdict implies a card change, say so to planner
  (`@hermes-planner` comment on the PR/issue) and let planner move it —
  the same intake channel the developer's roadblocks use.

That last rule is the one this team got wrong. The reviewer's verdict
steps used to say "Card → In Progress / In Review / Done", and on a
label-mechanism repo the card *is* the `status/*` label — so a failed
review wrote `status/in-progress`, which is the developer's own
claim/**resume** label: the developer's next self-pull then reads the
item as its own interrupted turn, moves it back, and the two profiles
trade the same issue every tick. Judge on the PR; hand the card to
planner.

The onboarding procedure creates this whole set per repo; a missing one
is a real fault (work routed there goes invisible), which the queue
scripts report rather than silently showing an empty queue. The
converse — a label of the *wrong family* for the object — is reported
just as loudly by the queue guard (`!! FOREIGN LABEL`, see below), so a
misfiled label is a thing you will be told about rather than a thing you
have to remember to check.

### Review threads (the reviewer opens, the developer resolves)

A repo can require every review conversation resolved before merge
(`required_review_thread_resolution` — GitHub's own doc: "This ensures
that all comments are addressed or acknowledged before merge"). It is a
MERGE gate, invisible to CI, and the state one PR sat in on 2026-09-26
with every check green: the reviewer had opened nine threads across four
rounds, verified every finding fixed, and approved — and every thread was
still open, so nothing could merge.

The ownership is one-writer-per-action, the same shape as the labels:

| Action | Owner |
|---|---|
| open a thread (one per finding) | reviewer, with the verdict |
| reply with what changed | developer |
| resolve a thread | **developer**, in the turn it fixes that finding |

**A fix is not complete until its thread is resolved.** The developer
resolves the threads for the findings it fixed, in the same turn it
publishes the fix, and leaves open only what it did not fix — with a
reply saying why, because an open thread then means a disagreement
rather than an oversight. The reviewer does not resolve the developer's
work for it; it re-reads the threads and re-opens (replies on) any it
finds were resolved without the finding being fixed.

One residual is the reviewer's alone, because the developer never gets
another turn: a finding the reviewer raises **with its own approving
verdict** (a nit it will not block on) must not be left open — the
reviewer either puts it in the summary comment or resolves it in the
same turn it raises it.

### Handoff read-back: the gates CI cannot see

Green checks are not a mergeable PR. Two repo SETTINGS bypass CI
entirely, and both produce the same symptom — `mergeStateStatus:
BLOCKED` with every check green:

- **Required signatures** — a repo that requires signed commits checks
  every commit on the head branch at merge time. A GitHub App can only
  produce a verified commit through the API, never by pushing, so the
  developer publishes with `git-publish.py` and never `git push` (see
  `team-developer` §Publishing).
- **Required review-thread resolution** — the table above.

Read the state back before claiming a handoff is ready, on both sides:

```bash
gh pr view <PR#> --repo owner/repo --json mergeable,mergeStateStatus \
  --jq '"\(.mergeable) \(.mergeStateStatus)"'      # BLOCKED = a setting is unmet
gh api repos/owner/repo/pulls/<PR#>/commits \
  --jq '[.[].commit.verification.verified] | all'  # false = unsigned commits
```

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
  `status/blocked`, and say plainly that it is waiting on the user. Do **not**
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
turn, not someone else's. It also prints `!! FOREIGN LABEL` when a label
of the wrong family is sitting on an object (`review/*` on an issue, or
`status/*` on a PR) — that one is a misfiled write, and the line names
the object and the command to undo it.

Read back after each handoff, and compare with what you intended. Note
the two different numbers: `gh issue view` takes the **issue** number,
`gh pr view` the **pull request** number, and for one work item they are
not the same (the PR body's `Closes #<issue#>` is the link between them —
`gh pr list --json number,body` finds the PR for an issue):

```bash
gh issue view <ISSUE#> --repo <owner/repo> --json labels --jq '[.labels[].name]|join(",")'
gh pr view    <PR#>    --repo <owner/repo> --json isDraft,labels
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

The team's GitHub Apps are installed per account/org, and the `gh` shim
picks the right installation token from the command's target owner — a
`-R/--repo` argument, a `gh api repos/<owner>/…` path, or the cwd's git
origin. There is no `GH_TOKEN_<OWNER>` variable to export: the org
credentials are descriptor files in your tool-home that the shim reads
on your behalf, and a call whose owner it cannot see is forced with
`GH_TOKEN="$(gh-org-token <orgslug>)"`. A 403
`Resource not accessible by integration` on an org repo means the
PERSONAL token went out — not that a permission is missing. See
`team-github-token`, and `hermes-stack-ops` for the full routing rules.
