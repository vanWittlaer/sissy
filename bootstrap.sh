#!/usr/bin/env bash
# One-shot / idempotent bootstrap for the whole box.
# Brings up edge + every app stack. Each stack's `setup` container INSTALLS
# Shopware on an empty DB and migrates an existing one, before the app
# containers are allowed to start.
#
# Usage:  ./bootstrap.sh [stack ...]        (default: prod stage)
set -euo pipefail
cd "$(dirname "$0")"

STACKS=("$@")
((${#STACKS[@]})) || STACKS=(prod stage)

# .env/.env.local are gitignored, so they are hand-written on every host and
# silently drift. A missing key doesn't fail the boot, it just makes the app
# behave subtly wrong (http:// asset URLs, wrong canonical host), so warn
# loudly. The *.example files are the roster of required keys — the same
# fixture lint.yml validates compose against — so adding a variable there is
# enough to have every host checked for it.
require_env() {
  local dir=$1 f key missing=0
  for f in .env .env.local; do
    [[ -f "$dir/$f" ]] || { echo "ERROR: $dir/$f missing (copy from $f.example)" >&2; exit 1; }
    # These hold DB passwords and APP_SECRET; the default umask leaves them
    # world-readable to any local account.
    $SUDO chmod 600 "$dir/$f"
    while IFS= read -r key; do
      grep -qE "^${key}=.+" "$dir/$f" || { echo "WARNING: $dir/$f has no $key" >&2; missing=1; }
    done < <(grep -oE '^[A-Z][A-Z0-9_]*' "$dir/$f.example" 2>/dev/null || true)
  done
  # The #1 documented gotcha: the DB password lives in .env (DB_PASSWORD) and
  # again, spelled out, inside .env.local's DSNs. Catch a change made in only
  # one of the two places before it turns into a refused connection.
  local db_pw
  db_pw=$(grep -E '^DB_PASSWORD=' "$dir/.env" | cut -d= -f2- || true)
  if [[ -n "$db_pw" ]] && ! grep -E '^DATABASE_URL=' "$dir/.env.local" | grep -qF ":${db_pw}@"; then
    echo "WARNING: $dir/.env.local DATABASE_URL does not carry .env's DB_PASSWORD" >&2; missing=1
  fi
  # Bind-mounted single files must exist first: Docker would create a DIRECTORY
  # in their place, and MariaDB's !includedir skips non-files without a word,
  # so the tuning silently never applies.
  [[ -f "$dir/mariadb.cnf" ]] || {
    echo "ERROR: $dir/mariadb.cnf missing or not a regular file" >&2
    echo "       (if Docker already created a directory there, rmdir it first)" >&2
    exit 1
  }
  # MariaDB runs as uid 999 and skips a file it cannot read — and refuses one
  # that is group/world writable. Both silently. 0644 is the only mode that works.
  $SUDO chmod 644 "$dir/mariadb.cnf"
  # Same trap for stage's Mailpit UI password file. Unlike mariadb.cnf the
  # failure is loud (Mailpit exits: "HTTP password file not found") but under
  # restart: unless-stopped that is a crash-loop reading as "Restarting".
  if grep -q 'MP_UI_AUTH_FILE' "$dir/compose.yaml"; then
    [[ -f "$dir/mailpit.htpasswd" ]] || {
      echo "ERROR: $dir/mailpit.htpasswd missing or not a regular file" >&2
      echo "       create it with: htpasswd -nbB user pass > $dir/mailpit.htpasswd" >&2
      echo "       (single '\$' — no doubling; if Docker created a directory there, rmdir it first)" >&2
      exit 1
    }
    $SUDO chmod 644 "$dir/mailpit.htpasswd"
  fi
  [[ $missing -eq 0 ]] || echo "  ^ compare against $dir/*.example before continuing" >&2
}

# Pre-create bind-mount dirs with correct ownership. If Docker creates them it
# does so as root; the Shopware container runs as UID 82 and must own var/log
# (else logging dies with Permission denied).
SUDO=""; [[ $EUID -ne 0 ]] && SUDO="sudo"
prep_dirs() {
  local dir=$1
  # Everything the app writes. Keep in sync with x-app-volumes in compose.yaml.
  # data/mysql is deliberately NOT in this list: it belongs to the mariadb
  # image's own user (uid 999). chown it to 82 and MariaDB starts but cannot
  # create tables -- "errno: 13 Permission denied" — leaving a half-written
  # data dictionary behind.
  local app_dirs=(media thumbnail theme sitemap files log)
  mkdir -p "${app_dirs[@]/#/$dir/data/}" "$dir/data/mysql"
  $SUDO chown -R 82:82 "${app_dirs[@]/#/$dir/data/}"
}

echo "==> Ensuring shared 'edge' network exists"
docker network inspect edge >/dev/null 2>&1 || docker network create edge

echo "==> Bringing up edge (Traefik)"
[[ -f edge/.env ]] || { echo "ERROR: edge/.env missing (copy from edge/.env.example)" >&2; exit 1; }
docker compose -f edge/compose.yaml up -d

for stack in "${STACKS[@]}"; do
  echo "==> Bootstrapping stack: $stack"
  require_env "$stack"
  # One image name for every environment: they differ by TAG. Drift here means
  # promoting a stage build to prod silently ships a different repository.
  img=$(grep -E '^APP_IMAGE=' "$stack/.env" | cut -d= -f2-)
  if [[ -z "${first_img:-}" ]]; then
    first_img=$img first_stack=$stack
  elif [[ "$img" != "$first_img" ]]; then
    echo "WARNING: $stack/.env APP_IMAGE ($img) differs from $first_stack/.env ($first_img)" >&2
  fi
  prep_dirs "$stack"
  local_file="$stack/compose.yaml"
  docker compose -f "$local_file" pull
  # `up -d` blocks on the setup container, which installs on an empty DB and
  # migrates on an existing one before web/worker/scheduler are allowed to
  # start — and setup itself gates on the database being healthy, so when this
  # returns, the whole stack is up. No extra health polling needed.
  docker compose -f "$local_file" up -d
done

echo "==> Done. Point DNS at this host if you haven't; Traefik will issue certs on first hit."
