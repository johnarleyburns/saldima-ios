<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# CLAUDE.md — Saldima for iPhone (`johnarleyburns/saldima-ios`)

Saldima is a GnuCash-compatible accounting app. This repo is the **iPhone
track**: a complete book on the phone with no account, optionally linked to a
hosted Saldima book through the web track's `/api/v1` sync API. The product is
**Saldima**; say "compatible with GnuCash", never use GnuCash as our name or
logo. The web track is `johnarleyburns/saldima`.

## Source of truth

1. The Saldima spec: Spec tab (iPhone app, Testing, License, Coding-agent
   handoff) and Design tab (iPhone app design). Local copies:
   `~/Downloads/Spec.md` and `~/Downloads/Design (HLD + LLD).md`.
2. The Go-to-market doc (`~/Downloads/Go-to-market.md`) for positioning and
   launch constraints: no "gnucash" in the name or domain, no analytics, no
   third-party ads/scripts, source always linked.
3. This file and `docs/plans/P0.md`.
4. The GitHub issue being worked; its acceptance criteria define done.

If the spec, design and this file disagree, stop and ask in the issue. Record
undecided items under **Risks and open questions**; never guess.

## Product model: standalone first

- The app is a complete **standalone** GnuCash-compatible book. No Saldima
  account, subscription or network is required.
- Linking to a hosted Saldima book is optional and removable; the local
  `.gnucash` file is the source of truth.
- The only purchase is a one-time **Supporter** consumable
  (`guru.parso.saldima.support.dev`). It never gates anything; success sets a
  one-way local badge. No subscription, no ads, no analytics.
- Android parity lives in `johnarleyburns/saldima-android` with
  `saldima_supporter` as the equivalent Play Billing consumable.

## Stack and identity

- **Xcode 27 / iOS 27 SDK**, Swift 6 language mode, complete strict
  concurrency, no warnings. Deployment target iOS 27.0. iPhone first, iPad
  allowed, no Mac Catalyst.
- **Bundle ID** `guru.parso.saldima`, signed by the owner's Apple Developer
  team. The App ID and App Store Connect record are human-only.
- **UI:** SwiftUI with Liquid Glass from the iOS 27 SDK. Standard navigation,
  tab bars, toolbars and sheets get it automatically; custom surfaces use the
  glass effect APIs. Check with Reduce Transparency, Increase Contrast and the
  largest Dynamic Type size.
- **Project generation:** XcodeGen `project.yml`. Never hand-edit
  `Saldima.xcodeproj`; run `xcodegen generate` after changing `project.yml`.
- **Persistence:** a hand-rolled `actor` over SQLite3 with integer-numbered,
  append-only migrations. No GRDB, no Core Data.
- **Observation:** `@Observable` only. `ObservableObject` is banned and fails
  `scripts/check-observable.sh`.

### Layout

```
Package.swift              SaldimaCore, SaldimaSync, SaldimaTestKit
SaldimaCore/               Money, Guid, invariants, BookStore actor, reports, templates
SaldimaSync/               /api/v1 client, device token, lease and merge-review models
SaldimaTestKit/            fakes for every protocol, manual clock, URLProtocol replay
Saldima/App/               lifecycle and dependency container
Saldima/DesignSystem/      Liquid Glass surfaces, typography, amount formatting
Saldima/Features/          Accounts, Register, Receipts, Reconcile, Reports, Sync, Settings
SaldimaCoreTests/          Swift Testing suites for pure logic
SaldimaSyncTests/          API client tests with recorded fixtures
Fixtures/                  books and vectors pulled from the web repo at a pinned commit
scripts/                   check-swift6.sh, check-observable.sh, pull-vectors.sh, test.sh
.githooks/pre-commit       runs swift test
.github/workflows/         ci (compile + swift test), testflight (guarded)
```

`SaldimaCore` is pure: it never imports SwiftUI, StoreKit, Keychain or
networking, and must also build on Linux for the container test job.

## Commands

| Command | Purpose |
| --- | --- |
| `xcodegen generate` | regenerate `Saldima.xcodeproj` from `project.yml` |
| `swift test` | Swift Testing logic suites (macOS or Linux container) |
| `scripts/test.sh` | wrapper used locally and in CI |
| `docker run --rm -v "$PWD":/w -w /w swift:6.2-noble swift test` | portable core tests on Linux |
| `bash scripts/check-swift6.sh` | reject Swift 5 modes and concurrency escape hatches |
| `bash scripts/check-observable.sh` | reject `ObservableObject` |
| `bash scripts/check-spdx.sh` | every authored file carries the AGPL SPDX header |
| `bash scripts/check-licenses.sh` | remote Swift packages must be allowlisted with a permissive licence; GRDB is banned |
| `bash scripts/pull-vectors.sh` | fetch vectors from the pinned web commit; fails on schema drift |
| `xcodebuild build -project Saldima.xcodeproj -scheme Saldima -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO` | CI compile |

Do not start or boot a simulator unless the owner explicitly asks. CI compiles
for generic iOS and runs logic tests on a macOS runner; the Linux container job
covers portable logic.

## Test-first, always

- Write the failing acceptance test first, watch it fail for the right reason,
  then the smallest change that passes, then refactor green. A PR without a test
  that failed first is not done.
- Every async dependency sits behind a protocol: `BookStore`, `FileAccess`,
  `SyncAPI`, `Clock`, `IDGenerator`, `KeychainStore`, `ImageEncoder`. View
  models are `@Observable` classes on the main actor that take protocols in
  their initialisers, so screen logic is tested with fakes and no simulator.
- Tests use in-memory fakes from `SaldimaTestKit`; HTTP tests use a
  `URLProtocol` stub replaying responses recorded by the web repo's API
  contract tests. Do not hit the network in tests.
- Tests never sleep, poll or read wall time. Advance `ManualClock` explicitly.
- UI behaviour that cannot be automated must be documented in the PR with a
  concrete device-verification step.

## Money, GUIDs and files

- Amounts are `Int64` numerator/denominator pairs, exactly as GnuCash stores
  them. No `Double`, `Float` or `Decimal` for money. Add exact, round
  half-to-even to the commodity fraction.
- GUIDs are 32 lowercase hex characters from `IDGenerator`, never reused.
- Work happens on a working copy in Application Support (never Caches). Save
  writes back atomically and keeps earlier versions by SHA-256.
- While a book is open, write a `gnclock` row as desktop GnuCash does and clear
  it on close. Our `gcw_` tables are stripped on export.
- Keep what we do not model; never delete unknown tables, columns or KVP slots.

## Golden vectors and the link to the web

- The web track generates `fixtures/vectors/{index,money,guid,accounts}.json` with
  `pnpm vectors`. This repo pins a **web commit SHA** and commits the files.
  `scripts/pull-vectors.sh` fetches exactly that revision.
- Current pin: `5fa44eb92334a7dfbb16bd698cc0047d8f723e67` (web account-tree
  vector merged).
  Update the pin in one PR with the regenerated files and a note in
  `docs/vectors.md`.
- Never invent behaviour the web has not defined. If a vector or `/api/v1`
  schema is missing, stop and ask; add it to the web track's plan.
- `accounts.json` currently describes a synthetic fixture; the real-book vector
  keeps the same schema when the owner supplies the book.
- A vector schema version newer than this app understands must fail loudly.

## License and dependencies

- **AGPL-3.0-only**, sole copyright retained by `johnarleyburns` through
  `CLA.md`. Every outside PR needs the CLA check.
- SPDX header on every authored file:
  `// SPDX-License-Identifier: AGPL-3.0-only` (or the correct comment syntax).
  Legal texts are exempt.
- Dependencies must be MIT, BSD, Apache-2.0, ISC, 0BSD or CC0. GPL/AGPL/SSPL or
  unknown licences fail CI. No GRDB (it is MIT; the ban is architectural).
- Never copy code from GnuCash, gnucash-web, piecash or any GPL project. Read
  them for behaviour only. GnuCash and gnucash-web are credited in `NOTICE`.
- No analytics, third-party SDKs, ads or tracking. The About screen links the
  public source at the running commit, as AGPL requires.

## Git and GitHub workflow

- **One task, one small branch, one PR, squash merge.** Never push to `main`.
- Use the `gh` CLI for every GitHub action.
- Before opening or updating a PR: `git diff --check`, review
  `git diff --name-only`, run the required tests in the foreground, and audit
  the saved diff against the issue. A prose-only description is not a
  deliverable.
- PR body states the failing test that now passes, the gates run, and any issue
  requirement not covered.
- Install hooks with `git config core.hooksPath .githooks`; pre-commit runs
  `swift test`. Allow at least 10 minutes for a commit.

## Hard limits for agents

1. **Never deploy, tag, or upload to TestFlight by hand, and never touch secrets,
   environments or rulesets unless the owner explicitly asks.** Open PRs only.
   TestFlight uploads are automatic: merging a PR authored by `johnarleyburns`
   into `main` starts the `testflight` workflow, and its gate job skips direct
   pushes and other authors.
2. Never create or modify the `ios-release` environment, App Store Connect keys,
   certificates, provisioning profiles, branch protection or Actions secrets
   without an explicit owner request.
3. Never add a GPL/AGPL dependency or copy GPL code.
4. Never commit keys, tokens, customer books or personal data. Fixtures must be
   anonymised and licensed for the repo.
5. Never guess a missing decision; stop and ask, or record it in the plan.
6. Never invent hosted behaviour: consume the web's vectors and `/api/v1`
   contract from a pinned commit.
7. Never run a simulator unless the owner asks; use the physical iPhone for
   device checks.

## Definition of done (every PR)

- A test failed first and passes now; compile, tests and guards are green with
  no warnings.
- A completion audit against the issue finds no gaps.
- `CLAUDE.md` and the phase checklist are updated if a decision changed.
- No secrets, environments, rulesets, tags, manual TestFlight uploads or
  deploys touched.

## Risks and open questions

- **Xcode 27 on hosted runners.** The macOS image must provide the iOS 27 SDK.
  If it does not, CI compile is blocked on a runner image change owned by the
  human; do not lower the deployment target silently.
- **Fixture book.** The real anonymised GnuCash 5.x book is human-supplied; the
  SQLite actor and account-tree acceptance cannot fully pass without it.
- **Account-tree vector.** The synthetic vector now matches across tracks.
  The real-book vector is still pending the owner's fixture.
- **Purchases.** Standalone use is free with an optional one-time StoreKit 2
  unlock (open question). Hosting is bought on the web; Apple may require the
  subscription to be sold in the app too. Decide before P5.
- **Int64 vs web bigint.** GnuCash values fit 64-bit integers in practice; the
  web uses `bigint`. If a fixture exceeds `Int64`, fail loudly rather than
  truncate.

## P0 / mobile status

See `docs/plans/P0.md` and `docs/plans/P1-MOBILE.md`. P0 exits when all six items and the exit gate close,
vectors replay, and the owner has installed the empty app on a physical iPhone.
