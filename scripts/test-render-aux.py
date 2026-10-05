#!/usr/bin/env python3
"""Offline tests for the aux-lane rendering rules in render.py.

WHY THIS EXISTS

Hermes routes its auxiliary side tasks (compression, title generation,
memory-query rewrite, vision, ...) through one resolver whose model comes from
`auxiliary.<task>.{provider, model}` in config.yaml — `auto` meaning "the
profile's primary model". This repo pinned four of those lanes through
`AUXILIARY_*_MODEL` env vars for months; the image reads no such var for any
of those tasks, so every lane silently inherited the primary and the docs
described a routing that was not happening. The repair moved the pins into
STACK_AUX_MODELS, rendered per profile — and a rendered pin can fail in
exactly the same silent way, so these cases pin the loud half:

  1. THE DECLARATION. Every task in STACK_AUX_MODELS is a task the image has
     (KNOWN_AUX_TASKS), and every tier it names exists in models.toml.
  2. THE RENDERED SHAPE. A real profile renders compression/title_generation/
     memory_query_rewrite as {provider, model} blocks naming a TIER (never an
     upstream id), so the gateway name and the declared window both resolve.
  3. THE TYPO GUARD. An unknown `auxiliary.<task>` key is a build error, not
     a knob that does nothing.
  4. THE WINDOW RULE. Compression summarises up to 80% of the PROFILE's
     window, so a compression lane narrower than the primary — set by the
     stack default or by a profile override — fails the build. This is the
     case a check on the stack default alone would miss, which is why the
     check runs on the merged block.
  5. THE OVERRIDES. A profile may set a bare tier name, or a table merged over
     the declared block ({model = "cheap"} alone keeps the provider).

Run from the repo root: python3 scripts/test-render-aux.py  (needs 3.11+
for tomllib; `mise run test` provides it). No Docker, no network.
"""
from __future__ import annotations

import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
import render  # noqa: E402  (import after the path fix-up)

pass_count = 0
fail_count = 0


def ok(what: str) -> None:
    global pass_count
    pass_count += 1
    print(f"ok   {what}")


def bad(what: str) -> None:
    global fail_count
    fail_count += 1
    print(f"FAIL {what}")


def check(what: str, got, want) -> None:
    if got == want:
        ok(what)
    else:
        bad(f"{what} (want [{want!r}], got [{got!r}])")


def check_raises(what: str, fn) -> None:
    """A build error is the PASS for these — silence is the failure mode."""
    try:
        fn()
    except render.ConfigError:
        ok(what)
    else:
        bad(f"{what} (no ConfigError raised — the fault would ship)")


models = render.load_toml(render.CONFIG / "models.toml")["models"]
providers = render.load_toml(render.CONFIG / "providers.toml")["providers"]
integrations = render.load_toml(render.CONFIG / "integrations.toml")["integrations"]
DEFAULT_DIR = render.CONFIG / "profiles" / "default"
default_profile = render.load_toml(DEFAULT_DIR / "profile.toml")

# Render into a throwaway root: render_profile writes files, and the repo's
# own build/ must not be touched by a test run.
_scratch = tempfile.TemporaryDirectory(prefix="test-render-aux-")
render.set_build_root(_scratch.name)


def renders(overrides: dict | None = None, profile: dict | None = None) -> dict:
    """Render the default profile (with optional auxiliary overrides) and
    return the rendered `auxiliary` block."""
    prof = dict(profile or default_profile)
    prof["config_extra"] = dict(prof.get("config_extra") or {})
    if overrides is not None:
        prof["config_extra"]["auxiliary"] = overrides
    render.render_profile("auxprobe", prof, DEFAULT_DIR, models, providers, integrations)
    text = Path(_scratch.name, "auxprobe", "config.yaml").read_text()
    block = text.split("auxiliary:", 1)[1].split("\nskills:", 1)[0]
    # Tiny hand-parse: the block is 2-space-nested key/value lines only.
    out: dict = {}
    task = None
    for line in block.splitlines()[1:]:
        if line.startswith("  ") and not line.startswith("    ") and line.strip():
            task = line.strip().rstrip(":")
            out[task] = {}
        elif line.startswith("    ") and task and ":" in line:
            key, _, value = line.strip().partition(":")
            out[task][key] = value.strip()
    return out


def with_aux(overrides: dict):
    return lambda: renders(overrides)


# ---------------------------------------------------------------------------
# 1. the declaration is internally consistent
# ---------------------------------------------------------------------------
print("# 1. the declaration")
for task, alias in render.STACK_AUX_MODELS.items():
    if task not in render.KNOWN_AUX_TASKS:
        bad(f"declared task '{task}' is not in KNOWN_AUX_TASKS")
        break
else:
    ok("every declared task is a task the image has (KNOWN_AUX_TASKS)")

for task, alias in render.STACK_AUX_MODELS.items():
    render.aux_model_block("STACK_AUX_MODELS", task, alias, models)
ok("every declared task names a tier that exists in models.toml")

check("known tasks match the image's aux task set",
      sorted(render.KNOWN_AUX_TASKS),
      sorted({"approval", "background_review", "compression", "curator",
              "goal_judge", "kanban_decomposer", "kanban_estimator", "mcp",
              "memory_query_rewrite", "moa_aggregator", "moa_reference",
              "monitor", "profile_describer", "review", "skills_hub",
              "title_generation", "triage_specifier", "tts_audio_tags",
              "vision"}))

# ---------------------------------------------------------------------------
# 2. the rendered shape
# ---------------------------------------------------------------------------
print("# 2. the rendered shape")
rendered = renders()
check("compression renders on the smarter tier", rendered["compression"],
      {"provider": "litellm", "model": "smarter"})
check("title_generation renders on the cheap tier", rendered["title_generation"],
      {"provider": "litellm", "model": "cheap"})
check("memory_query_rewrite renders on the cheap tier",
      rendered["memory_query_rewrite"], {"provider": "litellm", "model": "cheap"})
check("approval keeps its timeout", rendered["approval"], {"timeout": "60"})
check("vision is left unpinned (it must land on an image-capable model)",
      "vision" in rendered, False)
# A lane pinned to an upstream id would lose its declared window (the reason
# models.toml states windows per TIER).
check("every pin names a gateway tier, not an upstream id",
      all(v["model"] in models for v in rendered.values() if "model" in v), True)

# ---------------------------------------------------------------------------
# 3. the typo guard
# ---------------------------------------------------------------------------
print("# 3. the typo guard")
check_raises("an unknown aux task key is a build error",
             lambda: render.validate_aux({"compresion": {"model": "cheap"}},
                                         models, "test"))
check_raises("a task pinned to a non-tier is a build error",
             lambda: render.aux_model_block("test", "compression", "gpt-4o", models))
check_raises("a non-table task config is a build error",
             lambda: render.validate_aux({"compression": "cheap"}, models, "test"))

# ---------------------------------------------------------------------------
# 4. the compression window rule
# ---------------------------------------------------------------------------
print("# 4. the compression window rule")
check("tier_window_for_block reads the tier's declared window",
      render.tier_window_for_block({"provider": "litellm", "model": "smarter"}, models),
      1048576)
check("tier_window_for_block returns None for an undeclared model",
      render.tier_window_for_block({"provider": "litellm", "model": "nope"}, models),
      None)
# The default profile's primary is `smarter` (1M): a narrower compression lane
# would be handed more context than it can hold.
check_raises("a profile override narrowing compression below the primary fails",
             with_aux({"compression": {"model": "cheap"}}))
check_raises("compression pointing at an undeclared model fails",
             with_aux({"compression": {"provider": "litellm",
                                       "model": "glm-5.3-raw-id"}}))
# A 256K-window primary may run a 256K compression lane (the planner's case:
# `smart` primary, `smarter` compression — wider is always allowed).
planner_dir = render.CONFIG / "profiles" / "planner"
planner = render.load_toml(planner_dir / "profile.toml")
try:
    render.render_profile("auxprobe", planner, planner_dir, models, providers, integrations)
    ok("a 256K-window profile keeps the 1M compression lane")
except render.ConfigError as exc:
    bad(f"a 256K-window profile keeps the 1M compression lane ({exc})")

# ---------------------------------------------------------------------------
# 5. the overrides
# ---------------------------------------------------------------------------
print("# 5. the overrides")
overridden = renders({"title_generation": "smart"})
check("a bare tier name override expands", overridden["title_generation"],
      {"provider": "litellm", "model": "smart"})
partial = renders({"title_generation": {"model": "smarter"}})
check("a {model} override keeps the declared provider", partial["title_generation"],
      {"provider": "litellm", "model": "smarter"})
added = renders({"skills_hub": {"provider": "litellm", "model": "cheap"}})
check("a profile may add a task the stack does not pin", added["skills_hub"],
      {"provider": "litellm", "model": "cheap"})
check_raises("a non-table, non-string override is a build error",
             with_aux({"title_generation": 3}))

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------
_scratch.cleanup()
print()
if fail_count == 0:
    print(f"{pass_count} passed")
    sys.exit(0)
print(f"{fail_count} FAILED, {pass_count} passed", file=sys.stderr)
sys.exit(1)
