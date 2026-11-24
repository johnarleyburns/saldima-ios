<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# iOS design audit 1 — Liquid Glass (iOS 27 SDK)

Scope: `Saldima/App`, `Saldima/DesignSystem`, `Saldima/Features`, asset catalog,
`project.yml` and the archive settings. Build 20 (Xcode 27.2, deployment target
27.0) was the baseline.

## What we found

| # | Area | Finding | Verdict |
| --- | --- | --- | --- |
| 1 | SDK + deployment | Built with Xcode 27.2 against the iOS 27 SDK, target 27.0, no `UIDesignRequiresCompatibility` opt-out | Correct; the shell gets system glass automatically |
| 2 | Tab bar | Plain `TabView` — it *does* get the floating glass tab bar, but it never minimises on scroll | Under-used: add `tabBarMinimizeBehavior(.onScrollDown)` |
| 3 | Custom surfaces | Accounts summary and empty states used opaque list rows and default buttons; no `glassEffect` anywhere | Missing: the app's own surfaces ignored the material language |
| 4 | Primary actions | `.borderedProminent` buttons (New book, Create, Support) | Not glass: switch to `.glassProminent` |
| 5 | App icon | One universal 1024 image, no dark or tinted appearance | Incomplete: iOS 26/27 expects appearance variants |
| 6 | Grouping | Summary values sat in a list footer, away from the account rows | Fix: a glass summary capsule above the tree, grouped with `GlassEffectContainer` |
| 7 | Typography | Account names used `.headline`/`.body` without tabular figures for money | Fix: monospaced digits on amounts |

## Applied in this change

- `GlassEffectContainer` + `.glassEffect(.regular, in:)` for the accounts
  summary (Net assets, Profit) and the no-book empty state.
- `.buttonStyle(.glassProminent)` on primary actions.
- `.tabBarMinimizeBehavior(.onScrollDown)` so the tab bar behaves like iOS 27
  apps when scrolling long account lists.
- App icon dark and tinted appearance entries sharing the 1024 artwork.
- Explicit `UIDesignRequiresCompatibility: false` in the generated Info.plist so
  a future default cannot silently opt us out of Liquid Glass.

## Deliberate choices

- No custom blur/backdrop imitations: system glass only, so reduced-transparency
  and increased-contrast accessibility settings keep working.
- The account tree stays a `List`; glass belongs to chrome and summary surfaces,
  not to every row.
- Numbers keep half-even display from the accounting kernel; the design layer
  never rounds.

## Follow-ups

- Register and reports chrome with glass toolbars once those screens land.
- Icon Composer (`.icon`) artwork once the owner supplies final brand art.
- Visual QA on device: light/dark, tinted icon, reduced transparency, VoiceOver.
