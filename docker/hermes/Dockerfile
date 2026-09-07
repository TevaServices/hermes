# Hermes agent image — thin over the OFFICIAL upstream image.
#
# The official nousresearch/hermes-agent image (published per upstream
# release, multi-arch incl. arm64) ships the s6-overlay supervision tree:
# per-profile gateways register as s6 services (gateway-<name> slots),
# crash-restart under s6-supervise, and reconcile across container
# restarts. That supervision is what makes the docs' "one container
# hosting all profiles" deployment model work — a custom installer build
# (the old image here) had no /run/service tree at all, so every profile
# needed its own container. Build on upstream instead of re-implementing
# it; upstream bump = change HERMES_REF (build arg / compose / mise env).
#
# What we add on top (kept minimal — each COPY/RUN is a separate final
# layer so config-only pushes invalidate only the last one):
#   1. gh CLI (arm64 tarball) + the GitHub App token helper + git
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
ARG HERMES_REF=v2026.8.31
FROM nousresearch/hermes-agent:${HERMES_REF}

# gh CLI (pinned arm64 tarball — this image is only ever built on the
# aarch64 homelab host): the agent's github-* skills (github-issues,
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
COPY docker/hermes/gh-credential-helper.sh /usr/local/bin/gh-credential-helper.sh
COPY docker/hermes/bootstrap-profiles.sh /usr/local/bin/hermes-bootstrap-profiles.sh
RUN chmod 0755 /usr/local/bin/github-app-token.sh \
               /usr/local/bin/gh-credential-helper.sh \
               /usr/local/bin/hermes-bootstrap-profiles.sh

# Declarative config: sources + renderer, compiled at BUILD time (no
# committed build/ artifacts in git — the renderer IS the verification).
# python3 is the image's own interpreter; render.py is stdlib-only.
COPY render.py /tmp/render.py
COPY config/ /tmp/config/
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
 && rm -rf /tmp/render.py /tmp/config

COPY docker/hermes/entrypoint.sh /usr/local/bin/hermes-stack-entrypoint.sh
RUN chmod 0755 /usr/local/bin/hermes-stack-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/hermes-stack-entrypoint.sh"]
# `gateway run` is the legacy-run argv the boot reconciler recognizes: on
# first boot it seeds the default profile's gateway_state as running and
# the s6 reconciler starts gateway-default (one supervised gateway for
# the root profile; named profiles start from their own recorded state).
# Inside the s6 container `gateway run` also self-upgrades: it registers
# the gateway-default slot, then keeps the CMD alive as a `sleep
# infinity` heartbeat while s6-supervise runs the real gateway.
CMD ["gateway", "run"]