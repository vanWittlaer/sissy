#!/usr/bin/env bash
# Import a SQL dump (e.g. `ddev export-db`) into a stack's database, then run
# the deployment helper so the schema matches the image's Shopware version.
#
# DESTRUCTIVE: drops and recreates the target database.
#
# Usage:  ./import-db.sh <stack> <dump.sql[.gz]> [source-host]
#   ./import-db.sh stage /tmp/sissy-db.sql.gz
#   ./import-db.sh stage /tmp/dump.sql example.test    # rewrite that host instead
#
# source-host defaults to 'ddev.site': every sales_channel_domain URL containing
# it is repointed at the stack's own DOMAIN, otherwise the storefront keeps
# redirecting to the machine the dump came from.
set -euo pipefail
cd "$(dirname "$0")"

STACK=${1:?usage: import-db.sh <stack> <dump.sql[.gz]> [source-host]}
DUMP=${2:?usage: import-db.sh <stack> <dump.sql[.gz]> [source-host]}
SRC_HOST=${3:-ddev.site}
FILE="$STACK/compose.yaml"

[[ -f "$FILE" ]] || { echo "ERROR: unknown stack '$STACK'" >&2; exit 1; }
[[ -f "$DUMP" ]] || { echo "ERROR: dump '$DUMP' not found" >&2; exit 1; }

# Importing a dev dump over production wipes every real order and customer.
if [[ "$STACK" == prod && "${FORCE:-}" != "1" ]]; then
  echo "REFUSING: '$STACK' is production. Re-run with FORCE=1 if you truly mean it." >&2
  echo "          (prod -> stage is what refresh-stage.sh is for.)" >&2
  exit 1
fi

ROOT_PW=$(grep -E '^DB_ROOT_PASSWORD=' "$STACK/.env" | cut -d= -f2-)
DOMAIN=$(grep -E '^DOMAIN=' "$STACK/.env" | cut -d= -f2-)
[[ -n "$ROOT_PW" && -n "$DOMAIN" ]] || { echo "ERROR: DB_ROOT_PASSWORD/DOMAIN missing from $STACK/.env" >&2; exit 1; }

db() { docker compose -f "$FILE" exec -T database mariadb -uroot -p"$ROOT_PW" "$@"; }

echo "==> Recreating '$STACK' database (everything currently in it is lost)"
db -e "DROP DATABASE IF EXISTS shopware; CREATE DATABASE shopware;"

echo "==> Importing $DUMP"
# -T matters: with a TTY allocated, the pipe delivers nothing and the import
# silently does nothing at all.
case "$DUMP" in
  *.gz) gunzip -c "$DUMP" ;;
  *)    cat "$DUMP" ;;
esac | docker compose -f "$FILE" exec -T database mariadb -uroot -p"$ROOT_PW" shopware

echo "==> Migrating to the image's Shopware version + compiling theme"
docker compose -f "$FILE" exec -T web /var/www/html/vendor/bin/shopware-deployment-helper run -n

echo "==> Repointing sales channel domains ($SRC_HOST -> $DOMAIN)"
db shopware -e "UPDATE sales_channel_domain SET url = CONCAT('https://', '$DOMAIN')
                WHERE url LIKE '%$SRC_HOST%';"
# Dev leftovers in the queue would be replayed by this stack's workers.
db shopware -e "DELETE FROM messenger_messages;" 2>/dev/null || true

docker compose -f "$FILE" exec -T web php bin/console cache:clear

echo "==> Imported into $STACK."
echo "    Media is NOT in the dump — the DB only holds references. To copy it:"
echo "      rsync -a <local>/shopware/public/media/ /tmp/media/"
echo "      sudo rsync -a /tmp/media/ $STACK/data/media/ && sudo chown -R 82:82 $STACK/data/media"
echo "      docker compose -f $FILE exec -T web php bin/console media:generate-thumbnails"
echo "    Admin logins now come from the dump, not from this server."
