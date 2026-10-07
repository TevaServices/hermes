#!/usr/bin/env bash
# One-time preparation of a Linux host (the Komodo Periphery machine).
#
#   sudo ./scripts/bootstrap-host.sh
#
# Creates:
#   /etc/hermes/*.env          — secret env files, copied from secrets/*.env.example
#                                if not already present (chmod 600)
#   docker network hermes-net  — shared network the three stacks join
#   /etc/docker/daemon.json    — BuildKit GC cap + json-file log rotation
#   /etc/systemd/journald.conf.d/size-cap.conf — journald 500M cap
#
# Idempotent: safe to re-run; existing env files are never overwritten.

set -euo pipefail

HERMES_ENV_DIR="${HERMES_ENV_DIR:-/etc/hermes}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ "$(id -u)" -ne 0 ] && [ "${HERMES_ENV_DIR}" = "/etc/hermes" ]; then
  echo "needs root to write ${HERMES_ENV_DIR}; re-run with sudo, or set HERMES_ENV_DIR" >&2
  exit 1
fi

command -v docker >/dev/null || { echo "docker not found — install Docker first" >&2; exit 1; }
# git is required on hosts that run the Honcho compose stack (its image
# builds from a git context) and by Komodo's repo handling.
command -v git >/dev/null || echo "warning: git not found — required for git build contexts (Honcho)" >&2

# --- secret env files -----------------------------------------------------
mkdir -p "${HERMES_ENV_DIR}"
chmod 700 "${HERMES_ENV_DIR}"

for template in "${REPO_ROOT}"/secrets/*.env.example; do
  [ -e "$template" ] || continue
  name="$(basename "$template" .env.example)"
  target="${HERMES_ENV_DIR}/${name}.env"
  if [ -e "$target" ]; then
    echo "keep existing ${target}"
  else
    cp "$template" "$target"
    chmod 600 "$target"
    echo "created ${target} — EDIT IT and fill in real values"
  fi
done

# --- shared docker network ------------------------------------------------
if docker network inspect hermes-net >/dev/null 2>&1; then
  echo "keep existing docker network hermes-net"
else
  docker network create hermes-net
  echo "created docker network hermes-net"
fi

# --- host disk hygiene ------------------------------------------------------
# Written once per host; never overwrites an existing file (merge by hand if
# a host already carries other daemon.json content). A daemon restart is
# what applies daemon.json to a host that already runs workloads — this
# script is not the place to bounce stack containers, so it prints the step
# and leaves it to the operator:
#   sudo systemctl restart docker
#   (stops containers briefly; their restart policies bring them back —
#   every container in this stack runs unless-stopped for exactly this)
#
#   * json-file rotation — the daemon default is UNBOUNDED container logs;
#     Komodo's MongoDB held 394 MB of a month's boot noise. 10 MB x 3 is
#     the default for every NEW container (existing ones pick it up at
#     their next recreate).
#   * BuildKit GC — the webhook-driven builds accumulate build cache
#     without bound (59 GB in four weeks on this host, 55 GB reclaimable);
#     the GC keeps the newest 10 GB, which is what the config-only
#     cache-hit deploys need to stay cheap.
if [ -f /etc/docker/daemon.json ]; then
  echo "keep existing /etc/docker/daemon.json — check it carries log-opts + builder.gc"
else
  cat > /etc/docker/daemon.json <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "builder": { "gc": { "enabled": true, "defaultKeepStorage": "10GB" } }
}
JSON
  echo "wrote /etc/docker/daemon.json (log rotation + BuildKit GC) — restart docker to apply"
fi

# journald's own default cap is none — it held 3.3 GB here; 500 MB is
# several weeks of volume for a low-throughput host. vacuum once by hand
# (journalctl --rotate && journalctl --vacuum-size=500M); the cap keeps the
# future in place from the first boot.
if [ -f /etc/systemd/journald.conf.d/size-cap.conf ]; then
  echo "keep existing /etc/systemd/journald.conf.d/size-cap.conf"
else
  install -d -m 755 /etc/systemd/journald.conf.d
  printf "[Journal]\nSystemMaxUse=500M\n" > /etc/systemd/journald.conf.d/size-cap.conf
  systemctl restart systemd-journald
  echo "capped journald at 500M"
fi

# --- scheduled fuller trims (systemd timer) ---------------------------------
# The daemon's BuildKit GC above caps the cache; dangling images and orphaned
# anonymous volumes drift slower (~700 MB / 5 weeks observed) and get one
# daily oneshot. This is the host's timer, not a Komodo Action: Actions run
# as sandboxed deno scripts and cannot spawn the docker CLI at all — ENOENT
# even by absolute path (tested live 2026-10-07 + deleted the experiment;
# a Procedure's Exec is komodo-managed work only). `--reserved-space` needs
# docker 29+; on an older engine, spell it `--keep-storage` instead.
install -m 644 /dev/stdin /etc/systemd/system/trim-docker.service <<'UNIT'
[Unit]
Description=Trim docker build cache (keep 10 GB), dangling images, orphaned anonymous volumes

[Service]
Type=oneshot
ExecStart=/usr/bin/docker builder prune --reserved-space 10GB -f
ExecStart=/usr/bin/docker image prune -f
ExecStart=/usr/bin/docker volume prune -f
UNIT
install -m 644 /dev/stdin /etc/systemd/system/trim-docker.timer <<'UNIT'
[Unit]
Description=Run trim-docker.service daily at 05:17

[Timer]
OnCalendar=*-*-* 05:17:00
Persistent=true

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now trim-docker.timer
echo "enabled trim-docker.timer (daily 05:17)"

# The host was found once with /dev/null at 664 (2026-10-07), which
# silently breaks every non-root `>/dev/null` redirect — the command its
# redirection fails is not run at all, so probe outputs went missing
# without an error naming it. udev restores 666 at boot; enforce it here
# too so a hand-run bootstrap heals it immediately.
chmod 666 /dev/null

cat <<EOF

Next steps:
  1. Fill in the secrets:  vim ${HERMES_ENV_DIR}/*.env
     (key names per profile: check the rendered .env.example inside the
     agent image — docker run --rm hermes-agent:v<ref> cat
     /overlay/default/.env.example — or run \`mise run render\` locally)
  2. Point komodo/resources.toml at this repo and your Komodo server name,
     then follow komodo/README.md to wire the Resource Sync + webhook.
EOF