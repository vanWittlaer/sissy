#!/usr/bin/env bash
# Shopware-side update for one stack: pull the new image and recreate services.
# The `setup` container runs install-or-migrate + theme compile and must exit 0
# before web/worker/scheduler start, so `up -d` is the whole deploy.
#
# Usage:  ./deploy.sh <stack> [tag]
#   ./deploy.sh prod 1a2b3c4
#   ./deploy.sh stage latest
#   ./deploy.sh prod            # re-deploys the tag recorded in prod/.env
set -euo pipefail
cd "$(dirname "$0")"

STACK=${1:?usage: deploy.sh <stack> [tag]}
FILE="$STACK/compose.yaml"
[[ -f "$FILE" ]] || { echo "ERROR: unknown stack '$STACK'" >&2; exit 1; }

# No tag given: reuse what this stack is already recorded as running, rather
# than jumping to `latest` -- which is a DIFFERENT build the moment CI pushes
# again, and on projects whose prod builds never emit it, no image at all.
# `|| true` matters: under `set -e` with pipefail, a TAG-less .env would
# otherwise abort the script here.
if [[ -n "${2:-}" ]]; then
  TAG=$2; TAG_SRC="argument"
else
  TAG=$(grep -E '^TAG=' "$STACK/.env" 2>/dev/null | cut -d= -f2- || true)
  TAG_SRC="$STACK/.env"
  [[ -n "$TAG" ]] || { TAG=latest; TAG_SRC="default"; }
fi

# CI passes this through a remote ssh command line, and it lands in the sed
# below — refuse anything that isn't a plain docker tag before using it.
[[ "$TAG" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] || { echo "ERROR: '$TAG' is not a valid image tag" >&2; exit 1; }

echo "==> Deploying $STACK @ $TAG (from $TAG_SRC)"
# Pull only the app image: web/worker/scheduler/setup share it, so one pull
# fetches it for all — and a freshly published mariadb patch image doesn't get
# to recreate the database container as a deploy side effect. (A missing DB
# image on a fresh host is still pulled by `up -d` itself.)
TAG="$TAG" docker compose -f "$FILE" pull web
TAG="$TAG" docker compose -f "$FILE" up -d

# Record what is actually running. TAG is only passed for the two calls above,
# so without this .env keeps whatever it was seeded with (usually `latest`) and
# a later bare `docker compose up -d` -- which any .env.local change requires --
# silently rolls the stack onto a different build. Written after `up -d` on
# purpose: a failed deploy must not leave .env claiming the new tag.
# .env is gitignored host-local state, so this is not a repo edit.
if grep -q '^TAG=' "$STACK/.env" 2>/dev/null; then
  sed -i "s|^TAG=.*|TAG=$TAG|" "$STACK/.env"
else
  printf 'TAG=%s\n' "$TAG" >> "$STACK/.env"
fi

echo "==> $STACK now on $TAG (recorded in $STACK/.env)"
# Migrations apply while the OLD containers still serve, then the new ones start
# — brief old-code-vs-new-schema, which Shopware tolerates far better than the
# reverse. Still not zero-downtime: theme compile happens in setup, and web
# restarts.
