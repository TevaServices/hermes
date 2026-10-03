---
name: team-planner
description: Planner role procedure — issue authoring, per-repo boards, standup/sprint cadence, roadblock intake
version: 1.2.0
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

## Decisions
<the table below. REQUIRED — see "Speccing" below.>

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

**Write the body to a FILE and pass `--body-file` — never inline.** A
quoted `--body "…"` is expanded by the shell *before* gh runs, so a
backtick code span is command substitution: the span is replaced by that
command's stdout (empty, if the command does not exist). A planner filed
five issues in one repo this way, with a fleet table where the word
`mach` belonged and blanks mid-sentence where `systemctl`, `.deb` and
`MACH_STATE_DIR` belonged — the issue body was literally the shell's
output. The `gh` shim now refuses the inline spelling (exit 1, message
names the fix), so this is the shape that works:

```bash
# 1. write the body with write_file, e.g.
#    /opt/data/profiles/planner/cache/scratch/issue_body.md
# 2. then:
gh issue create --repo <owner>/<repo> --title "<title>" \
  --label status/backlog --label type/feature --body-file <file>
gh issue edit   <n> --repo <owner>/<repo> --body-file <file>
```

An **already-corrupted** body is repaired, not just avoided: re-read it
(`gh issue view <n> --json body`) and check every code span, path and env
var survived before you move on.

- Label `status/backlog` or add to the repo Project's Backlog column on
  creation.
- **A `type/*` label is REQUIRED, every time** — `type/bug`,
  `type/feature`, `type/chore` or `type/security` (and `type/breaking` when
  the change is incompatible with what is already deployed). It is not
  decoration: the release agent infers the version bump from it
  (`breaking`→major, `feature`→minor, else patch), so an untyped issue
  contributes only a patch and is named in the release announcement. The
  developer copies the issue's type onto its PR, and the developer's queue
  hoists `type/bug` items ahead of features — which is the whole mechanism
  behind "bugs before features". An issue with no type is incomplete.
- the user's idea → issue link goes back to the Discord thread the same
  turn.

## Speccing: decide it, or ask — never hand the choice on

Your job is to *end* open questions, not to enumerate them. An issue whose
Design still contains a choice is not a spec; it is a note that a spec
should exist. The developer implements what you wrote and has no way to
ask the user — so anything you leave open, it decides unilaterally.

**An unresolved alternative in the Design or Acceptance criteria is a
defect of the same severity as a wrong instruction.** The shapes, taken
from real output on this stack:

- an either/or aimed at the implementer — *"Use WiX Toolset **or a similar
  MSI generator**"*. `or similar` is not a decision: pick the tool, say
  why, and say what it costs you.
- a hedge where the issue names the thing to build — *"a Homebrew-compatible
  state directory (**e.g.** `var/mach` relative to the prefix)"* followed
  by *"State: `/var/mach`"* two sections later. Two answers is worse than
  none.
- *"TBD"*, *"decide later"*, *"a signed corporate certificate"* when the
  certificate infrastructure is declared out of scope — an AC that depends
  on something nobody agreed to supply.
- any path, env var, flag, binary name or entry point you have not read in
  the code. `MACH_STATE_DIR`, `mach run`, `/lib/systemd/system/machd.service`
  are claims: check them (`file:line`) before they become requirements.
- a reversal of an earlier revision with no rationale (a `User=nobody` →
  `User=mach` flip needs its *why* and its migration story in the body, or
  the implementer cannot tell a decision from a typo).

When you find one, do exactly one of two things:

1. **Decide it.** Write the choice, the reason, and what it traded away
   into `## Decisions`. A stated trade-off can be corrected; a silent one
   cannot.
2. **Take it to the user** in the plan-approval round (see SOUL.md), as a
   concrete question with your own recommendation attached, and write the
   answer back.

Then keep it decided: **the issue body is the record, not the latest
draft.** A revision that quietly reverses a decision from an earlier
revision destroys the thing the developer is relying on. When a decision
changes, change it *visibly* — say in the edit what changed and why.

`## Decisions` is a table, one row per decision the work depends on:

```markdown
## Decisions

| Decision | Choice | Why |
|---|---|---|
| Service user | `mach`, created by the package | `nobody` cannot own a state dir; packages already create users (deb/rpm/apk hooks differ — see Design) |
| Service start | `systemctl enable`, NOT `--now` | the service cannot start before enrollment; `--now` would fail the install |
| MSI toolchain | WiX v4 via the GoReleaser post-build hook | one Linux/Windows toolchain; needs the corporate cert — **user confirmed** |
```

Mark who decided: your own call, or the user's. The developer must be able
to tell *"this is settled"* from *"I may still pick"*.

## Before you route it (`status/ready`)

Run this audit in the same turn as the handoff — a half-specced issue is
expensive to fix later, because the developer has already started:

1. **Re-read the body as the developer will** (`gh issue view <n> --json body`).
2. Grep it for the unresolved-alternative markers: `or similar`, `e.g.`,
   `TBD`, `later`, `Option A`, `<placeholders>`, `$VAR`. Each hit is either
   decided or asked — or it does not ship.
3. Check every path / env var / command in the body against the code, and
   cite `file:line` in the body where it matters. Your Design is only as
   good as your reading of the code it lands in (see "Reading code").
4. Check the ACs do not duplicate another open issue's work. If you are
   re-stating "remove the install logic" in the distribution issue, that is
   a second issue for work one issue already owns — reference it instead
   (`blocked by #N`), and remove the duplicate AC.
5. Verify the user has seen the plan and had their round (SOUL.md). No
   silent self-approval.

**Splitting an umbrella issue closes it.** When an umbrella issue spawns
children, its job is done: close it (or narrow it to what remains) in the
same change. An
umbrella left open in `status/backlog` is a card no queue can ever resolve,
and it reads as live planning work forever.

## Fleshing out an existing issue

"Flesh out #N" means the issue is under-specced and you must finish it.
It does **not** mean re-summarising the previous draft in longer prose.

1. Read the current body (and the issues it references — the earlier one may
   already contain the decision you are looking for).
2. Read the code the change lands in. This is what makes a spec concrete:
   the existing unit file, the existing CLI verbs, the existing state-dir
   resolution. `claude -p '<question>' --max-turns 10` in the worktree, per
   "Reading code".
3. Resolve the decisions (above) — from the code where the code answers,
   from the user where it does not.
4. Rewrite the body to include them, with the `## Decisions` table.
5. Say what you changed and what is still open. "Fleshed out" with no
   mention of an undecided point is a claim the user has to verify by
   re-reading the issue.


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
the wrapper's contract. Do not pass a permission flag — the wrapper already
supplies `--dangerously-skip-permissions`, and a different mode re-enables a
classifier call this gateway cannot serve.

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