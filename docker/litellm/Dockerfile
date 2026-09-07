# LiteLLM gateway image — upstream image with this repo's config baked in.
#
# Built from repo-root context (build_path "." in the komodo repo's
# [[build]] litellm; local: `mise run up`):
#   docker build -f docker/litellm/Dockerfile .
#
# config/litellm.yaml is COPYed as the final layer, so a config-only push
# invalidates just that layer: the rebuild emits a new image ID, and the
# deploy's `compose up` recreates the litellm service on the image change.
# That IS the config restart path — no bind mount to stale-out, no manual
# restart. Compose-side: compose/litellm.compose.yml (image: litellm:main).
#
# Base: the multi-arch main-latest tag (the versioned main-v1.x.y tags
# are amd64-only — check the host's architecture). Pre-pull it on the
# host before the first build: docker pull
# ghcr.io/berriai/litellm:main-latest — gateway upgrades re-pull, then
# push (the COPY layer cache-hits on top of the new base, producing a
# fresh litellm:main).
FROM ghcr.io/berriai/litellm:main-latest

COPY config/litellm.yaml /app/config.yaml