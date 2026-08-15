#!/usr/bin/env bash
# Copy the prod database into stage, then run the deployment helper on stage.
# Routes through the host because prod's and stage's databases live on
# separate internal networks and can't reach each other directly.
#
# Reads DB passwords from prod/.env and stage/.env.
set -euo pipefail
cd "$(dirname "$0")"

PROD_DB_PW=$(grep -E '^DB_PASSWORD=' prod/.env | cut -d= -f2-)
STAGE_DB_PW=$(grep -E '^DB_PASSWORD=' stage/.env | cut -d= -f2-)
PROD_DOMAIN=$(grep -E '^DOMAIN=' prod/.env | cut -d= -f2-)
STAGE_DOMAIN=$(grep -E '^DOMAIN=' stage/.env | cut -d= -f2-)

# Same dump flags as backup.sh, for the same reasons: --hex-blob keeps the
# binary(16) ids out of charset conversion, --routines/--events/--triggers
# catch what plugins left in the schema. Passwords ride in as MYSQL_PWD env,
# not -p args readable in the host's `ps` for the duration of the copy.
echo "==> Dumping prod DB -> stage DB"
docker compose -f prod/compose.yaml exec -T -e MYSQL_PWD="$PROD_DB_PW" database \
    mariadb-dump \
      --single-transaction \
      --hex-blob \
      --default-character-set=utf8mb4 \
      --routines --events --triggers \
      -ushopware shopware \
| docker compose -f stage/compose.yaml exec -T -e MYSQL_PWD="$STAGE_DB_PW" database \
    mariadb -ushopware shopware

# The dump carries prod's URLs; without this the storefront 400s on stage.
# And it carries prod's QUEUE: left in place, stage's workers replay prod's
# pending jobs (mails included) — same guard import-db.sh applies to dev dumps.
echo "==> Repointing sales channel domains -> $STAGE_DOMAIN"
docker compose -f stage/compose.yaml exec -T -e MYSQL_PWD="$STAGE_DB_PW" database \
    mariadb -ushopware shopware \
    -e "UPDATE sales_channel_domain SET url = REPLACE(url, '$PROD_DOMAIN', '$STAGE_DOMAIN');
        DELETE FROM messenger_messages;"

echo "==> Running deployment helper on stage"
docker compose -f stage/compose.yaml exec -T web /var/www/html/vendor/bin/shopware-deployment-helper run -n

echo "==> Stage refreshed from prod."
echo "    Reminder: media/thumbnail are NOT copied — stage still serves prod media"
echo "    only if you sync ./prod/data/media -> ./stage/data/media (rsync) or share it."
