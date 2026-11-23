<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# TestFlight setup (owner)

The iPhone app is standalone and free. The only product is the optional
one-time **Supporter** consumable `guru.parso.saldima.support.dev`; it never
unlocks a feature.

## 1. Apple identifiers

1. Apple Developer → Certificates, Identifiers & Profiles → Identifiers:
   - App ID `guru.parso.saldima` (explicit), In-App Purchase enabled.
2. App Store Connect → My Apps → **+ New App**:
   - Name: `Saldima`
   - Bundle ID: `guru.parso.saldima`
   - SKU: e.g. `saldima-ios`
   - Primary language, iOS.

## 2. Supporter product

App Store Connect → Saldima → Monetization → **In-App Purchases** → Create:

- Type: **Consumable**
- Product ID: `guru.parso.saldima.support.dev`
- Reference name: `Supporter`
- Price: your choice (Voxglass uses $9.99)
- Localization and review screenshot
- Save; status should be Ready to Submit (TestFlight can use it in sandbox).

Create a Sandbox tester under Users and Access → Sandbox → Testers; when the
purchase sheet appears on device, sign in with that tester.

## 3. Distribution signing

1. Xcode → Settings → Accounts → your team → Manage Certificates → create
   **Apple Distribution**; export it as a `.p12` with a password.
2. Developer portal → Profiles → Distribution → App Store, bundle
   `guru.parso.saldima`; download `.mobileprovision`.
3. App Store Connect → Users and Access → Integrations → **App Store Connect
   API** → Team Keys → generate a key with App Manager access; download the
   `.p8` **once** and note the Key ID and Issuer ID.

## 4. GitHub `ios-release` environment

Create the environment with **you as required reviewer**. Add secrets:

| Secret | Value |
| --- | --- |
| `APP_STORE_CONNECT_KEY_ID` | Key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | Issuer ID |
| `APP_STORE_CONNECT_API_KEY_P8_BASE64` | `base64 < AuthKey_XXX.p8 \| tr -d '\n'` |
| `BUILD_CERTIFICATE_BASE64` | `base64 < distribution.p12 \| tr -d '\n'` |
| `BUILD_PROVISION_PROFILE_BASE64` | `base64 < profile.mobileprovision \| tr -d '\n'` |
| `DEVELOPMENT_TEAM_ID` | Apple Team ID |
| `KEYCHAIN_PASSWORD` | any strong temporary keychain password |
| `P12_PASSWORD` | password you set on the `.p12` |

```sh
gh secret set APP_STORE_CONNECT_KEY_ID --env ios-release
gh secret set APP_STORE_CONNECT_ISSUER_ID --env ios-release
gh secret set APP_STORE_CONNECT_API_KEY_P8_BASE64 --env ios-release
gh secret set BUILD_CERTIFICATE_BASE64 --env ios-release
gh secret set BUILD_PROVISION_PROFILE_BASE64 --env ios-release
gh secret set DEVELOPMENT_TEAM_ID --env ios-release
gh secret set KEYCHAIN_PASSWORD --env ios-release
gh secret set P12_PASSWORD --env ios-release
```

The `.p12` must contain the Apple Distribution certificate and its private key.

## 5. Build and TestFlight

1. Actions → **testflight** → Run workflow (main). The job waits for your
   approval on `ios-release`.
2. The archive uploads to App Store Connect (build number = commit count,
   marketing version `0.1.0`).
3. TestFlight → Saldima → Internal Testing → add yourself; install the
   TestFlight app on the iPhone and accept the invite.
4. The device must meet the app’s iOS 27 deployment target.

The agent never uploads or approves; this lane is owner-only. If the build fails
with signing, check the certificate/profile pair and the bundle ID.

## 6. What to verify

- Install from TestFlight.
- Create/open a standalone book and confirm it works with the network off.
- Open Settings → Supporter; cancel once, then buy with the sandbox tester.
  Confirm the thanks/badge appears and every feature still works without it.
- Optional link mode: sign in, download/upload, and confirm the local file is
  unaffected when the link is removed.
