#!/usr/bin/env bash
# Restore one stack's database, media and files from a backup.sh timestamp.
#
# DESTRUCTIVE: drops and recreates the target database, and wipes the
# stack's data/media and data/files before extracting the archived copies.
#
# Usage:  ./restore.sh <stack> <timestamp>
#   ./restore.sh stage 20260811-030000
#   FORCE=1 ./restore.sh prod 20260811-030000
set -euo pipefail
cd "$(dirname "$0")"

STACK=${1:?usage: restore.sh <stack> <timestamp>}
TIMESTAMP=${2:?usage: restore.sh <stack> <timestamp>}
FILE="$STACK/compose.yaml"
[[ -f "$FILE" ]] || { echo "ERROR: unknown stack '$STACK'" >&2; exit 1; }
[[ -f "$STACK/.env" ]] || { echo "ERROR: $STACK/.env missing" >&2; exit 1; }

# Restoring wipes everything currently in the database and in media/files.
if [[ "$STACK" == prod && "${FORCE:-}" != "1" ]]; then
  echo "REFUSING: '$STACK' is production. Re-run with FORCE=1 if you truly mean it." >&2
  exit 1
fi

BACKUP_ROOT=${BACKUP_ROOT:-backups}
SRC="$BACKUP_ROOT/$STACK/$TIMESTAMP"
if [[ ! -f "$SRC/database.sql.gz" || ! -f "$SRC/media.tar.gz" || ! -f "$SRC/files.tar.gz" ]]; then
  echo "ERROR: incomplete or missing backup at $SRC" >&2
  echo "       available timestamps for '$STACK':" >&2
  ls -1 "$BACKUP_ROOT/$STACK" 2>/dev/null >&2 || echo "       (none)" >&2
  exit 1
fi

# Check every archive BEFORE dropping anything: discovering a truncated dump
# after the database is gone is the one failure mode a restore must not have.
echo "==> Verifying archives in $SRC"
gzip -t "$SRC/database.sql.gz" "$SRC/media.tar.gz" "$SRC/files.tar.gz"

ROOT_PW=$(grep -E '^DB_ROOT_PASSWORD=' "$STACK/.env" | cut -d= -f2-)
[[ -n "$ROOT_PW" ]] || { echo "ERROR: DB_ROOT_PASSWORD missing from $STACK/.env" >&2; exit 1; }

SUDO=""; [[ $EUID -ne 0 ]] && SUDO="sudo"

echo "==> [$STACK] Stopping web/worker/scheduler"
docker compose -f "$FILE" stop web worker scheduler

# On a rebuilt host the stack may be entirely down, and `exec` on a stopped
# container just fails -- bring the database up on its own and wait it out.
echo "==> [$STACK] Ensuring database is up"
docker compose -f "$FILE" up -d database
tries=60
until [[ "$(docker inspect -f '{{.State.Health.Status}}' "$(docker compose -f "$FILE" ps -q database)" 2>/dev/null || echo starting)" == healthy ]]; do
  ((tries--)) || { echo "ERROR: database did not become healthy in time" >&2; exit 1; }
  sleep 2
done

echo "==> [$STACK] Restoring database from $TIMESTAMP"
docker compose -f "$FILE" exec -T database \
    mariadb -uroot -p"$ROOT_PW" -e "DROP DATABASE IF EXISTS shopware; CREATE DATABASE shopware;"
# messenger_messages is deliberately left intact -- this is a same-host
# disaster-recovery restore of real data, not a dev-dump import, so queued
# jobs (import-db.sh drops them; this does not) should survive.
gunzip -c "$SRC/database.sql.gz" \
  | docker compose -f "$FILE" exec -T database mariadb -uroot -p"$ROOT_PW" shopware

echo "==> [$STACK] Restoring media/ and files/"
$SUDO rm -rf "$STACK/data/media" "$STACK/data/files"
$SUDO tar --numeric-owner -xzf "$SRC/media.tar.gz" -C "$STACK/data"
$SUDO tar --numeric-owner -xzf "$SRC/files.tar.gz" -C "$STACK/data"
$SUDO chown -R 82:82 "$STACK/data/media" "$STACK/data/files"

echo "==> [$STACK] Bringing services back up"
docker compose -f "$FILE" up -d

echo "==> Restored $STACK from $TIMESTAMP."
echo "    thumbnail/theme/sitemap were not touched -- they regenerate on their own."
echo "    No sales_channel_domain rewriting was done (same-stack restore, not a cross-host import)."
