#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail
cd "${CI_VALIDATE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

fail=0

if grep -REl 'swiftLanguageMode\(\.v[0-5]\)|SWIFT_VERSION: "[0-5]|SWIFT_VERSION = [0-5]' \
    Package.swift project.yml >/dev/null 2>&1; then
    echo "Swift 6 guard: a Swift 5 language mode is configured" >&2
    fail=1
fi

if ! grep -q 'SWIFT_STRICT_CONCURRENCY: complete' project.yml; then
    echo "Swift 6 guard: SWIFT_STRICT_CONCURRENCY is not complete" >&2
    fail=1
fi

escape_hatches="$(
    grep -REn 'nonisolated\(unsafe\)|MainActor\.assumeIsolated|@unchecked Sendable' \
        Saldima SaldimaCore SaldimaSync SaldimaTestKit SaldimaCoreTests SaldimaSyncTests \
        --include='*.swift' || true
)"
if [ -n "$escape_hatches" ]; then
    echo "Swift 6 guard: concurrency escape hatch found" >&2
    printf '%s\n' "$escape_hatches"
    fail=1
fi

if ((fail)); then
    echo "Swift 6 guard: FAILED" >&2
    exit 1
fi
echo "Swift 6 guard: OK"
