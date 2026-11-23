<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# P1 mobile roadmap — standalone first, sync optional

The iPhone app is a complete GnuCash-compatible book on the phone. It needs no
Saldima account, no subscription and no network. Linking to Saldima is optional
and removable.

## Product rules

- Every book/accounting feature works offline and without payment.
- The only purchase is a one-time, optional **Supporter** consumable
  (`guru.parso.saldima.support.dev`), never a subscription and never a gate.
- A local `.gnucash` file is always one click away; standalone and linked books
  use the same format.
- The Android track (`johnarleyburns/saldima-android`) reaches the same core
  behaviour, with `saldima_supporter` as its Play Billing consumable.

## Checklist

- [ ] [#21 M1 Accounting verification kernel](https://github.com/johnarleyburns/saldima-ios/issues/21):
      Money, half-up posting, ledger, trial balance, balance sheet, P&L and the
      GnuCash scenarios. Core landed; scenarios and parity remain.
- [ ] [#20 M2 Standalone book, templates and account tree](https://github.com/johnarleyburns/saldima-ios/issues/20):
      create/open/save SQLite `.gnucash`, templates, account CRUD, Files/iCloud.
- [ ] [#22 M3 Optional Saldima sync](https://github.com/johnarleyburns/saldima-ios/issues/22):
      `/api/v1`, Keychain device token, download/upload/merge, no network in
      standalone.
- [x] [#23 M4 Supporter one-time consumable](https://github.com/johnarleyburns/saldima-ios/issues/23):
      core policy + StoreKit adapter + Settings card landed; App Store Connect
      product remains owner-only.
- [ ] Android P0 parity: see `saldima-android/docs/plans/P0.md`.

## Exit

- Standalone create/open/save/edit works with the network disabled.
- Optional link round-trips a book and can be removed without data loss.
- Purchase success/cancel/pending tested with fakes; no feature checks the flag.
- A physical iPhone (and Android device) pass owner QA.
