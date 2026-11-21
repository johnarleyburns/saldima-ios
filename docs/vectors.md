# Golden vectors

<!-- SPDX-License-Identifier: AGPL-3.0-only -->

`Fixtures/vectors/` is copied from the web repository, which is the source of
truth. This app replays the vectors; it never re-derives expected values.

## Pin

| | |
| --- | --- |
| Web repo | `johnarleyburns/saldima` |
| Commit | `49c7f83369185b839c4cdede8423f0bcbedc50f5` |
| Files | `index.json`, `money.json`, `guid.json` |
| Schema | `1` |

## Rules

- Update the pin in its own PR: change `COMMIT` in `scripts/pull-vectors.sh`,
  run it, commit the files, and update this table.
- A schema version newer than this app understands must fail the pull and the
  tests; never silently ignore unknown fields.
- The web track changes a vector before any app code depends on it. If a case
  is missing, file it on the web repo; do not invent it here.
- The current vectors cover money and GUIDs. An account-tree vector is pending
  the web track's fixture book (see P0-5).

## Regenerating

```sh
bash scripts/pull-vectors.sh
swift test
```

`swift test` reads `Fixtures/vectors/` relative to the package root.
