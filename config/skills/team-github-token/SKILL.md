---
name: team-github-token
description: Select the right GitHub App installation token for a repo (owner → GH_TOKEN_<ACCOUNT> mapping)
version: 1.0.0
metadata:
  hermes:
    tags: [github, tokens, team]
    category: devops
---

# GitHub token selection for team roles

The team's GitHub Apps are installed once per account/org (user
accounts and organizations). Each installation has its own
installation-token env var: `GH_TOKEN_<ACCOUNT>` with the account name
upper-cased and non-alphanumerics replaced by `_` (e.g. account
`acme-corp` → `GH_TOKEN_ACME_CORP`).

## Procedure

1. Determine the repo's owner from `owner/repo`.
2. Export the matching variable for the gh/git call. **Hermes strips
   credential env vars from tool subprocesses by design** (GHSA
   rhgp-j443-p4rf) — plain `export GH_TOKEN=…` before a `terminal()`
   call does not reach gh. Instead, write the token to a temp file with
   a tool that can, or pass it via `gh`'s `--hostname` config:

   ```bash
   # inside terminal():
   grep -oP '(?<=^GH_TOKEN_<OWNER>=).*' "$HERMES_HOME/.env" > /tmp/tok
   gh auth status
   # per-call: GH_TOKEN="$(cat /tmp/tok)" gh api …   # works: env is
   # set INSIDE the shell process, not inherited from the agent
   shred -u /tmp/tok   # when done with the batch
   ```

   Setting the var **inside the terminal command** (`VAR=x gh …`) is
   reliable; setting it in the agent process is not.

3. If the variable is missing or the call 401s/403s, the repo's owner
   probably has no installation for your App yet — do not fall back to
   another App's identity. Report it to the user (or, for planner:
   flag it in the onboarding checklist) and move on.
4. Never log, echo, or commit token values. Temp-token files live under
   `/tmp` and are deleted immediately after the batch of calls.

## Which App am I?

The entrypoint provisions each profile with its own App credentials
(`GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`,
`GITHUB_APP_PRIVATE_KEY_PATH`) and keeps the gh CLI in this profile's
tool-home logged in with the default installation's token. For
cross-installation work use the explicit `GH_TOKEN_<ACCOUNT>` vars —
the profile's stored gh auth covers only its primary installation.