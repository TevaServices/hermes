#!/usr/bin/env python3
"""Check each tier's declared context window against the provider's own API.

Two files describe a model tier, and they can drift:

  * config/models.toml  — the window the AGENT side assumes
                          (`context_length`, emitted into model_overrides)
  * config/litellm.yaml — the BACKEND that actually answers for the tier

Repoint a tier at a different model in the gateway and forget the window, and
nothing fails: compaction math just runs against a wrong number (too large
overruns the provider, too small compacts early). render.py cannot catch it —
it is offline and structural. This is the check that can, so run it whenever
either file changes:

    mise run check-model-windows

It asks the PROVIDER, not a catalogue: POST ollama.com/api/show ->
model_info.*.context_length, the method AGENTS.md documents for verifying a
window by hand. Third-party catalogues disagree with it (models.dev reports a
1M window for nemotron-3-nano:30b, which the provider says is 262144), which
is exactly why this asks the provider.

Only Ollama Cloud tiers are checked — this script knows one provider's API.
Any other backend is reported as unchecked rather than silently passed.

Exit: 0 = every checkable tier matches, 1 = drift, 2 = a tier could not be
checked (provider unreachable, unknown model id, or a group whose backend
cannot be read out of litellm.yaml).

Usage: python3 scripts/check-model-windows.py [repo-root]
"""

from __future__ import annotations

import json
import re
import sys
import tomllib
import urllib.error
import urllib.request
from pathlib import Path

OLLAMA_SHOW = "https://ollama.com/api/show"
# The api_base that marks a deployment as Ollama Cloud. Anything else is a
# provider this script cannot ask.
OLLAMA_API_BASE = "https://ollama.com/v1"
# ollama.com sits behind Cloudflare, which blocks bare urllib User-Agents.
USER_AGENT = "hermes-check-model-windows/1"

# The tier-group shape config/litellm.yaml documents as its contract:
#   - model_name: smart
#     litellm_params:
#       model: openai/<provider-model-id>
#       api_base: https://ollama.com/v1
# A group is a `- model_name:` list item; its keys are the indented lines
# under it, until the next top-level key ends the block.
_GROUP_RE = re.compile(r"^\s*-\s*model_name:\s*['\"]?([^'\"\s]+)['\"]?\s*$")
_KV_RE = re.compile(r"^\s+([a-z_]+):\s*(\S+)\s*$")


def gateway_groups(path: Path) -> dict[str, dict[str, str]]:
    """{model_name: {key: value}} for every group in the gateway config."""
    groups: dict[str, dict[str, str]] = {}
    current: str | None = None
    in_params = False
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0]
        if not line.strip():
            continue
        match = _GROUP_RE.match(line)
        if match:
            current, in_params = match.group(1), False
            groups.setdefault(current, {})
            continue
        if raw[:1] not in (" ", "\t"):
            # A top-level key (model_list:, router_settings:, …) ends the
            # block, so a later indented key is never read as a deployment
            # parameter.
            in_params = False
            continue
        if line.strip() == "litellm_params:":
            in_params = True
            continue
        if in_params and current is not None:
            kv = _KV_RE.match(line)
            if kv:
                groups[current][kv.group(1)] = kv.group(2)
    return groups


def declared_windows(models_path: Path) -> dict[str, int]:
    with open(models_path, "rb") as fh:
        models = tomllib.load(fh).get("models", {})
    return {
        tier: model["context_length"]
        for tier, model in models.items()
        if model.get("context_length")
    }


def provider_window(model_id: str) -> int:
    """The context window the provider reports for *model_id*, in tokens."""
    request = urllib.request.Request(
        OLLAMA_SHOW,
        data=json.dumps({"model": model_id}).encode(),
        headers={"Content-Type": "application/json", "User-Agent": USER_AGENT},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        info = json.load(response)
    if "error" in info:
        raise LookupError(info["error"])
    windows = [
        value
        for key, value in (info.get("model_info") or {}).items()
        if key.endswith("context_length") and isinstance(value, int)
    ]
    if not windows:
        raise LookupError("the provider reported no context_length")
    return max(windows)


def main() -> int:
    root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else (
        Path(__file__).resolve().parent.parent
    )
    gateway_path = root / "config" / "litellm.yaml"
    models_path = root / "config" / "models.toml"
    for path in (gateway_path, models_path):
        if not path.is_file():
            print(f"error: {path} not found", file=sys.stderr)
            return 2

    groups = gateway_groups(gateway_path)
    declared = declared_windows(models_path)
    checked = skipped = 0
    rc = 0

    for tier in sorted(declared):
        params = groups.get(tier)
        if params is None:
            # render.py fails the build on this; report it here too, for the
            # case where the two files are edited by hand.
            print(f"MISSING  {tier}: litellm.yaml declares no such group")
            rc = 2
            continue
        model = params.get("model", "")
        if OLLAMA_API_BASE not in params.get("api_base", ""):
            print(f"skipped  {tier}: backend is '{model or '?'}', not Ollama "
                  f"Cloud — this script cannot ask it")
            skipped += 1
            continue
        if not model.startswith("openai/"):
            print(f"UNREADABLE {tier}: cannot read a model id from "
                  f"litellm_params.model='{model}'")
            rc = 2
            continue
        model_id = model.split("/", 1)[1]

        try:
            actual = provider_window(model_id)
        except (urllib.error.URLError, TimeoutError, LookupError, OSError) as exc:
            print(f"UNCHECKED {tier}: {model_id} — {exc}")
            rc = rc or 2
            continue

        checked += 1
        if actual != declared[tier]:
            print(f"MISMATCH {tier}: models.toml says {declared[tier]}, "
                  f"{model_id} reports {actual}")
            rc = 1
        else:
            print(f"ok       {tier}: {model_id} = {actual}")

    print(f"\n{checked} tier(s) verified against the provider"
          + (f", {skipped} skipped" if skipped else ""))
    return rc


if __name__ == "__main__":
    sys.exit(main())
