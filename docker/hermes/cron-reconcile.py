#!/usr/bin/env python3
"""Reconcile GitOps-declared cron jobs into a profile's cron store.

Called by bootstrap-profiles.sh at container boot, once per profile, with
that profile's rendered cron.json (from config/cron.toml via render.py).

WHY A RECONCILER AND NOT A COPIED FILE

A profile's cron store ($HERMES_HOME/cron/jobs.json) is *runtime state*:
it carries run history, failure streaks, next_run_at and per-job
notepads. Overwriting it from the image on every boot — the way
config.yaml and SOUL.md are overwritten — would reset all of that on
each deploy and re-fire everything from scratch. So the declared jobs
are reconciled through the `hermes cron` CLI instead, which edits in
place and leaves runtime fields alone.

Matching is BY NAME, which is why render.py rejects duplicate
(profile, name) pairs at build time: a duplicate would silently edit the
wrong job.

Idempotent by construction: a job whose stored config already matches
the declaration is left completely untouched, so a boot with no config
change does not rewrite jobs.json at all.

Ownership: names are namespaced with the MANAGED_PREFIX ("team: ").
--prune only ever removes MANAGED_PREFIX jobs, so a job the agent
created for itself is never deleted by a deploy.

Usage:
    cron-reconcile.py --home <profile home> --spec <cron.json> [--prune]

Exit: 0 = reconciled (or nothing to do); 1 = at least one job failed.
Failures are reported per job and do not stop the others.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

# Names under this prefix are stack-owned; --prune may remove them.
MANAGED_PREFIX = "team: "

# Where the job scripts are baked in the image. The cron scheduler
# requires a job's script to live under <HERMES_HOME>/scripts/, so each
# one is copied from here into the profile at boot.
IMAGE_SCRIPT_DIR = Path("/usr/local/bin")

# Scripts that job scripts EXEC rather than being scheduled themselves.
# Seeded alongside any declared job so a profile's scripts dir is
# self-contained: review-queue.sh execs team-queue.sh, and while it can
# also find it on PATH, depending on the runtime PATH for a file we
# control is a needless failure mode.
SHARED_SCRIPTS = ("team-queue.sh",)


def log(msg: str) -> None:
    print(f"[cron-reconcile] {msg}", flush=True)


def warn(msg: str) -> None:
    print(f"[cron-reconcile] {msg}", file=sys.stderr, flush=True)


def hermes_bin() -> str:
    """Locate the hermes CLI. Not assumed to be on PATH at boot."""
    found = shutil.which("hermes")
    if found:
        return found
    for candidate in ("/opt/hermes/bin/hermes", "/usr/local/bin/hermes"):
        if Path(candidate).is_file():
            return candidate
    raise SystemExit("cron-reconcile: cannot find the 'hermes' CLI")


def run_hermes(home: Path, args: list[str]) -> tuple[bool, str]:
    """Run `hermes <args>` with HERMES_HOME pointed at the profile.

    NOTE: a non-zero exit is treated as failure, but a ZERO exit is NOT
    treated as success — `hermes cron create` prints "Failed to create
    job: ..." on stdout and still exits 0. Callers must confirm the
    intended change by reading the store back. (Same lesson as the REST
    reviewer-request endpoint, which returns 201 and silently drops a
    bot: a status code is not evidence.)
    """
    env = dict(os.environ)
    env["HERMES_HOME"] = str(home)
    try:
        proc = subprocess.run(
            [hermes_bin(), *args],
            env=env, capture_output=True, text=True, timeout=120,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return False, f"{exc.__class__.__name__}: {exc}"
    output = ((proc.stdout or "") + "\n" + (proc.stderr or "")).strip()
    if proc.returncode != 0:
        return False, _first_line(output) or f"exit {proc.returncode}"
    if "Failed to" in output or "failed to" in output:
        return False, _first_line(output)
    return True, output


def _first_line(text: str) -> str:
    for line in text.splitlines():
        if line.strip():
            return line.strip()
    return ""


def resolve_runtime_owner(home: Path) -> tuple[int, int] | None:
    """Find the uid/gid the profile's scheduler actually runs as.

    NOT simply the profile dir's own owner: on a FIRST boot
    bootstrap-profiles.sh has just created that directory — as root,
    before the entrypoint's `chown -R` to the runtime uid — so its owner
    is still a lie at the moment this runs. Trusting it chowns the cron
    dir to root and the ticker (uid 10000) then cannot write
    `<profile>/cron/output`, which fails job creation outright (seen
    live).

    So: walk up to the nearest ancestor that is not root-owned. The
    volume root is the directory the entrypoint guarantees is owned by
    the runtime uid, so that is the authoritative answer; a profile dir
    that is already correctly owned short-circuits at step one.
    """
    for candidate in (home, *home.parents):
        try:
            st = candidate.stat()
        except OSError:
            continue
        if st.st_uid != 0:
            return st.st_uid, st.st_gid
    try:
        st = home.stat()
        return st.st_uid, st.st_gid
    except OSError:
        return None


def match_owner(path: Path, home: Path) -> None:
    """Hand `path` to the runtime uid when this runs as root.

    bootstrap runs as root before s6 starts the ticker; anything it
    creates for the ticker to write must end up owned by the runtime uid
    or the job is created and then never fires.
    """
    if os.geteuid() != 0:
        return
    owner = resolve_runtime_owner(home)
    if owner is None:
        return
    try:
        os.chown(path, *owner)
    except OSError:
        pass


def load_existing(home: Path) -> dict[str, dict]:
    """Read the profile's cron store, keyed by job name.

    Read-only: this is the existence/match check. All writes go through
    the CLI so the store's schema and runtime fields stay intact.
    """
    store = home / "cron" / "jobs.json"
    if not store.is_file():
        return {}
    try:
        data = json.loads(store.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        warn(f"cannot read {store} ({exc}); treating as empty")
        return {}
    return {j.get("name"): j for j in data.get("jobs", []) if j.get("name")}


def seed_scripts(home: Path, scripts: list[str]) -> list[str]:
    """Copy each needed script into <home>/scripts/. Returns failures.

    The scheduler refuses a script outside <HERMES_HOME>/scripts, and a
    no_agent job whose script is missing is "unrunnable" — the scheduler
    AUTO-PAUSES it at the first tick. Seeding at boot (before s6 starts
    the ticker) is what keeps that from happening.
    """
    failures = []
    scripts_dir = home / "scripts"
    try:
        scripts_dir.mkdir(parents=True, exist_ok=True)
        match_owner(scripts_dir, home)
    except OSError as exc:
        return [f"scripts dir: {exc}"]
    for name in scripts:
        src = IMAGE_SCRIPT_DIR / name
        if not src.is_file():
            failures.append(f"{name}: not present at {src}")
            continue
        dst = scripts_dir / name
        try:
            shutil.copyfile(src, dst)
            dst.chmod(0o755)
            match_owner(dst, home)
        except OSError as exc:
            failures.append(f"{name}: {exc}")
    return failures


def schedule_matches(job: dict, declared: str) -> bool:
    """True when the stored schedule already means the declared one."""
    sched = job.get("schedule") or {}
    if not isinstance(sched, dict):
        sched = {}
    return declared in (
        job.get("schedule_display"), sched.get("expr"), sched.get("display"),
    )


def matches(job: dict, spec: dict) -> bool:
    """True when the stored job already matches the declaration."""
    if not schedule_matches(job, spec.get("schedule", "")):
        return False
    if (job.get("script") or None) != (spec.get("script") or None):
        return False
    if (job.get("deliver") or None) != (spec.get("deliver") or None):
        return False
    if bool(job.get("no_agent")) != bool(spec.get("no_agent")):
        return False
    # Only agent jobs carry a prompt; ignore when the declaration has none.
    if spec.get("prompt") and (job.get("prompt") or "") != spec["prompt"]:
        return False
    return True


def create_args(spec: dict) -> list[str]:
    args = ["cron", "create", spec["schedule"], "--name", spec["name"]]
    if spec.get("script"):
        args += ["--script", spec["script"]]
    if spec.get("no_agent"):
        args.append("--no-agent")
    if spec.get("deliver"):
        args += ["--deliver", spec["deliver"]]
    if spec.get("prompt"):
        args.append(spec["prompt"])
    return args


def edit_args(job_id: str, spec: dict) -> list[str]:
    args = [
        "cron", "edit", job_id,
        "--schedule", spec["schedule"],
        "--deliver", spec.get("deliver") or "local",
        "--no-agent" if spec.get("no_agent") else "--agent",
    ]
    if spec.get("script"):
        args += ["--script", spec["script"]]
    if spec.get("prompt"):
        args += ["--prompt", spec["prompt"]]
    return args


def reconcile(home: Path, specs: list[dict], prune: bool) -> int:
    jobs_dir = home / "cron"
    if not jobs_dir.is_dir():
        # A profile that has never ticked has no cron dir yet; creating it
        # here is what lets the very first boot land its jobs. Ownership
        # matters: the ticker writes here as the runtime uid.
        try:
            jobs_dir.mkdir(parents=True, exist_ok=True)
            match_owner(jobs_dir, home)
        except OSError as exc:
            warn(f"{home}: cannot create cron dir: {exc}")
            return 1

    scripts = sorted(
        {s["script"] for s in specs if s.get("script")} | set(SHARED_SCRIPTS)
    )
    failures = [f"seed {f}" for f in seed_scripts(home, scripts)]

    existing = load_existing(home)
    created = updated = 0

    for spec in specs:
        name = spec["name"]
        job = existing.get(name)
        if job is None:
            ok, detail = run_hermes(home, create_args(spec))
            # Read back: 'hermes cron create' exits 0 even when it fails.
            after = load_existing(home).get(name)
            if ok and after is not None:
                created += 1
                log(f"{home.name}: created '{name}'")
            else:
                failures.append(
                    f"create '{name}': {detail or 'job absent after create'}"
                )
        elif matches(job, spec):
            continue          # already correct — leave it completely alone
        else:
            ok, detail = run_hermes(home, edit_args(job.get("id", ""), spec))
            # Read back: the edit may not have applied even on exit 0.
            after = load_existing(home).get(name)
            if ok and after is not None and matches(after, spec):
                updated += 1
                log(f"{home.name}: updated '{name}'")
            else:
                failures.append(
                    f"edit '{name}': {detail or 'job still differs after edit'}"
                )

    # Prune only stack-owned jobs: the MANAGED_PREFIX namespace is the
    # boundary between "declared here" and "the agent's own jobs".
    if prune:
        declared = {s["name"] for s in specs}
        for name, job in existing.items():
            if not name.startswith(MANAGED_PREFIX) or name in declared:
                continue
            ok, detail = run_hermes(home, ["cron", "remove", job.get("id", "")])
            if ok and name not in load_existing(home):
                log(f"{home.name}: pruned '{name}' (no longer declared)")
            else:
                failures.append(
                    f"prune '{name}': {detail or 'job still present after remove'}"
                )

    if not (created or updated) and not failures:
        log(f"{home.name}: {len(specs)} job(s) already in sync")
    for failure in failures:
        warn(f"{home.name}: {failure}")
    return 1 if failures else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", required=True,
                        help="profile home (the profile's HERMES_HOME)")
    parser.add_argument("--spec", required=True,
                        help="rendered cron.json for this profile")
    parser.add_argument("--prune", action="store_true",
                        help=f"remove '{MANAGED_PREFIX}' jobs no longer declared")
    args = parser.parse_args()

    home = Path(args.home)
    spec_path = Path(args.spec)
    if not spec_path.is_file():
        log(f"no spec at {spec_path}; nothing to do")
        return 0
    try:
        specs = json.loads(spec_path.read_text()).get("jobs", [])
    except (OSError, json.JSONDecodeError) as exc:
        warn(f"cannot read {spec_path}: {exc}")
        return 1
    # An EMPTY spec is not a no-op: it is a declaration that this profile
    # has no stack-owned jobs, so the prune pass must still run to remove
    # any previously-declared ones. (Deleting a job from config/cron.toml
    # is otherwise the one edit that would never take effect.)
    if not specs:
        log(f"{home.name}: no jobs declared")

    return reconcile(home, specs, args.prune)


if __name__ == "__main__":
    sys.exit(main())
