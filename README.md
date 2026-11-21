# Saldima for iPhone

<!-- SPDX-License-Identifier: AGPL-3.0-only -->

Saldima is a GnuCash-compatible accounting app. This is the iPhone track: a
complete book on your phone, no account required, with optional linking to a
hosted Saldima book.

**Compatible with GnuCash.** Saldima is an independent project, not affiliated
with or endorsed by the GnuCash project.

## Status

Phase **P0 (Foundations)**. The web track is
[`johnarleyburns/saldima`](https://github.com/johnarleyburns/saldima).

- Agent contract, stack and rules: [`CLAUDE.md`](CLAUDE.md)
- P0 checklist and exit criteria: [`docs/plans/P0.md`](docs/plans/P0.md)
- Contributions: [`CONTRIBUTING.md`](CONTRIBUTING.md), [`CLA.md`](CLA.md)

## Development

Requires Xcode 27 with the iOS 27 SDK and XcodeGen.

```sh
xcodegen generate
swift test
bash scripts/check-swift6.sh
bash scripts/check-observable.sh
bash scripts/check-spdx.sh
```

Portable core tests also run on Linux:

```sh
docker run --rm -v "$PWD":/w -w /w swift:6.2-noble \
  swift test -Xswiftc -warnings-as-errors
```

## Licence

`AGPL-3.0-only`. See [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE). Copyright is
retained by John Arley Burns; outside contributions are accepted under the CLA.
