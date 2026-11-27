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
spread. Built by the web repo's `scripts/import-gronewald-fixture.ts`; see
its `fixtures/books/README.md` for full provenance, per-file account/
transaction counts, and hashes. Every file was opened and re-saved by the
real GnuCash engine as an external oracle, with zero errors.
