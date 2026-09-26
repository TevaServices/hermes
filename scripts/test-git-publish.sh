#!/bin/sh
# Offline tests for git-publish.py — the developer's publish path.
#
# WHY THIS EXISTS
#
# `git-publish.py` replaces `git push` for the team profiles, because a
# repo can require signed commits and a GitHub App's commits only carry a
# signature when GitHub creates them server-side through the API. That
# makes this script the only way a developer's work can reach a repo with
# `required_signatures` at all — so a regression in it is not a broken
# helper, it is a team that cannot land work.
#
# Nothing about that contract is visible from the outside when it breaks.
# A wrong tree publishes silently; a `git push`-shaped mistake (sending
# `author`/`committer` fields) still creates commits and still moves the
# ref, and only the repo's merge button ever notices that they are
# unsigned. So the assertions here are mechanical and specific:
#
#   1. THE PAYLOAD CONTRACT. Every commit object is created with NO
#      `author`, `committer` or `signature` field — that omission is the
#      entire reason GitHub signs it. The stub fails the run if one
#      appears, and the test also forbids `git push` from the skills.
#   2. THE TREE. What lands is byte-identical to the worktree: file
#      modes (an executable `run.sh` stays 100755), symlinks (120000),
#      and deletes (a removed file is gone from the published tree).
#   3. THE TRAILER. A `Signed-off-by:` is re-pointed at the identity
#      GitHub actually stamps — the worktree's git config can name a
#      DIFFERENT bot, and a personal-App identity in an org repo is
#      exactly that mismatch — and a commit that carried no sign-off does
#      not acquire one.
#   4. THE SELF-HEALING. When the local identity guess is wrong, the
#      chain is re-created with the stamped identity, and the correction
#      is remembered, so it happens once rather than every publish.
#   5. THE REFUSALS. Default branch, merge commits and an unforced
#      rewrite are refused with nothing published.
#
# Offline: no Docker, no network. The stub `gh` implements the git-data
# REST API against a REAL bare repo (blobs -> trees -> commits -> refs),
# so the branch that ends up in it can be inspected with plain git.
#
# Run: $ mise run test      (or: sh scripts/test-git-publish.sh)

set -u

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
helper="$here/docker/hermes/git-publish.py"
[ -f "$helper" ] || { echo "git-publish.py not found at $helper" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not on PATH" >&2; exit 2; }
python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$helper" \
    || { echo "syntax error in $helper" >&2; exit 2; }

tmp=$(mktemp -d) || exit 2
trap 'rm -rf "$tmp"' EXIT INT TERM
# Sandbox the helper's tool-home: it caches the identity it learned there,
# and this must not write into the tester's own ~/.cache.
mkdir -p "$tmp/home"
HOME="$tmp/home"
export HOME

pass=0
fail=0

ok()  { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

check() {  # check <description> <expected> <actual>
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$2], got [$3])"; fi
}

contains() {  # contains <description> <needle> <haystack>
    case "$3" in
        *"$2"*) ok "$1" ;;
        *) bad "$1 (missing [$2] in [$(printf '%s' "$3" | head -c 200)])" ;;
    esac
}

# --- the stub gh ------------------------------------------------------------
# Implements the git-data API against a real bare repo, so a published
# branch is a real branch. It also REFUSES any commit payload carrying
# author/committer/signature — the property that makes a bot's commit
# verifiable — so a regression cannot pass this test by looking plausible.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'PY'
#!/usr/bin/env python3
"""Stub `gh api` for the git-data endpoints, backed by a real bare repo."""
import base64
import json
import os
import subprocess
import sys

BARE = os.environ["STUB_BARE"]
RECORD = os.environ["STUB_RECORD"]
SCRATCH = os.environ["STUB_SCRATCH"]
SLUG = os.environ.get("STUB_SLUG", "acme/widget")
BOT_NAME = os.environ.get("STUB_BOT_NAME", "acme-hermes-dev[bot]")
BOT_EMAIL = os.environ.get(
    "STUB_BOT_EMAIL", "42+acme-hermes-dev[bot]@users.noreply.github.com")


def git(*args, input=None, extra_env=None):
    env = dict(os.environ)
    env["GIT_DIR"] = BARE
    # update-index is a worktree command and refuses to run in a bare repo;
    # it never touches the tree here (--cacheinfo only), so a scratch dir is
    # all it needs.
    env["GIT_WORK_TREE"] = SCRATCH
    if extra_env:
        env.update(extra_env)
    proc = subprocess.run(["git"] + list(args), input=input,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr.decode("utf-8", "replace"))
        raise SystemExit(9)
    return proc.stdout


args = sys.argv[1:]
if not args or args[0] != "api":
    sys.stderr.write("stub gh: only `api` is implemented\n")
    raise SystemExit(2)

method, endpoint, payload = "GET", None, None
args = args[1:]
i = 0
while i < len(args):
    arg = args[i]
    if arg == "--method":
        method = args[i + 1]
        i += 2
        continue
    if arg == "--input":
        where = args[i + 1]
        raw = sys.stdin.read() if where == "-" else open(where).read()
        payload = json.loads(raw)
        i += 2
        continue
    if endpoint is None:
        endpoint = arg
    i += 1

with open(RECORD, "a", encoding="utf-8") as fh:
    fh.write(json.dumps({"method": method, "endpoint": endpoint,
                         "payload": payload}) + "\n")


def emit(obj):
    print(json.dumps(obj))
    raise SystemExit(0)


if endpoint == "repos/%s" % SLUG:
    emit({"default_branch": "main"})

if endpoint.startswith("users/"):
    login = endpoint.split("/", 1)[1]
    emit({"id": 42 if login == BOT_NAME else 43, "login": login, "type": "Bot"})

if endpoint == "repos/%s/git/blobs" % SLUG and method == "POST":
    content = base64.b64decode(payload["content"])
    emit({"sha": git("hash-object", "-w", "--stdin", input=content).decode().strip()})

if endpoint == "repos/%s/git/trees" % SLUG and method == "POST":
    index = os.path.join(BARE, "stub-index-%d" % os.getpid())
    env = {"GIT_INDEX_FILE": index}
    git("read-tree", payload["base_tree"], extra_env=env)
    for entry in payload["tree"]:
        if entry.get("sha") is None:
            git("update-index", "--force-remove", "--", entry["path"], extra_env=env)
        else:
            git("update-index", "--add",
                "--cacheinfo", "%s,%s,%s" % (entry["mode"], entry["sha"], entry["path"]),
                extra_env=env)
    emit({"sha": git("write-tree", extra_env=env).decode().strip()})

if endpoint == "repos/%s/git/commits" % SLUG and method == "POST":
    for field in ("author", "committer", "signature"):
        if field in payload:
            sys.stderr.write(
                "stub gh: commit payload carried '%s' — GitHub would not sign "
                "this commit, which is the whole point of the helper\n" % field)
            raise SystemExit(3)
    argv = ["commit-tree", payload["tree"]]
    for parent in payload.get("parents", []):
        argv += ["-p", parent]
    # GitHub stamps the App's bot identity and signs it as itself.
    sha = git(*argv, input=payload["message"].encode("utf-8"), extra_env={
        "GIT_AUTHOR_NAME": BOT_NAME, "GIT_AUTHOR_EMAIL": BOT_EMAIL,
        "GIT_COMMITTER_NAME": "GitHub", "GIT_COMMITTER_EMAIL": "noreply@github.com",
    }).decode().strip()
    emit({"sha": sha,
          "author": {"name": BOT_NAME, "email": BOT_EMAIL},
          "committer": {"name": "GitHub", "email": "noreply@github.com"}})

if endpoint == "repos/%s/git/refs" % SLUG and method == "POST":
    git("update-ref", payload["ref"], payload["sha"])
    emit({"ref": payload["ref"], "object": {"sha": payload["sha"]}})

if endpoint.startswith("repos/%s/git/refs/heads/" % SLUG) and method == "PATCH":
    ref = "refs/heads/" + endpoint.split("/git/refs/heads/", 1)[1]
    git("update-ref", ref, payload["sha"])
    emit({"ref": ref, "object": {"sha": payload["sha"]}})

if endpoint.startswith("repos/%s/git/ref/heads/" % SLUG):
    ref = "refs/heads/" + endpoint.split("/git/ref/heads/", 1)[1]
    proc = subprocess.run(["git", "rev-parse", "--verify", "-q", ref],
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          env=dict(os.environ, GIT_DIR=BARE))
    if proc.returncode != 0:
        sys.stderr.write('{"message": "Not Found", "status": "404"}')
        raise SystemExit(1)
    emit({"ref": ref, "object": {"sha": proc.stdout.decode().strip()}})

if endpoint.startswith("repos/%s/commits/" % SLUG):
    # GitHub's own answer for a commit it created and signed.
    emit({"commit": {"verification": {"verified": True, "reason": "valid"}}})

sys.stderr.write("stub gh: unhandled %s %s\n" % (method, endpoint))
raise SystemExit(9)
PY
chmod 0755 "$tmp/bin/gh"
PATH="$tmp/bin:$PATH"
export PATH

STUB_BARE="$tmp/origin.git"
STUB_RECORD="$tmp/record.jsonl"
STUB_SLUG="acme/widget"
mkdir -p "$tmp/scratch"
STUB_SCRATCH="$tmp/scratch"
export STUB_BARE STUB_RECORD STUB_SLUG STUB_SCRATCH
# An empty descriptor dir: the personal-repo path, so the identity comes
# from the worktree's git config and GitHub's stamp can disagree with it.
mkdir -p "$tmp/creds-empty"
ORG_CREDS_DIR="$tmp/creds-empty"
export ORG_CREDS_DIR
: > "$STUB_RECORD"

publish() {  # publish <worktree> [extra args...]
    worktree="$1"; shift
    python3 "$helper" -C "$worktree" "$@" 2>&1
}

# --- fixture: a bare "origin" and a worktree whose identity is STALE --------
git init -q --bare "$tmp/origin.git"
git -C "$tmp/origin.git" symbolic-ref HEAD refs/heads/main

mkdir "$tmp/src"
git -C "$tmp/src" init -q -b main
git -C "$tmp/src" config user.name "acme-hermes-dev[bot]"
git -C "$tmp/src" config user.email "acme-hermes-dev[bot]@users.noreply.github.com"
printf 'one\n' > "$tmp/src/a.txt"
printf 'gone\n' > "$tmp/src/old.txt"
git -C "$tmp/src" add -A
git -C "$tmp/src" commit -qm "base"
git -C "$tmp/src" remote add origin https://github.com/acme/widget
git -C "$tmp/src" config "url.file://$tmp/origin.git.insteadOf" \
    "https://github.com/acme/widget"
git -C "$tmp/src" push -q origin main

# The topic branch. Its git config deliberately names a DIFFERENT bot than
# the App the token belongs to — the stale-identity case.
git -C "$tmp/src" checkout -q -b topic
git -C "$tmp/src" config user.name "stale-dev[bot]"
git -C "$tmp/src" config user.email "stale-dev[bot]@users.noreply.github.com"
printf 'one two\n' > "$tmp/src/a.txt"
printf '#!/bin/sh\necho hi\n' > "$tmp/src/run.sh"
chmod 0755 "$tmp/src/run.sh"
ln -s a.txt "$tmp/src/link.txt"
rm "$tmp/src/old.txt"
git -C "$tmp/src" add -A
git -C "$tmp/src" commit -qm "feat: add the runner" -s   # carries a sign-off
printf '#!/bin/sh\necho hi again\n' > "$tmp/src/run.sh"
git -C "$tmp/src" add -A
git -C "$tmp/src" commit -qm "fix: runner output"        # carries none

# ===========================================================================
# 1. Publishing a new branch: verified commits, exact tree, honest trailer
# ===========================================================================
out=$(publish "$tmp/src"); rc=$?
check "new branch: publish exits 0" "0" "$rc"
contains "new branch: reports the stamped identity" \
    "acme-hermes-dev[bot] <42+acme-hermes-dev[bot]@users.noreply.github.com>" "$out"
contains "new branch: notices the stale local identity" "re-pointing the trailers" "$out"

remote_tip=$(git -C "$tmp/origin.git" rev-parse --verify -q refs/heads/topic)
if [ -n "$remote_tip" ]; then
    ok "new branch: remote branch created"
else
    bad "new branch: remote branch created"
fi

local_tip=$(git -C "$tmp/src" rev-parse HEAD)
check "local branch re-pointed at the published commit" "$remote_tip" "$local_tip"

# The published tree must equal the worktree's, byte for byte. Guarded on
# a non-empty listing so a missing ref fails loudly instead of matching
# every "is it absent?" assertion.
listing=$(git -C "$tmp/origin.git" ls-tree -r refs/heads/topic 2>/dev/null)
if [ -z "$listing" ]; then
    bad "published branch is listable (case 1 published nothing)"
else
    ok "published branch is listable"
    check "published tree matches the worktree" \
        "$(git -C "$tmp/src" rev-parse 'HEAD^{tree}')" \
        "$(git -C "$tmp/origin.git" rev-parse "refs/heads/topic^{tree}")"
    check "executable bit preserved" "100755" \
        "$(printf '%s\n' "$listing" | awk '$4=="run.sh"{print $1}')"
    check "symlink preserved" "120000" \
        "$(printf '%s\n' "$listing" | awk '$4=="link.txt"{print $1}')"
    check "deleted file is gone" "" \
        "$(printf '%s\n' "$listing" | awk '$4=="old.txt"{print $4}')"
fi

# The trailer that was there is re-pointed at the identity GitHub stamped;
# the commit that never carried one does not acquire one.
check "signed-off commit carries the stamped trailer" "1" \
    "$(git -C "$tmp/origin.git" log --format=%B refs/heads/topic \
        | grep -c '^Signed-off-by: acme-hermes-dev\[bot\] <42+acme-hermes-dev\[bot\]@users.noreply.github.com>$')"
check "only the signed-off commit carries a trailer" "1" \
    "$(git -C "$tmp/origin.git" log --format=%B refs/heads/topic \
        | grep -c '^Signed-off-by: ')"
check "the stale worktree identity never reaches a trailer" "0" \
    "$(git -C "$tmp/origin.git" log --format=%B refs/heads/topic | grep -c 'stale-dev')"

# The correction is remembered rather than repeated.
check "stamped identity cached (correction happens once)" "acme-hermes-dev[bot]" \
    "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["login"])' \
        "$tmp/home/.cache/git-publish/identity-acme.json" 2>/dev/null)"

# ===========================================================================
# 2. Appending: an org descriptor, no correction, a fast-forward
# ===========================================================================
printf '# org app\ndummy\n' > "$tmp/creds-empty/acme.env"
printf 'ORG_SLUG=acme\nGH_GIT_NAME=acme-hermes-dev[bot]\n' > "$tmp/creds-empty/acme.env"
printf 'three\n' >> "$tmp/src/a.txt"
git -C "$tmp/src" add -A
git -C "$tmp/src" commit -qm "feat: more" -s
rm -f "$tmp/record.jsonl"; : > "$tmp/record.jsonl"

out=$(publish "$tmp/src"); rc=$?
check "append: publish exits 0" "0" "$rc"
check "append: no identity correction needed" "0" \
    "$(printf '%s' "$out" | grep -c 're-pointing')"
commit_calls=$(grep -c 'git/commits' "$tmp/record.jsonl")
check "append: one new commit object" "1" "$commit_calls"
check "append: ref update is not forced" "0" \
    "$(grep '"PATCH"' "$tmp/record.jsonl" | python3 -c \
        'import json,sys; print(int(any(json.loads(l)["payload"].get("force") for l in sys.stdin)))')"
check "append: remote moved" "$(git -C "$tmp/src" rev-parse HEAD)" \
    "$(git -C "$tmp/origin.git" rev-parse refs/heads/topic)"

# ===========================================================================
# 3. Refusals — every one of them publishes nothing
# ===========================================================================
before=$(git -C "$tmp/origin.git" rev-parse refs/heads/topic)
: > "$tmp/record.jsonl"

out=$(python3 "$helper" -C "$tmp/src" -b main 2>&1); rc=$?
check "default branch: refused" "1" "$rc"
contains "default branch: says why" "default branch" "$out"

out=$(publish "$tmp/src" --replay-from origin/main); rc=$?
check "unforced rewrite: refused" "1" "$rc"
contains "unforced rewrite: says why" "--force" "$out"
check "unforced rewrite: nothing was created" "0" \
    "$(grep -c 'git/blobs' "$tmp/record.jsonl")"

git -C "$tmp/src" checkout -q -b side
printf 'side\n' > "$tmp/src/side.txt"
git -C "$tmp/src" add -A
git -C "$tmp/src" commit -qm "side" -s
git -C "$tmp/src" checkout -q topic
git -C "$tmp/src" merge -q --no-ff -m "merge side" side
out=$(publish "$tmp/src" --replay-from origin/main --force); rc=$?
check "merge commit: refused" "1" "$rc"
contains "merge commit: says why" "merge commit" "$out"

check "nothing was published by any refusal" "$before" \
    "$(git -C "$tmp/origin.git" rev-parse refs/heads/topic)"

# ===========================================================================
# 4. The skills must route commits through the helper, never `git push`
# ===========================================================================
for skill in "$here/config/profiles/developer/skills/team-developer/SKILL.md" \
             "$here/config/skills/team-conventions/SKILL.md"; do
    [ -f "$skill" ] || continue
    name=$(basename "$(dirname "$skill")")
    # Every mention must be a corrective one ("never `git push`", "not
    # `git push`"): an unqualified mention reads as an instruction to run it.
    mentions=$(grep -c 'git push' "$skill")
    corrective=$(grep -cE '(never|Never|not|NOT).{0,20}`git push' "$skill")
    check "$name: every 'git push' mention is corrective" "$mentions" "$corrective"
    if grep -q 'git-publish.py' "$skill"; then
        ok "$name: names git-publish.py"
    else
        bad "$name: names git-publish.py"
    fi
done

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
