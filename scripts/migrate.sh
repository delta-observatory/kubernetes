#!/bin/sh
# Apply database migrations from one delta-database image.
# Usage: scripts/migrate.sh <database-image-tag>
set -eu
TAG="${1:?database image tag required}"
HERE=$(cd "$(dirname "$0")/.." && pwd)
JOB="migrate-$(echo "$TAG" | tr . -)-$(date +%H%M%S)"
RENDERED="${TMPDIR:-/tmp}/$JOB.yaml"
sed -e "s|{{JOB_NAME}}|$JOB|g" -e "s|{{IMAGE_TAG}}|$TAG|g" \
    "$HERE/builds/migrate.template.yaml" > "$RENDERED"
kubectl apply -f "$RENDERED"
status=0
kubectl -n delta-observatory wait --for=condition=complete "job/$JOB" --timeout=5m || status=1
kubectl -n delta-observatory logs "job/$JOB"
exit $status
