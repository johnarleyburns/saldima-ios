#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Single test entry point. Pass extra arguments through to swift test.
set -euo pipefail
cd "$(dirname "$0")/.."
exec swift test -Xswiftc -warnings-as-errors "$@"
