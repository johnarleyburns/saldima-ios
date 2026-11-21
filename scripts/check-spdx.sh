#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail
cd "${CI_VALIDATE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

HEADER="SPDX-License-Identifier: AGPL-3.0-only"
EXEMPT="LICENSE NOTICE CLA.md CODEOWNERS"

fail=0
while IFS= read -r file; do
    case " $EXEMPT " in
        *" $file "*) continue ;;
    esac
    [ -f "$file" ] || continue
    case "$file" in
        *.swift|*.sh|*.yml|*.yaml|*.md) ;;
        *) continue ;;
    esac
    if ! head -n 3 "$file" | grep -q "$HEADER"; then
        echo "Missing SPDX header: $file" >&2
        fail=1
    fi
done < <(git ls-files --cached --others --exclude-standard)

if ((fail)); then
    echo "SPDX guard: FAILED" >&2
    exit 1
fi
echo "SPDX guard: OK"
