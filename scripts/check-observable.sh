#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail
cd "${CI_VALIDATE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

matches="$(
    grep -REn 'ObservableObject|@ObservedObject|@StateObject' \
        Saldima SaldimaCore SaldimaSync SaldimaTestKit SaldimaCoreTests SaldimaSyncTests \
        --include='*.swift' || true
)"
if [ -n "$matches" ]; then
    echo "Observable gate: use @Observable instead" >&2
    printf '%s\n' "$matches"
    exit 1
fi
echo "Observable gate: OK"
