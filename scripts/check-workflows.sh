#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail

# Pinned actionlint, checksum-verified.
VERSION="1.7.7"
SHA256="023070a287cd8cccd71515fedc843f1985bf96c436b7effaecce67290e7e0757"
ARCHIVE="actionlint_${VERSION}_linux_amd64.tar.gz"
URL="https://github.com/rhysd/actionlint/releases/download/v${VERSION}/${ARCHIVE}"
WORKDIR="${TMPDIR:-/tmp}/actionlint-${VERSION}"

mkdir -p "$WORKDIR"
if [ ! -x "$WORKDIR/actionlint" ]; then
  curl -fsSL "$URL" -o "$WORKDIR/$ARCHIVE"
  echo "${SHA256}  $WORKDIR/$ARCHIVE" | sha256sum -c -
  tar -xzf "$WORKDIR/$ARCHIVE" -C "$WORKDIR" actionlint
fi

"$WORKDIR/actionlint" -color
