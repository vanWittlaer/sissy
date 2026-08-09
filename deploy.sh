#!/usr/bin/env bash
# Shopware-side update for one stack: pull new image, recreate all services
# (web/worker/scheduler onto new code), then migrate + theme-compile INSIDE
# the live web container (no S3 -> compiled theme must land on the serving fs).
#
# Usage:  ./deploy.sh <stack> [tag]
#   ./deploy.sh prod 1a2b3c4
#   ./deploy.sh stage latest
set -euo pipefail
cd "$(dirname "$0")"

STACK=${1:?usage: deploy.sh <stack> [tag]}
TAG=${2:-latest}
FILE="$STACK/compose.yaml"
[[ -f "$FILE" ]] || { echo "ERROR: unknown stack '$STACK'" >&2; exit 1; }

echo "==> Deploying $STACK @ $TAG"
TAG="$TAG" docker compose -f "$FILE" pull
TAG="$TAG" docker compose -f "$FILE" up -d          # recreates web/worker/scheduler on new image

echo "==> Migrate + theme-compile (inside live web)"
docker compose -f "$FILE" exec -T web /var/www/html/vendor/bin/shopware-deployment-helper run -n

echo "==> $STACK now on $TAG"
# NOTE: this flips new code live BEFORE migrations apply — a brief new-code-vs-old-schema
# window. Acceptable for single-node; true zero-downtime needs blue-green.
# Persist TAG for next run by writing it into $STACK/.env if you want it sticky.
