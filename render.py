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
    add(str(profile.get("env", {}).get("placeholder", "") or ""))
    return keys


# ----------------------------------------------------------------- rendering

def render_profile(name: str, profile: dict, profile_dir: Path,
                   models: dict, providers: dict, integrations: dict) -> dict:
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

    # $HERMES_HOME/honcho.json: the agent's BUILT-IN Honcho integration
    # auto-enables whenever HONCHO_API_KEY is in the environment (it is,
    # for the honcho-mcp Authorization header) and then fails against the
    # hosted Honcho API with "Invalid API key" — its honcho_* tools also
    # land on the tool surface in a dead state. An explicit enabled:false
    # keeps the built-in off in every profile: this stack wires Honcho
    # through MCP (config/integrations.toml) only. The startup banner
    # still prints "Skipping MCP toolset alias 'honcho'" — cosmetic: the
    # built-in honcho TOOLSET owns the alias, but the MCP server's tools
    # (mcp_honcho_*) still register into the hermes-* umbrella toolsets.
    (out_dir / "honcho.json").write_text(
        json.dumps({"enabled": False}, indent=2) + "\n"
    )

    soul = profile_dir / "SOUL.md"
    if soul.is_file():
        shutil.copy2(soul, out_dir / "SOUL.md")

    skills = profile_dir / "skills"
    if skills.is_dir():
        shutil.copytree(skills, out_dir / "skills", dirs_exist_ok=True)

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
        profile_dirs = sorted(
            d for d in profile_root.iterdir()
            if d.is_dir() and (d / "profile.toml").is_file()
        )
        if args.profile:
            profile_dirs = [d for d in profile_dirs if d.name == args.profile]
            if not profile_dirs:
                raise ConfigError(f"no such profile: {args.profile}")

        if args.check:
            print("config valid")
            return 0

        rows = []
        for profile_dir in profile_dirs:
            profile = load_toml(profile_dir / "profile.toml")
            rows.append(render_profile(
                profile_dir.name, profile, profile_dir,
                models, providers, integrations,
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