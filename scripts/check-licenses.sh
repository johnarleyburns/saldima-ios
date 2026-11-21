#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail
cd "${CI_VALIDATE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

ALLOW="Support/allowed-dependencies.txt"
fail=0

# Architecture ban is independent of licensing.
if grep -q 'GRDB' Package.swift; then
    echo "license guard: GRDB is banned by the design" >&2
    fail=1
fi

urls="$(
    grep -Eo '\.package\([^)]*url: *"[^"]+"' Package.swift |
        sed -E 's/.*url: *"([^"]+)"/\1/' || true
)"

while IFS= read -r url; do
    [ -n "$url" ] || continue
    line="$(grep -F "$url" "$ALLOW" 2>/dev/null | grep -v '^#' || true)"
    if [ -z "$line" ]; then
        echo "license guard: $url is not in $ALLOW" >&2
        fail=1
        continue
    fi
    license="$(printf '%s\n' "$line" | awk '{print $2}')"
    case "$license" in
        MIT|BSD-2-Clause|BSD-3-Clause|Apache-2.0|ISC|0BSD|CC0-1.0) ;;
        *)
            echo "license guard: $url has disallowed licence $license" >&2
            fail=1
            ;;
    esac
done <<< "$urls"

if ((fail)); then
    echo "license guard: FAILED" >&2
    exit 1
fi
echo "license guard: OK"
