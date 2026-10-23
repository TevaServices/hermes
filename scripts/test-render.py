#!/usr/bin/env python3
"""Offline tests for what render.py emits per profile.

WHY THIS EXISTS

Two rendered surfaces here were both silently wrong in the same way — a
setting that reads correct and reaches nothing — and both cost real
behaviour before anyone noticed. These cases pin the loud half.

AUX LANES (`auxiliary.<task>`). Hermes routes its auxiliary side tasks
(compression, title generation, memory-query rewrite, vision, ...) through
one resolver whose model comes from `auxiliary.<task>.{provider, model}` in
config.yaml — `auto` meaning "the profile's primary model". This repo pinned
four of those lanes through `AUXILIARY_*_MODEL` env vars for months; the
image reads no such var for any of those tasks, so every lane silently
inherited the primary and the docs described a routing that was not
happening. The pins now live in STACK_AUX_MODELS and are rendered per
profile:

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

HONCHO PLUGIN CONFIG (`honcho.json`). Every value there is a recall
behaviour the plugin's own defaults got wrong on this stack, measured from
the plugin source and the running system (AGENTS.md §"Honcho memory"): the
30s default HTTP timeout discarded recall that takes 90-270s, a 5-round
reasoning level was being spent on a 600-char-capped supplement, no user
peer was pinned so cron/Bot-Chat turns had no identity and stored nothing
(327 of 504 memory blocks ever injected were the "memory is off" notice),
and the injection audit log was off, so none of it left a trace. Also pinned
here: the peer id travels as a boot placeholder rather than a literal in
this public repo, and the boot expander actually covers honcho.json.

Run from the repo root: python3 scripts/test-render.py  (needs 3.11+
for tomllib; `mise run test` provides it). No Docker, no network.
"""
from __future__ import annotations

import json
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

# The base image's own aux task set (probed from DEFAULT_CONFIG['auxiliary']
# under the image venv). Pinned here so a HERMES_REF bump that adds/drops a
# task is caught offline: v0.22.5 gained free_only, openrouter_model,
# stream_only_base_urls, transient_retries and lost kanban_estimator.
check("known tasks match the image's aux task set",
      sorted(render.KNOWN_AUX_TASKS),
      sorted({"approval", "background_review", "compression", "curator",
              "free_only", "goal_judge", "kanban_decomposer", "mcp",
              "memory_query_rewrite", "moa_aggregator", "moa_reference",
              "monitor", "openrouter_model", "profile_describer", "review",
              "skills_hub", "stream_only_base_urls", "title_generation",
              "transient_retries", "triage_specifier", "tts_audio_tags",
              "vision", "voice_chat"}))

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
check("vision renders on the smarter tier (the one image-capable tier — "
      "smart moved to Beam, text-only, 2026-10-17)",
      rendered["vision"], {"provider": "litellm", "model": "smarter"})
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
# A 256K-window primary may run a 256K compression lane (the case of a
# package profile choosing the "smart" tier: `smart` primary, `smarter`
# compression — wider is always allowed — but NOT narrower).
smart_profile = {"model": "smart", "integrations": ["honcho"], "platforms": [],
                 "config_extra": {}}
try:
    render.render_profile("auxprobe", smart_profile, DEFAULT_DIR,
                          models, providers, integrations)
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
# 6. the Honcho plugin config (honcho.json)
# ---------------------------------------------------------------------------
print("# 6. honcho.json")
renders()  # (re)render the default profile into the scratch root
honcho = json.loads(Path(_scratch.name, "auxprobe", "honcho.json").read_text())

# The peer pin: without it a cron/Bot-Chat turn resolves no user identity and
# Honcho memory is simply off for that session.
check("the user peer is pinned", honcho.get("pinUserPeer"), True)
check("the peer id is a boot placeholder, not a literal",
      honcho.get("peerName"), "@@HONCHO_USER_PEER@@")
check("the peer placeholder is declared, so the boot expander knows it",
      "HONCHO_USER_PEER" in render.BOOT_PLACEHOLDERS, True)
# The plugin's 30s default discarded recall that takes 90-270s on this stack.
check("the HTTP timeout exceeds the plugin default (30s)",
      honcho.get("timeout", 0) > 30, True)
# A 5-round reasoning level on a char-capped, every-turn supplement bought
# latency the cap then threw away.
check("auto-injection reasoning is bounded to minimal",
      (honcho.get("dialecticReasoningLevel"), honcho.get("reasoningLevelCap")),
      ("minimal", "minimal"))
check("the injection cap is raised from the 600 default",
      honcho.get("dialecticMaxChars", 0) > 600, True)
check("the injection audit log is on", honcho.get("logging"), True)

# The placeholder must actually be expanded at boot: honcho.json is copied to
# the profile home by bootstrap-profiles.sh, so the expander has to cover it
# or the literal @@VAR@@ would ship into the plugin's config.
bootstrap = Path(ROOT, "docker/hermes/bootstrap-profiles.sh").read_text()
expand_loop = bootstrap.split("expand_overlay()", 1)[1].split("}", 1)[0]
check("bootstrap expands placeholders in honcho.json",
      "honcho.json" in expand_loop, True)

# ---------------------------------------------------------------------------
# 7. the [discord] table (the dead-drop package's channel declaration)
# ---------------------------------------------------------------------------
print("# 7. the [discord] table")


def discord_profile(block_extra: dict) -> dict:
    """A minimal profile carrying the given [discord] block."""
    prof = {"model": "smart", "integrations": [], "platforms": ["discord"],
            "config_extra": {}}
    prof.update(block_extra)
    return prof


def discord_channel(prof, extra=None):
    render.render_profile("discprobe", prof, DEFAULT_DIR, models, providers,
                          integrations, extra_placeholders=extra)
    text = Path(_scratch.name, "discprobe", "config.yaml").read_text()
    return text

# the fence is generated in the NESTED platforms.discord.extra form, with
# the channel placeholder passed through verbatim (boot expansion owns it;
# the placeholder must be DECLARED — here via extra_placeholders, in real
# renders collected from the package sources)
prof = discord_profile({"discord": {"channel": "@@DISCORD_CHANNEL_X@@",
                                    "require_mention": False}})
body = discord_channel(prof, {"DISCORD_CHANNEL_X"})
check("the [discord] fence lands in the nested extra block",
      "allowed_channels: [\"@@DISCORD_CHANNEL_X@@\"]" in body, True)
check("require_mention rides the generated block", "require_mention: false" in body, True)

# a hand-written extra block PLUS [discord] is two sources of truth
conflicting = discord_profile({
    "discord": {"channel": "@@DISCORD_CHANNEL_X@@"},
    "config_extra": {"platforms": {"discord": {"extra":
                          {"allowed_channels": ["1"]}}}},
})
check_raises("a hand-written fence conflicts with [discord]",
             lambda: discord_channel(conflicting))
check_raises("[discord] without the platform declared is an error",
             lambda: discord_channel({
                 "model": "smart", "integrations": [], "platforms": [],
                 "config_extra": {},
                 "discord": {"channel": "@@X@@"}}))
check_raises("an unknown [discord] key is an error",
             lambda: discord_channel({
                 "model": "smart", "integrations": [], "platforms": ["discord"],
                 "config_extra": {}, "discord": {"channel": "@@X@@",
                                                 "channels": ["1"]}}))

# the generated route entries: default profile re-render with routes
def default_with(routes, extra=None):
    render.render_profile("default", default_profile, DEFAULT_DIR, models,
                          providers, integrations, discord_routes=routes,
                          extra_placeholders=extra)
    return Path(_scratch.name, "default", "config.yaml").read_text()

# In a real boot render main()/the drop renderer collect the package
# placeholders; the test passes them alongside.
body = default_with(
    [("planner", "@@DISCORD_CHANNEL_PLANNER@@")],
    {"DISCORD_CHANNEL_PLANNER", "DISCORD_CHANNEL_DEVELOPER",
     "DISCORD_CHANNEL_REVIEWER", "DISCORD_CHANNEL_RELEASE"})
EXTRA = {"DISCORD_CHANNEL_PLANNER", "DISCORD_CHANNEL_DEVELOPER",
         "DISCORD_CHANNEL_REVIEWER", "DISCORD_CHANNEL_RELEASE"}
body = default_with([("planner", "@@DISCORD_CHANNEL_PLANNER@@")], EXTRA)
check("routes land namespaced ext_<profile>",
      "ext_planner:" in body and "profile: planner" in body, True)
check("the route carries the chat_id placeholder",
      "chat_id: \"@@DISCORD_CHANNEL_PLANNER@@\"" in body, True)
# replace semantics: a vanished package must lose its route
body = default_with([], EXTRA)
check("ext_ routes are replaced as a set (empty set = none left)",
      "ext_planner:" in body, False)
# a hand-written route key using the renderer's namespace is an error
def conflicting_key_profile():
    prof = dict(default_profile)
    prof["config_extra"] = dict(default_profile.get("config_extra") or {})
    prof["config_extra"]["gateway"] = {
        "profile_routes": {"ext_planner": {"platform": "discord",
                                           "chat_id": "1",
                                           "profile": "planner"}}}
    return prof

check_raises("a hand-written route key in the ext_ namespace is an error",
             lambda: render.render_profile(
                 "default", conflicting_key_profile(),
                 DEFAULT_DIR, models, providers, integrations,
                 discord_routes=[("planner", "@@V@@")]))
# the default profile itself cannot declare [discord]
def default_with_discord():
    prof = dict(default_profile)
    prof["discord"] = {"channel": "@@V@@"}
    prof["platforms"] = list(default_profile.get("platforms") or []) + ["discord"]
    return render.render_profile(
        "default", prof, DEFAULT_DIR, models, providers, integrations)

check_raises("the default profile cannot declare [discord]",
             default_with_discord)

# ---------------------------------------------------------------------------
# 8. package-declared boot placeholders
# ---------------------------------------------------------------------------
print("# 8. package-declared placeholders")
pkg_profile = discord_profile({"env": {"MY_TOOL_TOKEN": ""},
                               "discord": {"channel": "@@MY_CHANNEL_ID@@"}})
declared = render.collect_profile_placeholders(pkg_profile)
check("a package's @@VAR@@ is collectable from its source",
      "MY_CHANNEL_ID" in declared, True)
# the render accepts the declared name beside the stack-owned set
render.render_profile("discprobe", pkg_profile, DEFAULT_DIR, models,
                      providers, integrations,
                      extra_placeholders={"MY_CHANNEL_ID"})
ok("a declared package placeholder renders (boot expander's job)")
# undeclared -> the old typo guard
check_raises("an undeclared @@VAR@@ remains a build error",
             lambda: render.render_profile(
                 "discprobe",
                 discord_profile({"discord": {"channel": "@@UNDECLARED_XYZ@@"}}),
                 DEFAULT_DIR, models, providers, integrations,
                 extra_placeholders={"MY_CHANNEL_ID"}))

# a package re-declaring a STACK-owned placeholder is an error
check_raises("re-declaring a stack-owned placeholder fails",
             lambda: render.render_profile(
                 "discprobe",
                 discord_profile({"discord": {"channel": "@@HONCHO_USER_PEER@@"}}),
                 DEFAULT_DIR, models, providers, integrations,
                 extra_placeholders={"HONCHO_USER_PEER"}))

# ---------------------------------------------------------------------------
# 9. the cron spec carries shared_scripts for package script seeding
# ---------------------------------------------------------------------------
print("# 9. cron spec shared_scripts")
scratch = tempfile.mkdtemp(prefix="test-render-cron-")
spec = Path(scratch, "cron.toml")
spec.write_text('shared_scripts = ["sibling.sh", "baked.sh"]\n'
                '[[jobs]]\nprofile = "p1"\nname = "j"\nschedule = "*/5 * * * *"\n'
                'script = "baked.sh"\nno_agent = true\n')
Path(scratch, "baked.sh").write_text("#!/bin/sh\n")
Path(scratch, "sibling.sh").write_text("#!/bin/sh\n")
jobs, shared = render.load_cron_jobs(spec, {"p1"}, [scratch])
check("shared scripts pass through", sorted(shared) == ["baked.sh", "sibling.sh"], True)
check("jobs render", [j["name"] for j in jobs["p1"]] == ["j"], True)
(render.BUILD / "p1").mkdir(parents=True, exist_ok=True)
render.render_profile("p1", {"model": "smart"}, DEFAULT_DIR, models,
                      providers, integrations, cron_jobs=jobs["p1"],
                      cron_shared=shared)
doc = json.loads((render.BUILD / "p1" / "cron.json").read_text())
check("cron.json carries shared_scripts", doc.get("shared_scripts"),
      ["baked.sh", "sibling.sh"])
check("cron.json carries the job", [j["name"] for j in doc["jobs"]], ["j"])
spec2 = Path(scratch, "bad.toml")
spec2.write_text('shared_scripts = ["missing.sh"]\n[[jobs]]\nprofile = "p1"\n'
                 'name = "j"\nschedule = "*/5 * * * *"\nscript = "baked.sh"\n')
check_raises("a shared script that exists nowhere is a build error",
             lambda: render.load_cron_jobs(spec2, {"p1"}, [scratch]))

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------
_scratch.cleanup()
import shutil  # noqa: E402
shutil.rmtree(scratch, ignore_errors=True)
print()
if fail_count == 0:
    print(f"{pass_count} passed")
    sys.exit(0)
print(f"{fail_count} FAILED, {pass_count} passed", file=sys.stderr)
sys.exit(1)
