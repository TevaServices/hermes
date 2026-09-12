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
  copy_overlay "$OVERLAY_ROOT/default" "$HERMES_HOME"
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
    copy_overlay "$overlay" "$target"
    log "applied overlay: $name"
    reconcile_cron "$overlay" "$target"
  done
fi

exec "$@"