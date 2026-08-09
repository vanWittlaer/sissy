#!/usr/bin/env bash
# Copy the prod database into stage, then run the deployment helper on stage.
# Routes through the host because prod's ops-shell/db and stage's db live on
# separate internal networks and can't reach each other directly.
#
# Reads DB passwords from prod/.env and stage/.env.
set -euo pipefail
cd "$(dirname "$0")"

# shellcheck disable=SC1091
PROD_DB_PW=$(grep -E '^DB_PASSWORD=' prod/.env | cut -d= -f2-)
STAGE_DB_PW=$(grep -E '^DB_PASSWORD=' stage/.env | cut -d= -f2-)

echo "==> Dumping prod DB -> stage DB"
docker compose -f prod/compose.yaml exec -T database \
    mariadb-dump --single-transaction -ushopware -p"$PROD_DB_PW" shopware \
| docker compose -f stage/compose.yaml exec -T database \
    mariadb -ushopware -p"$STAGE_DB_PW" shopware

echo "==> Running deployment helper on stage"
docker compose -f stage/compose.yaml exec -T web /var/www/html/vendor/bin/shopware-deployment-helper run -n

echo "==> Stage refreshed from prod."
echo "    Reminder: media/thumbnail are NOT copied — stage still serves prod media"
echo "    only if you sync ./prod/data/media -> ./stage/data/media (rsync) or share it."
