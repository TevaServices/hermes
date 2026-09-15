#!/usr/bin/env python3
"""Print the Hermes profile's configured models as tab-separated fields.

Reads the RENDERED Hermes config (source of truth baked from the git repo):
  field 1: model provider (e.g. litellm)
  field 2: primary model id as the gateway expects it (e.g. ollama/glm-5.3-flash)
  field 3: cheap/secondary model id (smart_model_routing.cheap_model)

With --window <model-id> it instead prints that model's declared context
window as a bare integer (exit 1 if the config declares none). The window
comes from the `model_overrides` block render.py emits out of
config/models.toml's `context_length` — the provider's TRUE window, which
models.toml states explicitly because Hermes' own catalogue probe cannot
resolve an ID through the litellm base_url. The `claude` wrapper uses it
for CLAUDE_CODE_MAX_CONTEXT_TOKENS: Claude Code knows none of these
`ollama/*` ids, so it assumes a 200K window and auto-compacts far too
early without it.

Pure stdlib — no PyYAML dependency. Path: $CLAUDE_HERMES_CONFIG or
/opt/data/config.yaml.
"""
import os
import re
import sys

SECTION_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):\s*$")
MODEL_kv_RE = re.compile(
    r"^\s{2}(provider|default|context_length):\s*['\"]?([^'\"]+?)['\"]?\s*$"
)
CHEAP_BLOCK_RE = re.compile(r"^\s{2}cheap_model:\s*$")
CHEAP_MODEL_RE = re.compile(r"^\s{4}model:\s*['\"]?([^'\"]+?)['\"]?\s*$")
# model_overrides: <provider> / <model id> / context_window — two levels
# deeper than anything else we parse. Model ids carry "/" and ":" (e.g.
# ollama/nemotron-3-nano:30b); plain unquoted keys are valid YAML for both,
# but strip quotes anyway so a quoted emit can never break the lookup.
OVR_PROVIDER_RE = re.compile(r"^\s{2}([A-Za-z0-9_.:@/-]+):\s*$")
OVR_MODEL_RE = re.compile(r"^\s{4}(\S+):\s*$")
OVR_WINDOW_RE = re.compile(r"^\s{6}context_window:\s*(\d+)\s*$")


def parse(text: str):
    """Return (provider, default, cheap, default_window, overrides).

    `overrides` maps model id -> context window, flattened across
    providers (a model id is unique in practice, and the callers only ever
    have an id to look up). The model block's own `context_length` is
    returned separately as the fallback for the default model, so the
    resolver still answers on a config rendered before model_overrides
    existed.
    """
    provider = default = cheap = default_window = None
    overrides: dict[str, int] = {}
    section = sub = ovr_provider = ovr_model = None
    for line in text.splitlines():
        m = SECTION_RE.match(line)
        if m:
            section, sub = m.group(1), None
            continue
        if section == "model":
            m = MODEL_kv_RE.match(line)
            if m:
                if m.group(1) == "provider":
                    provider = m.group(2)
                elif m.group(1) == "default":
                    default = m.group(2)
                elif m.group(2).isdigit():
                    default_window = int(m.group(2))
        elif section == "smart_model_routing":
            if CHEAP_BLOCK_RE.match(line):
                sub = "cheap"
                continue
            if sub == "cheap":
                m = CHEAP_MODEL_RE.match(line)
                if m:
                    cheap = m.group(1)
        elif section == "model_overrides":
            m = OVR_PROVIDER_RE.match(line)
            if m:
                ovr_provider, ovr_model = m.group(1), None
                continue
            m = OVR_MODEL_RE.match(line)
            if m and ovr_provider:
                ovr_model = m.group(1).strip("'\"")
                continue
            m = OVR_WINDOW_RE.match(line)
            if m and ovr_model:
                overrides[ovr_model] = int(m.group(1))
    return provider, default, cheap, default_window, overrides


def resolve_window(model_id, default, default_window, overrides):
    """Return the declared context window for *model_id*, or None.

    Mirrors Hermes' own `_explicit_model_override` matching
    (agent/models_dev.py): exact id first, then case-insensitively. None
    means "not declared" — the caller must leave the window UNSET rather
    than guess: compacting earlier than necessary is safe, claiming a
    window the provider does not have is not.
    """
    if model_id in overrides:
        return overrides[model_id]
    wanted = model_id.lower()
    for known, window in overrides.items():
        if known.lower() == wanted:
            return window
    if default and default_window and model_id == default:
        return default_window
    return None


def main() -> int:
    argv = sys.argv[1:]
    want = None
    if argv and argv[0] == "--window":
        if len(argv) < 2:
            print("claude-model-resolve: --window needs a model id", file=sys.stderr)
            return 2
        want, argv = argv[1], argv[2:]

    cfg_path = (
        (argv[0] if argv else None)
        or os.environ.get("CLAUDE_HERMES_CONFIG")
        or "/opt/data/config.yaml"
    )
    try:
        with open(cfg_path) as f:
            text = f.read()
    except OSError as exc:
        print(f"claude-model-resolve: cannot read {cfg_path}: {exc}", file=sys.stderr)
        return 1

    provider, default, cheap, default_window, overrides = parse(text)

    if want is not None:
        window = resolve_window(want, default, default_window, overrides)
        if window is None:
            print(
                f"claude-model-resolve: {cfg_path} declares no context window "
                f"for '{want}'",
                file=sys.stderr,
            )
            return 1
        print(window)
        return 0

    if not default:
        print(f"claude-model-resolve: no model.default found in {cfg_path}", file=sys.stderr)
        return 1

    print(f"{provider or 'litellm'}\t{default}\t{cheap or default}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
