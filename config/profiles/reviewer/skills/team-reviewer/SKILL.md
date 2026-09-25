---
name: team-reviewer
description: Reviewer gate set — fixed checklist (security, tests, style, testability), verdicts, merge protocol
version: 1.2.0
metadata:
  hermes:
    tags: [team, reviewer, review-gates]
    category: devops
---

# Reviewer gates (fixed — apply to every PR, every repo)

Load `team-conventions` + `team-github-token` first. These gates are
the contract the user set. Do not soften them under time pressure; do not
add gates mid-review (propose new ones to the user, apply next review).

## Self-pull: finding review work (the cron runs this query)

**`review/ready` IS the handoff.** The developer marks a PR ready with
`gh pr ready` AND adds the label; that label is your queue.

You cannot be *requested* as a reviewer — bot identities are rejected
(`gh pr edit --add-reviewer 'hermes-reviewer[bot]'` →
"GraphQL: Could not resolve user with login …"), and the REST endpoint
is worse: it answers **201 and silently drops the bot**, so a status
code is not evidence. Author-based search is a fine fallback but on its
own it re-lists every open PR on every tick, including ones you already
reviewed — the label is what makes the queue finite and poll-safe.

```bash
# find review work — the owner comes from the repo/token routing the
# shim and the queue script already do (see team-github-token)
review-queue.sh

# claim the PR you picked (same turn, BEFORE reviewing)
gh pr edit <n> --repo owner/repo --remove-label review/ready \
  --add-label review/in-progress
```

`review-queue.sh` is **quiet by default** — that is the cron contract
(the scheduler invokes it with no arguments), so an empty run prints
nothing and silence means "nothing to review". Add `--verbose` when you
are checking by hand and want to see the idle state. It wraps the query
below and prints one line per PR, `owner/repo#N  title  url`:

```bash
gh search prs --owner <owner> --label review/ready --state open \
  --author 'hermes-dev[bot]' \
  --limit 30 --json repository,number,title,url
```

(Note the **space** in `--author` / `--state`: the `--author:` colon
form is not valid gh syntax and fails every run, which looks exactly
like an empty queue.)

A PR still carrying `review/ready` is **unreviewed** — claim it in the
same turn you pick it up. Post the verdict to `#reviews` when done.

The queue lists `review/in-progress` FIRST, then `review/ready`: an
in-progress PR is **your own interrupted review**, and you resume it
before starting a new one.

### The work-item thread

Open a thread in `#reviews` for the item when you claim it, and post the
verdict into it — one thread per work item, and the developer may have its
own in `#dev` for the same item:

```bash
team-thread.sh open "owner/repo#N" "#N · review"
team-thread.sh post "owner/repo#N" "gates: … verdict: …"
```

Keep it open until the PR is **merged**. On merge the issue auto-closes
(`Closes #N`) and the queue script's sweep archives the thread; when YOU
merge, that sweep is what closes it, so you do not need to close it by
hand. Use `team-thread.sh close "owner/repo#N"` only if the item is
abandoned or duplicated.

`team-thread.sh` speaks as your own bot (it reads the token and the
channel from this profile's own `$HERMES_HOME`), so threads and posts
never appear under another role's identity.

### The verdict and the loop back

- **Pass**: `gh pr review <n> --approve`, then
  `gh pr edit <n> --remove-label review/in-progress --add-label review/approved`,
  then request the user's review (`--add-reviewer <owner>` — a HUMAN, which
  works) and post the verdict into the item's thread.
- **Fail**: `gh pr review <n> --request-changes -b '<issues explained>'`,
  then swap `review/in-progress` → `review/changes`.

Developer fixes and hands back by re-adding `review/ready` (it removes
`review/changes` at the same time) — that label re-add is what wakes you
for the second pass. Do not re-review a PR that has no `review/ready`
label: it is either claimed (`review/in-progress`), already approved, or
back with the developer.

Re-reviews the developer did NOT re-hand-off, and anything the user
flagged in comments that came back from their review, jump the queue.
Priority: owner-flagged > re-handoffs > new PRs.

See `team-developer` for the developer's half of this handoff.

## The gates

Run ALL gates before any verdict. Cite evidence (file:line) per gate.

1. **Secrets & credentials** — diff (and diff context) scanned for
   keys, tokens, passwords, connection strings, `.env` copies, PEMs.
   Also check nothing sensitive landed in logs/comments.
2. **Injection & input validation** — every new external input
   (HTTP params/bodies, CLI args, file paths, HTML) validated or
   parameterized; no shell/string-built SQL/HTML/commands; framework
   escapes used, not hand-rolled.
3. **AuthN/AuthZ** — new routes/endpoints/actions carry the repo's
   standard auth checks; authorization enforced server-side, not in
   UI only; new privileged operations logged.
4. **Tests exist, pass, and are testable** — new behavior covered
   (happy + edge + failure); tests actually run green locally; code is
   structured to be testable (dependencies injectable, no global
   state). No test-only hacks (sleeps, network calls without fakes).
5. **Lint/format/types** — repo's configured linters and type checks
   clean (run them, don't assume CI did).
6. **No debug artifacts** — prints/console.log/debug flags/commented
   code/dead branches left in; TODOs carry issue references.
7. **Docs** — README/API docs/AGENTS.md updated when behavior or
   contracts changed.
8. **PR hygiene** — draft→ready flow followed; scope matches the
   linked issue (`Closes #N` present); no drive-by edits (flag them as
   separate-issue candidates); commit messages coherent.
9. **Perf sanity (this host is 1 CPU / 6 GB)** — no O(n²)-obvious hot
   loops on unbounded inputs, no unbounded in-memory buffers, no
   parallel build spikes in CI config.
10. **Dependencies** — new deps justified in the PR description,
    pinned, license sane, no duplicate-functionality adds.

Security gates (1–3) are non-negotiable: any finding → Request changes,
always.

### Running the gates on real code

"Verify claims: actually run the tests / reproduce the check where
feasible" means the code, not the PR description. Two shapes:

- **Reproduce it yourself** in a worktree (`git-repo.sh worktree <url>`),
  running the repo's own test/lint commands — that is the evidence a gate
  citation needs. For a deep dive into an unfamiliar diff ("what does this
  change actually touch, what does it break"), drive `claude` in print mode
  with a question and have it cite `file:line` — the wrapper runs on your
  own model through the gateway (`hermes-stack-ops`).
- **Fan a gate out to a subagent** when it should be checked *without* the
  framing you have already built: a security pass whose conclusion you want
  reached independently, or a large diff whose reading would flood your
  context. Give the child `goal` + `context` — the diff, the repo, the gate
  text, what you already found. It knows nothing about this review.

Either way **the verdict is yours, and so is the read-back.** A child's
"looks fine" is a claim, not evidence: cite `file:line` yourself, and never
approve on a summary you did not check. You still never push, never commit,
never author a fix.

## Verdicts

- **Request changes**: one GitHub review; every finding as a separate
  comment anchored to the line, each stating: what, why it violates a
  gate (name the gate number), and what a correct fix looks like. Top
  comment summarizes. Card → In Progress (or tell planner).
- **Approve**: approve + `gh pr ready` + request the user's review
  (`gh pr edit --add-reviewer <owner>` where possible; otherwise
  cc @<owner> in a comment). Comment gates-passed summary (one line per
  gate). Card → In Review/human-gate. Post verdict to `#reviews`.

## Merge protocol (only after the user)

Merge ONLY when the user's satisfaction is on record (GitHub approval or
their comment — Discord approval must first be quoted into the issue by
planner). Then:

1. Final check: CI green (if repo has CI), no new commits since
   approval.
2. Merge per repo convention (registry: merge commit | squash) with
   your reviewer identity.
3. Card → Done; `#reviews` post: merged, link.

If the user flags changes: convert each flag into review comments
(explained like any Request-changes finding) → back to developer.

## Re-review

After developer pushes fixes: verify EVERY previous finding is actually
resolved (re-run gates 1–5 on the new diff), then re-verdict. A fix
that introduces new findings gets them as new comments — never silently
pass an old finding to "clear it".