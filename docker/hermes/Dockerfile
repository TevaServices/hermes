# Hermes agent image.
#
# Built from repo-root context (the komodo repo's hermes-agent Build uses
# build_path "." + dockerfile_path docker/hermes/Dockerfile; local:
#   docker compose -f compose/hermes.compose.yml build
# which passes the same context via `build:` in the service).
#
# The image runs the official Nous Research installer at a pinned ref
# (versions.env -> HERMES_REF), which sets up:
#   - the agent code at /usr/local/lib/hermes-agent (root/FHS layout)
#   - a `hermes` launcher at /usr/local/bin/hermes
#   - a managed Node.js runtime under $HERMES_HOME/node (used by npx-
#     based MCP servers like firecrawl-mcp)
#
# Agent state (config.yaml, .env, memories, sessions, skills) lives in a
# volume mounted at /data, set via HERMES_HOME. The rendered profile
# overlay (build/main/ — committed to git) is BAKED into the image at
# /overlay by the final COPY layer: a config-only push invalidates just
# that layer, the rebuild emits a new image ID, and the deploy recreates
# hermes-main — the config restart path. entrypoint.sh re-applies /overlay
# on every start. A bind mount at /overlay (other profiles, local dev)
# shadows the baked copy, so per-profile overlays still work.
#
# Rebuilding the image after bumping HERMES_REF IS the update path:
# the code lives in the image, state lives in the volume.
FROM ubuntu:24.04

ARG HERMES_REF=v2026.8.31
ENV HERMES_HOME=/data \
    DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8

# curl/git/certs: installer + updates. docker.io: the CLI for Hermes'
# "docker" terminal backend (mount /var/run/docker.sock to use it —
# see compose/hermes.compose.yml). openssh-client: ssh backend.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git openssh-client docker.io tzdata xz-utils \
 && rm -rf /var/lib/apt/lists/*

# gh CLI (pinned arm64 tarball — this image is only ever built on the
# aarch64 homelab host): the agent's github-* skills (github-issues,
# github-pr-workflow, github-repo-management, github-code-review) work
# through gh when present. Auth is GH_TOKEN env only (see
# secrets/hermes-main.env.example) — gh reads it natively, so there is
# no `gh auth login` state to persist.
ARG GH_VERSION=2.100.0
RUN curl -fsSL \
      https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_arm64.tar.gz \
      -o /tmp/gh.tgz \
 && tar -xzf /tmp/gh.tgz -C /tmp \
 && install -m 0755 /tmp/gh_${GH_VERSION}_linux_arm64/bin/gh /usr/local/bin/gh \
 && rm -rf /tmp/gh*

# Official installer. --branch pins the checkout (accepts a tag or
# branch ref); --skip-setup skips the interactive onboarding that has
# no TTY inside docker build. The installer refuses to roll an existing
# install backward without --force-commit, which never applies here
# since the layer is always fresh.
RUN curl -fsSL \
      https://raw.githubusercontent.com/NousResearch/hermes-agent/${HERMES_REF}/scripts/install.sh \
      -o /tmp/hermes-install.sh \
 && bash /tmp/hermes-install.sh --branch ${HERMES_REF} --skip-setup \
 && rm -f /tmp/hermes-install.sh
# The installer lays out an FHS install (code+venv at
# /usr/local/lib/hermes-agent, launcher at /usr/local/bin/hermes) and
# needs NO launcher fixups. (The v2026.3.x installer landed in
# $HOME/.hermes with no launcher, which needed the symlink this
# Dockerfile used to add — do not re-add it: it would clobber the
# installer's working launcher with a dangling path.)

# Final layers — keep last so config-only pushes (build/ changes) don't
# invalidate the installer layers above. Context is the repo root, hence
# the docker/hermes/ prefixes.
COPY docker/hermes/entrypoint.sh /usr/local/bin/hermes-entrypoint.sh
COPY docker/hermes/github-app-token.sh /usr/local/bin/github-app-token.sh
RUN chmod +x /usr/local/bin/hermes-entrypoint.sh /usr/local/bin/github-app-token.sh \
 && mkdir -p /data
# The rendered main-profile overlay (build/main/, committed by render.py):
# baked in so config changes ride the image-ID recreation path. A bind
# mount at /overlay (researcher profile, local overrides) shadows it.
COPY build/main /overlay

VOLUME ["/data"]

ENTRYPOINT ["/usr/local/bin/hermes-entrypoint.sh"]
CMD ["gateway"]