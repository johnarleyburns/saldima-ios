# Golden vectors

<!-- SPDX-License-Identifier: AGPL-3.0-only -->

`Fixtures/vectors/` is copied from the web repository, which is the source of
truth. This app replays the vectors; it never re-derives expected values.

## Pin

| | |
| --- | --- |
| Web repo | `johnarleyburns/saldima` |
| Commit | `5fa44eb92334a7dfbb16bd698cc0047d8f723e67` |
| Files | `index.json`, `money.json`, `guid.json`, `accounts.json` |
| Schema | `1` |

## Rules

- Update the pin in its own PR: change `COMMIT` in `scripts/pull-vectors.sh`,
  run it, commit the files, and update this table.
- A schema version newer than this app understands must fail the pull and the
  tests; never silently ignore unknown fields.
- The web track changes a vector before any app code depends on it. If a case
  is missing, file it on the web repo; do not invent it here.
- The account-tree vector currently comes from a synthetic fixture. The real
  book vector keeps the same schema when the owner supplies it (P0-5b).

## Regenerating

```sh
bash scripts/pull-vectors.sh
swift test
```

`swift test` reads `Fixtures/vectors/` relative to the package root.
