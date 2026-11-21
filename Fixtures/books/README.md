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
