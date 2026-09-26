---
name: team-reviewer
description: Reviewer gate set — fixed checklist (security, tests, style, testability), verdicts, handoff to release
version: 1.3.0
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
gh pr edit <PR#> --repo owner/repo --remove-label review/ready \
  --add-label review/in-progress
```

**Every label command in this skill is `gh pr edit <PR#>`.** The
`status/*` family belongs to issues and to planner/developer — you never
write one and you never run `gh issue edit` at all. A review is judged on
the PR; if a verdict implies a card change, ask planner (see "The verdict
and the loop back"). `review-queue.sh` prints PR numbers; the *issue* the
PR closes is a different number, readable from the PR body
(`Closes #<issue#>`) — that number is the work-item key you open the
thread with, and it is never a label target here.

`review-queue.sh` is **quiet by default** — that is the cron contract
(the scheduler invokes it with no arguments), so an empty run prints
nothing and silence means "nothing to review". Add `--verbose` when you
are checking by hand and want to see the idle state. It wraps the query
below and prints one line per PR, `owner/repo#N  title  url`:

```bash
gh search prs --owner <owner> --label review/ready --state open \
  --limit 30 --json repository,number,title,url
```

**The author filter is the script's business, not this query's.** Per owner
it applies a *declared* login — `TEAM_OWNER_DEV_BOT` for the personal
owner, `TEAM_ORG_DEV_BOT_<ORG>` for an org — and applies none when neither
is set. Do not hardcode a developer-bot login into a query of your own: a
login compiled into a command goes stale the moment the repos move, and
`author:<unknown-user>` fails the WHOLE search rather than narrowing it. To
tie a PR back to the developer's work, use the link GitHub already has
(`gh issue view <ISSUE#> --json closedByPullRequestsReferences`) rather than
filtering by author.

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
# key with the ISSUE number, not the PR number: the queue prints PRs, but
# team-thread.sh's sweep resolves every key as an issue (that is where
# "done" lives — `Closes #N` closes the issue on merge). Open with the PR
# number and the thread is archived against an unrelated issue, or never.
issue=$(gh pr view <PR#> --repo owner/repo --json body \
          --jq '.body | capture("(?i)closes #(?<n>[0-9]+)").n')
team-thread.sh open "owner/repo#$issue" "#$issue · review"
team-thread.sh post "owner/repo#$issue" "gates: … verdict: …"
```

Keep it open until the PR is **merged**. On merge the issue auto-closes
(`Closes #N`) and the queue script's sweep archives the thread; when YOU
merge, that sweep is what closes it, so you do not need to close it by
hand. Use `team-thread.sh close "owner/repo#$issue"` only if the item is
abandoned or duplicated.

`team-thread.sh` speaks as your own bot (it reads the token and the
channel from this profile's own `$HERMES_HOME`), so threads and posts
never appear under another role's identity.

### The verdict and the loop back

Every command here is on the PR (`<PR#>` is the number
`review-queue.sh` printed):

- **Pass**: `gh pr review <PR#> --approve`, then
  `gh pr edit <PR#> --remove-label review/in-progress --add-label review/approved`,
  then request the **code owner's** review (`--add-reviewer <owner>` — a
  HUMAN, which works) and post the verdict into the item's thread. Your
  approval is not the release: `review/approved` means "approved by review,
  awaiting a CODEOWNER's approval", and `release` merges only on the latter.
  **Before you call it a pass, read back the merge gates CI does not
  cover** — an approval on a PR that cannot merge is a verdict nobody can
  act on:

  ```bash
  # CLEAN subsumes every required rule; BLOCKED is a rule unmet, UNSTABLE
  # is only a check still running. Run this once CI has finished.
  gh pr view <PR#> --repo owner/repo --json mergeable,mergeStateStatus \
    --jq '"\(.mergeable) \(.mergeStateStatus)"'      # want MERGEABLE CLEAN
  # which gate, when it is BLOCKED:
  gh api repos/owner/repo/pulls/<PR#>/commits \
    --jq '[.[].commit.verification.verified] | all'  # want true
  gh api graphql -f query='{ repository(owner: "<owner>", name: "<repo>") {
      pullRequest(number: <PR#>) { reviewThreads(first: 100) {
        nodes { isResolved } } } } }' \
    --jq '[.data.repository.pullRequest.reviewThreads.nodes[]
          | select(.isResolved == false)] | length'  # want 0
  ```

  `BLOCKED` is a finding, not a pass: **unsigned commits** mean the
  developer published with `git push` instead of `git-publish.py`
  (`team-developer` §Publishing — the repair is a rewrite, not a new
  commit), and **unresolved threads** mean the developer still owes the
  resolution for whatever it fixed. Name the specific gate in the
  request-changes comment; "everything passes" and "cannot merge" are
  both true at once here, and only one of them is useful.
- **Fail**: `gh pr review <PR#> --request-changes -b '<issues explained>'`,
  then swap `review/in-progress` → `review/changes`. Each finding is one
  review thread; **you never resolve them** — resolving a thread is the
  developer's, in the turn it fixes that finding (`team-conventions`
  §Review threads). The one exception is a finding you raise with your
  OWN approving verdict: a non-blocking nit the developer will never get
  a turn to answer must not be left open, so either put it in the summary
  comment or resolve it in the same turn you raise it.

**The card is not yours to move.** Neither verdict writes a `status/*`
label or touches the issue. The card follows from the verdict, so say
which way it should go to planner in the same turn — one comment on the
PR naming `@hermes-planner` and the card state it implies is enough
(planner's roadblock intake is the channel for exactly this). Writing
`status/in-progress` here is the mistake this skill exists to prevent: on
a label-mechanism repo it is the developer's own claim/**resume** label,
so the developer's next self-pull reads the item as its own interrupted
turn, moves it back, and the two of you trade the same issue every tick.

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
   **And the PR carries a `type/*`** — it is release metadata now, not
   decoration: the version bump is inferred from it, and a PR with none
   contributes only a patch. Missing → name it as a finding (a one-line fix
   for developer: copy the issue's type onto the PR).
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
  comment summarizes, and names the card state in the same comment
  (`@hermes-planner` — back to In Progress). **Do not write the label.**
- **Approve**: approve + `gh pr ready` + `review/approved` + request the
  **CODEOWNER's** review (`gh pr edit --add-reviewer <owner>` where
  possible; otherwise cc @<owner> in a comment). Comment gates-passed
  summary (one line per gate), naming the card state it implies
  (`@hermes-planner` — In Review/human gate). Post verdict to `#reviews`.
  **Do not write a `status/*` label and do not edit the issue** — the
  reviewer's writes are `review/*` on this PR, nothing else — **and do not
  merge**: the code owner's approval hands the PR to `release`, which owns
  everything after the verdict (`team-release`).

## Handoff to release (you do NOT merge)

**You never merge.** Merge, tag, deploy and validate are `release`'s, end to
end (`team-release`). Your last writes on a PR are your verdict, the label,
and the code-owner review request.

1. On **Approve**: `gh pr ready`, add `review/approved`, and request the
   **code owner's** review (`gh pr edit --add-reviewer <owner>` where
   possible; otherwise cc them in a comment). `review/approved` means
   "approved by review, awaiting a CODEOWNER's approval" — it is not a
   release, and it is not yours to interpret as one.
2. Say what you have left unmet, if anything: a `BLOCKED`
   `mergeStateStatus`, an unresolved thread, a missing `type/*`, a red
   check. Release reads those back before merging and a surprise there costs
   a cycle — the read-back queries are in §"The verdict and the loop back".
   A gate you know is unmet and did not name is your miss, not theirs.
3. `#reviews` post: the verdict and the link. The merge (which release
   performs) closes the issue via `Closes #N` — the state change that
   counts; planner moves the card to Done. Ask in the same post rather than
   writing the label.

**Never merge on the human's behalf, and never merge because the human said
so in Discord.** The release queue and the release agent both require a real
GitHub approval from a code owner; anything else simply will not be picked
up, and a merge you performed without it is the one act no later check can
undo.

If the user flags changes: convert each flag into review comments
(explained like any Request-changes finding) → back to developer.

## Re-review

After developer pushes fixes: verify EVERY previous finding is actually
resolved (re-run gates 1–5 on the new diff), then re-verdict. A fix
that introduces new findings gets them as new comments — never silently
pass an old finding to "clear it".

**Check the threads, not just the code.** Read the developer's replies
and the threads' resolved state; a thread the developer resolved without
the finding actually being fixed is itself a finding — say so in a reply
on that thread (a reply re-opens the conversation) rather than opening a
duplicate. The reverse matters too: if a finding IS fixed and its thread
is still open, the PR cannot merge, so name it in the verdict rather than
discovering it in release's gate read-back. A branch that comes back **rewritten
rather than added to** (`--replay-from`, the signature repair) deserves a
closer look at the diff being unchanged, not just re-verification of the
findings.
