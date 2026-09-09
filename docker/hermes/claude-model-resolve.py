#!/usr/bin/env python3
"""Print the Hermes profile's configured models as tab-separated fields.

Reads the RENDERED Hermes config (source of truth baked from the git repo):
  field 1: model provider (e.g. litellm)
  field 2: primary model id as the gateway expects it (e.g. ollama/glm-5.3-flash)
  field 3: cheap/secondary model id (smart_model_routing.cheap_model)

Pure stdlib — no PyYAML dependency. Path: $CLAUDE_HERMES_CONFIG or
/opt/data/config.yaml.
"""
import os
import re
import sys

SECTION_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):\s*$")
MODEL_kv_RE = re.compile(r"^\s{2}(provider|default):\s*['\"]?([^'\"]+?)['\"]?\s*$")
CHEAP_BLOCK_RE = re.compile(r"^\s{2}cheap_model:\s*$")
CHEAP_MODEL_RE = re.compile(r"^\s{4}model:\s*['\"]?([^'\"]+?)['\"]?\s*$")


def parse(text: str):
    provider = default = cheap = None
    section = sub = None
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
                else:
                    default = m.group(2)
        elif section == "smart_model_routing":
            if CHEAP_BLOCK_RE.match(line):
                sub = "cheap"
                continue
            if sub == "cheap":
                m = CHEAP_MODEL_RE.match(line)
                if m:
                    cheap = m.group(1)
    return provider, default, cheap


def main() -> int:
    cfg_path = (
        sys.argv[1]
        or os.environ.get("CLAUDE_HERMES_CONFIG")
        or "/opt/data/config.yaml"
    )
    try:
        with open(cfg_path) as f:
            text = f.read()
    except OSError as exc:
        print(f"claude-model-resolve: cannot read {cfg_path}: {exc}", file=sys.stderr)
        return 1

    provider, default, cheap = parse(text)
    if not default:
        print(f"claude-model-resolve: no model.default found in {cfg_path}", file=sys.stderr)
        return 1

    print(f"{provider or 'litellm'}\t{default}\t{cheap or default}")
    return 0


if __name__ == "__main__":
    sys.exit(main())