#!/usr/bin/env bash
# Copy the prod database into stage, then run the deployment helper on stage.
# Routes through the host because prod's and stage's databases live on
# separate internal networks and can't reach each other directly.
#
# Reads DB passwords from prod/.env and stage/.env.
set -euo pipefail
cd "$(dirname "$0")"

# shellcheck disable=SC1091
PROD_DB_PW=$(grep -E '^DB_PASSWORD=' prod/.env | cut -d= -f2-)
STAGE_DB_PW=$(grep -E '^DB_PASSWORD=' stage/.env | cut -d= -f2-)
PROD_DOMAIN=$(grep -E '^DOMAIN=' prod/.env | cut -d= -f2-)
STAGE_DOMAIN=$(grep -E '^DOMAIN=' stage/.env | cut -d= -f2-)

echo "==> Dumping prod DB -> stage DB"
docker compose -f prod/compose.yaml exec -T database \
    mariadb-dump --single-transaction -ushopware -p"$PROD_DB_PW" shopware \
| docker compose -f stage/compose.yaml exec -T database \
    mariadb -ushopware -p"$STAGE_DB_PW" shopware

# The dump carries prod's URLs; without this the storefront 400s on stage.
echo "==> Repointing sales channel domains -> $STAGE_DOMAIN"
docker compose -f stage/compose.yaml exec -T database \
    mariadb -ushopware -p"$STAGE_DB_PW" shopware \
    -e "UPDATE sales_channel_domain SET url = REPLACE(url, '$PROD_DOMAIN', '$STAGE_DOMAIN');"

echo "==> Running deployment helper on stage"
docker compose -f stage/compose.yaml exec -T web /var/www/html/vendor/bin/shopware-deployment-helper run -n

echo "==> Stage refreshed from prod."
echo "    Reminder: media/thumbnail are NOT copied — stage still serves prod media"
echo "    only if you sync ./prod/data/media -> ./stage/data/media (rsync) or share it."
