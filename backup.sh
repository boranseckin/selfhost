#!/bin/bash

set -euo pipefail

SELFHOST_DIR="/home/boran/selfhost"
BACKUP_ROOT="/root/backups/docker-volumes"
DATE=$(date +%Y-%m-%d)
DEST="$BACKUP_ROOT/$DATE"
RETAIN_DAYS=5

mkdir -p $DEST

# --- Pull DB credentials from each project's secret file ---
FORGEJO_ENV="$SELFHOST_DIR/forgejo.secret"
PAPERLESS_ENV="$SELFHOST_DIR/paperless.secret"

FORGEJO_DB_USER=$(grep -E '^POSTGRES_USER=' "$FORGEJO_ENV" | cut -d= -f2-)
FORGEJO_DB_NAME=$(grep -E '^POSTGRES_DB='   "$FORGEJO_ENV" | cut -d= -f2-)

PAPERLESS_DB_USER=$(grep -E '^POSTGRES_USER=' "$PAPERLESS_ENV" | cut -d= -f2-)
PAPERLESS_DB_NAME=$(grep -E '^POSTGRES_DB='   "$PAPERLESS_ENV" | cut -d= -f2-)

# --- Postgres dumps ---
echo "Dumping forgejo-db..."
docker exec forgejo-db-1 pg_dump -U "$FORGEJO_DB_USER" "$FORGEJO_DB_NAME" | gzip > "$DEST/forgejo-db.sql.gz"

echo "Dumping paperless-db..."
docker exec paperless-db-1 pg_dump -U "$PAPERLESS_DB_USER" "$PAPERLESS_DB_NAME" | gzip > "$DEST/paperless-db.sql.gz"

# --- Volume archives ---
VOLUMES=(
  aiostreams_data
  copyparty_state
  forgejo_data
  obsidian_data
  obsidian_etc
  paperless_data
  paperless_media
)

# --- Pre-flight check: fail loudly if an expected volume is missing/renamed ---
for VOL in "${VOLUMES[@]}"; do
  if ! docker volume inspect "$VOL" > /dev/null 2>&1; then
    echo "ERROR: expected volume '$VOL' not found — check for renames before continuing" >&2
    exit 1
  fi
done

for VOL in "${VOLUMES[@]}"; do
  echo "Archiving volume: $VOL"
  docker run --rm \
    -v "${VOL}:/data:ro" \
    -v "${DEST}:/backup" \
    alpine \
    tar czf "/backup/${VOL}.tar.gz" -C /data .
done

# --- Sync to Backblaze B2 ---
echo "Syncing to Backblaze B2..."
rclone sync "$BACKUP_ROOT" backblaze:mossy-backups/docker-volumes \
  --fast-list \
  --transfers 8 \
  --stats 5s \
  --stats-one-line \
  --log-level INFO

# --- Local retention cleanup ---
find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d -mtime +"$RETAIN_DAYS" -exec rm -rf {} \;

echo "Backup complete: $DEST"
