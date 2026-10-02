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

Only Ollama Cloud tiers are checked against the provider's own API — this
script knows one provider's show endpoint; any other backend is reported as
unchecked rather than silently passed. A second pass checks the ROUTER
FALLBACKS (config/litellm.yaml router_settings.fallbacks) against OpenRouter's
public catalog: every fallback's window must be >= its tier's declared window
and the id must support tools — the two properties the fallback contract
depends on (a smaller-windowed fallback silently breaks long-context work; a
non-tools fallback cannot serve an agent turn), checked because a drift here
degrades exactly during an outage, when nothing else would notice.

Exit: 0 = every checkable tier and fallback matches, 1 = drift, 2 = a tier
could not be checked (provider unreachable, unknown model id, or a group
whose backend cannot be read out of litellm.yaml).

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
# OpenRouter's public model catalog — the provider that serves the router
# fallbacks; no key needed for a read.
OPENROUTER_CATALOG = "https://openrouter.ai/api/v1/models"
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
# A router-fallback line inside the router_settings block:
#   - cheap: ["openrouter/nvidia/nemotron-3-nano-30b-a3b"]
# One fallback LIST per line, a plain JSON array value — the literal shape
# config/litellm.yaml documents as its contract.
_FALLBACK_LINE_RE = re.compile(r"^\s*-\s*(\S+):\s*(\[.*\])\s*$")


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


def fallback_map(gateway_path: Path) -> dict[str, list[str]]:
    """{tier: [fallback model names]} from the gateway's router_settings
    block."""
    fallbacks: dict[str, list[str]] = {}
    in_router_settings = False
    for raw in gateway_path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0]
        if not line.strip():
            continue
        if raw[:1] not in (" ", "\t"):
            in_router_settings = line.startswith("router_settings")
            continue
        if in_router_settings:
            match = _FALLBACK_LINE_RE.match(line)
            if match:
                fallbacks[match.group(1)] = json.loads(match.group(2))
    return fallbacks


def openrouter_window(model_name: str, catalog: dict[str, dict]) -> int | None:
    """The context window the OpenRouter catalog reports for the model, and
    (caller-side) its supported_parameters — None if absent from it."""
    entry = catalog.get(model_name)
    if entry is None:
        return None
    return entry.get("context_length")


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

    # ── The router-fallback pass. The contract being enforced: every
    #    fallback is servable by the gateway (render.py fails the build on
    #    a missing group), its window is >= the tier's declared window, and
    #    it supports tools. A drift degrades exactly during an outage,
    #    which is the one moment nothing else would notice.
    fallbacks = fallback_map(gateway_path)
    catalog: dict[str, dict] = {}
    catalog_unreachable: Exception | None = None
    if fallbacks:
        try:
            request = urllib.request.Request(
                OPENROUTER_CATALOG, headers={"User-Agent": USER_AGENT}
            )
            with urllib.request.urlopen(request, timeout=30) as response:
                payload = json.load(response)
            catalog = {m["id"]: m for m in payload.get("data", [])}
        except (urllib.error.URLError, TimeoutError, OSError, LookupError) as exc:
            catalog_unreachable = exc

    fallback_checked = 0
    for tier in sorted(fallbacks):
        declared_window = declared.get(tier)
        if declared_window is None:
            print(f"MISSING  {tier}: router fallback names a tier with no "
                  f"context_length in models.toml")
            rc = 2
            continue
        for name in fallbacks[tier]:
            label = f"{tier} → {name}"
            if name not in groups:
                print(f"MISSING  {label}: litellm.yaml declares no such group")
                rc = 2
                continue
            if catalog_unreachable is not None:
                print(f"UNCHECKED {label}: OpenRouter catalog unreachable — "
                      f"{catalog_unreachable}")
                rc = 2
                continue
            entry = catalog.get(name.removeprefix("openrouter/"))
            if entry is None:
                print(f"UNCHECKED {label}: not in OpenRouter's catalog — "
                      f"the id has been renamed or retired")
                rc = 2
                continue
            supported = set(entry.get("supported_parameters") or [])
            context_length = entry.get("context_length") or 0
            fallback_checked += 1
            if context_length < declared_window:
                print(f"MISMATCH {label}: window {context_length} < "
                      f"tier's declared {declared_window}")
                rc = 1
            elif "tools" not in supported:
                print(f"MISMATCH {label}: catalog reports no tools support")
                rc = 1
            else:
                print(f"ok       {label}: window {context_length} >= "
                      f" declared {declared_window}, tools")

    lines = [f"\n{checked} tier(s) verified against the provider"]
    if skipped:
        lines.append(f", {skipped} skipped")
    if fallbacks:
        lines.append(f"; {fallback_checked} fallback(s) verified against "
                     f"OpenRouter's catalog")
    print("".join(lines))
    return rc


if __name__ == "__main__":
    sys.exit(main())
