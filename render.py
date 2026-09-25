#!/usr/bin/env python3
"""Compile config/ into per-profile Hermes agent overlay files.

Reads:
  config/providers.toml      provider registry (endpoints, key vars)
  config/models.toml        model tiers -> gateway model names + windows
  config/litellm.yaml       the gateway's own config — read only to verify
                            that every tier has a group (see validate)
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
import re
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
#
# ROOT is the directory holding render.py, which is NOT always the repo
# root: the Dockerfile renders from /tmp (it COPYs render.py and config/
# there). The Dockerfile therefore also COPYs docker/hermes/ to
# /tmp/docker/hermes/ so this check resolves identically inside the build —
# without that, a job script that exists in the repo looks missing at
# build time and fails the deploy (which is exactly what happened).
CRON_SPEC = CONFIG / "cron.toml"
CRON_SCRIPT_DIR = ROOT / "docker" / "hermes"
# Merged into every rendered config (see render_profile) — a profile can
# override any individual key via [config_extra.cron].
STACK_CRON_DEFAULTS = {
    # Upstream 600 kills a real agent turn mid-flight; see render_profile.
    # 3600 was the first correction, but it is unbounded against a `*/5`
    # self-pull: a delivery that runs an hour while its own job fires every
    # 5 minutes stacks up to 12 overlapping wakes (observed 2026-09-25 —
    # four bot_chat_pending files for one issue, one of them a 3600s
    # timeout). 900 clears the longest legitimate turn this host runs while
    # keeping the backlog bounded to ~3 ticks. The real fix for the
    # stacking is the one-session-per-item gate in team-queue.sh; this is
    # the backstop under it.
    "bot_chat_delivery_timeout_seconds": 900,
}
# Approvals for EVERY profile — merged like STACK_CRON_DEFAULTS, and
# overridable per profile via [config_extra.approvals].
#
# WHY THIS IS SO OPEN. The upstream defaults for the unattended lanes are
# `deny`, and upstream's own comment on `single_query_mode` names the exact
# failure that put this stack in a 33-minute loop on 2026-09-25: an
# unanswered approval "just waits the full timeout then fails closed, so the
# agent is forced to work around the block (often via execute_code)". The
# developer profile's cron lane ran in `-q`, so EVERY dangerous-flagged
# command hard-blocked — heredoc script execution, `SQL DELETE without
# WHERE`, Tirith HIGH "nested executable body" — and the agent fell back to
# `execute_code` 102 times. The stack's own memory had already recorded the
# symptom ("AGENTS.md/CLAUDE.md writes are BLOCKED by write-gate when no
# user is present").
#
# The operator's call (2026-09-25): Hermes runs inside a container on a
# mostly dedicated host, so unintentional damage is not the primary risk —
# but an agent that cannot act is. Hence: everything is auto-approved, and
# STACK_APPROVAL_DENY keeps only the permanently-destructive commands shut.
# `mode: off` (= --yolo) is what makes this true for the interactive lanes
# too; the three unattended modes are what stop a cron turn timing out.
#
# WHAT THIS GIVES UP, stated plainly: Tirith still scans and still logs, but
# with mode off a finding no longer gates anything, so `command_allowlist`
# (TIRITH_PREAPPROVED_RULES) is now belt-and-braces rather than the control.
# Credential READS stay permitted on purpose — AGENTS.md's own verification
# checklist reads /etc/hermes/litellm.env, so a glob on that path would break
# documented work. To dial this back: set `mode: smart` here (or per profile)
# and the guardian gates HIGH/CRITICAL findings again.
STACK_APPROVAL_DEFAULTS = {
    "mode": "off",
    "cron_mode": "approve",
    "single_query_mode": "approve",
    "unattended_mode": "approve",
    "deny": [
        # `deny` globs block even under --yolo / mode=off — the last line.
        # Deliberately TIGHT: the stack's own jobs delete things (mktemp
        # dirs, pruned worktree session dirs under /opt/data/worktrees), so
        # a blanket "*rm -rf*" would break prune-repos.sh and teach the next
        # operator to delete this list. Anchored to root/home, the paths a
        # recursive delete cannot come back from, plus the explicit
        # --no-preserve-root form.
        "*rm -rf /", "*rm -rf / ", "*rm -rf /*",
        "*rm -fr /", "*rm -fr / ", "*rm -fr /*",
        "*rm -rf ~*", "*rm -fr ~*", "*--no-preserve-root*",
        # Writing over a block device, or laying a filesystem on one.
        "*dd *of=/dev/*", "*mkfs *", "*mkfs.*",
        # Force-push. main is protected on this stack's own repos, but the
        # org repos agents work in need not be, and a force-push is the one
        # git operation that destroys commits outright.
        "*git push --force*", "*git push -f*",
        # Deleting the volumes that hold every profile's live state.
        "*docker volume rm*", "*docker system prune*", "*docker stack rm*",
        "*docker compose down -v*", "*docker compose down --volumes*",
    ],
}
# Merged into every rendered config (see render_profile) — a profile can
# override any individual key via [config_extra.delegation]. Top-level
# `delegation:` (a sibling of `cron:`/`agent:`), read by
# tools/delegate_tool_config.py::_load_config as
# load_config_readonly().get("delegation").
#
# Subagent delegation is ENABLED on every profile (the team profiles
# dropped it from agent.disabled_toolsets on 2026-09-15), so these are the
# stack's bounds on it. Upstream defaults differ from its own docs here —
# the code is authoritative (hermes_cli/config_defaults.py
# DEFAULT_CONFIG["delegation"]): max_concurrent_children defaults to **10**
# (not the 3 some docs claim), and worktree_isolation is absent from
# DEFAULT_CONFIG entirely. Verify against the code, not the prose, at a
# HERMES_REF bump.
STACK_DELEGATION_DEFAULTS = {
    # Upstream 10. This host is deliberately right-sized small and a
    # parallel batch is where a run's tokens concentrate, so fan-out is
    # capped at 2 — an agent that wants more must be doing genuinely
    # independent work that a pair cannot cover.
    "max_concurrent_children": 2,
    # Upstream 1 = flat (parent -> leaf children; a child never gets
    # delegate_task back). Stated explicitly because it is the cheap shape
    # and we want it to stay that way: an orchestrator child re-adds the
    # delegation toolset for itself, deepening the tree and multiplying
    # spend.
    "max_spawn_depth": 1,
    # Pinned OFF deliberately. It is NOT a default upstream key, so leaving
    # it unset means inheriting whatever the base image does next; and on
    # THIS stack it actively misbehaves, because agents already work inside
    # a per-session git worktree (git-repo.sh), not a plain clone:
    #   * subagent worktrees would nest at
    #     <session-worktree>/.worktrees/subagent-<id>, and
    #     _ensure_gitignore_entry() appends ".worktrees/" to the SESSION
    #     worktree's own .gitignore — a working-tree modification in the
    #     parent's tree, which the agent's next commit can sweep in;
    #   * a child's branch is created off the session HEAD but lives in the
    #     SHARED central object store, so it is visible to every profile
    #     and session rather than staying session-scoped.
    # Children share the parent's cwd instead, which is already the
    # session's worktree — the isolation the stack needs it already has.
    "worktree_isolation": False,
}
# `profile` is dropped: the rendered file is already per-profile.
_JOB_FIELDS = ("name", "schedule", "script", "no_agent", "deliver", "prompt")

# Values that vary per deployment but are RUNTIME secrets, so they cannot be
# resolved here: render.py runs at image build time, while these live in the
# host env file ($HERMES_ENV_DIR/hermes-main.env). They are emitted as
# @@VAR@@ placeholders and expanded at container boot by
# docker/hermes/expand-placeholders.py. Keeping the set here means a typo
# fails the build instead of shipping a literal @@VAR@@ into a config.
# See secrets/hermes-main.env.example for the operator-facing descriptions.
BOOT_PLACEHOLDERS = {
    # #hermes-home — gateway system messages AND the housekeeping jobs'
    # delivery target (config/cron.toml).
    "DISCORD_HOME_CHANNEL",
    # #hermes — the default agent's unrouted channel.
    "DISCORD_CHANNEL_MAIN",
    # The three team channels, one per profile.
    "DISCORD_CHANNEL_PLANNER",
    "DISCORD_CHANNEL_DEVELOPER",
    "DISCORD_CHANNEL_REVIEWER",
}
_PLACEHOLDER_RE = re.compile(r"@@([A-Z][A-Z0-9_]*)@@")

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
    # Second batch (Sep 2026), from the tirith audit log over the
    # intervening week — the rules that kept demanding human buttons on
    # routine work:
    #   trailing_dot_whitespace / schemeless_to_sink (63 each) — fire on
    #     benign compound commands like `export PATH=… && cd /opt/data/mach
    #     && go build ./...` (a trailing-dot path plus a scheme-less URL).
    #   data_exfiltration (12) — the komodo-ops skill's own call shape
    #     (`curl -X POST http://komodo-core-1:9120/... -H @/etc/komodo-auth-header`);
    #     "exfiltration" is our internal control-plane API, not the internet.
    #   interpreter_suspicious_inline_exec (2) — `python -c`, the shape
    #     SOUL_OPERATING.md steers toward via execute_code.
    #   lookalike_tld (2) — go.dev in docs lookups. archive_extract (3) —
    #     worktree/build tarballs.
    # Deliberately NOT pre-approved: credential_file_sweep and
    # sensitive_env_export (reading credentials and exporting secrets should
    # stay gated), and hermes' own recursive-delete pattern (rm -rf prompts
    # stay as the safety net; "Always" is offered there).
    "tirith:trailing_dot_whitespace",
    "tirith:schemeless_to_sink",
    "tirith:data_exfiltration",
    "tirith:interpreter_suspicious_inline_exec",
    "tirith:lookalike_tld",
    "tirith:archive_extract",
]

# Dashboard plugins vendored into the image (docker/hermes/Dockerfile,
# ARG HERMES_MEMORY_UI_REF). Enablement is a config key
# (`plugins.enabled` — an opt-in allow-list; a missing key enables
# nothing). A name listed under [config_extra.plugins] that is not
# vendored would 404 its plugin-api routes forever, so fail the build
# on it — same shape as the unknown-tier and cron-script checks.
STACK_VENDORED_PLUGINS = {"hermes-memory-ui"}


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


# The gateway's own config. The model NAMES the apps send are LiteLLM
# `model_name` groups declared here, while the AGENT side (models.toml) only
# knows the tier name and its window — so this file is read at build time to
# fail loudly on the one failure that split makes possible: a profile says
# "smart" and the gateway has no "smart" group, which would 404 every turn at
# runtime. Absent file = the fork supplies its gateway elsewhere; that skips
# the check (with a warning) rather than failing it.
GATEWAY_SPEC = CONFIG / "litellm.yaml"
# A deployment's group name. The list-item form with optional quotes
# (`- model_name: smart`, `- model_name: "ollama/*"`) is the shape
# config/litellm.yaml's header documents as the contract, so a config that
# keeps to it is always understood here.
_MODEL_NAME_RE = re.compile(r"^\s*-\s*model_name:\s*['\"]?([^'\"\s]+)['\"]?\s*$")
# Hermes hard-rejects a configured window below this (MINIMUM_CONTEXT_LENGTH
# in agent/agent_init.py), so a typo would ship a config that dies at
# container start. Catch it here instead.
MIN_CONTEXT_LENGTH = 65536


def gateway_model_names() -> set[str] | None:
    """The model names the LiteLLM gateway serves, or None if it isn't here."""
    if not GATEWAY_SPEC.is_file():
        return None
    names: set[str] = set()
    for line in GATEWAY_SPEC.read_text(encoding="utf-8").splitlines():
        match = _MODEL_NAME_RE.match(line.split("#", 1)[0])
        if match:
            names.add(match.group(1))
    return names


# Config schema version used when the base image's own value can't be read
# (local preview runs, where hermes_cli isn't installed). Keep in sync with
# the HERMES_REF pin — the authoritative stamp is derived at build time.
_FALLBACK_CONFIG_VERSION = 46


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


_APPROVAL_BINARY_KEYS = ("cron_mode", "single_query_mode", "unattended_mode")


def validate_approvals(cfg: dict, where: str) -> None:
    """Fail the build on an approval posture the container will reject.

    Every value here decides whether an unattended turn can act at all, and
    a wrong one fails at request time deep inside a cron run — where nobody
    is watching — rather than at build time. The modes are a closed set in
    hermes_cli/config_defaults.py DEFAULT_CONFIG["approvals"]:
    `mode` is manual | smart | off (= --yolo), and the three unattended
    switches are deny | approve.
    """
    mode = cfg.get("mode")
    if mode not in ("manual", "smart", "off"):
        raise ConfigError(
            f"{where}: approvals.mode is {mode!r}, but the container accepts "
            f"only 'manual', 'smart' or 'off' (off = --yolo)"
        )
    for key in _APPROVAL_BINARY_KEYS:
        value = cfg.get(key)
        # Absent is fine — the image's own default then applies; only a
        # PRESENT but wrong value is a build error.
        if value is None:
            continue
        if value not in ("deny", "approve"):
            raise ConfigError(
                f"{where}: approvals.{key} is {value!r}, but the container "
                f"accepts only 'deny' or 'approve'"
            )
    deny = cfg.get("deny")
    if deny is not None:
        if not isinstance(deny, list) or any(
            not isinstance(p, str) or not p.strip() for p in deny
        ):
            raise ConfigError(
                f"{where}: approvals.deny must be a list of non-empty glob "
                f"strings — it blocks commands even under --yolo, so an "
                f"empty entry would block nothing while looking like a guard"
            )


def validate(models: dict, providers: dict, integrations: dict,
             gateway_names: set[str] | None = None) -> None:
    # `--check` returns before render_profile runs, so the stack-wide
    # posture is validated here; the per-profile merged result is validated
    # in render_profile (the image build runs the full render, so a bad
    # profile override still fails the build).
    validate_approvals(STACK_APPROVAL_DEFAULTS, "STACK_APPROVAL_DEFAULTS")
    for alias, model in models.items():
        prov = model.get("provider")
        if prov not in providers:
            raise ConfigError(
                f"model '{alias}' references unknown provider '{prov}'"
            )
        if not model.get("model"):
            raise ConfigError(f"model '{alias}' has no model id")
        window = model.get("context_length")
        if window and window < MIN_CONTEXT_LENGTH:
            raise ConfigError(
                f"model '{alias}' declares context_length {window}, below "
                f"Hermes' {MIN_CONTEXT_LENGTH} floor (MINIMUM_CONTEXT_LENGTH): "
                f"the container refuses to start on a window that small"
            )
        # Every tier must exist as a group on the gateway — that is the whole
        # contract between the two files, and the only way this indirection
        # fails is silently, at request time. A tier served by a native
        # provider instead opts out with `via_gateway = false`.
        if gateway_names is None or model.get("via_gateway") is False:
            continue
        name = model["model"]
        if name in gateway_names:
            continue
        if any(n.endswith("/*") and name.startswith(n[:-1]) for n in gateway_names):
            continue
        raise ConfigError(
            f"model '{alias}' is served as '{name}', but "
            f"{GATEWAY_SPEC.name} declares no such group. Add a "
            f"`- model_name: {name}` entry there, or set via_gateway = false "
            f"on the entry in models.toml if it is served natively instead. "
            f"Declared on the gateway: {', '.join(sorted(gateway_names))}"
        )
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
                f"in {CRON_SCRIPT_DIR} — job scripts live in docker/hermes/ "
                f"(baked to /usr/local/bin). If this is the IMAGE BUILD, the "
                f"Dockerfile must COPY docker/hermes/ next to render.py."
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


def cheap_model_block(profile: str, alias: str, models: dict) -> dict:
    """The smart_model_routing cheap-lane block Hermes reads, from a tier name.

    Same shape an explicit `[config_extra.smart_model_routing.cheap_model]`
    table renders as: the named provider plus the gateway's model name. The
    provider's base_url and key ride the `custom_providers` entry render.py
    emits for that provider name, so nothing is repeated here — which is the
    point: a profile names a TIER, and the backend stays in one file.
    """
    if alias not in models:
        raise ConfigError(
            f"profile '{profile}': smart_model_routing.cheap_model is "
            f"'{alias}', which is not a tier in config/models.toml. Known: "
            f"{', '.join(sorted(models))}"
        )
    model = models[alias]
    return {"provider": model["provider"], "model": model["model"]}


def fallback_entry(alias: str, models: dict, providers: dict) -> dict:
    """One `fallback_providers` entry for a tier, in the shape Hermes reads.

    Keys are exactly the ones `hermes_cli/fallback_config.py` resolves:
    `provider` + `model` required, `base_url` pinning the route, and
    `key_env` naming the env var that holds the credential — that last one is
    read through the active profile's secret scope (agent.secret_scope
    .get_secret), and is why this stack names a var rather than inlining an
    `api_key` into a config file.
    """
    model = models[alias]
    provider = providers[model["provider"]]
    entry = {"provider": model["provider"], "model": model["model"]}
    if provider.get("base_url"):
        entry["base_url"] = provider["base_url"]
    if provider.get("api_key_env"):
        entry["key_env"] = provider["api_key_env"]
    return entry


def build_model_overrides(models: dict) -> dict:
    """Return the `model_overrides` config block for every declared tier.

    `models.toml` states each tier's TRUE provider window as
    `context_length`; this is the same value in the shape Hermes reads:
    `model_overrides.<provider>.<model_id>.context_window`. One source, two
    consumers:

      * Hermes' own context-length resolution
        (agent/model_metadata.get_model_context_length) consults this block
        at step 0b — before any probe, catalogue lookup, or the 256K
        fallback. So the cheap lane, the auxiliary models, and any /model
        switch get the real window instead of a guess (the catalogue probe
        cannot resolve an ID through the litellm base_url, which is why
        models.toml states the windows at all).
      * The `claude` wrapper reads it back to export
        CLAUDE_CODE_MAX_CONTEXT_TOKENS. Claude Code's own model catalogue
        knows none of these tier names, so without it Claude Code assumes
        200K and auto-compacts a 1M-context session five times too early.

    Grouped by provider because that is the block's shape; every tier in
    models.toml currently rides the litellm gateway. The window belongs to
    the TIER, so it must be updated whenever litellm.yaml points that tier
    at a differently-windowed model.
    """
    overrides: dict[str, dict] = {}
    for model in models.values():
        window = model.get("context_length")
        if not window:
            continue
        overrides.setdefault(model["provider"], {})[model["model"]] = {
            "context_window": window
        }
    return overrides


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

    # plugins.enabled must name plugins the image actually vendors
    # (STACK_VENDORED_PLUGINS). Discovery is opt-in — an absent
    # `plugins` key enables nothing — so this only fires on an explicit
    # enablement naming something the dashboard could never mount.
    enabled_plugins = (config.get("plugins") or {}).get("enabled") or []
    unknown = [p for p in enabled_plugins if p not in STACK_VENDORED_PLUGINS]
    if unknown:
        raise ConfigError(
            f"profile '{name}': plugins.enabled names {', '.join(unknown)} — "
            f"not vendored in the image. Known: "
            f"{', '.join(sorted(STACK_VENDORED_PLUGINS))}. Vendor it in "
            f"docker/hermes/Dockerfile (ARG HERMES_MEMORY_UI_REF) or fix "
            f"the name."
        )

    # smart_model_routing.cheap_model may be a TIER NAME (a plain string —
    # the shape the default profile writes) rather than the {provider, model}
    # table Hermes reads. Expanding it here means a profile never repeats an
    # upstream model id, and an unknown tier is a build error rather than a
    # cheap lane that 404s on every short turn. An explicit table passes
    # through unchanged, so a profile can still point the lane at a model
    # that is not a tier.
    routing = config.get("smart_model_routing")
    if isinstance(routing, dict) and isinstance(routing.get("cheap_model"), str):
        routing["cheap_model"] = cheap_model_block(
            name, routing["cheap_model"], models
        )

    # The fallback chain: the tier a failing primary moves to. Hermes reads
    # `fallback_providers` (hermes_cli/fallback_config.get_fallback_chain),
    # consumed by the agent's provider init AND the cron setup, and tries each
    # entry in order when the primary fails with rate-limit, overload or
    # connection errors.
    #
    # Until this was emitted, a profile's `fallback_model` was validated here
    # and then silently dropped — nothing in the rendered config expressed it,
    # so every "a dead primary degrades up to X" comment described intent
    # rather than behaviour. A profile may still contribute entries of its own
    # via [config_extra] `fallback_providers`; those are tried FIRST, then the
    # declared `fallback_model` tier.
    chain = list(config.get("fallback_providers") or [])
    if fallback:
        chain.append(fallback_entry(fallback, models, providers))
    if chain:
        config["fallback_providers"] = chain

    # Per-model context windows for EVERY tier in config/models.toml, in
    # the shape Hermes reads (see build_model_overrides). Merged per
    # provider+model rather than replaced, so a profile may add or correct
    # one entry via [config_extra.model_overrides] without dropping the
    # rest of the catalogue.
    model_overrides = build_model_overrides(models)
    for provider, entries in (config.get("model_overrides") or {}).items():
        if isinstance(entries, dict):
            model_overrides.setdefault(provider, {}).update(entries)
    config["model_overrides"] = model_overrides

    # Cron: raise the bot-chat delivery cap for EVERY profile.
    #
    # A bot-chat delivery runs the target profile's agent for a FULL TURN,
    # SYNCHRONOUSLY inside the cron job's execution, under a timeout whose
    # upstream default is 600s — and on expiry that child is killed. A real
    # work turn is far longer than 600s, so the default does not merely
    # log a warning, it terminates the agent mid-task: observed live, the
    # developer agent claimed its issue at 16:19 and was killed at 16:21
    # having done nothing further.
    #
    # Stack-wide rather than per profile because the value is read by
    # whichever scheduler fires the job, which under
    # GATEWAY_MULTIPLEX_PROFILES is not necessarily the job's own profile.
    # Holding the execution open also SERIALISES the 5-minute poll against
    # a running turn — the next tick cannot stack a second wake on top of
    # work already in flight. Merged (not replaced) so a profile may still
    # override any individual key via [config_extra.cron].
    cron_cfg = dict(STACK_CRON_DEFAULTS)
    cron_cfg.update(config.get("cron") or {})
    config["cron"] = cron_cfg

    # Approval posture for EVERY profile — see STACK_APPROVAL_DEFAULTS for
    # the reasoning and for what this gives up. Merged (not replaced) so a
    # profile may raise or lower its own posture via [config_extra.approvals].
    # `deny` is a list, so a profile that sets it REPLACES the stack list
    # rather than adding to it — stated because the opposite would be the
    # natural guess.
    approvals_cfg = dict(STACK_APPROVAL_DEFAULTS)
    approvals_cfg.update(config.get("approvals") or {})
    validate_approvals(approvals_cfg, f"profile '{name}' approvals")
    config["approvals"] = approvals_cfg

    # Subagent delegation bounds for EVERY profile — see
    # STACK_DELEGATION_DEFAULTS. Merged (not replaced) so a profile may
    # still override an individual key via [config_extra.delegation].
    delegation_cfg = dict(STACK_DELEGATION_DEFAULTS)
    delegation_cfg.update(config.get("delegation") or {})
    config["delegation"] = delegation_cfg

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

    # Smart-approval aux budget for EVERY profile.
    #
    # Phase 2.5 smart approval (tools/approval.py) asks the auxiliary LLM to
    # judge a tirith/warning prompt before escalating to a human button, and
    # `auxiliary.approval.timeout` (auxiliary_client.py _get_task_timeout)
    # bounds that call at the upstream default of 30s. The call retries once,
    # so a slow upstream burns ~90s and then the gate escalates anyway
    # ("Smart approvals: LLM call failed after 93.3s ... escalating") — the
    # latency of the aux model, not its verdict, decides whether a prompt
    # reaches a human. 60s survives Ollama Cloud latency. Merged so a profile
    # may override via [config_extra.auxiliary.approval].
    aux_extra = profile.get("config_extra", {}).get("auxiliary", {}) or {}
    approval_cfg = {"timeout": 60}
    approval_cfg.update(aux_extra.get("approval") or {})
    aux_cfg = {"approval": approval_cfg}
    for key, value in aux_extra.items():
        if key != "approval":
            aux_cfg[key] = value
    config["auxiliary"] = aux_cfg

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

    # Fail the build on an @@VAR@@ placeholder the boot resolver does not
    # know. render.py cannot resolve these itself — the values (Discord
    # channel IDs) are runtime secrets in the host env file, not in git — so
    # they are emitted verbatim for docker/hermes/expand-placeholders.py to
    # fill in at container boot. An unknown name is a typo that would ship a
    # config with a literal @@VAR@@ where a channel id belongs, so it is a
    # build error rather than a boot-time surprise.
    for fname in ("config.yaml", "cron.json"):
        for var in _PLACEHOLDER_RE.findall((out_dir / fname).read_text()):
            if var not in BOOT_PLACEHOLDERS:
                raise ConfigError(
                    f"profile '{name}': unknown placeholder @@{var}@@ in {fname}. "
                    f"Known: {', '.join(sorted(BOOT_PLACEHOLDERS))} — resolved at "
                    f"boot by docker/hermes/expand-placeholders.py."
                )

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
        gateway_names = gateway_model_names()
        if gateway_names is None:
            print(f"  warning: {GATEWAY_SPEC} not found — every model tier "
                  f"goes unverified against the gateway", file=sys.stderr)
        validate(models, providers, integrations, gateway_names)

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