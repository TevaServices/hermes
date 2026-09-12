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
2. **Ready** → issue assigned to developer (planner or the user).
3. **Implementation** → developer works a branch, opens a **draft PR
   early** (`Closes #N`), keeps the issue updated via comments, moves
   the board item through its columns (see boards below).
4. **Roadblock** → developer decides unilaterally, documents the
   decision in the PR/issue, hands the information to planner via a
   GitHub comment `@hermes-planner` (planner may surface it to
   the user on Discord; developer never messages the user directly).
5. **Review** → developer marks the PR ready for review → reviewer runs
   the gates (`team-reviewer` skill): pass = approve + mark ready +
   request the user's review; fail = "Request changes" with issues
   explained, back to developer.
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