#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail
cd "$(dirname "$0")/.."

# Pinned web commit that owns vector generation. Update in its own PR together
# with the regenerated files and docs/vectors.md.
COMMIT="5fa44eb92334a7dfbb16bd698cc0047d8f723e67"
BASE="https://raw.githubusercontent.com/johnarleyburns/saldima/${COMMIT}/fixtures/vectors"
DEST="Fixtures/vectors"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for name in index money guid accounts; do
    curl -fsSL "${BASE}/${name}.json" -o "${tmp}/${name}.json"
done

if ! grep -q '"schemaVersion": 1' "${tmp}/index.json"; then
    echo "pull-vectors: unsupported schemaVersion in index.json" >&2
    cat "${tmp}/index.json" >&2
    exit 1
fi

mkdir -p "$DEST"
for name in index money guid accounts; do
    mv "${tmp}/${name}.json" "${DEST}/${name}.json"
done

echo "pull-vectors: fetched index, money, guid and accounts at ${COMMIT}"
