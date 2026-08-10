#!/usr/bin/env bash
# Shopware-side update for one stack: pull the new image and recreate services.
# The `setup` container runs install-or-migrate + theme compile and must exit 0
# before web/worker/scheduler start, so `up -d` is the whole deploy.
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
TAG="$TAG" docker compose -f "$FILE" up -d

echo "==> $STACK now on $TAG"
# Migrations apply while the OLD containers still serve, then the new ones start
# — brief old-code-vs-new-schema, which Shopware tolerates far better than the
# reverse. Still not zero-downtime: theme compile happens in setup, and web
# restarts. Persist TAG in $STACK/.env if you want it sticky.
