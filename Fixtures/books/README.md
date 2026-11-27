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

`gronewald-gl-2023-01.gnucash`, `gronewald-gl-2023-07.gnucash`, and
`gronewald-gl-2024-12.gnucash` are a real, independently-published academic
synthetic general-ledger dataset -- **"DIB General Ledger Data"**, Jan
Gronewald, Sebastian Stephan, Alexander Rombach, and Peter Fettke (Saarland
University / DFKI), Zenodo record
[22014653](https://doi.org/10.5281/zenodo.22014653) (v2, 2026-08-19), **CC BY
4.0**. A genuinely complex German SME chart of accounts (VAT, trade
receivables/payables, payroll) and balanced multi-leg journal entries; each
file is one standalone calendar month (not a cumulative series) from the
dataset's full 2023-01..2024-12 range, picked non-adjacent for temporal
spread.

`gronewald-gl-full.gnucash` is the same dataset again, but as one
continuous book spanning the entire 2023-01..2024-12 range (102,429
transactions, 25 accounts) instead of a standalone month -- for
year-over-year comparison (e.g. total revenue 2023 vs 2024) that a single
month can't give you. It's a single ~10 MB file (~119 MB decompressed);
prefer a `YYYY-MM` month above for a fast test and reach for this one
specifically when the test needs more than one month's data.

Built by the web repo's `scripts/import-gronewald-fixture.ts`; see its
`fixtures/books/README.md` for full provenance, per-file account/
transaction counts, and hashes. Every file here was opened and re-saved by
the real GnuCash engine as an external oracle, with zero errors.
