#!/bin/sh
# Apply the migrations of one database image to a copy of the newest dump, then drop the copy.
# Usage: scripts/rehearse.sh <database-image-tag> [dump-file]
set -eu
TAG="${1:?database image tag required}"
DIR="${DELTA_BACKUP_DIR:-$HOME/backups/delta-observatory}"
DUMP="${2:-$(ls -t "$DIR"/*.dump | head -1)}"
HERE=$(cd "$(dirname "$0")/.." && pwd)
DB=delta_rehearsal
JOB="rehearse-$(echo "$TAG" | tr . -)-$(date +%H%M%S)"
RENDERED="${TMPDIR:-/tmp}/$JOB.yaml"
PSQL="kubectl -n delta-observatory exec -i delta-db-1 -c postgres -- psql -U postgres -v ON_ERROR_STOP=1 -X -q"
$PSQL -c "DROP DATABASE IF EXISTS $DB" -c "CREATE DATABASE $DB OWNER delta"
kubectl -n delta-observatory exec -i delta-db-1 -c postgres -- pg_restore -U postgres -d "$DB" --no-owner --role=delta < "$DUMP"
sed -e "s|{{JOB_NAME}}|$JOB|g" -e "s|{{IMAGE_TAG}}|$TAG|g" -e "s|{{DATABASE}}|$DB|g" \
    "$HERE/builds/rehearse.template.yaml" > "$RENDERED"
kubectl apply -f "$RENDERED"
status=0
kubectl -n delta-observatory wait --for=condition=complete "job/$JOB" --timeout=5m || status=1
kubectl -n delta-observatory logs "job/$JOB"
$PSQL -d "$DB" -At -c "SELECT version FROM schema_migration ORDER BY 1" \
    -c "SELECT 'observations', count(*) FROM observation UNION ALL SELECT 'jobs', count(*) FROM job UNION ALL SELECT 'measurements', count(*) FROM measurement UNION ALL SELECT 'artifacts', count(*) FROM artifact"
$PSQL -c "DROP DATABASE $DB"
exit $status
