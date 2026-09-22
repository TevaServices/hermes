#!/bin/sh
# Apply the rendered profile overlay(s) into their Hermes profile dirs,
# then exec the CMD. Runs inside the container at boot, before s6 starts
# the services.
#
# The rendered overlays are baked into the image at /overlay (see the
# Dockerfile: render.py runs at build time, output COPYed to
# /overlay/<profile>). Layout:
#   /overlay/default/           -> $HERMES_HOME           (default profile)
#   /overlay/profiles/<name>/   -> $HERMES_HOME/profiles/<name>/
#
# Overlay apply = merge, NOT replace: config.yaml / SOUL.md / honcho.json
# are overwritten (git-managed), skills/ are merged over (agent-authored
# skills survive), and .env.example is only seeded when absent. Runtime
# state (.env, memories/, sessions/, gateway_state.json after first
# provisioning) is never touched here.
#
# This script is built INTO the image; the same file lives in the repo
# at docker/hermes/bootstrap-profiles.sh.
set -eu

HERMES_HOME="${HERMES_HOME:-/opt/data}"
OVERLAY_ROOT="${HERMES_OVERLAY_ROOT:-/overlay}"

log() { echo "[bootstrap-profiles] $*"; }

# Resolve @@VAR@@ placeholders in the rendered overlays from the container
# environment, BEFORE anything reads them. render.py runs at image build time
# and cannot see runtime secrets, so per-deployment values (Discord channel
# IDs) are rendered as placeholders and resolved here, at boot, where the
# env_file values are present. Runs on the overlay in place: both
# copy_overlay (config.yaml) and reconcile_cron (cron.json) read from there.
# Missing vars expand to empty and are reported — see expand-placeholders.py.
expand_overlay() {
  overlay_dir="$1"
  files=""
  for f in config.yaml cron.json; do
    [ -f "$overlay_dir/$f" ] && files="$files $overlay_dir/$f"
  done
  [ -n "$files" ] || return 0
  if [ ! -f /usr/local/bin/expand-placeholders.py ]; then
    log "WARNING: expand-placeholders.py missing; @@VAR@@ left in $overlay_dir"
    return 0
  fi
  # shellcheck disable=SC2086  # deliberate word-splitting of the file list
  python3 /usr/local/bin/expand-placeholders.py $files 2>&1 | while read -r line; do
    log "$line"
  done
}

copy_overlay() {
  overlay="$1"
  target="$2"
  mkdir -p "$target"
  for f in config.yaml SOUL.md honcho.json; do
    if [ -f "$overlay/$f" ]; then
      cp -f "$overlay/$f" "$target/$f"
    fi
  done
  # Documentation for the human (real keys arrive via the env_file); never
  # overwrite a file the operator may have edited.
  if [ -f "$overlay/.env.example" ] && [ ! -f "$target/.env.example" ]; then
    cp "$overlay/.env.example" "$target/.env.example"
  fi
  if [ -d "$overlay/skills" ]; then
    # Merge: overlay skills overwrite same-named ones; existing others
    # (including skills the agent created itself) are kept.
    mkdir -p "$target/skills"
    cp -a "$overlay/skills/." "$target/skills/"
  fi
}

# Vendored dashboard plugins (stack-wide, /overlay/plugins/<name> at the
# overlay ROOT — see the Dockerfile): seeded into EVERY home,
# exact-replace. The image is the source of truth for plugin CONTENT, so
# a runtime `hermes plugins update` (or a hand-edit) is overwritten on
# the next boot; enablement is NOT done here — it is the
# `plugins.enabled` list in the home's config.yaml, which copy_overlay
# overwrites from the overlay too. Both knobs are git-side; see
# AGENTS.md §"Dashboard + the memory-UI plugin".
seed_plugins() {
  # Distinct variable names on purpose: this script's functions share one
  # global namespace (no `local` in POSIX sh), and seed_plugins is called
  # INSIDE the named-profile loop, whose `overlay` / `target` / `name`
  # globals must survive it.
  seed_root="$1"
  seed_target="$2"
  if [ -d "$seed_root/plugins" ]; then
    for seed_plugin in "$seed_root/plugins"/*; do
      [ -d "$seed_plugin" ] || continue
      seed_name="$(basename "$seed_plugin")"
      # Exact replace, not merge: a plugin upgrade must not leave stale
      # files (e.g. a dist asset removed upstream) behind in the home.
      rm -rf "$seed_target/plugins/$seed_name"
      mkdir -p "$seed_target/plugins"
      cp -a "$seed_plugin" "$seed_target/plugins/$seed_name"
    done
  fi
}

# Reconcile the profile's GitOps-declared cron jobs (rendered from
# config/cron.toml into the overlay as cron.json). NOT a copy: a profile's
# cron store is runtime state (run history, failure streaks, notepads), so
# the reconciler drives the `hermes cron` CLI to create/edit in place and
# leaves everything else alone. It also seeds the job scripts into
# <profile>/scripts/, which is where the scheduler requires them — a
# no_agent job whose script is missing is "unrunnable" and gets
# auto-paused at the first tick.
#
# Failures here are reported but never fatal: a profile with a broken
# cron declaration must still boot and serve its gateway.
reconcile_cron() {
  overlay="$1"
  target="$2"
  spec="$overlay/cron.json"
  name="$(basename "$target")"
  [ "$target" = "$HERMES_HOME" ] && name="default"
  if [ ! -f "$spec" ]; then
    return 0
  fi
  if [ ! -f /usr/local/bin/cron-reconcile.py ]; then
    log "cron-reconcile.py missing from the image; skipped cron for '$name'"
    return 0
  fi
  if python3 /usr/local/bin/cron-reconcile.py \
       --home "$target" --spec "$spec" --prune; then
    log "reconciled cron for '$name'"
  else
    log "WARNING: cron reconcile reported problems for '$name' (see above)"
  fi
}

# Default profile lives at the root of HERMES_HOME.
if [ -d "$OVERLAY_ROOT/default" ]; then
  expand_overlay "$OVERLAY_ROOT/default"
  copy_overlay "$OVERLAY_ROOT/default" "$HERMES_HOME"
  # Stack-wide vendored plugins live at the OVERLAY ROOT, not under
  # default/ — seed from there, into this home.
  seed_plugins "$OVERLAY_ROOT" "$HERMES_HOME"
  log "applied overlay: default"
  reconcile_cron "$OVERLAY_ROOT/default" "$HERMES_HOME"
fi

# Named profiles live under $HERMES_HOME/profiles/<name>/. A profile is
# provisioned on first boot: create the dir + a seed SOUL (the container
# boot reconciler uses SOUL.md as the "real profile" marker), record
# desired gateway state = running so the s6 reconciler auto-starts it.
if [ -d "$OVERLAY_ROOT/profiles" ]; then
  for overlay in "$OVERLAY_ROOT/profiles"/*; do
    [ -d "$overlay" ] || continue
    name="$(basename "$overlay")"
    [ "$name" = "default" ] && continue
    target="$HERMES_HOME/profiles/$name"
    if [ ! -d "$target" ]; then
      log "provisioning profile '$name' (first boot)"
      mkdir -p "$HERMES_HOME/profiles" "$target"
      printf 'You are %s, a Hermes agent profile deployed from the <owner>/hermes GitOps repo.\n' \
        "$name" > "$target/SOUL.md"
      printf '{"gateway_state": "running", "desired_state": "running", "timestamp": %s, "seeded_by": "bootstrap-profiles"}\n' \
        "$(date +%s)" > "$target/gateway_state.json"
    fi
    expand_overlay "$overlay"
    copy_overlay "$overlay" "$target"
    seed_plugins "$OVERLAY_ROOT" "$target"
    log "applied overlay: $name"
    reconcile_cron "$overlay" "$target"
  done
fi

exec "$@"