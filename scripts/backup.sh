#!/bin/sh
# Write a logical dump of the delta database before a migration.
# Usage: scripts/backup.sh [label]
# The dump and its SHA-256 go to ~/backups/delta-observatory/, outside every repository.
set -eu
LABEL="${1:-before-migration}"
DIR="${DELTA_BACKUP_DIR:-$HOME/backups/delta-observatory}"
mkdir -p "$DIR"
FILE="$DIR/delta-$(date -u +%Y%m%dT%H%M%SZ)-$LABEL.dump"
kubectl -n delta-observatory exec delta-db-1 -c postgres -- pg_dump -U postgres -Fc -d delta > "$FILE"
pg_restore --list "$FILE" > /dev/null
(cd "$DIR" && sha256sum "$(basename "$FILE")" > "$(basename "$FILE").sha256")
echo "$FILE"
