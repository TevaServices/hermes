#!/usr/bin/env python3
"""Publish a worktree branch with GitHub-SIGNED commits (replaces `git push`).

WHY THIS EXISTS

A repository can require signed commits (`required_signatures` in a
ruleset, or "Require signed commits" in branch protection). GitHub's docs
are explicit that this is not a formality for a PR:

    When GitHub evaluates whether a pull request can be merged, it creates
    a test merge commit whose parents are the latest commit on the base
    branch and the pull request's head commit. GitHub checks the commits
    introduced by this test merge, including commits from the head branch.
    As a result, unsigned commits on the head branch can block a squash
    merge, even though GitHub would sign the final squash commit.

So EVERY commit on the branch has to carry a verified signature, or the
merge button stays dead no matter what CI says.

A GitHub App cannot sign one. Bots have no account settings, so no
GPG/SSH key can be registered against `hermes-dev[bot]`, and a commit made
with `git commit` and pushed with `git push` is unverifiable for the App
that pushed it — forever. The ONLY path that produces a signature for an
App is GitHub signing it server-side, which it does when the commit object
is created through the REST API while authenticated as the App:

    Signature verification for bots will only work if the request is
    verified and authenticated as the GitHub App or bot and contains no
    custom author information, custom committer information, and no
    custom signature information, such as Commits API.

That last clause is why this script never sends `author`, `committer` or a
signature: omitting them is what earns the `verified: true`.

Observed 2026-09-26 on a PR the team had open: four commits, all
`verification.verified=false, reason=unsigned`, the PR approved by both the
reviewer and the user, `mergeStateStatus: BLOCKED` — the developer could
not have fixed it by pushing harder, and nothing in the stack said so.
This script is the capability that was missing.

WHAT IT DOES

It replays the local commits that are not yet published as API-created
commits, one at a time, preserving each one's message and diff:

    blobs  -> trees -> commits -> ref update

* The commit identity is the App behind the token the `gh` shim selects
  for this repo's owner (personal App, or the org's App for an org repo),
  which is also what makes the signature valid.
* Each tree is built from the LOCAL commit's own diff against its parent,
  so file modes (100755 scripts), symlinks and deletes are preserved
  exactly. Renames are flattened to add+delete, which is what the API
  models.
* The `Signed-off-by:` trailer of every commit is re-pointed at the App
  identity GitHub will actually stamp (the DCO hook wrote the identity
  from the worktree's git config, which can be a DIFFERENT bot — a
  personal-App worktree config in an org repo is exactly the mismatch seen
  on mach#27). The local trailer is never dropped, only re-pointed: this
  script does not invent sign-off policy.
* NOTHING IS PUBLISHED UNTIL IT IS PROVEN: the ref update is the commit
  point. The App's own identity is read back from the first created commit
  and, if it disagrees with the local guess, the chain is re-created with
  the corrected trailer BEFORE any ref moves. The final commit is then
  read back and must report `verification.verified == true`, or this exits
  non-zero and says the merge will be blocked.

After a successful publish the local branch is re-pointed at the published
tip (`git reset --soft`, which leaves the index and worktree alone because
the trees are identical). That keeps local == remote so the next publish
fast-forwards instead of re-replaying, and it is the docs' own remedy for
an existing unsigned branch: "rewrite and sign the unsigned commits on the
head branch".

USAGE

    git-publish.py [-C DIR] [-b BRANCH] [--base REF] [--force] [--dry-run]

Run it inside the worktree, on the branch checked out. The first run on a
branch creates the remote branch, so `gh pr create` works straight after.

Exit codes: 0 published (or nothing to publish), 1 refused/failed.
A refusal never changes anything — see `--force` for the one case that
needs an explicit opt-in.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import shutil
import subprocess
import sys

# The Blob API rejects anything larger; refuse before uploading rather
# than half-publishing a branch.
BLOB_LIMIT = 40 * 1024 * 1024

# `<id>+<slug>[bot]@users.noreply.github.com` — the form GitHub stamps on
# commits it signs for an App, verified against a known bot commit.
BOT_EMAIL = "%d+%s@users.noreply.github.com"


class Refused(Exception):
    """A condition this script will not publish through. Changes nothing."""


def run(cmd, cwd=None, input_bytes=None):
    """Run a command, raising Refused (with its stderr) on failure."""
    proc = subprocess.run(
        cmd, cwd=cwd, input=input_bytes,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if proc.returncode != 0:
        detail = proc.stderr.decode("utf-8", "replace").strip()
        raise Refused(f"{cmd[0]} failed ({proc.returncode}): {detail}")
    return proc.stdout


def git(args, cwd, input_bytes=None):
    return run(["git"] + list(args), cwd=cwd, input_bytes=input_bytes)


def git_text(args, cwd):
    return git(args, cwd).decode("utf-8", "replace").strip()


def git_ok(args, cwd):
    """git call whose failure is an expected answer (e.g. a detached HEAD)."""
    proc = subprocess.run(
        ["git"] + list(args), cwd=cwd,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if proc.returncode != 0:
        return None
    return proc.stdout.decode("utf-8", "replace").strip()


def gh(args, payload=None):
    """Call the gh CLI (the stack's shim, so tokens route by owner).

    The shim reads the owner out of a `repos/<owner>/…` endpoint path, so
    every call here is built that way and never needs GH_TOKEN.
    """
    cmd = [GH, "api"] + list(args)
    data = None
    if payload is not None:
        cmd += ["--input", "-"]
        data = json.dumps(payload).encode("utf-8")
    out = run(cmd, input_bytes=data)
    return json.loads(out.decode("utf-8")) if out.strip() else {}


def gh_ok(args):
    """gh call whose failure is an expected answer (e.g. a missing ref)."""
    proc = subprocess.run(
        [GH, "api"] + list(args),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if proc.returncode != 0:
        return None
    out = proc.stdout.decode("utf-8", "replace").strip()
    return json.loads(out) if out else {}


def slugify(text):
    """GitHub owner -> descriptor filename, exactly as the gh shim does."""
    return re.sub(r"[^a-z0-9]", "", text.lower())


def creds_dir():
    override = os.environ.get("ORG_CREDS_DIR", "")
    if override:
        return override
    home = os.environ.get("HOME", "")
    return os.path.join(home, "org-creds") if home else ""


def descriptor_for(owner):
    """The org-App descriptor for this owner, or None for a personal repo.

    Same lookup as the gh shim and gh-org-token: slugified filename match,
    so an owner's case and separators do not matter.
    """
    directory = creds_dir()
    if not directory or not os.path.isdir(directory):
        return None
    want = slugify(owner)
    if not want:
        return None
    for name in sorted(os.listdir(directory)):
        if name.endswith(".env") and slugify(name[: -len(".env")]) == want:
            return os.path.join(directory, name)
    return None


def descriptor_value(path, key):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                if line.startswith(key + "="):
                    return line.split("=", 1)[1].strip()
    except OSError:
        return ""
    return ""


def candidate_login(worktree, owner):
    """Who we BELIEVE the token's App is, before asking GitHub.

    For an org repo the descriptor is authoritative: the entrypoint wrote
    it from `PROFILE_<NAME>_GH_GIT_NAME_<ORG>` at boot, and it exists
    precisely because a worktree's git config cannot be trusted to match
    the token the shim will pick. Falls back to the worktree's git
    identity (the personal App) for a personal repo.
    """
    desc = descriptor_for(owner)
    if desc:
        name = descriptor_value(desc, "GH_GIT_NAME")
        if name:
            return name, desc
        return "", desc
    return git_text(["config", "user.name"], worktree), None


def normalize_login(name):
    """`app/<slug>` (REST's spelling of an App author) -> `<slug>[bot]`."""
    name = name.strip()
    if name.startswith("app/"):
        name = name[len("app/"):]
    if name and not name.endswith("[bot]"):
        name += "[bot]"
    return name


def cache_path(owner):
    home = os.environ.get("HOME", "")
    if not home:
        return ""
    return os.path.join(home, ".cache", "git-publish",
                        f"identity-{slugify(owner)}.json")


def resolve_identity(worktree, owner):
    """(login, email) that GitHub will stamp on API commits from this App.

    A cached answer wins: it was read back from a real commit, which is
    better evidence than any local file. Otherwise the candidate is
    resolved against GitHub (`/users/<login>` -> id) so the sign-off
    trailer can be built exactly. The read-back after the first created
    commit is what makes a wrong guess harmless.
    """
    path = cache_path(owner)
    if path and os.path.isfile(path):
        try:
            with open(path, "r", encoding="utf-8") as fh:
                cached = json.load(fh)
            if cached.get("login") and cached.get("email"):
                return cached["login"], cached["email"], "cache"
        except (OSError, ValueError):
            pass

    raw, source = candidate_login(worktree, owner)
    login = normalize_login(raw) if raw else ""
    if not login:
        raise Refused(
            f"cannot tell which App publishes '{owner}' — no org descriptor "
            f"in {creds_dir()} and no git identity in the worktree"
        )
    user = gh_ok([f"users/{login.replace('[', '%5B').replace(']', '%5D')}"])
    if not user or "id" not in user:
        where = source or "the worktree git config"
        raise Refused(
            f"GitHub has no user '{login}' (identity came from {where}) — the "
            f"declared bot identity is wrong, and publishing would stamp "
            f"commits with an identity nobody can verify"
        )
    if user.get("type") != "Bot":
        raise Refused(
            f"'{login}' is a {user.get('type')} account, not a bot — refusing "
            f"to publish as it (only an App's bot identity can be verified)"
        )
    return user["login"], BOT_EMAIL % (user["id"], user["login"]), source or "worktree"


def remember_identity(owner, login, email):
    path = cache_path(owner)
    if not path:
        return
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump({"login": login, "email": email}, fh)
    except OSError:
        pass  # a cache we cannot write is not a reason to fail a publish


def repo_slug(worktree):
    """owner/repo from the worktree's origin remote.

    The RAW config value, not `git remote get-url`: git applies any
    `url.<base>.insteadOf` rewrite to the latter, so a mirror or a local
    rewrite would hide the owner and this would refuse a repo it should
    have published to.
    """
    url = git_ok(["config", "--get", "remote.origin.url"], worktree) or ""
    if not url:
        url = git_text(["remote", "get-url", "origin"], worktree)
    for pattern in (
        r"^https?://[^/]+/(?P<slug>[^/]+/[^/]+?)(?:\.git)?$",
        r"^ssh://git@[^/]+/(?P<slug>[^/]+/[^/]+?)(?:\.git)?$",
        r"^git@[^:]+:(?P<slug>[^/]+/[^/]+?)(?:\.git)?$",
    ):
        match = re.match(pattern, url)
        if match:
            return match.group("slug")
    raise Refused(f"cannot read owner/repo from origin remote: {url!r}")


def repoint_trailer(message, login, email):
    """Re-point every Signed-off-by at the identity GitHub will stamp.

    The local commits were signed off by the DCO hook as whatever the
    worktree's git config said; GitHub stamps API commits as the App
    behind the token. A trailer that disagrees with the author is the one
    thing that makes the target repo's DCO job fail on a commit that IS
    signed, so it is corrected here — and only ever corrected, never
    added: a repo that does not ask for a sign-off does not get one.
    """
    lines = message.split("\n")
    fixed = [f"Signed-off-by: {login} <{email}>"
             if line.startswith("Signed-off-by: ") else line
             for line in lines]
    return "\n".join(fixed), fixed != lines


def raw_changes(worktree, parent, commit):
    """[(status, path, mode, blob_sha)] for one commit vs its parent.

    `--no-renames` keeps every entry a single path (a rename arrives as
    delete+add, which is what the API models). `--raw` carries the mode
    and blob sha of the NEW side, so an unchanged-mode edit and an
    executable-bit change are both described exactly.
    """
    out = git(["diff-tree", "-r", "-z", "--no-commit-id", "--raw",
               "--no-renames", parent, commit], worktree)
    fields = out.split(b"\x00")
    changes = []
    idx = 0
    while idx + 1 < len(fields):
        header = fields[idx].decode("utf-8", "replace")
        path = fields[idx + 1].decode("utf-8", "replace")
        idx += 2
        if not header.startswith(":"):
            continue
        _old_mode, new_mode, _old_sha, new_sha, status = header[1:].split(" ")[:5]
        changes.append((status[0], path, new_mode, new_sha))
    return changes


def build_entries(worktree, slug, parent, commit):
    """Tree entries for one replayed commit, uploading new blobs."""
    entries = []
    for status, path, mode, sha in raw_changes(worktree, parent, commit):
        if status == "D" or mode == "000000":
            entries.append({"path": path, "mode": "100644",
                            "type": "blob", "sha": None})
            continue
        if mode == "160000":  # submodule: a commit pointer, not a blob
            entries.append({"path": path, "mode": mode, "type": "commit",
                            "sha": sha})
            continue
        blob = git(["cat-file", "blob", sha], worktree)
        if len(blob) > BLOB_LIMIT:
            raise Refused(
                f"{path} is {len(blob)} bytes, over the {BLOB_LIMIT}-byte Blob "
                f"API limit — commit it another way or trim it"
            )
        created = gh([f"repos/{slug}/git/blobs", "--method", "POST"], {
            "content": base64.b64encode(blob).decode("ascii"),
            "encoding": "base64",
        })
        if len(sha) == 40 and created.get("sha") and created["sha"] != sha:
            raise Refused(
                f"blob sha mismatch for {path}: git says {sha}, GitHub says "
                f"{created.get('sha')} — refusing to publish a tree that "
                f"disagrees with the worktree"
            )
        entries.append({"path": path, "mode": mode, "type": "blob",
                        "sha": created["sha"]})
    return entries


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Publish a branch as GitHub-signed commits (replaces git push).",
    )
    parser.add_argument("-C", dest="worktree", default=".",
                        help="worktree to publish from (default: cwd)")
    parser.add_argument("-b", "--branch", default="",
                        help="branch to publish (default: the checked-out one)")
    parser.add_argument("--base", default="",
                        help="base branch for a NEW remote branch "
                             "(default: the repo's default branch)")
    parser.add_argument("--replay-from", dest="replay_from", default="",
                        help="ref to replay the branch's commits from, instead of "
                             "appending on top of the remote branch (e.g. "
                             "origin/main). This is the repair for a branch whose "
                             "existing commits are unsigned.")
    parser.add_argument("--force", action="store_true",
                        help="allow publishing over a remote branch that is not "
                             "an ancestor of what you are publishing (a rewrite)")
    parser.add_argument("--dry-run", action="store_true",
                        help="resolve and report, change nothing")
    args = parser.parse_args(argv)

    global GH
    GH = shutil.which("gh")
    if not GH:
        raise Refused("gh not found on PATH")

    worktree = os.path.abspath(args.worktree)
    if git_text(["rev-parse", "--is-inside-work-tree"], worktree) != "true":
        raise Refused(f"not a git worktree: {worktree}")

    head = git_text(["rev-parse", "HEAD"], worktree)
    if len(head) != 40:
        raise Refused(
            f"HEAD is {len(head)} hex digits — this repo does not use SHA-1 "
            f"object names, so local blob shas cannot be matched to GitHub's"
        )

    branch = args.branch or git_ok(["symbolic-ref", "--short", "-q", "HEAD"], worktree)
    if not branch:
        raise Refused("detached HEAD — check out the branch you want to publish")

    slug = repo_slug(worktree)
    owner = slug.split("/")[0]
    repo = gh([f"repos/{slug}"])
    default_branch = repo.get("default_branch", "main")
    if branch == default_branch:
        raise Refused(
            f"'{branch}' is this repo's default branch — publish a topic branch "
            f"and open a PR; nothing here may push {slug}@{default_branch}"
        )

    # Where the remote branch is now (the replay base when it exists).
    remote_ref = gh_ok([f"repos/{slug}/git/ref/heads/{branch}"])
    remote_head = (remote_ref or {}).get("object", {}).get("sha", "")

    if args.replay_from:
        # Repair path: replay the branch's own commits from a ref, instead
        # of appending on top of what is already there.
        base_ref = args.replay_from
        tracking = base_ref[len("origin/"):] if base_ref.startswith("origin/") else ""
        if tracking:
            git(["fetch", "origin",
                 f"+refs/heads/{tracking}:refs/remotes/origin/{tracking}"], worktree)
        base_sha = git_text(["rev-parse", f"{base_ref}^{{commit}}"], worktree)
    elif remote_head:
        base_ref = branch
        git(["fetch", "origin", f"+refs/heads/{branch}:refs/remotes/origin/{branch}"],
            worktree)
        base_sha = remote_head
    else:
        base_ref = args.base or default_branch
        git(["fetch", "origin",
             f"+refs/heads/{base_ref}:refs/remotes/origin/{base_ref}"], worktree)
        base_sha = git_text(["rev-parse", f"origin/{base_ref}^{{commit}}"], worktree)

    # The base must exist locally before anything is replayed onto it.
    git(["cat-file", "-e", f"{base_sha}^{{commit}}"], worktree)

    # A rewrite is the one thing that needs an explicit opt-in, and it is
    # refused BEFORE anything is created: uploading blobs and commit
    # objects for a publish that never happens is its own kind of mess.
    rewriting = bool(remote_head) and base_sha != remote_head
    if rewriting and not args.force:
        raise Refused(
            f"{slug}@{branch} is at {remote_head[:10]}, and this publishes "
            f"on top of {base_ref} ({base_sha[:10]}) instead — that rewrites "
            f"published history. Re-run with --force if that is intended."
        )

    listed = git_text(["rev-list", "--reverse", f"{base_sha}..{branch}"], worktree)
    commits = [c for c in listed.split("\n") if c]
    login, email, identity_source = resolve_identity(worktree, owner)

    if not commits:
        print(f"{slug}: nothing to publish — {branch} has no commits on top of "
              f"{base_ref} ({base_sha[:10]})")
        print(f"identity: {login} <{email}> (from {identity_source})")
        return 0

    print(f"publishing {len(commits)} commit(s) to {slug}@{branch} "
          f"as {login} <{email}> (identity from {identity_source})")

    parents = {}
    for commit in commits:
        fields = git_text(["rev-list", "--parents", "-n1", commit], worktree).split()
        if len(fields) > 2:
            raise Refused(
                f"{commit[:10]} is a merge commit — a linear replay cannot "
                f"represent it, and its second parent would land unverified. "
                f"Rebase onto {base_ref} so the branch is one line of commits."
            )
        parents[commit] = fields[1]

    if parents[commits[0]] != base_sha:
        raise Refused(
            f"{commits[0][:10]} is based on {parents[commits[0]][:10]}, not on "
            f"{base_ref} ({base_sha[:10]}) — rebase onto {base_ref} so what is "
            f"published is what was reviewed"
        )

    if args.dry_run:
        for commit in commits:
            message, _ = repoint_trailer(
                git_text(["log", "-1", "--format=%B", commit], worktree), login, email)
            subject = message.split("\n")[0]
            print(f"  would replay {commit[:10]} {subject}")
        return 0

    base_tree = git_text(["rev-parse", f"{base_sha}^{{tree}}"], worktree)

    # Trees first, once: they carry no identity, so the identity correction
    # below must not pay for them twice.
    trees = []
    running = base_tree
    for commit in commits:
        entries = build_entries(worktree, slug, parents[commit], commit)
        if entries:
            running = gh([f"repos/{slug}/git/trees", "--method", "POST"],
                         {"base_tree": running, "tree": entries})["sha"]
        trees.append(running)

    def chain(identity_login, identity_email):
        """Create the commit objects; [(sha, response)] in order."""
        made = []
        parent = base_sha
        for commit, tree in zip(commits, trees):
            message, repointed = repoint_trailer(
                git_text(["log", "-1", "--format=%B", commit], worktree),
                identity_login, identity_email)
            if repointed:
                print(f"  {commit[:10]}: re-pointed Signed-off-by -> "
                      f"{identity_login} <{identity_email}>")
            created = gh([f"repos/{slug}/git/commits", "--method", "POST"],
                         {"message": message, "tree": tree, "parents": [parent]})
            made.append((created["sha"], created))
            parent = created["sha"]
        return made

    made = chain(login, email)

    # The App GitHub actually stamped. A disagreement means the local guess
    # (a stale worktree identity, a descriptor that drifted) was wrong, and
    # the trailer must follow the truth — the trees are already correct, so
    # only the commit objects are re-created.
    stamp = made[0][1].get("author", {})
    if stamp and (stamp.get("name") != login or stamp.get("email") != email):
        actual_login, actual_email = stamp.get("name", ""), stamp.get("email", "")
        if not actual_login or not actual_email:
            raise Refused(f"GitHub stamped an unreadable author: {stamp!r}")
        print(f"note: GitHub stamps these commits as {actual_login} "
              f"<{actual_email}>, not {login} <{email}> "
              f"(identity came from {identity_source}) — re-pointing the "
              f"trailers and remembering it")
        made = chain(actual_login, actual_email)
        login, email = actual_login, actual_email
        remember_identity(owner, login, email)
        stamp = made[0][1].get("author", {})
        if stamp.get("name") != login:
            raise Refused(
                f"stamp still disagrees after re-creating the chain "
                f"({stamp.get('name')!r} != {login!r}) — refusing to publish"
            )

    tip = made[-1][0]

    # Prove the signature before the ref moves: an unverified commit would
    # block the merge exactly as the unsigned ones did.
    probe = gh_ok([f"repos/{slug}/commits/{made[0][0]}"])
    if probe is not None:
        if not probe.get("commit", {}).get("verification", {}).get("verified"):
            raise Refused(
                "GitHub did not sign the commit it just created "
                f"({probe.get('commit', {}).get('verification')!r}) — this App "
                "cannot produce verified commits, so the branch would still "
                "be unmergeable. Nothing was published."
            )
        print(f"  {made[0][0][:10]}: verified")

    if remote_head:
        gh([f"repos/{slug}/git/refs/heads/{branch}", "--method", "PATCH"],
           {"sha": tip, "force": rewriting})
        print(f"updated {branch}: {remote_head[:10]} -> {tip[:10]}"
              + (" (forced)" if rewriting else ""))
    else:
        gh([f"repos/{slug}/git/refs", "--method", "POST"],
           {"ref": f"refs/heads/{branch}", "sha": tip})
        print(f"created {branch} at {tip[:10]} (from {base_ref})")

    # Read the published commit back — a status code is not evidence.
    published = gh([f"repos/{slug}/commits/{tip}"])
    verification = published.get("commit", {}).get("verification", {})
    if not verification.get("verified"):
        print(f"WARNING: {tip[:10]} does not report verified "
              f"({verification.get('reason')}) — the merge will be blocked; "
              f"do not hand this off", file=sys.stderr)
        return 1
    print(f"{slug}@{branch} -> {tip[:10]} ({len(commits)} commit(s), "
          f"verified {verification.get('reason')}, author {login})")

    # Local == remote keeps the next publish a fast-forward. The published
    # commits were created server-side, so they have to be fetched before
    # the branch can point at them. `--soft` leaves the index and worktree
    # untouched, which is safe because the published tree IS the local tree.
    try:
        git(["fetch", "origin",
             f"+refs/heads/{branch}:refs/remotes/origin/{branch}"], worktree)
        git(["reset", "--soft", tip], worktree)
    except Refused as exc:
        print(f"WARNING: published, but the local branch is still at the "
              f"pre-publish commit ({exc}). Fetch and reset it before the next "
              f"publish, or it will be replayed twice.", file=sys.stderr)
        return 1
    print(f"local {branch} re-pointed at the published commit "
          f"(previous local commits stay in the reflog)")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Refused as exc:
        print(f"git-publish: refused: {exc}", file=sys.stderr)
        sys.exit(1)
