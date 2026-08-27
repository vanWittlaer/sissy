#!/usr/bin/env bash
# Back up one stack's database, media and files to a timestamped directory,
# then rotate old backups away.
#
# Database: mariadb-dump run inside the stack's own database container.
# --single-transaction takes ONE InnoDB snapshot for the whole dump, so the
# result is consistent across tables while taking no locks at all -- and it
# needs no RELOAD privilege, so the app user is enough and no root password
# is read here. (Concurrent DDL breaks that snapshot: don't deploy and back
# up at the same time.) Nothing is filtered out -- unlike import-db.sh's dev
# refresh, real queued jobs in messenger_messages are part of the state a
# disaster-recovery backup exists to protect.
#
# Media/files: tar'd straight off the bind-mounted data/ dirs on the host.
#
# Usage:  ./backup.sh <stack>
#   ./backup.sh prod
#   BACKUP_ROOT=/mnt/backup/sissy ./backup.sh prod
set -euo pipefail
cd "$(dirname "$0")"

# The backup IS the shop's data (full DB dump, invoice PDFs); the default
# umask would leave it world-readable on whatever volume BACKUP_ROOT is.
umask 077

STACK=${1:?usage: backup.sh <stack>}
FILE="$STACK/compose.yaml"
[[ -f "$FILE" ]] || { echo "ERROR: unknown stack '$STACK'" >&2; exit 1; }
[[ -f "$STACK/.env" ]] || { echo "ERROR: $STACK/.env missing" >&2; exit 1; }

# Point this at your actual mounted backup volume/disk -- the default lives
# in the repo checkout, which is fine for testing but not where you want your
# only copy of production data.
BACKUP_ROOT=${BACKUP_ROOT:-backups}
BACKUP_KEEP=${BACKUP_KEEP:-7}

# media/files are owned by UID 82, so reading them needs root. Same pattern as
# bootstrap.sh/restore.sh; running the whole script as root (cron) skips it.
SUDO=""; [[ $EUID -ne 0 ]] && SUDO="sudo"

for d in media files; do
  [[ -d "$STACK/data/$d" ]] || { echo "ERROR: $STACK/data/$d missing -- run bootstrap.sh first" >&2; exit 1; }
done

# The app user, not root: --single-transaction needs no privilege beyond the
# grants MARIADB_USER already has on the `shopware` database. restore.sh does
# need DB_ROOT_PASSWORD -- it drops and recreates the database itself.
DB_PW=$(grep -E '^DB_PASSWORD=' "$STACK/.env" | cut -d= -f2-)
[[ -n "$DB_PW" ]] || { echo "ERROR: DB_PASSWORD missing from $STACK/.env" >&2; exit 1; }

# Fail here with something readable rather than inside `exec` on a dead stack.
[[ -n "$(docker compose -f "$FILE" ps -q database)" ]] || {
  echo "ERROR: '$STACK' database container is not running -- start the stack first" >&2; exit 1; }

TS=$(date -u +%Y%m%d-%H%M%S)
DEST="$BACKUP_ROOT/$STACK/$TS"
mkdir -p "$DEST"

# A failed run must not leave a partial backup lying around for rotation to
# count as real or for restore.sh to pick up.
SUCCESS=0
cleanup() { [[ $SUCCESS -eq 1 ]] || rm -rf "$DEST"; }
trap cleanup EXIT

# tar exits 1 for "file changed as we read it", which is routine on a live shop
# and no reason to throw the whole backup away. 2 and up are real failures.
#
# tar writes to stdout and THIS shell does the redirect, so the archive is
# owned by whoever ran the script -- sudo is only needed to read UID 82's
# files. Letting `sudo tar -f FILE` create it leaves a root:root 600 file
# the invoking user can't read back (or scp) on a host with root disabled.
tar_live() {
  local out=$1 rc=0; shift
  $SUDO tar --numeric-owner -cz "$@" > "$out" || rc=$?
  ((rc <= 1)) || return "$rc"
  ((rc == 0)) || echo "    note: files changed while archiving (tar warning); archive is still usable" >&2
}

echo "==> [$STACK] Dumping database"
# pigz compresses on all cores, shortening the window the --single-transaction
# snapshot stays open (during which a concurrent deploy's DDL would break it).
COMPRESS=gzip; command -v pigz >/dev/null 2>&1 && COMPRESS=pigz
# --hex-blob keeps Shopware's binary(16) ids out of charset conversion on the
# way through the pipe; --routines/--events/--triggers catch anything a plugin
# left in the schema that the default flags would skip. The password goes in
# as MYSQL_PWD env, not -p on the command line, where every host account
# could read it out of `ps` for the duration of the dump.
docker compose -f "$FILE" exec -T -e MYSQL_PWD="$DB_PW" database \
    mariadb-dump \
      --single-transaction \
      --hex-blob \
      --default-character-set=utf8mb4 \
      --routines --events --triggers \
      -ushopware shopware \
  | "$COMPRESS" -c > "$DEST/database.sql.gz"
# pipefail already caught a failed dump; this also catches a half-written .gz,
# which is otherwise indistinguishable from a real one until restore day.
gzip -t "$DEST/database.sql.gz"

echo "==> [$STACK] Archiving media/ and files/"
tar_live "$DEST/media.tar.gz" -C "$STACK/data" media
tar_live "$DEST/files.tar.gz" -C "$STACK/data" files

SUCCESS=1
echo "==> Backup complete: $DEST ($(du -sh "$DEST" | cut -f1))"

# After SUCCESS: a hiccup in rotation must not delete the backup we just made.
echo "==> [$STACK] Rotating: keeping last $BACKUP_KEEP backup(s)"
shopt -s nullglob
existing=("$BACKUP_ROOT/$STACK"/*/)
shopt -u nullglob
if ((${#existing[@]} > BACKUP_KEEP)); then
  # The glob is already sorted by name, and the directory name IS the UTC
  # timestamp — oldest first — so "everything but the last KEEP" is a slice.
  old=("${existing[@]:0:${#existing[@]}-BACKUP_KEEP}")
  echo "    removing ${#old[@]} old backup(s):"
  printf '      %s\n' "${old[@]}"
  $SUDO rm -rf "${old[@]}"
fi
