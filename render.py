#!/usr/bin/env python3
"""Compile config/ into per-profile Hermes agent overlay files.

Reads:
  config/providers.toml      provider registry (endpoints, key vars)
  config/models.toml        model aliases -> provider/model IDs
  config/integrations.toml  Honcho / Firecrawl / other MCP wiring
  config/profiles/<name>/   profile.toml + SOUL.md (+ optional skills/)

Writes, per profile:
  build/<name>/config.yaml      Hermes config (model, providers, mcp_servers, extras)
  build/<name>/.env.example     env var placeholders the profile needs
  build/<name>/SOUL.md          copied from the profile dir
  build/<name>/skills/          copied from the profile dir, if present

The build/<name>/ directory is the container overlay mounted at /overlay.
Repo sources are the source of truth: re-run after any edit. Generated
files are safe to delete and regenerate.

Requires Python 3.11+ (stdlib tomllib). No third-party dependencies.
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONFIG = ROOT / "config"
BUILD = ROOT / "build"

# Stack-wide operating-discipline block, appended to EVERY rendered
# profile's SOUL.md. SOUL.md rides the system prompt on every turn, unlike
# a skill (lazily loaded), so this is the right home for behaviour that
# must hold on every single turn. One source, all profiles.
SOUL_OPERATING = CONFIG / "SOUL_OPERATING.md"

# Scheduled jobs, declared once for the whole stack in config/cron.toml and
# rendered PER PROFILE (build/<name>/cron.json -> /overlay/profiles/<name>/
# cron.json). Rendered as JSON, not YAML/TOML, because the consumer is the
# boot reconciler (docker/hermes/cron-reconcile.py), which drives the
# `hermes cron` CLI — see that file and the header of config/cron.toml.
#
# CRON_SCRIPT_DIR is where the job scripts live in the REPO; they are baked
# to /usr/local/bin in the image and seeded into each profile's scripts dir
# at boot. Validating against it here means a typo'd script name fails the
# BUILD rather than becoming an "unrunnable" job that the scheduler
# silently auto-pauses in production.
CRON_SPEC = CONFIG / "cron.toml"
CRON_SCRIPT_DIR = ROOT / "docker" / "hermes"
# `profile` is dropped: the rendered file is already per-profile.
_JOB_FIELDS = ("name", "schedule", "script", "no_agent", "deliver", "prompt")

# Tirith rules pre-approved for every profile. A Tirith finding raises an
# approval gate keyed `tirith:<rule_id>`; tools/approval.py loads
# `command_allowlist` from config at MODULE IMPORT (approval.py:5971) and
# is_approved() consults it, so listing a key here permanently
# auto-approves that rule. These six are the ones that actually fired on
# this stack's own legitimate work, mined from the live state.db
# (Sep 2026). Tirith itself stays ON — only these rules are pre-approved.
# Extend by hand from `tirith audit stats --format json` -> top_rules.
# See AGENTS.md §"Security tuning (guard friction)".
TIRITH_PREAPPROVED_RULES = [
    # "Nested executable body could not be resolved" — the $(...) /
    # dynamic-command shape, i.e. exactly the scripting we ask for.
    "tirith:analysis_incomplete",
    # Our own internal plain-HTTP services (komodo-core:9120, litellm:4000).
    "tirith:plain_http_to_sink",
    # Worktree/build churn. The hardline floor still blocks `rm -rf /`.
    "tirith:mass_file_deletion",
    "tirith:curl_pipe_shell",
    "tirith:pipe_to_interpreter",
    "tirith:blast_find_delete",
]


def set_build_root(path: str | None) -> None:
    """Override the output root (default <repo>/build).

    The Dockerfile renders into /overlay at image build time with
    --build-root /overlay, so rendered profiles ship as image layers
    instead of committed files. Local runs keep the default.
    """
    global BUILD
    if path:
        BUILD = Path(path).resolve()

# Env vars per gateway platform (required + the optional ones worth
# surfacing). Verified against gateway/config.py: a platform is enabled
# by the mere presence of its *_BOT_TOKEN var. Hermes reads these from
# .env (locally) or the stack env_file (Komodo: /etc/hermes/*.env).
GATEWAY_ENV = {
    "telegram": ["TELEGRAM_BOT_TOKEN"],
    "discord": ["DISCORD_BOT_TOKEN", "DISCORD_ALLOWED_USERS"],
    "slack": ["SLACK_BOT_TOKEN", "SLACK_APP_TOKEN"],
    "whatsapp": ["WHATSAPP_TOKEN", "WHATSAPP_PHONE_NUMBER_ID"],
    "signal": ["SIGNAL_NUMBER"],
    "cli": [],
}


class ConfigError(Exception):
    pass


# Config schema version used when the base image's own value can't be read
# (local preview runs, where hermes_cli isn't installed). Keep in sync with
# the HERMES_REF pin — the authoritative stamp is derived at build time.
_FALLBACK_CONFIG_VERSION = 39


def latest_config_version() -> int:
    """The base image's current config schema version (DEFAULT_CONFIG's
    ``_config_version``).

    Stamped into every rendered config.yaml so Hermes' version checks see
    current == latest: without it the schema version reads as 1 and the
    Docker boot-time migration (`scripts/docker_config_migrate.py`) warns
    the config "predates version 12" on every boot — its simple check lacks
    the fresh-minimal-config carve-out the CLI wrapper has. render.py runs
    inside the Docker build with the image's own venv python3 (plain
    `python3` IS /opt/hermes/.venv/bin/python3), so hermes_cli imports
    there; local preview runs take the fallback.

    Deriving instead of hardcoding means a HERMES_REF bump automatically
    re-stamps (explicit older stamps would floor-refuse future ladders —
    worse than absent). The stamped value is the base image's own view of
    "latest", and the resolver still reads the legacy `custom_providers`
    list form at read time, so stamping never changes resolution behavior.
    """
    try:
        from hermes_cli.config import DEFAULT_CONFIG
        version = int(DEFAULT_CONFIG.get("_config_version", 0))
        if version:
            return version
    except Exception:
        pass
    return _FALLBACK_CONFIG_VERSION


# ---------------------------------------------------------------- YAML emit

def _scalar(value, flow: bool = False) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if value is None:
        return "null"
    if isinstance(value, (int, float)):
        return str(value)
    s = str(value)
    # Quote strings that would otherwise parse as something else. Inside
    # flow sequences, quote all strings — commas/brackets are common in
    # MCP args and would break the sequence.
    needs_quotes = flow or (
        not s
        or s.strip() != s
        or s[0] in "{}[]'\"&#*?|>%@`!-,<"
        or s.lower() in ("true", "false", "null", "yes", "no", "on", "off")
        or ": " in s
        or " #" in s
        or _looks_numeric(s)
    )
    if needs_quotes:
        return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'
    return s


def _looks_numeric(s: str) -> bool:
    try:
        float(s)
        return True
    except ValueError:
        return False


def to_yaml(value, indent: int = 0) -> str:
    """Emit a nested dict/list structure as YAML. Values in profiles and
    integrations are plain data, so a small emitter suffices."""
    pad = "  " * indent
    lines: list[str] = []
    if isinstance(value, dict):
        for key, val in value.items():
            if isinstance(val, dict):
                if not val:
                    lines.append(f"{pad}{key}: {{}}")
                else:
                    lines.append(f"{pad}{key}:")
                    lines.append(to_yaml(val, indent + 1))
            elif isinstance(val, list) and val and all(
                not isinstance(x, (dict, list)) for x in val
            ):
                inner = ", ".join(_scalar(x, flow=True) for x in val)
                lines.append(f"{pad}{key}: [{inner}]")
            elif isinstance(val, list):
                # list of dicts/lists (e.g. custom_providers): block form,
                # emitted by the list branch below.
                if not val:
                    lines.append(f"{pad}{key}: []")
                else:
                    lines.append(f"{pad}{key}:")
                    lines.append(to_yaml(val, indent + 1))
            else:
                lines.append(f"{pad}{key}: {_scalar(val)}")
    elif isinstance(value, list):
        for item in value:
            if isinstance(item, (dict, list)):
                sub = to_yaml(item, indent + 1).splitlines()
                # "- key: val" for the first line, then aligned children.
                lines.append(f"{pad}- {sub[0].lstrip()}")
                lines.extend(sub[1:])
            else:
                lines.append(f"{pad}- {_scalar(item)}")
    else:  # pragma: no cover - only used as a recursion terminal
        lines.append(f"{pad}{_scalar(value)}")
    return "\n".join(lines)


# ------------------------------------------------------------------ loading

def load_toml(path: Path) -> dict:
    if not path.is_file():
        raise ConfigError(f"missing config file: {path}")
    with open(path, "rb") as fh:
        return tomllib.load(fh)


def validate(models: dict, providers: dict, integrations: dict) -> None:
    for alias, model in models.items():
        prov = model.get("provider")
        if prov not in providers:
            raise ConfigError(
                f"model '{alias}' references unknown provider '{prov}'"
            )
        if not model.get("model"):
            raise ConfigError(f"model '{alias}' has no model id")
    for key in integrations:
        if not key.strip():
            raise ConfigError("integration names must be non-empty")
    # `--check` returns before render_profile runs, so the operating block
    # would otherwise go unverified on the fast validation path. Every
    # profile depends on it; a missing file must fail loudly here.
    if not SOUL_OPERATING.is_file():
        raise ConfigError(f"missing operating-discipline block: {SOUL_OPERATING}")


def load_cron_jobs(profile_names: set[str]) -> dict[str, list[dict]]:
    """Return {profile: [job, ...]} from config/cron.toml, validated.

    Fails the build on anything that would produce a job the scheduler
    cannot run or the reconciler cannot match: an unknown profile, a
    missing required field, a duplicate (profile, name) — the reconciler
    matches jobs BY NAME, so a duplicate would edit the wrong one — or a
    script that does not exist in the image.
    """
    if not CRON_SPEC.is_file():
        return {}
    by_profile: dict[str, list[dict]] = {}
    seen: set[tuple[str, str]] = set()
    for job in load_toml(CRON_SPEC).get("jobs", []):
        profile = job.get("profile")
        if profile not in profile_names:
            raise ConfigError(
                f"cron job '{job.get('name')}' targets unknown profile "
                f"'{profile}'. Known: {', '.join(sorted(profile_names))}"
            )
        for field in ("name", "schedule", "script"):
            if not job.get(field):
                raise ConfigError(
                    f"cron job for profile '{profile}' is missing '{field}'"
                )
        if bool(job.get("no_agent")) and not job.get("script"):
            raise ConfigError(
                f"cron job '{job['name']}': no_agent requires a script"
            )
        script = CRON_SCRIPT_DIR / job["script"]
        if not script.is_file():
            raise ConfigError(
                f"cron job '{job['name']}': script '{job['script']}' not found "
                f"in docker/hermes/ (job scripts are baked to /usr/local/bin)"
            )
        key = (profile, job["name"])
        if key in seen:
            raise ConfigError(
                f"duplicate cron job name '{job['name']}' for profile "
                f"'{profile}' — the reconciler matches by name"
            )
        seen.add(key)
        by_profile.setdefault(profile, []).append(
            {k: v for k, v in job.items() if k in _JOB_FIELDS}
        )
    return by_profile


def build_model_config(model_key: str, models: dict, providers: dict) -> tuple[dict, dict]:
    """Return (model block, custom_providers entries) for a model alias.

    Hermes resolves `model.provider` at runtime through the
    `custom_providers` LIST in config.yaml (hermes_cli/runtime_provider.py:
    _resolve_named_custom_runtime) — not a `providers:` dict; nothing in
    v2026.3.x consumes the dict form. Each entry carries base_url +
    api_mode + an `api_key` that Hermes ${VAR}-expands from the agent's
    environment at load time, so the key itself never lands in config.
    The entry `name` must match the provider key in providers.toml.
    """
    model = models[model_key]
    provider = providers[model["provider"]]
    model_block = {
        "provider": model["provider"],
        "default": model["model"],
    }
    if provider.get("base_url"):
        model_block["base_url"] = provider["base_url"]
    if model.get("context_length"):
        model_block["context_length"] = model["context_length"]
    if provider.get("api_mode"):
        model_block["api_mode"] = provider["api_mode"]

    custom_providers = []
    for name, prov in providers.items():
        if not prov.get("base_url"):
            continue
        entry = {
            "name": name,
            "base_url": prov["base_url"],
            "api_mode": prov.get("api_mode") or "chat_completions",
        }
        if prov.get("api_key_env"):
            entry["api_key"] = "${%s}" % prov["api_key_env"]
        custom_providers.append(entry)
    return model_block, custom_providers


def build_mcp_servers(profile: dict, integrations: dict) -> dict:
    servers = {}
    for key in profile.get("integrations", []):
        if key not in integrations:
            raise ConfigError(
                f"profile lists integration '{key}' which is not defined in "
                f"config/integrations.toml"
            )
        integ = integrations[key]
        if not integ.get("enabled", False):
            continue
        if integ.get("mcp_url"):
            servers[key] = {"url": integ["mcp_url"], "enabled": True}
            # honcho-mcp (and any OAuth-style MCP endpoint) requires an
            # Authorization header; Hermes interpolates ${VAR} from the
            # agent's env at connect time.
            if integ.get("mcp_headers"):
                servers[key]["headers"] = dict(integ["mcp_headers"])
        else:
            block = {
                "command": integ["mcp_command"],
                "args": integ.get("mcp_args", []),
                "enabled": True,
            }
            if integ.get("mcp_env"):
                block["env"] = dict(integ["mcp_env"])
            servers[key] = block
        # Optional per-server tool filtering — same shape the Hermes MCP
        # loader expects (mcp_servers.<name>.tools.{include,exclude}, the
        # lists `hermes tools disable <server>:<tool>` maintains). Used to
        # trim tool schemas an integration cannot actually serve (see
        # firecrawl below: cloud-only routes 404/500/503 self-hosted).
        if integ.get("mcp_tools_exclude"):
            servers[key].setdefault("tools", {})["exclude"] = list(
                integ["mcp_tools_exclude"]
            )
        if integ.get("mcp_tools_include"):
            servers[key].setdefault("tools", {})["include"] = list(
                integ["mcp_tools_include"]
            )
    return servers


def collect_env_keys(profile: dict, model_key: str, models: dict,
                      providers: dict, integrations: dict) -> list[str]:
    """Union of env vars the profile needs, in stable order."""
    keys: list[str] = []

    def add(key: str | None) -> None:
        if key and key not in keys:
            keys.append(key)

    for mk in (model_key, profile.get("fallback_model")):
        if mk and mk in models:
            add(providers[models[mk]["provider"]].get("api_key_env"))
    for platform in profile.get("platforms", []):
        if platform not in GATEWAY_ENV:
            print(f"  warning: unknown platform '{platform}' (no env mapping)",
                  file=sys.stderr)
        for key in GATEWAY_ENV.get(platform, []):
            add(key)
    for key in profile.get("integrations", []):
        for env in integrations.get(key, {}).get("required_env", []):
            add(env)
    # Profile-declared env vars ([env] table: keys are var names, values
    # are placeholder documentation). Every key lands in .env.example so
    # the operator's host env file can supply secrets per profile
    # (mapped into the profile's own .env by entrypoint.sh
    # PROFILE_<NAME>_<VAR>).
    for key in profile.get("env", {}):
        add(str(key))
    return keys


# ----------------------------------------------------------------- rendering

def render_profile(name: str, profile: dict, profile_dir: Path,
                   models: dict, providers: dict, integrations: dict,
                   cron_jobs: list[dict] | None = None) -> dict:
    model_key = profile.get("model")
    if model_key not in models:
        raise ConfigError(
            f"profile '{name}' references unknown model '{model_key}'. "
            f"Known models: {', '.join(sorted(models))}"
        )
    fallback = profile.get("fallback_model")
    if fallback is not None and fallback not in models:
        raise ConfigError(
            f"profile '{name}' references unknown fallback_model '{fallback}'"
        )

    model_block, custom_providers = build_model_config(model_key, models, providers)
    mcp_servers = build_mcp_servers(profile, integrations)

    config = {"model": model_block}
    if custom_providers:
        config["custom_providers"] = custom_providers
    if mcp_servers:
        config["mcp_servers"] = mcp_servers
    config.update(profile.get("config_extra", {}))

    # Memory: provider plugin + built-in store caps for EVERY profile.
    # The memory-provider plugin (plugins/memory/honcho, agent_init.py
    # MemoryManager) is activated by config `memory.provider`; the built-in
    # markdown store caps are `memory.memory_char_limit` /
    # `memory.user_char_limit` (memory_tool.py). Per-profile profile.toml
    # [config_extra.memory] still wins — it merges AFTER this default.
    mem_extra = profile.get("config_extra", {}).get("memory", {})
    memory_cfg = {
        "provider": "honcho",
        "memory_char_limit": 8192,
        "user_char_limit": 2048,
    }
    memory_cfg.update(mem_extra)
    config["memory"] = memory_cfg

    # Tirith pre-approvals (see TIRITH_PREAPPROVED_RULES). UNION with
    # anything the profile set via [config_extra.command_allowlist], so a
    # profile can add entries but never accidentally drops the stack-wide
    # ones. Loaded by tools/approval.py at import; see AGENTS.md
    # §"Security tuning (guard friction)".
    allowlist = set(config.get("command_allowlist") or [])
    allowlist.update(TIRITH_PREAPPROVED_RULES)
    config["command_allowlist"] = sorted(allowlist)

    # Authoritative schema stamp, set after config_extra so a profile
    # cannot (accidentally) claim a version the rendered shape doesn't
    # have — see latest_config_version() for why this exists at all.
    config["_config_version"] = latest_config_version()

    out_dir = BUILD / name
    out_dir.mkdir(parents=True, exist_ok=True)

    header = (
        f"# Generated by render.py for the '{name}' profile — DO NOT EDIT.\n"
        f"# Edit config/ sources and run `mise run render` instead.\n"
    )
    (out_dir / "config.yaml").write_text(header + to_yaml(config) + "\n")

    # $HERMES_HOME/honcho.json — Honcho MEMORY PROVIDER connection config.
    # The memory-provider plugin (plugins/memory/honcho) reads this file
    # FIRST in its config chain, before env fallback. baseUrl points at
    # the stack's self-hosted instance on the shared compose network;
    # apiKey falls back to env HONCHO_API_KEY (present in every
    # container's env; only honcho-mcp enforces it — honcho-api
    # self-hosts unauthenticated). enabled:true is explicit; baseUrl
    # alone would auto-enable. workspace/aiPeer are deliberately unset —
    # the plugin defaults them per active profile at runtime.
    # There is no separate built-in honcho integration in this agent
    # version (the honcho toolset was removed — Honcho IS the memory
    # provider plugin), so enabling this does not double-wire anything;
    # the honcho MCP server (config/integrations.toml) remains the
    # on-demand tool surface.
    (out_dir / "honcho.json").write_text(
        json.dumps({"enabled": True, "baseUrl": "http://honcho-api:8000"},
                   indent=2) + "\n"
    )

    soul = profile_dir / "SOUL.md"
    if soul.is_file():
        shutil.copy2(soul, out_dir / "SOUL.md")
    # Append the stack-wide operating discipline to EVERY profile — the
    # per-role SOUL.md stays the role document, the shared rules live in
    # one file. A profile with no SOUL.md of its own still gets the block.
    with open(out_dir / "SOUL.md", "a", encoding="utf-8") as fh:
        fh.write("\n" + SOUL_OPERATING.read_text(encoding="utf-8"))

    # Stack-wide skills (config/skills/) merge into EVERY rendered profile
    # — operating-manual skills every agent in this stack should carry.
    # Profile-specific skills are copied after, so same-named ones win.
    shared_skills = CONFIG / "skills"
    if shared_skills.is_dir():
        (out_dir / "skills").mkdir(parents=True, exist_ok=True)
        shutil.copytree(shared_skills, out_dir / "skills", dirs_exist_ok=True)
    skills = profile_dir / "skills"
    if skills.is_dir():
        shutil.copytree(skills, out_dir / "skills", dirs_exist_ok=True)

    # This profile's scheduled jobs (config/cron.toml). Rendered, NOT
    # applied: the profile's cron store is runtime state (run history,
    # failure streaks, notepads) and writing jobs.json from here would
    # clobber it on every deploy. bootstrap-profiles.sh reconciles this
    # file into the store at boot via the CLI, which preserves that state.
    # Always written, even when empty, so the overlay is self-describing.
    (out_dir / "cron.json").write_text(
        json.dumps({"jobs": cron_jobs or []}, indent=2) + "\n"
    )

    env_keys = collect_env_keys(profile, model_key, models, providers, integrations)
    env_lines = [
        "# Generated by render.py for the '{name}' profile — DO NOT EDIT.".format(name=name),
        "# Copy the matching secrets/*.env.example, fill in real values,",
        "# and point HERMES_ENV_DIR at it (see README).",
    ]
    for key in env_keys:
        env_lines.append(f"{key}=")
    if env_keys:
        (out_dir / ".env.example").write_text("\n".join(env_lines) + "\n")

    return {
        "profile": name,
        "model": f"{models[model_key]['provider']}:{models[model_key]['model']}",
        "integrations": ", ".join(profile.get("integrations", [])) or "-",
        "env_keys": len(env_keys),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", help="render only this profile")
    parser.add_argument("--check", action="store_true",
                        help="validate only; do not write build output")
    parser.add_argument("--build-root", metavar="DIR",
                        help="output root for rendered profiles "
                             "(default: <repo>/build; the Docker build "
                             "renders into /overlay)")
    args = parser.parse_args()
    set_build_root(args.build_root)

    try:
        providers = load_toml(CONFIG / "providers.toml")["providers"]
        models = load_toml(CONFIG / "models.toml")["models"]
        integrations = load_toml(CONFIG / "integrations.toml")["integrations"]
        validate(models, providers, integrations)

        profile_root = CONFIG / "profiles"
        all_profile_dirs = sorted(
            d for d in profile_root.iterdir()
            if d.is_dir() and (d / "profile.toml").is_file()
        )
        # Cron jobs are validated against EVERY profile, not just the
        # (possibly --profile-filtered) render set, so rendering one
        # profile does not fail on another profile's jobs.
        cron_by_profile = load_cron_jobs({d.name for d in all_profile_dirs})

        profile_dirs = all_profile_dirs
        if args.profile:
            profile_dirs = [d for d in profile_dirs if d.name == args.profile]
            if not profile_dirs:
                raise ConfigError(f"no such profile: {args.profile}")

        if args.check:
            jobs = sum(len(v) for v in cron_by_profile.values())
            print(f"config valid ({jobs} cron job(s) declared)")
            return 0

        rows = []
        for profile_dir in profile_dirs:
            profile = load_toml(profile_dir / "profile.toml")
            rows.append(render_profile(
                profile_dir.name, profile, profile_dir,
                models, providers, integrations,
                cron_by_profile.get(profile_dir.name, []),
            ))

        width = max(len(r["profile"]) for r in rows)
        for row in rows:
            print(f"  {row['profile']:<{width}}  model={row['model']}  "
                  f"integrations=[{row['integrations']}]  env_keys={row['env_keys']}")
        print(f"rendered {len(rows)} profile(s) to {BUILD}/")
        return 0
    except (ConfigError, tomllib.TOMLDecodeError, KeyError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())