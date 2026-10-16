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
#   4. The hermes-memory-ui dashboard plugin (xraysight/hermes-memory-ui),
#      cloned at build time from a pinned commit and vendored into the
#      overlay's plugins/ — shipped DISABLED (enablement is the
#      plugins.enabled config key, not this copy); see AGENTS.md
#      §"Dashboard + the memory-UI plugin".
#   5. A readability fix over the base image's baked PM tool store —
#      see the RUN below §"Base-image tool-store readability" (not a
#      source patch: upstream's build artifact, fixed in a thin layer).
#
ARG HERMES_REF=v0.22.0
FROM nousresearch/hermes-agent:${HERMES_REF}

# ── Source patches over upstream ──────────────────────────────────────
# docker/hermes/patches/*.patch are applied to /opt/hermes at build time.
# Each must be re-anchored at every HERMES_REF bump, and DELETED once
# upstream adopts the fix (the build says so — see below).
#
# FOUR patches currently.
#
# 4. cron/scheduler_delivery.py — a cron wake must start a FRESH session, not
# resume the profile's canonical "Bot Chat". The delivery hardcodes
# `-c "Bot Chat" --create-if-missing`, so every wake a profile ever took
# landed in ONE transcript that only grew, and every later wake replayed all
# of it (observed live 2026-10-04: a profile's Bot Chat held 700+ messages /
# ~150k tokens of history and the release lane paid for it on every
# 5-minute wake). These jobs are work items, not a conversation, so the
# patch titles each wake uniquely (`Bot Chat - <job> - <run id>`), which makes
# --create-if-missing mint a fresh session. Interactive chat is untouched:
# a Discord thread keeps its own persistent session (a different session
# store entirely), and the live-owner lane above the CLI fallback is
# unchanged. The canonical Bot Chat is no longer written by cron at all.
# (`grep -n '"Bot Chat"' on that file finds the one literal this anchors.)
#
# 3. plugins/platforms/discord/adapter.py — self-heal voice after Discord
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
# 2. gateway/platforms/base.py — build_auto_tts_output_path() must not
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

# ── Base-image tool-store readability ────────────────────────────────
# The official image bakes PM's sealed tool store at /opt/hermes/tools
# (PM's INSTALLATION_COMPLETE payloads: chromium-1208, npm-*, node, …),
# and the bake behind v2026.9.24 carries entries the runtime user cannot
# read — observed 2026-10-15, chromium-1208/chrome-linux/extensions
# shipped as mode 700 root:root (the store copy landed with this
# morning's rebuild; prior bakes came out 755). The boot-time PM sync
# stages that store into each new dependency generation's workspace as
# uid 10000 (pm copytree into installs/<sha>/environments/<uuid>/…), so
# ONE unreadable entry fails the whole staging with EACCES and — under
# the entrypoint's deliberate continue-on-failure — the sync NEVER
# publishes: the honcho memory provider's honcho-ai (vendored plugin
# deps resolved by that same sync) never installs, and both failure
# signatures show the identical EACCES triple (pmsync FAILED on every
# boot; honcho_* tools erroring "Honcho session could not be
# initialized" + web_search/web_extract keyless rescue dying, all with
# [Errno 13] on extensions). First symptom pair 2026-10-15 with the
# #74/#76/#77 rebuild.
#
# Fix at the right layer: make what lacks other-read/traverse readable
# (chmod a+rX on entries not already o+r). Self-limiting — with a
# readable store the layer copies up nothing and is a no-op, and once
# upstream bakes a readable store this RUN can be deleted entirely
# (probe after each HERMES_REF bump with:
# `find /opt/hermes/tools ! -perm -o+r | head` inside the new image).
# Deliberately not a patches/ diff: changing file MODES of a baked
# payload is not a source change, and this needs no re-anchoring.
#
# NOTE (2026-10-16): this build-time chmod alone proved INSUFFICIENT — the
# chromium-cdp s6 service was running chrome as root, which creates an
# empty root-owned mode-700 `extensions/` probe dir inside the store next
# to its own binary at EVERY boot, re-poisoning the store after this chmod
# ran. The service now drops to the runtime user (s6-setuidgid hermes —
# see s6-rc.d/chromium-cdp/run and AGENTS.md §"Stack particulars"); keep
# that drop if this layer is ever deleted.
RUN set -e; find /opt/hermes/tools -xdev ! -perm -o+r -exec chmod a+rX {} +; \
    remaining=$(find /opt/hermes/tools ! -perm -o+r | wc -l); \
    [ "$remaining" = 0 ] || { echo "unreadable store entries remain: $remaining" >&2; exit 1; }

# gh CLI (pinned tarball): the agent's github-* skills (github-issues,
# github-pr-workflow, github-repo-management, github-code-review) work
# through gh when present. Auth is the GitHub App (entrypoint) — gh
# never needs `auth login` state persisted; a fresh installation token
# is minted per git op by the credential helper.
#
# TARGETARCH is Docker's own build-arg (amd64 / arm64), so the image builds
# on either architecture with no host assumptions. gh's release names use
# the same two words. (The claude-* scripts do the equivalent at runtime
# with `uname -m`.)
ARG GH_VERSION=2.100.0
ARG TARGETARCH
RUN case "${TARGETARCH}" in \
      amd64|arm64) ;; \
      *) echo "unsupported TARGETARCH '${TARGETARCH}'" >&2; exit 1 ;; \
    esac \
 && curl -fsSL --retry 3 \
      "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${TARGETARCH}.tar.gz" \
      -o /tmp/gh.tgz \
 && tar -xzf /tmp/gh.tgz -C /tmp \
 && install -m 0755 "/tmp/gh_${GH_VERSION}_linux_${TARGETARCH}/bin/gh" /usr/local/bin/gh-real \
 && rm -rf /tmp/gh*

# gh is installed as gh-real: /usr/local/bin/gh is the STACK SHIM
# (docker/hermes/gh), which picks the personal vs org App installation
# token per invocation (see that script). Anything that must bypass the
# shim calls gh-real directly. The shim is COPY'd with the other stack
# helpers below.

# Vendored dashboard plugin: xraysight/hermes-memory-ui. Cloned at BUILD
# time from a pinned full commit SHA (tags are mutable; a full SHA is
# not) and installed into /overlay/plugins/ later, after the render —
# bootstrap-profiles.sh then seeds it into every profile home at boot.
# This is CONTENT only: the plugin ships DISABLED, enablement is the
# `plugins.enabled` config key (render.py fails the build on a name that
# is not vendored here). See AGENTS.md §"Dashboard + the memory-UI
# plugin" for the enable/upgrade procedures.
#
# Integrity: git's object model makes the checkout exactly the pinned
# commit's content — the rev-parse assertion IS the checksum (a tarball
# sha256 would add nothing but a per-bump chore). The `version:` grep
# cross-checks that the pinned commit is the release we think it is.
#
# If a build host ever rejects `fetch <sha>` (needs allowAnySHA1InWant,
# which github.com grants), fall back to
# `git clone --depth 1 --branch <tag>` + the same rev-parse assertion.
# Desktop half deliberately stripped: no desktop app in this stack
# (re-add desktop/ to the vendored set if that changes).
ARG HERMES_MEMORY_UI_REF=97cc937e49517dbd9e55cf10717da55d9024c29c  # tag v0.6.2
RUN set -e \
 && git clone --quiet --no-checkout \
      https://github.com/xraysight/hermes-memory-ui /tmp/hermes-memory-ui \
 && git -C /tmp/hermes-memory-ui fetch --quiet --depth 1 origin "$HERMES_MEMORY_UI_REF" \
 && git -C /tmp/hermes-memory-ui checkout --quiet --detach FETCH_HEAD \
 && test "$(git -C /tmp/hermes-memory-ui rev-parse HEAD)" = "$HERMES_MEMORY_UI_REF" \
 && grep -q '^version: 0\.6\.2$' /tmp/hermes-memory-ui/plugin.yaml \
 && rm -rf /tmp/hermes-memory-ui/.git /tmp/hermes-memory-ui/.github \
            /tmp/hermes-memory-ui/tests /tmp/hermes-memory-ui/desktop \
            /tmp/hermes-memory-ui/docs

# Vendored memory-provider plugin: honcho (plastic-labs/honcho, subdir
# hermes-plugin-honcho). v0.22.0 removed the bundled plugins/memory/honcho —
# the provider moved to the plugin catalog (plugin-catalog/honcho.yaml) — but
# this stack renders memory.provider: honcho into EVERY profile, and the
# runtime auto-migration would resolve that by cloning the catalog entry from
# the network at first agent start, per profile home: nondeterministic
# provisioning a GitOps stack cannot rely on. So vendor it like the dashboard
# plugin above: catalog-pinned SHA, extracted from the monorepo subdir, staged
# for the overlay layer below. Integrity: same object-model argument as the
# clone above, plus the version grep. The plugin ships ENABLED BY SELECTION
# (memory.provider); no plugins.enabled entry is needed — PM's plugin discovery
# adds the active memory provider's dir to the dependency union itself, and its
# Python deps (honcho-ai, httpx — declared in the plugin's pyproject.toml) are
# resolved by the boot-time PM sync (entrypoint section 1d).
# Desktop/API-server extras in the repo stay unextracted (docs/ only).
ARG HERMES_HONCHO_REF=e2d2aba182862deeb846e5cd4a30a41bce0ed82a  # plugin-catalog pin, plugin version 1.0.0
RUN set -e \
 && git clone --quiet --no-checkout \
      https://github.com/plastic-labs/honcho /tmp/honcho-src \
 && git -C /tmp/honcho-src fetch --quiet --depth 1 origin "$HERMES_HONCHO_REF" \
 && git -C /tmp/honcho-src checkout --quiet --detach FETCH_HEAD \
 && test "$(git -C /tmp/honcho-src rev-parse HEAD)" = "$HERMES_HONCHO_REF" \
 && grep -q '^version: 1\.0\.0$' /tmp/honcho-src/hermes-plugin-honcho/plugin.yaml \
 && cp -a /tmp/honcho-src/hermes-plugin-honcho /tmp/honcho-plugin \
 && rm -rf /tmp/honcho-plugin/docs /tmp/honcho-src

# Stack helpers (each a separate layer so script-only pushes stay cheap).
COPY docker/hermes/github-app-token.sh /usr/local/bin/github-app-token.sh
COPY docker/hermes/bootstrap-profiles.sh /usr/local/bin/hermes-bootstrap-profiles.sh
COPY docker/hermes/git-repo.sh /usr/local/bin/git-repo.sh
COPY docker/hermes/cron-reconcile.py /usr/local/bin/cron-reconcile.py
# Resolves @@VAR@@ in the rendered overlays at boot (render.py runs at
# build time and cannot see runtime secrets — see bootstrap-profiles.sh).
COPY docker/hermes/expand-placeholders.py /usr/local/bin/expand-placeholders.py
# Renders dead-drop profile packages (the host's profile-source path) into
# the overlay at boot, with the baked stack config sources — external
# packages from other repos appear/change/vanish with no rebuild.
# team-session.py (the one-session-per-item gate) and team-thread.sh
# (work-item threads) are the stack-baked primitives the shared
# SOUL_OPERATING.md and team-conventions skill reference; the delivery-lane
# queues (team/review/release-queue.sh) travel with the team package.
COPY docker/hermes/team-thread.sh /usr/local/bin/team-thread.sh
COPY docker/hermes/team-session.py /usr/local/bin/team-session.py
COPY docker/hermes/prune-repos.sh /usr/local/bin/prune-repos.sh
COPY docker/hermes/refresh-repos.sh /usr/local/bin/refresh-repos.sh
# The developer's publish path, replacing `git push`. A repo can require
# signed commits, and a GitHub App's commits only carry a signature when
# GitHub creates them server-side through the API; this replays the branch
# as API-created commits so they verify (see the file's own header).
COPY docker/hermes/git-publish.py /usr/local/bin/git-publish.py
# claude-update.sh also lands here (not only in /opt/claude-hermes/) so
# the reconciler can seed it as the default profile's daily job script.
COPY docker/hermes/claude-update.sh /usr/local/bin/claude-update.sh
# Org GitHub App plumbing: the gh shim (real binary is gh-real above),
# the org token minter/cache, and the git credential router.
COPY docker/hermes/gh /usr/local/bin/gh
COPY docker/hermes/gh-org-token /usr/local/bin/gh-org-token
COPY docker/hermes/git-credential-hermes.sh /usr/local/bin/git-credential-hermes.sh
# Git hooks. Not /usr/local/bin helpers: the entrypoint points every
# tool-home's global core.hooksPath here, so they apply to every repo AND
# every worktree a profile commits in (a worktree cannot carry its own
# hooks). prepare-commit-msg adds the DCO sign-off only where the repo
# declares the rule and can never fail a commit; pre-push REFUSES a git
# push from a bot identity (publishing is git-publish.py) — see each
# file's own header.
COPY docker/hermes/git-hooks/ /opt/hermes-git-hooks/
RUN chmod 0755 /opt/hermes-git-hooks/prepare-commit-msg \
               /opt/hermes-git-hooks/pre-push

RUN chmod 0755 /usr/local/bin/github-app-token.sh \
               /usr/local/bin/hermes-bootstrap-profiles.sh \
               /usr/local/bin/git-repo.sh \
               /usr/local/bin/team-thread.sh \
               /usr/local/bin/team-session.py \
               /usr/local/bin/cron-reconcile.py \
               /usr/local/bin/expand-placeholders.py \
               /usr/local/bin/prune-repos.sh \
               /usr/local/bin/refresh-repos.sh \
               /usr/local/bin/git-publish.py \
               /usr/local/bin/claude-update.sh \
               /usr/local/bin/gh \
               /usr/local/bin/gh-org-token \
               /usr/local/bin/git-credential-hermes.sh

# Headless Chromium for the browser tools (browser-harness / browser_exec).
# The base image already bakes the Playwright Chromium headless shell
# (PLAYWRIGHT_BROWSERS_PATH) but nothing runs it on a headless server, so
# browser tool calls died with "chrome-not-running". Expose it at a stable
# path; the supervised chromium-cdp service below serves CDP on
# 127.0.0.1:9333 (enabled per-deploy via HERMES_CHROMIUM_CDP, like the
# dashboard service).
# Three bases, three browser shapes (the newest wins):
#   v0.22.0+:  pm's pinned full Chromium staged into HERMES_RUNTIME_DIR — the
#     build already resolved the executable and baked its ABSOLUTE path to
#     /etc/hermes/agent-browser-executable-path (upstream Dockerfile; layout
#     per arch: chrome-linux64/chrome on amd64, chromium-linux-arm64/... on
#     arm64). The old PLAYWRIGHT_BROWSERS_PATH layout is GONE in this base.
#   v2026.9.x: chromium_headless_shell-1243/chrome-headless-shell-linux-<arch>/chrome-headless-shell
#   older:     chromium_headless_shell-1234/chrome-linux/headless_shell
RUN if [ -s /etc/hermes/agent-browser-executable-path ] && [ -x "$(cat /etc/hermes/agent-browser-executable-path)" ]; then \
      ln -sf "$(cat /etc/hermes/agent-browser-executable-path)" /usr/local/bin/chromium-headless-shell; \
    else \
      SHELL="$( { ls -d /opt/hermes/.playwright/chromium_headless_shell-*/chrome-linux/headless_shell 2>/dev/null; \
                  ls -d /opt/hermes/.playwright/chromium_headless_shell-*/chrome-headless-shell-linux-*/chrome-headless-shell 2>/dev/null; \
                } | sort -V | tail -1)" \
      && test -n "$SHELL" && test -x "$SHELL" \
      && ln -sf "$SHELL" /usr/local/bin/chromium-headless-shell; \
    fi

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
# The sources stay in the image at /opt/hermes-stack-config: the ENTRYPOINT
# boot renderer (docker/hermes/render-drop-profiles.py) re-renders the
# default overlay's generated routes and renders EXTERNAL profile packages
# with the same sources at container boot. A config-only push invalidates
# this layer onward — cheap, and the boot re-render is deterministic.
COPY render.py /opt/hermes-stack-config/render.py
COPY config/ /opt/hermes-stack-config/config/
COPY docker/hermes/ /opt/hermes-stack-config/docker/hermes/
# The boot-time drop renderer.
COPY docker/hermes/render-drop-profiles.py /usr/local/bin/render-drop-profiles.py
# render.py resolves CONFIG from its own location (/opt/hermes-stack-config),
# so the job scripts it validates (config/cron.toml -> CRON_SCRIPT_DIR =
# ROOT/docker/hermes) are already in place above — validated at build time,
# where a typo fails the build rather than shipping a dead job.
RUN chmod 0755 /usr/local/bin/render-drop-profiles.py \
 && python3 /opt/hermes-stack-config/render.py --build-root /overlay \
 && if [ -d /overlay/main ]; then mv /overlay/main /overlay/default; fi \
 && mkdir -p /overlay/profiles \
 && for d in /overlay/*/; do \
      b="$(basename "$d")"; \
      case "$b" in default|profiles) continue ;; esac; \
      mv "$d" "/overlay/profiles/$b"; \
    done

# Install the vendored plugins into the overlay (stack-wide, at the overlay
# ROOT — not under default/ or profiles/<name>/; the arrange loop above would
# otherwise sweep a pre-created plugins/ dir into /overlay/profiles/plugins,
# which is why the clones stage in /tmp and this layer sits after the render).
# This layer re-runs on config-only pushes by design — it is a local cp, no
# network — and stays BEFORE the entrypoint COPY so the entrypoint layer
# remains the config-change boundary.
RUN mkdir -p /overlay/plugins \
 && cp -a /tmp/hermes-memory-ui /overlay/plugins/hermes-memory-ui \
 && cp -a /tmp/honcho-plugin /overlay/plugins/honcho \
 && rm -rf /tmp/hermes-memory-ui /tmp/honcho-plugin

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
