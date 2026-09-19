# Hermes agent image — thin over the OFFICIAL upstream image.
#
# The official nousresearch/hermes-agent image (published per upstream
# release, multi-arch incl. arm64) ships the s6-overlay supervision tree:
# per-profile gateways register as s6 services (gateway-<name> slots),
# crash-restart under s6-supervise, and reconcile across container
# restarts. That supervision is what makes the docs' "one container
# hosting all profiles" deployment model work. Build on upstream instead
# of re-implementing it; upstream bump = change HERMES_REF (build arg /
# compose / mise env).
#
# What we add on top (kept minimal — each COPY/RUN is a separate final
# layer so config-only pushes invalidate only the last one):
#   0. A source patch to upstream tools/approval_detection.py — see
#      docker/hermes/patches/ and AGENTS.md §"Security tuning (guard
#      friction)". Placed FIRST so a config-only push still cache-hits
#      it, and so a rebase of the patch invalidates everything after.
#   1. gh CLI (pinned tarball) + the GitHub App token helper + git
#      credential helper — the agent manages its own infra over git/gh.
#   2. The declarative config sources (config/, render.py) rendered at
#      BUILD time into /overlay — profiles ship as image layers, replacing
#      the old committed-build/ approach. The overlay COPY is the final
#      layer: a config-only push invalidates exactly that layer → new
#      image ID → deploy recreates the container (the config restart
#      path is preserved).
#   3. A two-script entrypoint: bootstrap-profiles.sh applies each
#      rendered overlay into its Hermes profile dir (default →
#      $HERMES_HOME, others → $HERMES_HOME/profiles/<name>/) and
#      provisions missing profiles; entrypoint.sh adds the GitHub App
#      wiring upstream doesn't know about, then execs the upstream
#      dispatcher so s6 takes over.
#
ARG HERMES_REF=v2026.9.14
FROM nousresearch/hermes-agent:${HERMES_REF}

# ── Source patches over upstream ──────────────────────────────────────
# docker/hermes/patches/*.patch are applied to /opt/hermes at build time.
# Each must be re-anchored at every HERMES_REF bump, and DELETED once
# upstream adopts the fix (the build says so — see below).
#
# FOUR patches currently.
#
# 4. plugins/platforms/discord/adapter.py — self-heal voice after Discord
# externally terminates the session. Discord kicks voice sessions
# server-side ("We were externally disconnected from voice" — discord.py
# logs the reason at DEBUG only, so at INFO the only trace is "The voice
# handshake is being terminated"): the receiver dies with the session, the
# bot goes deaf AND mute while its voice-mode state still says on, and the
# next auto voice reply silently degrades to a file attachment (observed
# live 2026-09-14: a joined session was externally disconnected ~6 minutes
# in, seconds before the reply landed). The patch (a) logs the external
# disconnect at INFO, (b) rejoins when the binding is still active and an
# allowed user is present in voice (on the disconnect event with teardown
# grace, when a user (re)joins while we hold a dead binding, and on demand
# from play_tts before falling back to an attachment).
#
# 3. gateway/platforms/base.py — build_auto_tts_output_path() must not
# point /tmp when HERMES_WRITE_SAFE_ROOT is set. This stack sets
# HERMES_WRITE_SAFE_ROOT=/opt/data (Dockerfile below), and the TTS tool
# hard-rejects any output_path outside the safe root with
# "output_path targets a protected credential or system path" — a silent
# JSON failure, no exception, no log line. Upstream's auto-TTS path
# builder hardcodes tempfile.gettempdir()/hermes_voice/, so on this image
# EVERY automatic voice reply (Discord voice-channel speech, voice-input
# auto-TTS) failed before synthesis: the bot joined the VC, transcribed
# speech fine, but never spoke (observed live 2026-09-14). The patch
# redirects to the TTS tool's default dir (HERMES_HOME/cache/audio,
# under the safe root) only when /tmp is outside the configured safe
# roots; stock behavior (no HERMES_WRITE_SAFE_ROOT) is byte-identical.
#
# 2. cron/scheduler_delivery.py — bot-chat delivery must POINT
# HERMES_HOME at the target profile before spawning
# `hermes -p <name> chat`. Upstream drops it (the code moved here from
# cron/scheduler.py at v2026.9.14; upstream fixed the no-profile
# multiplex branch in the same move but kept the drop for -p). Dropping
# is right when HERMES_HOME points AT a profile (it would
# shadow -p) but wrong when it is the ROOT holding profiles/, as here
# (/opt/data holds profiles/<name>): the child falls back to the native
# ~/.hermes, so every delivery died with "Profile '<name>' does not
# exist" and no cron job could wake a named profile at all. Simply KEEPING
# the root is no better — the child's home then points at the DEFAULT
# profile, so anything resolving credentials from the home rather than
# from -p (`hermes send`'s get_hermes_home()/.env, the GitHub App env)
# acts as the default profile; observed live as the main bot posting a
# developer status line into #dev, and the child inheriting a sibling
# profile's GITHUB_APP_ID. The patch sets it to get_profile_dir(profile),
# so -p and the home agree and every .env lookup is profile-scoped.
#
# 1. tools/approval_detection.py (the grep-operand scanner lived in
#    tools/approval.py until v2026.9.14 moved it): `grep` inside a quoted
# `$(...)` command substitution makes the
# grep-operand scanner surface an inner word it then can't tokenize
# (unbalanced quote) -> hardline-blocks the entire command, even though
# the block is unconditional (not bypassable by --yolo, /yolo,
# approvals.mode, or command_allowlist) and reports ~150-byte commands
# as "command parser limit or malformed executable payload". That shape
# is exactly the scripting this stack asks its agents for, so it was
# blocking the behaviour we want. The patch skips an unparseable operand
# instead of failing the command; it is fail-closed, because skipping
# only declines to MASK text as data (and the hardline path discards the
# masked variant anyway, using only the malformed flag).
#
# `git apply` rather than `patch` (the base image has no patch binary);
# it works outside a git repo, which matters because .dockerignore drops
# .git. Three outcomes, deliberately:
#   * applies        -> normal path.
#   * already applied-> upstream adopted the fix: NOTICE + continue, so
#                       the image still builds and the operator removes
#                       the patch file.
#   * neither        -> upstream refactored the code: FAIL the build
#                       loudly rather than ship an unpatched image.
COPY docker/hermes/patches/ /tmp/hermes-patches/
RUN set -e; cd /opt/hermes; \
    for p in /tmp/hermes-patches/*.patch; do \
      [ -e "$p" ] || continue; \
      base="$(basename "$p")"; \
      if git apply --check -p1 "$p" 2>/dev/null; then \
        git apply -p1 "$p"; \
        echo "applied $base"; \
      elif git apply --check -R -p1 "$p" 2>/dev/null; then \
        echo "NOTICE: $base is ALREADY APPLIED upstream — upstream has"; \
        echo "        adopted this fix; delete docker/hermes/patches/$base"; \
      else \
        echo "ERROR: $base neither applies nor is applied — upstream"; \
        echo "       moved the code. Re-anchor the patch, or delete it"; \
        echo "       if upstream fixed the issue."; \
        exit 1; \
      fi; \
    done; \
    rm -rf /tmp/hermes-patches

# gh CLI (pinned tarball for the build host's architecture — this image
# is only ever built on the homelab host): the agent's github-* skills
# (github-issues,
# github-pr-workflow, github-repo-management, github-code-review) work
# through gh when present. Auth is the GitHub App (entrypoint) — gh
# never needs `auth login` state persisted; a fresh installation token
# is minted per git op by the credential helper.
ARG GH_VERSION=2.100.0
RUN curl -fsSL --retry 3 \
      https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_arm64.tar.gz \
      -o /tmp/gh.tgz \
 && tar -xzf /tmp/gh.tgz -C /tmp \
 && install -m 0755 /tmp/gh_${GH_VERSION}_linux_arm64/bin/gh /usr/local/bin/gh \
 && rm -rf /tmp/gh*

# Stack helpers (each a separate layer so script-only pushes stay cheap).
COPY docker/hermes/github-app-token.sh /usr/local/bin/github-app-token.sh
COPY docker/hermes/bootstrap-profiles.sh /usr/local/bin/hermes-bootstrap-profiles.sh
COPY docker/hermes/git-repo.sh /usr/local/bin/git-repo.sh
COPY docker/hermes/team-queue.sh /usr/local/bin/team-queue.sh
COPY docker/hermes/review-queue.sh /usr/local/bin/review-queue.sh
# Cron job scripts are ALSO seeded per profile at boot
# (cron-reconcile.py) — the scheduler requires a job's script to live
# under <HERMES_HOME>/scripts/, so /usr/local/bin is the image-side
# source of truth for script CONTENT and config/cron.toml for its
# schedule.
COPY docker/hermes/cron-reconcile.py /usr/local/bin/cron-reconcile.py
COPY docker/hermes/team-thread.sh /usr/local/bin/team-thread.sh
COPY docker/hermes/prune-repos.sh /usr/local/bin/prune-repos.sh
COPY docker/hermes/refresh-repos.sh /usr/local/bin/refresh-repos.sh
# claude-update.sh also lands here (not only in /opt/claude-hermes/) so
# the reconciler can seed it as the default profile's daily job script.
COPY docker/hermes/claude-update.sh /usr/local/bin/claude-update.sh
RUN chmod 0755 /usr/local/bin/github-app-token.sh \
               /usr/local/bin/hermes-bootstrap-profiles.sh \
               /usr/local/bin/git-repo.sh \
               /usr/local/bin/team-queue.sh \
               /usr/local/bin/review-queue.sh \
               /usr/local/bin/team-thread.sh \
               /usr/local/bin/cron-reconcile.py \
               /usr/local/bin/prune-repos.sh \
               /usr/local/bin/refresh-repos.sh \
               /usr/local/bin/claude-update.sh

# Headless Chromium for the browser tools (browser-harness / browser_exec).
# The base image already bakes the Playwright Chromium headless shell
# (PLAYWRIGHT_BROWSERS_PATH) but nothing runs it on a headless server, so
# browser tool calls died with "chrome-not-running". Expose it at a stable
# path; the supervised chromium-cdp service below serves CDP on
# 127.0.0.1:9333 (enabled per-deploy via HERMES_CHROMIUM_CDP, like the
# dashboard service).
# Playwright >= 1.62 (v2026.9.x base) changed the baked layout:
#   old: chromium_headless_shell-1234/chrome-linux/headless_shell
#   new: chromium_headless_shell-1243/chrome-headless-shell-linux-<arch>/chrome-headless-shell
# Match both shapes; the newest wins.
RUN SHELL="$( { ls -d /opt/hermes/.playwright/chromium_headless_shell-*/chrome-linux/headless_shell 2>/dev/null; \
                 ls -d /opt/hermes/.playwright/chromium_headless_shell-*/chrome-headless-shell-linux-*/chrome-headless-shell 2>/dev/null; \
               } | sort -V | tail -1)" \
 && test -n "$SHELL" && test -x "$SHELL" \
 && ln -sf "$SHELL" /usr/local/bin/chromium-headless-shell

# Claude Code wrapper tooling (coding-agent delegation on the profile's
# own model via the LiteLLM gateway). Staged under /opt/claude-hermes
# (image layer, read-only at runtime) — /opt/data is volume-shadowed so
# it CANNOT be pre-baked; the provisioner copies these onto the volume at
# boot and installs the claude-real CLI there too (persistent, so the
# CLI itself is NOT baked into the image). The claude-update cron keeps
# it current. See the hermes-stack-ops skill for the full contract.
COPY docker/hermes/claude /opt/claude-hermes/claude
COPY docker/hermes/claude-model-resolve.py /opt/claude-hermes/claude-model-resolve.py
COPY docker/hermes/claude-env.sh /opt/claude-hermes/claude-env.sh
COPY docker/hermes/claude-shell-functions.sh /opt/claude-hermes/claude-shell-functions.sh
COPY docker/hermes/claude-provision.sh /opt/claude-hermes/claude-provision.sh
COPY docker/hermes/claude-update.sh /opt/claude-hermes/claude-update.sh
RUN chmod 0755 /opt/claude-hermes/claude \
               /opt/claude-hermes/claude-model-resolve.py \
               /opt/claude-hermes/claude-provision.sh \
               /opt/claude-hermes/claude-update.sh

# Declarative config: sources + renderer, compiled at BUILD time (no
# committed build/ artifacts in git — the renderer IS the verification).
# python3 is the image's own interpreter; render.py is stdlib-only.
COPY render.py /tmp/render.py
COPY config/ /tmp/config/
# render.py resolves ROOT from its own location, which here is /tmp — so
# the job scripts it validates (config/cron.toml -> CRON_SCRIPT_DIR =
# ROOT/docker/hermes) must exist at /tmp/docker/hermes too, or every
# declared cron job looks like it references a missing script and the
# build fails. Copied only for the render step; removed below.
COPY docker/hermes/ /tmp/docker/hermes/
# Render every profile into /overlay, then arrange the runtime layout:
#   /overlay/default/          — the root ("default") profile overlay.
#                                The repo's primary profile is named
#                                "main"; it maps 1:1 onto the root.
#   /overlay/profiles/<name>/  — one overlay per named profile
# A profile literally named "default" in config/ would already land
# correctly at /overlay/default (the mv is skipped, the loop skips it).
RUN python3 /tmp/render.py --build-root /overlay \
 && if [ -d /overlay/main ]; then mv /overlay/main /overlay/default; fi \
 && mkdir -p /overlay/profiles \
 && for d in /overlay/*/; do \
      b="$(basename "$d")"; \
      case "$b" in default|profiles) continue ;; esac; \
      mv "$d" "/overlay/profiles/$b"; \
    done \
 && rm -rf /tmp/render.py /tmp/config /tmp/docker

COPY docker/hermes/entrypoint.sh /usr/local/bin/hermes-stack-entrypoint.sh
RUN chmod 0755 /usr/local/bin/hermes-stack-entrypoint.sh

# Supervised headless Chromium (CDP sidecar for the browser tools) —
# mirrors the dashboard service: always declared, gated by
# HERMES_CHROMIUM_CDP in run/finish so the slot reports down when off.
COPY docker/hermes/s6-rc.d/chromium-cdp/ /etc/s6-overlay/s6-rc.d/chromium-cdp/
RUN chmod 0755 /etc/s6-overlay/s6-rc.d/chromium-cdp/run \
               /etc/s6-overlay/s6-rc.d/chromium-cdp/finish \
 && touch /etc/s6-overlay/s6-rc.d/user/contents.d/chromium-cdp

ENTRYPOINT ["/usr/local/bin/hermes-stack-entrypoint.sh"]
# `gateway run` is the legacy-run argv the boot reconciler recognizes: on
# first boot it seeds the default profile's gateway_state as running and
# the s6 reconciler starts gateway-default (one supervised gateway for
# the root profile; named profiles start from their own recorded state).
# Inside the s6 container `gateway run` also self-upgrades: it registers
# the gateway-default slot, then keeps the CMD alive as a `sleep
# infinity` heartbeat while s6-supervise runs the real gateway.
CMD ["gateway", "run"]