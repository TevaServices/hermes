#!/usr/bin/env python3
"""Render dead-drop profile packages into the image overlay, at boot.

WHY THIS EXISTS

External profile packages arrive on DISK — a directory tree provisioned by
their own repo onto the host's profile-source path (default
/etc/hermes/profiles.d/<name>/, mounted read-only in the container). The
hermes stack repo carries no knowledge of them: no registry, no git
sources, no compose entries. Discovery is purely structural — every
directory here that carries a package.toml IS a package.

render.py runs at IMAGE BUILD time for the builtin profiles, but a package
can appear or change on disk without any rebuild, so the packages are
rendered at CONTAINER BOOT instead, by this script, INTO the same overlay
the build bakes:

    <drop>/<package>/profiles/<n>/profile.toml
        -> render.render_profile() via the baked stack config sources
        -> /overlay/profiles/<n>/            (bootstrap applies as usual)
    <drop>/<package>/profiles/<n>/'s [discord] block
        -> a render_profile discord_routes pass over the default overlay,
           regenerating gateway.profile_routes' ext_* entries
    <drop>/<package>/cron.toml
        -> /overlay/profiles/<n>/cron.json (+ package scripts/ copied in
           for cron-reconcile.py to seed from)

Everything downstream is the stock boot machinery: bootstrap-profiles.sh
applies the overlays, expand-placeholders.py resolves @@VAR@@s (values
come from the packages' package.env, loaded into the boot environment by
the entrypoint), cron-reconcile.py syncs the stores.

FAILURE POSTURE. A broken package never takes the stack with it: each
package is validated + rendered independently; a failure prints an
unmissably loud line and skips THAT package only (its profiles simply do
not start). Run with --validate to check a drop directory without writing
(exit 1 on any failure) — the repo's `mise run validate-drop` wraps it.

Idempotency. Every render is full-file regeneration into /overlay, which
is also where the previous package renders live; a package that vanished
from the drop has its overlay dir (marked .rendered-by-drop) pruned, and
bootstrap-profiles.sh flips an orphaned profile home's gateway_state to
stopped so no ghost gateway starts.

Usage:
    render-drop-profiles.py [--drop-dir DIR] [--overlay-root DIR] [--validate]
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
import tempfile
import tomllib
from pathlib import Path

STACK_ROOT_CANDIDATES = (
    Path("/opt/hermes-stack-config"),            # the image: baked sources
    # A checkout: this script lives at <repo>/docker/hermes/, so the repo
    # root (render.py + config/) is three levels up. In the container
    # (/usr/local/bin/) the same arithmetic lands on the filesystem root,
    # where no render.py exists — the first candidate wins there.
    Path(__file__).resolve().parent.parent.parent,
)
_RENDER = None
for _cand in STACK_ROOT_CANDIDATES:
    if (_cand / "render.py").is_file():
        sys.path.insert(0, str(_cand))
        try:
            import render  # noqa: E402
            _RENDER = render
            break
        except ImportError as exc:  # pragma: no cover - broken checkout
            print(f"render-drop: found { _cand }/render.py but importing it "
                  f"failed: {exc}", file=sys.stderr)
if _RENDER is None:
    print(f"render-drop: cannot import render.py from any of "
          f"{', '.join(str(c) for c in STACK_ROOT_CANDIDATES)}", file=sys.stderr)
    sys.exit(1)
render = _RENDER

# Written into every package profile's overlay dir: marks it as
# drop-rendered, so the prune pass can distinguish "package gone" from
# "baked by the image build" and never touches the latter.
DROP_MARKER = ".rendered-by-drop"


def log(msg: str) -> None:
    print(f"[render-drop] {msg}", flush=True)


def err(msg: str) -> None:
    print(f"[render-drop] ERROR: {msg}", file=sys.stderr, flush=True)


def load_packages(drop_root: Path) -> list[tuple[Path, str | None]]:
    """Every candidate package dir under the drop, with its manifest name.

    Returns [(dir, name_or_None)] — name is None when package.toml is
    missing or unparseable, so the caller fails THAT package alone instead
    of taking the whole drop down (one broken package must not remove every
    other team's profiles).
    """
    if not drop_root.is_dir():
        return []
    candidates: list[tuple[Path, str | None]] = []
    for entry in sorted(drop_root.iterdir()):
        if not entry.is_dir():
            continue
        manifest = entry / "package.toml"
        if not manifest.is_file():
            continue
        try:
            with open(manifest, "rb") as fh:
                data = tomllib.load(fh)
        except (OSError, tomllib.TOMLDecodeError) as exc:
            print(f"[render-drop] ERROR: cannot read {manifest}: {exc}",
                  file=sys.stderr, flush=True)
            candidates.append((entry, None))
            continue
        name = data.get("name")
        if not isinstance(name, str) or not name.strip():
            print(f"[render-drop] ERROR: {manifest} must declare a "
                  f"non-empty 'name'", file=sys.stderr, flush=True)
            candidates.append((entry, None))
            continue
        candidates.append((entry, name.strip()))
    return candidates


def package_profile_dirs(pkg_root: Path) -> dict[str, Path]:
    profiles_dir = pkg_root / "profiles"
    if not profiles_dir.is_dir():
        return {}
    return {
        d.name: d
        for d in sorted(profiles_dir.iterdir())
        if d.is_dir() and (d / "profile.toml").is_file()
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--drop-dir",
                        default="/run/hermes-pem/profiles.d",
                        help="the profile-source path (dead drop root)")
    parser.add_argument("--overlay-root", default="/overlay",
                        help="the baked overlay root to render into")
    parser.add_argument("--validate", action="store_true",
                        help="validate only; write nothing; exit 1 on failure")
    parser.add_argument("--stack-root", default=None,
                        help="override the stack config source root (default: "
                             "first of /opt/hermes-stack-config, the checkout)")
    args = parser.parse_args()
    if args.stack_root:
        sys.path[0] = str(args.stack_root)
        import importlib
        importlib.reload(render)

    drop_root = Path(args.drop_dir)
    validate_only = args.validate
    _temp_overlay = None
    if validate_only:
        # Validate mode exercises the FULL render path, but into a
        # throwaway overlay — nothing on disk is touched.
        _temp_overlay = tempfile.mkdtemp(prefix="render-drop-validate-")
        overlay_root = Path(_temp_overlay)
    else:
        overlay_root = Path(args.overlay_root)
    profiles_overlay = overlay_root / "profiles"

    models = render.load_toml(render.CONFIG / "models.toml")["models"]
    providers = render.load_toml(render.CONFIG / "providers.toml")["providers"]
    integrations = render.load_toml(render.CONFIG / "integrations.toml")["integrations"]

    # ---- discovery: every package validated independently ---------------
    failures: list[str] = []
    good: dict[str, Path] = {}
    pkg_profiles: dict[str, dict[str, tuple[Path, dict]]] = {}
    routes: list[tuple[str, str]] = []
    extra_placeholders: set[str] = set()
    taken: dict[str, str] = {}  # package/profile name -> package name
    declared_by: dict[str, str] = {}  # placeholder var -> "pkg/profile"
    declared_anywhere: dict[str, Path] = {}  # profile name -> package root

    for root, name in load_packages(drop_root):
        if name is None:
            failures.append(f"{root.name}/(manifest)")
            continue
        try:
            if name != root.name:
                raise render.ConfigError(
                    f"package name {name!r} does not match its directory "
                    f"{root.name!r} — the directory IS the drop identity"
                )
            if name in ("default", "profiles"):
                raise render.ConfigError(
                    f"'{name}' is a reserved overlay name"
                )
            if name in good:
                raise render.ConfigError(
                    f"another package already took the name '{name}'"
                )
            pdirs = package_profile_dirs(root)
            profiles: dict[str, dict] = {}
            # Where each profile name was declared, regardless of whether
            # THIS package ends up valid: the prune pass must not tear down
            # a previously-rendered overlay while its (failed) package is
            # still on disk — that is a fix-and-restart, not a removal.
            declared_anywhere.update({p: root for p in pdirs})
            for pname, pdir in pdirs.items():
                profile = render.load_toml(pdir / "profile.toml")
                # Reserved name check FIRST: a package profile named
                # 'default' would collide with the builtin overlay layout.
                if pname == "default":
                    raise render.ConfigError(
                        "a package cannot ship a profile named 'default'"
                    )
                # [discord] validated HERE so a broken one fails its own
                # package without blocking the others.
                disc = render.discord_block(pname, profile)
                if disc is not None:
                    routes.append((pname, disc[0]))
                if pname in taken:
                    raise render.ConfigError(
                        f"profile '{pname}' already declared by package "
                        f"'{taken[pname]}' — profile names are global"
                    )
                taken[pname] = name
                profiles[pname] = profile
                for var in render.collect_profile_placeholders(profile):
                    if var in render.BOOT_PLACEHOLDERS:
                        raise render.ConfigError(
                            f"profile '{pname}' re-declares stack-owned "
                            f"placeholder @{('@')}{var}@@"
                        )
                    owner = f"{name}/{pname}"
                    if var in declared_by and declared_by[var] != owner:
                        raise render.ConfigError(
                            f"profile '{pname}' declares placeholder "
                            f"@{('@')}{var}@@ but '{declared_by[var]}' "
                            f"already does — two profiles cannot share one "
                            f"env var silently"
                        )
                    declared_by[var] = owner
                    extra_placeholders.add(var)
            pkg_profiles[name] = {
                pname: (pdirs[pname], profiles[pname])
                for pname in profiles
            }
            good[name] = root
        except (render.ConfigError, OSError, tomllib.TOMLDecodeError) as exc:
            err(f"PACKAGE '{root.name}' FAILED and will be SKIPPED: {exc}")
            failures.append(root.name)
            continue

    log(f"{len(good)} package(s) accepted of "
        f"{len(good) + len(failures)} discovered under {drop_root}")

    # ---- render each good package into /overlay/profiles/<name> ----------
    for name, root in good.items():
        profiles = pkg_profiles[name]
        if not profiles:
            log(f"package '{name}': no profiles; nothing to render")
            continue
        # Package cron: validated against ALL discovered profile names (the
        # reconciler matches by name), jobs + shared scripts against
        # /usr/local/bin (stack-baked helpers) and the package's scripts/.
        cron_by_profile, cron_shared = {"-": []}, []
        try:
            cron_by_profile, cron_shared = render.load_cron_jobs(
                root / "cron.toml",
                set(profiles),
                [Path("/usr/local/bin"), root / "scripts"],
            )
        except (render.ConfigError, tomllib.TOMLDecodeError) as exc:
            err(f"PACKAGE '{name}': cron.toml rejected, rendering profiles "
                f"WITHOUT jobs: {exc}")

        render.set_build_root(str(profiles_overlay))
        for pname, (pdir, profile) in profiles.items():
            out = profiles_overlay / pname
            out.mkdir(parents=True, exist_ok=True)
            try:
                render.render_profile(
                    pname, profile, pdir,
                    models, providers, integrations,
                    cron_jobs=cron_by_profile.get(pname, []),
                    cron_shared=cron_shared,
                    extra_placeholders=extra_placeholders,
                )
                (out / DROP_MARKER).write_text("true\n")
                # The package's scripts ride the overlay so
                # cron-reconcile.py can seed them into the profile home
                # (the scheduler requires scripts under <home>/scripts/, and
                # stack-baked helpers are still found at /usr/local/bin).
                if (root / "scripts").is_dir():
                    shutil.copytree(root / "scripts", out / "scripts",
                                    dirs_exist_ok=True)
                log(f"package '{name}': rendered profile '{pname}'")
            except render.ConfigError as exc:
                err(f"PACKAGE '{name}' profile '{pname}' FAILED: {exc}")
                failures.append(f"{name}/{pname}")
                shutil.rmtree(out, ignore_errors=True)
                continue
            except OSError as exc:
                err(f"PACKAGE '{name}' profile '{pname}' FAILED: {exc}")
                failures.append(f"{name}/{pname}")
                shutil.rmtree(out, ignore_errors=True)

    # ---- default overlay re-render, with generated routes ----------------
    # Only when EVERY discovered package rendered clean: a failed package
    # keeps its last-good overlay AND its last-good routes (the fix-and-
    # restart keeps the whole lane coherent rather than half-rerouted).
    default_ok = False
    default_dir = render.CONFIG / "profiles" / "default"
    if failures:
        pass
    elif routes and default_dir.joinpath("profile.toml").is_file():
        try:
            profile = render.load_toml(default_dir / "profile.toml")
            # The builtin cron jobs are the truth for the default profile
            # (a package cannot own cron for 'default'); the spec's
            # declaration is validated here against the baked script dir —
            # the same content the image build rendered into cron.json.
            all_names = set(
                d.name for d in (render.CONFIG / "profiles").iterdir()
                if d.is_dir() and (d / "profile.toml").is_file()
            ) | set(taken)
            cron_by, cron_shared = render.load_cron_jobs(
                render.CRON_SPEC, all_names, [render.CRON_SCRIPT_DIR],
            )
            render.set_build_root(str(overlay_root))
            render.render_profile(
                "default", profile, default_dir,
                models, providers, integrations,
                cron_jobs=cron_by.get("default", []),
                cron_shared=cron_shared,
                discord_routes=routes,
                extra_placeholders=extra_placeholders,
            )
            default_ok = True
            log(f"default overlay re-rendered with {len(routes)} generated "
                f"route(s)")
        except (render.ConfigError, tomllib.TOMLDecodeError) as exc:
            err(f"DEFAULT re-render FAILED: {exc} — generated routes are "
                f"stale/absent; package channels still fence their own bots")
            failures.append("default")
        except OSError as exc:
            err(f"DEFAULT re-render FAILED: {exc}")
            failures.append("default")
    elif routes:
        err("no builtin default profile to host generated discord routes — "
            "package channels will route nowhere until it exists")

    # ---- prune: package overlays whose source left the drop --------------
    # ONLY a package that is truly gone (its profile dir no longer on disk)
    # has its overlay removed. A package that FAILED validation keeps its
    # previously-rendered overlay: the fix-and-restart keeps profiles
    # running on their last good render rather than vanishing.
    if profiles_overlay.is_dir() and not validate_only:
        for d in sorted(profiles_overlay.iterdir()):
            if not d.is_dir() or not (d / DROP_MARKER).exists():
                continue  # not drop-marked: baked by the image build
            src = declared_anywhere.get(d.name)
            if src is not None and (src / "profiles" / d.name / "profile.toml").is_file():
                continue  # the defining package dir is still on disk
            log(f"pruning overlay for profile '{d.name}' — its package "
                f"profile dir left the drop")
            shutil.rmtree(d, ignore_errors=True)

    # ---- summary ---------------------------------------------------------
    rendered = sum(len(p) for p in pkg_profiles.values())
    if failures:
        err(f"{len(failures)} package item(s) failed, the rest rendered: "
            f"{', '.join(failures)} — fix and re-provision, then restart "
            f"the container to re-render")
    else:
        log(f"drop rendered clean: {rendered} package profile(s), "
            f"{len(routes)} route(s)"
            + (", default re-rendered" if default_ok else ""))
    if _temp_overlay is not None:
        shutil.rmtree(_temp_overlay, ignore_errors=True)
    if validate_only:
        return 1 if failures else 0
    # Never fatal at boot: a broken package must not hold the stack's boot
    # hostage (entrypoint contract).
    return 0


if __name__ == "__main__":
    sys.exit(main())