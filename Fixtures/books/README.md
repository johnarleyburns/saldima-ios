# Fixture books

<!-- SPDX-License-Identifier: AGPL-3.0-only -->

`synthetic-mini.gnucash` is our own hand-written SQLite fixture: it holds only
the `accounts` and `versions` tables needed to test the read-only actor. No
GnuCash code or data is copied into it.

`no-accounts.sqlite` is a valid SQLite database without the GnuCash account
schema, used to assert the typed schema error.

The owner's anonymised real GnuCash 5.x book will replace these for the
cross-track and oracle checks (P0-5 acceptance). Do not substitute a real book
with personal data.

`fa-001-straight-line-equipment-depreciation.gnucash` is a different kind of
fixture: a larger synthetic book from the sibling `saldima-accounting-verifier`
project's reviewed `FA-001` scenario (five years of straight-line equipment
depreciation, 8 real accounts, 187 transactions), hand-verified against that
project's own independent reference-model numbers, then re-opened and
re-saved by GnuCash 5.5 as an external oracle -- the same process used for
`oracle-mini.*`. Exporting it surfaced and fixed a real bug on that project's
side (`trn:commodity` instead of `trn:currency`). It does **not** replace the
owner's real anonymised book above; it's useful for exercising the read path
against independently-verified, known-correct numbers. SHA-256:
`791a5ddd8fa3e9ee293090dbe68ce8f2d5270b6ed2be3daea620265c99d6e0e9`.
