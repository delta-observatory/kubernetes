#!/bin/sh
# Build one component image in the cluster and print its tag.
# Usage: scripts/build.sh <database|workers|backend|frontend>
# The image name is localhost/delta-<component>:<tag>.
set -eu
COMPONENT="${1:?component required}"
HERE=$(cd "$(dirname "$0")/.." && pwd)
SOURCE_DIR=$(cd "$HERE/../$COMPONENT" && pwd)
TAG="0.1.0-$(date +%Y%m%d%H%M%S)"
JOB="build-$COMPONENT-$(echo "$TAG" | tr . -)"
RENDERED="${TMPDIR:-/tmp}/$JOB.yaml"
sed -e "s|{{JOB_NAME}}|$JOB|g" -e "s|{{COMPONENT}}|$COMPONENT|g" \
    -e "s|{{IMAGE_TAG}}|$TAG|g" -e "s|{{SOURCE_DIR}}|$SOURCE_DIR|g" \
    "$HERE/builds/build-image.template.yaml" > "$RENDERED"
kubectl apply -f "$RENDERED" >&2
if ! kubectl -n delta-observatory wait --for=condition=complete "job/$JOB" --timeout=30m >&2; then
    kubectl -n delta-observatory logs "job/$JOB" -c build --tail=40 >&2 || true
    exit 1
fi
kubectl -n delta-observatory logs "job/$JOB" -c import >&2
echo "$TAG"
