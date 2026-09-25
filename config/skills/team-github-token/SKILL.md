---
name: team-github-token
description: Which GitHub App identity a gh/git command runs as (owner routing), and what a 403 on an org repo actually means
version: 2.0.0
metadata:
  hermes:
    tags: [github, tokens, team]
    category: devops
---

# GitHub token selection for team roles

**You do not pick tokens by hand for ordinary work.** There is no
`GH_TOKEN_<ACCOUNT>` variable to export and no token file to read: the
stack routes automatically.

`/usr/local/bin/gh` is a shim (the real CLI is `gh-real`). It runs your
command under the ORG App installation token when it can resolve the
command's target owner to an org you hold credentials for, and under the
profile's personal App token otherwise. git routes the same way through
`git-credential-hermes.sh`. Both read descriptors in your tool-home
(`$HOME/org-creds/<orgslug>.env` + `.pem`) — a file layout, because
Hermes strips credential env vars from tool subprocesses
(GHSA-rhgp-j443-p4rf).

## The shim can see the owner when the command carries it

1. `-R`/`--repo owner/repo` — every spelling gh accepts (`-R x/y`,
   `-R=x/y`, `-Rx/y`, `--repo x/y`);
2. for `gh api`, the ENDPOINT PATH: `repos/<owner>/…` or `orgs/<owner>`.
   `gh api` takes no `-R` (gh rejects it), so the path is the only owner
   signal a REST call carries;
3. the cwd's git origin — which is why an org worktree usually "just
   works".

Put the owner in the path (or pass `-R` where gh supports it) and you
never think about tokens.

## When it cannot see the owner, force the identity

`gh api graphql`, `gh search` (its `--owner` is a filter, not routing),
`gh api` with no owner in the path, and any command run from a scratch
directory. Then name the token yourself:

```bash
GH_TOKEN="$(gh-org-token <orgslug>)" gh api graphql -f query='…'
```

- Setting the var **inside** the command is what works. Hermes strips
  credential env vars from tool subprocesses, so an `export` in one
  `terminal()` call does not reach the next one.
- `gh-org-token <orgslug>` prints a cached (~45 min) installation token,
  minting a fresh one from the descriptor's PEM when needed. Never log or
  echo its output — pipe it straight into the call.

## A 403 `Resource not accessible by integration` is a TOKEN question first

The personal App has no installation on an org, so on an org repo its
**writes** 403 while its reads of a *public* repo still succeed — which
is exactly how a correctly-granted installation gets reported as a
missing permission. Do not report a missing App permission until you have
walked this order:

1. **Did the call carry owner context at all?** A scratch-dir `gh api
   repos/<org>/<repo>/…` did not, before the path was read. Re-run with
   `GH_TOKEN="$(gh-org-token <orgslug>)"` and see if the 403 survives.
2. **Probe with a PRIVATE org repo read.** 200 = the org token is in
   play; 404 = you are on the personal token. A public repo proves
   nothing (reads pass under both).
3. **Read what is actually GRANTED**, with a user token:
   `gh api /orgs/<org>/installations --jq '.installations[] | {app_slug,permissions}'`.
   The App's own token cannot read that endpoint — it returns 404
   whatever is granted, so it can tell you nothing.

Only step 3 showing the permission absent makes it an owner-side fix.

## Which App am I?

The entrypoint provisions each profile with its own App credentials
(`GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`,
`GITHUB_APP_PRIVATE_KEY_PATH`) and keeps the gh CLI in this profile's
tool-home logged in with the personal App's installation token. The org
descriptors are a SECOND set alongside it — never fall back to another
App's identity to make a call work: report the gap instead.
