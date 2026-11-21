#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail
cd "${CI_VALIDATE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

matches="$(
    grep -REn 'Date\(\)|UUID\(\)' SaldimaCore --include='*.swift' |
        grep -v '^SaldimaCore/Production/' || true
)"
if [ -n "$matches" ]; then
    echo "Seam guard: use Clock/IDGenerator instead of Date()/UUID()" >&2
    printf '%s\n' "$matches"
    exit 1
fi
echo "Seam guard: OK"
