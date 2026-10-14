#!/bin/sh
# Select one component image tag in base/kustomization.yaml.
# Usage: scripts/set-tag.sh <database|workers|backend|frontend> <tag>
set -eu
COMPONENT="${1:?component required}"
TAG="${2:?tag required}"
FILE="$(cd "$(dirname "$0")/.." && pwd)/base/kustomization.yaml"
sed -i -e "s|^\(      - $COMPONENT=\).*|\1$TAG|" "$FILE"
sed -i -e "/name: localhost\/delta-$COMPONENT$/{n;s|newTag: .*|newTag: $TAG|}" "$FILE"
grep -n "$COMPONENT" "$FILE"
