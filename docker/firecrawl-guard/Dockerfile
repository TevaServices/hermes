# firecrawl-guard — the fence on the agent's web path. See guard.py's
# module docstring for what it does and AGENTS.md for why it exists.
#
# Built by Komodo Builds like the other images in this stack (the compose
# file runs `run_build = false`); the build context is the repo root, so
# the COPY path is repo-relative.
#
# alpine + one pure-Python dependency. The guard imports `redis` lazily, so
# the image still runs without it — FIRECRAWL_EGRESS=cache-only just refuses
# every miss instead of serving from cache.
FROM python:3.12-alpine

RUN pip install --no-cache-dir "redis>=5,<7"

WORKDIR /app
COPY docker/firecrawl-guard/guard.py /app/guard.py

# Runs unprivileged, like every other service in the stack. It binds 3003 and
# holds no secrets — the agent's Firecrawl API key passes through in a header
# it forwards untouched and never logs.
RUN adduser -D -u 10000 guard
USER 10000

EXPOSE 3003
ENTRYPOINT ["python3", "/app/guard.py"]
