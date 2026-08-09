#!/usr/bin/env bash
# One-shot / idempotent bootstrap for the whole box.
# Brings up edge + every app stack, waits for each DB, then runs the
# deployment helper (which INSTALLS Shopware on an empty DB and runs
# migrations on an existing one — same command either way).
#
# Usage:  ./bootstrap.sh [stack ...]        (default: prod stage)
set -euo pipefail
cd "$(dirname "$0")"

STACKS=("${@:-prod stage}")
read -r -a STACKS <<<"${STACKS[*]}"

require_env() {
  local dir=$1
  for f in .env .env.local; do
    [[ -f "$dir/$f" ]] || { echo "ERROR: $dir/$f missing (copy from $f.example)" >&2; exit 1; }
  done
}

# Pre-create bind-mount dirs with correct ownership. If Docker creates them it
# does so as root; the Shopware container runs as UID 82 and must own var/log
# (else logging dies with Permission denied).
SUDO=""; [[ $EUID -ne 0 ]] && SUDO="sudo"
prep_dirs() {
  local dir=$1
  # Everything the app writes. Keep in sync with x-app-volumes in compose.yaml.
  local app_dirs=(media thumbnail theme sitemap files log)
  mkdir -p "${app_dirs[@]/#/$dir/data/}" "$dir/data/mysql"
  [[ "$dir" == prod ]] && mkdir -p "$dir/data/rclone"
  $SUDO chown -R 82:82 "${app_dirs[@]/#/$dir/data/}"
}

wait_healthy() {
  local file=$1 svc=$2 tries=60 cid status
  echo "  waiting for '$svc' to be healthy..."
  while ((tries--)); do
    cid=$(docker compose -f "$file" ps -q "$svc" 2>/dev/null || true)
    if [[ -n "$cid" ]]; then
      status=$(docker inspect -f '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo starting)
      [[ "$status" == "healthy" ]] && { echo "  '$svc' healthy"; return 0; }
    fi
    sleep 2
  done
  echo "ERROR: '$svc' did not become healthy in time" >&2
  return 1
}

echo "==> Ensuring shared 'edge' network exists"
docker network inspect edge >/dev/null 2>&1 || docker network create edge

echo "==> Bringing up edge (Traefik)"
[[ -f edge/.env ]] || { echo "ERROR: edge/.env missing (copy from edge/.env.example)" >&2; exit 1; }
docker compose -f edge/compose.yaml up -d

for stack in "${STACKS[@]}"; do
  echo "==> Bootstrapping stack: $stack"
  require_env "$stack"
  prep_dirs "$stack"
  local_file="$stack/compose.yaml"
  docker compose -f "$local_file" pull
  docker compose -f "$local_file" up -d
  wait_healthy "$local_file" database
  echo "  running deployment helper (install-or-migrate)"
  docker compose -f "$local_file" exec -T web /var/www/html/vendor/bin/shopware-deployment-helper run -n
done

echo "==> Done. Point DNS at this host if you haven't; Traefik will issue certs on first hit."
