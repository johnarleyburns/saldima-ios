<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Saldima --- Technical Design and Implementation Blueprint

**Status:** Architecture baseline\
**Audience:** Engineering, security, product\
**Scope:** GnuCash-compatible mobile and web accounting clients,
optional zero-knowledge cloud sync, explicit desktop file exchange,
multi-device and multi-book reconciliation.

------------------------------------------------------------------------

## 1. Executive summary

Saldima is a new, clean-room implementation of a GnuCash-compatible
accounting application. It is not a fork of GnuCash and does not modify
or replace the official desktop GnuCash application.

The defining architecture decisions are:

1.  **GnuCash XML is the canonical book format** for Saldima web and
    mobile.
2.  **No SQLite** is used in Saldima web or mobile as an accounting
    store. No SQLite WASM.
3.  Web and mobile are independent accounting clients. Each can create,
    open, edit, save, import, and export books without an account or
    network connection.
4.  Cloud sync is optional. When enabled, clients synchronize encrypted
    whole-book snapshots. The cloud service cannot decrypt books or
    receipts.
5.  The official desktop GnuCash application remains unmodified. Desktop
    exchange is explicit: upload a file to Saldima, or download a
    synchronized file and open it in GnuCash. There is no desktop agent,
    daemon, file watcher, or automatic desktop sync.
6.  Reconciliation is performed on clients, using the GnuCash object
    model and stable object GUIDs. It is not a server-side accounting
    merge.
7.  Receipts are encrypted attachment objects stored separately from
    book snapshots. The book contains references to attachments
    associated with transaction GUIDs.
8.  The product should minimize third-party JavaScript, avoid analytics
    and third-party runtime scripts, and keep the security-critical
    surface small.

The cloud is a ciphertext storage, version-distribution, and
coordination service. It does not understand account balances,
transaction splits, payees, or receipt contents.

### System overview

``` text
                         OPTIONAL CLOUD
                  ┌──────────────────────────┐
                  │ Authentication / API     │
                  │ Ciphertext snapshot store│
                  │ Encrypted attachment store│
                  │ Version ancestry / heads │
                  │ Device public keys       │
                  │ No plaintext book data   │
                  └────────────┬─────────────┘
                               │ ciphertext only
                 ┌─────────────┴─────────────┐
                 │                           │
          ┌──────▼──────┐             ┌──────▼──────┐
          │ Saldima Web │             │ Saldima App │
          │ local book  │             │ local book  │
          │ XML         │             │ XML         │
          │ local keys  │             │ local keys  │
          └──────┬──────┘             └──────┬──────┘
                 │                           │
                 └─────────────┬─────────────┘
                               │ explicit file exchange
                        ┌──────▼──────┐
                        │ User's file │
                        └──────┬──────┘
                               │
                        ┌──────▼──────┐
                        │ Official    │
                        │ GnuCash     │
                        │ desktop app │
                        └─────────────┘
```

------------------------------------------------------------------------

## 2. Product boundaries and operating modes

### 2.1 Offline mode

Offline mode is a complete product mode, not a degraded trial:

-   No account required.
-   No cloud dependency.
-   One or more local books.
-   Local XML book persistence.
-   Local receipt storage.
-   Import and export.
-   Full accounting functionality supported by the clean-room engine.
-   No background synchronization.
-   The user can continue using the book even if Saldima's cloud service
    is unavailable or discontinued.

### 2.2 Optional cloud mode

When a user enables sync:

-   The client creates or joins an encrypted book identity.
-   Each device is enrolled and authorized.
-   The client encrypts snapshots and attachments before upload.
-   The server stores ciphertext and limited coordination metadata.
-   Clients download ciphertext, decrypt locally, reconcile locally, and
    upload a new snapshot.
-   Devices can be revoked.
-   A user can disable cloud sync without losing the local book.

### 2.3 Official desktop GnuCash

Desktop support is intentionally explicit and conservative:

-   Do not install a Saldima desktop daemon, plugin, file watcher, or
    sync agent.
-   Do not modify GnuCash.
-   Accept supported GnuCash files through a browser file picker.
-   Identify the file format before import. GnuCash installations may
    use XML-based files or a SQLite-backed book file, depending on how
    the book is stored.
-   Implement a dedicated import/export adapter for each supported
    desktop format. Do not assume that a SQLite-backed desktop file is
    an XML file.
-   Prefer GnuCash's own XML interchange/export path where practical and
    documented.
-   For an upload, the client reads and imports the selected file,
    validates it, then creates a Saldima-native XML snapshot and
    encrypts that snapshot.
-   For a download, the client decrypts the selected cloud snapshot and
    exports a GnuCash-compatible file. If the user needs a SQLite-backed
    desktop book, use an explicit conversion/export workflow supported
    by GnuCash rather than writing SQLite database pages yourself.
-   A desktop upload based on an old ancestor must create a branch or
    trigger reconciliation. It must never silently overwrite newer cloud
    data.

**Important:** Treat desktop file import/export as a format-adapter
boundary. The canonical Saldima model remains GnuCash XML; desktop
storage implementation details must not leak into the sync protocol.

------------------------------------------------------------------------

## 3. Architecture and module boundaries

Keep the system divided into independently testable layers.

``` text
┌───────────────────────────────────────────────────────────────┐
│ Presentation                                                  │
│ HTML + CSS + small first-party TypeScript                     │
├───────────────────────────────────────────────────────────────┤
│ Application services                                           │
│ book lifecycle, commands, validation, import/export, sync UX   │
├───────────────────────────────────────────────────────────────┤
│ Accounting domain                                              │
│ accounts, commodities, prices, transactions, splits, lots     │
│ GUID identity, invariants, reconciliation                     │
├───────────────────────────────────────────────────────────────┤
│ GnuCash XML adapter                                            │
│ parse, normalize, preserve unknown data, serialize, gzip       │
├───────────────────────────────────────────────────────────────┤
│ Local persistence                                              │
│ XML document files/blobs, attachment files, local metadata     │
├───────────────────────────────────────────────────────────────┤
│ Security                                                       │
│ key derivation, key wrapping, AEAD, device enrollment          │
├───────────────────────────────────────────────────────────────┤
│ Cloud adapter                                                  │
│ ciphertext upload/download, version DAG, attachment transport │
└───────────────────────────────────────────────────────────────┘
```

### 3.1 Architectural rules

-   The accounting domain must not depend on the DOM, browser storage,
    HTTP, or UI.
-   The XML adapter must not depend on UI state.
-   The sync protocol must not contain transaction-level commands.
-   The cloud API must not accept plaintext book XML.
-   Encryption must happen before any upload request is constructed.
-   A snapshot must be immutable once assigned a snapshot UUID.
-   Never mutate a snapshot already uploaded. A new edit creates a new
    snapshot.
-   A merge must be validated before it becomes the new local head.
-   All persistence writes must be atomic or recoverable after
    interruption.
-   Unknown XML elements and attributes must survive parse/serialize
    round trips whenever possible.

------------------------------------------------------------------------

## 4. Recommended technology choices

These are starting recommendations, not a mandate to adopt every
package. Pin exact versions, review licenses, audit transitive
dependencies, and keep a software bill of materials.

### 4.1 Web application

  -----------------------------------------------------------------------------
  Concern                 Recommended choice            Reason / notes
  ----------------------- ----------------------------- -----------------------
  Structure               Semantic HTML5                Forms, tables, dialogs,
                                                        navigation,
                                                        accessibility

  Styling                 Modern CSS                    Grid, Flexbox, custom
                                                        properties, responsive
                                                        layout

  Application code        TypeScript, compiled to       Type checking without a
                          modern JavaScript             large runtime framework

  UI framework            None initially                The app is
                                                        local-state-heavy;
                                                        avoid framework/runtime
                                                        complexity

  XML parsing             Native `DOMParser`            Browser-native, no
                                                        parser dependency for
                                                        normal book sizes

  XML serialization       Native `XMLSerializer`        Preserve XML as the
                                                        canonical interchange
                                                        document

  Compression             `CompressionStream` /         Native gzip streams;
                          `DecompressionStream` when    feature-detect and test
                          supported                     target browsers

  Local persistence       Origin Private File System    Store XML files/blobs
                          (OPFS) where available;       and local metadata;
                          IndexedDB fallback            neither replaces XML as
                                                        canonical format

  File import/export      File System Access API where  Explicit desktop file
                          supported; file               exchange
                          input/download fallback       

  Crypto                  libsodium.js                  Audited, established
                          (`libsodium-wrappers-sumo`)   primitives; includes
                                                        Argon2id and
                                                        XChaCha20-Poly1305

  HTTP                    Native `fetch`                No client dependency
                                                        needed

  Tests                   Vitest + Playwright           Unit/integration and
                                                        browser-level tests

  Lint/format             ESLint + Prettier, or Biome   Pick one consistent
                                                        toolchain

  Build                   Vite or esbuild               Small static bundle;
                                                        self-host all runtime
                                                        assets
  -----------------------------------------------------------------------------

Do not use a remote CDN for runtime dependencies. Bundle and self-host
pinned dependencies.

### 4.2 Mobile application

A pragmatic first implementation is a shared TypeScript/HTML/CSS
application hosted in a narrowly scoped native WebView shell. The same
domain engine and UI can run in the browser and in the mobile WebView.

  -----------------------------------------------------------------------
  Concern                 iOS                     Android
  ----------------------- ----------------------- -----------------------
  Shell                   Swift + WKWebView       Kotlin + Android
                                                  WebView

  Secure key storage      Keychain                Android Keystore

  File access             Document Picker / Files Storage Access
                          integration             Framework

  Receipt capture         AVFoundation / Photos   CameraX / photo picker
                          APIs                    

  Background work         BGTaskScheduler,        WorkManager, subject to
                          subject to OS limits    OS limits

  Local storage           App sandbox files;      App-private files;
                          optional native secure  optional native secure
                          storage                 storage

  Bridge                  Explicit allow-listed   Explicit allow-listed
                          message handlers        JavaScript interface or
                                                  message channel
  -----------------------------------------------------------------------

Keep the native bridge narrow. It should expose only operations such as:

-   `readSelectedFile`
-   `writeExportedFile`
-   `captureReceipt`
-   `storeWrappedDeviceKey`
-   `loadWrappedDeviceKey`
-   `requestBackgroundSync`

Do not expose arbitrary native method invocation or filesystem paths to
web content.

A native UI is also possible, but it duplicates presentation work. The
shared WebView approach is a reasonable way to ship one application
surface while retaining native access to keys, files, and camera
hardware.

### 4.3 Accounting engine language

The engine language has not been fixed in this design. Keep the domain
model behind a language-neutral API.

Possible choices:

-   TypeScript: easiest integration with a browser-first XML
    application; use strict types and avoid `any`.
-   Rust compiled to WebAssembly: attractive if the engine needs strong
    invariants, deterministic behavior, and reuse across web/native
    platforms, but introduces WASM build/debug complexity and a Rust
    toolchain.
-   C/C++: possible for a mature portable core, but memory safety and
    FFI complexity need deliberate mitigation.

Do not choose Rust merely because it is fashionable, and do not put
cryptographic primitives in a homegrown engine. The engine should use
vetted crypto libraries through a narrow security module.

A sensible staged plan is to start with a TypeScript domain engine and
establish a stable API. If profiling later shows a real bottleneck, move
isolated hot paths to Rust/WASM without changing the book format or sync
protocol.

### 4.4 Libraries to avoid or use cautiously

-   Avoid a large UI framework unless actual UI complexity justifies it.
-   Avoid runtime CDN scripts, analytics SDKs, tracking pixels, and ad
    scripts.
-   Avoid a general-purpose ORM. The canonical accounting representation
    is XML.
-   Avoid SQLite and SQLite WASM in Saldima web/mobile.
-   Avoid custom XML parsers unless native parsing demonstrably fails
    performance or memory tests.
-   Avoid implementing cryptographic algorithms yourself.
-   Avoid generic object merge libraries for accounting reconciliation.
    Accounting merges require domain-specific rules.
-   Avoid treating GnuCash XML as a simple flat list of transactions. It
    is a graph of related objects with invariants.

------------------------------------------------------------------------

## 5. Repository layout

A monorepo is recommended because the XML model, accounting domain,
crypto envelope, and sync protocol need shared contracts and tests.

``` text
saldima/
├── README.md
├── LICENSES.md
├── SECURITY.md
├── CONTRIBUTING.md
├── package.json
├── pnpm-workspace.yaml
├── pnpm-lock.yaml
├── tsconfig.base.json
├── .github/
│   └── workflows/
│       ├── ci.yml
│       ├── dependency-review.yml
│       └── release.yml
│
├── apps/
│   ├── web/
│   │   ├── index.html
│   │   ├── src/
│   │   │   ├── app/
│   │   │   ├── screens/
│   │   │   ├── components/
│   │   │   ├── styles/
│   │   │   ├── workers/
│   │   │   └── main.ts
│   │   ├── public/
│   │   └── vite.config.ts
│   │
│   └── mobile/
│       ├── webapp/                 # Shared HTML/CSS/TS application
│       ├── ios/
│       │   ├── Saldima/
│       │   └── Saldima.xcodeproj
│       └── android/
│           ├── app/
│           └── settings.gradle.kts
│
├── packages/
│   ├── domain/
│   │   ├── src/
│   │   │   ├── account/
│   │   │   ├── transaction/
│   │   │   ├── split/
│   │   │   ├── commodity/
│   │   │   ├── price/
│   │   │   ├── lot/
│   │   │   ├── guid/
│   │   │   ├── invariants/
│   │   │   └── index.ts
│   │   └── test/
│   │
│   ├── gnucash-xml/
│   │   ├── src/
│   │   │   ├── parse/
│   │   │   ├── serialize/
│   │   │   ├── normalize/
│   │   │   ├── preserve-unknown/
│   │   │   ├── compression/
│   │   │   └── index.ts
│   │   └── fixtures/
│   │
│   ├── import-export/
│   │   ├── src/
│   │   │   ├── detect-format/
│   │   │   ├── gnucash-xml/
│   │   │   ├── desktop-adapters/
│   │   │   └── validation/
│   │   └── fixtures/
│   │
│   ├── crypto/
│   │   ├── src/
│   │   │   ├── kdf.ts
│   │   │   ├── envelope.ts
│   │   │   ├── book-encryption.ts
│   │   │   ├── attachment-encryption.ts
│   │   │   ├── device-keys.ts
│   │   │   └── recovery.ts
│   │   └── test/
│   │
│   ├── local-store/
│   │   ├── src/
│   │   │   ├── book-files.ts
│   │   │   ├── attachment-files.ts
│   │   │   ├── metadata.ts
│   │   │   ├── atomic-write.ts
│   │   │   └── recovery.ts
│   │   └── test/
│   │
│   ├── sync-protocol/
│   │   ├── src/
│   │   │   ├── types.ts
│   │   │   ├── ancestry.ts
│   │   │   ├── heads.ts
│   │   │   ├── upload.ts
│   │   │   ├── download.ts
│   │   │   └── conflict-state.ts
│   │   └── test/
│   │
│   ├── reconciliation/
│   │   ├── src/
│   │   │   ├── three-way/
│   │   │   ├── objects/
│   │   │   ├── transactions/
│   │   │   ├── deletes/
│   │   │   ├── conflicts/
│   │   │   ├── validation/
│   │   │   └── index.ts
│   │   └── fixtures/
│   │
│   ├── attachments/
│   │   ├── src/
│   │   │   ├── manifest.ts
│   │   │   ├── upload-queue.ts
│   │   │   └── transaction-links.ts
│   │   └── test/
│   │
│   └── shared/
│       ├── src/
│       │   ├── result.ts
│       │   ├── ids.ts
│       │   ├── clock.ts
│       │   └── logging.ts
│       └── test/
│
├── services/
│   ├── sync-api/
│   │   ├── src/
│   │   │   ├── routes/
│   │   │   ├── auth/
│   │   │   ├── snapshot-store/
│   │   │   ├── attachment-store/
│   │   │   ├── device-registry/
│   │   │   └── database/
│   │   └── migrations/
│   └── worker/
│       └── src/
│
├── schemas/
│   ├── encrypted-envelope.schema.json
│   ├── sync-manifest.schema.json
│   └── api/
│
├── docs/
│   ├── architecture/
│   ├── threat-model/
│   ├── gnucash-compatibility/
│   ├── sync-protocol/
│   └── decisions/
│
└── test-data/
    ├── official-gnucash/
    ├── synthetic/
    ├── malformed/
    └── round-trip/
```

### Workspace rules

-   `domain` must not import from `apps`, `services`, `local-store`, or
    `crypto`.
-   `gnucash-xml` may depend on `domain`, but not on UI or cloud code.
-   `reconciliation` may depend on `domain` and XML abstractions, but
    not on HTTP.
-   `crypto` must not depend on the accounting domain.
-   `sync-protocol` transports opaque encrypted payloads and metadata.
-   `services/sync-api` must not contain XML parsing or accounting merge
    code.
-   Add dependency-boundary tests or lint rules to enforce these
    constraints.

------------------------------------------------------------------------

## 6. Canonical book model and XML compatibility

### 6.1 XML remains canonical

The GnuCash XML document is the canonical serialized book. The app may
create temporary in-memory indexes and domain objects for performance,
but it must not create a competing canonical accounting database.

The local persistence layer can store XML bytes as files or blobs. OPFS
or IndexedDB may be used as a browser storage mechanism; this does not
change the canonical format decision.

### 6.2 Preserve compatibility data

GnuCash XML may contain data the current Saldima release does not
understand. A clean-room implementation must avoid destroying that data.

Recommended parse representation:

``` ts
export interface ParsedBook {
  /** Original parsed XML document; retained for unknown-node preservation. */
  sourceDocument: Document;

  /** Known, normalized accounting objects. */
  model: BookModel;

  /** Unknown elements/attributes associated with their owning object. */
  extensions: ExtensionStore;

  /** Original file metadata and serialization hints. */
  sourceInfo: SourceInfo;
}
```

For objects with known GUIDs, keep a mapping from GUID to original XML
node. When serializing:

1.  Start from the original document or a carefully cloned document.
2.  Update known fields on their corresponding nodes.
3.  Add nodes for newly created objects.
4.  Remove nodes only when the domain operation explicitly deletes them.
5.  Preserve unknown elements, attributes, namespaces, and extension
    data.
6.  Serialize and validate the result.
7.  Reparse the serialized result in tests to ensure the output is
    readable.

Do not parse a book into a simplified model and then regenerate a
minimal XML document from scratch unless every unsupported element is
intentionally preserved.

### 6.3 XML parse example

``` ts
export interface XmlParseResult {
  document: Document;
  root: Element;
}

export function parseGnuCashXml(xmlText: string): XmlParseResult {
  const parser = new DOMParser();
  const document = parser.parseFromString(xmlText, "application/xml");

  const parserError = document.querySelector("parsererror");
  if (parserError) {
    throw new Error(`Invalid GnuCash XML: ${parserError.textContent ?? "parse error"}`);
  }

  const root = document.documentElement;
  if (!root || root.localName !== "gnc-v2") {
    throw new Error("Unsupported GnuCash XML root element");
  }

  return { document, root };
}
```

This is only the first validation layer. Follow it with
namespace/version checks, required-field checks, GUID uniqueness checks,
reference resolution, and accounting invariants.

### 6.4 Gzip detection and decompression

Do not assume that every selected file is plain XML. Detect supported
compression by its signature and then validate the decompressed content.

``` ts
function isGzip(bytes: Uint8Array): boolean {
  return bytes.length >= 2 && bytes[0] === 0x1f && bytes[1] === 0x8b;
}

async function decompressGzip(bytes: Uint8Array): Promise<Uint8Array> {
  if (typeof DecompressionStream === "undefined") {
    throw new Error("This browser does not support native gzip decompression");
  }

  const stream = new Blob([bytes]).stream().pipeThrough(
    new DecompressionStream("gzip")
  );

  return new Uint8Array(await new Response(stream).arrayBuffer());
}
```

Provide a tested fallback for browsers without the required native
stream APIs. Keep the fallback local and pinned; do not load it from a
CDN at runtime.

### 6.5 Serialization and compression

``` ts
export function serializeXml(document: Document): Uint8Array {
  const xml = new XMLSerializer().serializeToString(document);
  return new TextEncoder().encode(xml);
}

async function compressGzip(bytes: Uint8Array): Promise<Uint8Array> {
  if (typeof CompressionStream === "undefined") {
    throw new Error("This browser does not support native gzip compression");
  }

  const stream = new Blob([bytes]).stream().pipeThrough(
    new CompressionStream("gzip")
  );

  return new Uint8Array(await new Response(stream).arrayBuffer());
}
```

Add round-trip tests against files produced by multiple supported
GnuCash versions. A successful XML parse is not sufficient proof of
GnuCash compatibility.

------------------------------------------------------------------------

## 7. Local book persistence

### 7.1 Local data layout

A local profile may contain:

``` text
SaldimaData/
├── books/
│   └── <book-uuid>/
│       ├── current-book.xml.gz
│       ├── local-manifest.json
│       ├── snapshots/
│       │   ├── <snapshot-uuid>.xml.gz
│       │   └── ...
│       └── attachments/
│           ├── <attachment-uuid>.enc
│           └── ...
└── device/
    ├── device-id
    └── wrapped-device-key
```

For a browser, this logical layout can map to OPFS files and IndexedDB
metadata. Keep the actual XML document as the canonical book data.

### 7.2 Atomic save

Never overwrite the only valid book file in place if a crash could leave
it truncated.

Use a write-new-then-promote pattern:

1.  Serialize the updated book to a new temporary file.
2.  Reparse and validate the temporary file.
3.  Flush/close it.
4.  Atomically replace the current pointer or rename the file where the
    storage API supports it.
5.  Retain a previous known-good snapshot until the new file is
    confirmed.

For storage APIs without atomic rename, store immutable snapshot files
and update a small metadata pointer last. On startup, validate the
pointer target and recover to the newest valid snapshot if necessary.

``` ts
export interface LocalBookStore {
  readCurrent(bookId: string): Promise<Uint8Array>;
  writeImmutableSnapshot(
    bookId: string,
    snapshotId: string,
    bytes: Uint8Array
  ): Promise<void>;
  setCurrentSnapshot(
    bookId: string,
    snapshotId: string
  ): Promise<void>;
  listSnapshots(bookId: string): Promise<string[]>;
}
```

The exact OPFS/IndexedDB adapter is platform-specific. Keep it behind
this interface.

------------------------------------------------------------------------

## 8. Zero-knowledge encryption design

### 8.1 Security goals

-   Book contents are encrypted before leaving the device.
-   Receipt contents are encrypted before leaving the device.
-   Passwords and plaintext encryption keys are never sent to the cloud.
-   The service cannot decrypt a book or attachment.
-   A cloud database breach reveals ciphertext and limited metadata, not
    accounting contents.
-   Device revocation prevents future access by the revoked device after
    key rotation/re-enrollment. It cannot erase plaintext or keys
    already copied by a previously authorized device.
-   There is no company master key or hidden recovery backdoor.

### 8.2 Important threat-model limitation

A web application served by the same operator that stores ciphertext has
a first-party code-delivery risk: a malicious or compromised deployment
could serve JavaScript that captures a password or plaintext after
decryption. CSP, no third-party scripts, reproducible builds, signed
releases, strict deployment controls, and separation of static hosting
from the data API reduce risk but do not mathematically eliminate it.

Native applications provide a stronger code-integrity boundary, although
compromised devices remain a risk.

Do not market the system as "zero knowledge" without explaining what
metadata remains visible and the browser delivery limitation.

### 8.3 Cryptographic primitives

Recommended initial suite:

-   Password KDF: Argon2id using libsodium's vetted implementation.
-   Randomness: operating-system CSPRNG through libsodium.
-   Book encryption: XChaCha20-Poly1305 authenticated encryption.
-   Attachment encryption: XChaCha20-Poly1305 for small objects;
    libsodium `secretstream` for large/chunked files.
-   Key wrapping: a separate random key-encryption key or a device
    public-key envelope, using a vetted authenticated construction.
-   Hash: BLAKE2b or SHA-256 for ciphertext integrity identifiers. AEAD
    authentication is still mandatory; a hash is not a replacement for
    authentication.

Use one vetted library consistently across web and mobile where
possible. `libsodium-wrappers-sumo` is a practical JavaScript/WASM
binding because the sumo build includes the password-hashing and
streaming APIs. Verify the exact APIs and build artifacts for the pinned
release before implementation.

Do not use a fast general-purpose hash such as SHA-256 directly as a
password KDF.

### 8.4 Key hierarchy

Use envelope encryption:

``` text
User passphrase
      │
      ▼
 Argon2id(passphrase, salt, parameters)
      │
      ▼
   KEK (key-encryption key)
      │ unwraps
      ▼
 Random DEK (data-encryption key)
      │
      ├── encrypts book snapshots
      └── or wraps per-object attachment keys
```

Recommended separation:

-   `KEK`: derived from the user's passphrase. Used only to wrap/unwrap
    the book DEK.
-   `DEK`: random 256-bit key. Encrypts book snapshots.
-   `Attachment DEK`: random per attachment, wrapped by the book DEK or
    a dedicated attachment-key hierarchy.
-   `Device key pair`: device-specific key material used for secure
    device enrollment and key distribution.
-   `Recovery key`: optional high-entropy user-held secret that can
    unwrap the DEK. Display once and require the user to store it
    safely.

A password change should normally rewrap the DEK with a newly derived
KEK. It should not require re-encrypting every historical snapshot
unless the DEK itself is rotated.

### 8.5 Versioned envelope format

Example logical envelope:

``` ts
export interface EncryptedEnvelopeV1 {
  format: "saldima-envelope";
  version: 1;
  algorithm: "xchacha20-poly1305-ietf";
  kdf: {
    name: "argon2id";
    saltB64: string;
    opsLimit: number;
    memLimit: number;
  };
  keyWrap: {
    algorithm: "xchacha20-poly1305-ietf";
    nonceB64: string;
    wrappedDekB64: string;
  };
  payload: {
    nonceB64: string;
    ciphertextB64: string;
  };
  aad: {
    bookId: string;
    snapshotId: string;
    schemaVersion: number;
  };
}
```

This is a conceptual schema. In production, define canonical
serialization, strict size limits, validation, and domain separation.
Prefer a compact binary envelope for large payloads rather than
base64-encoding a large ciphertext into JSON.

Authenticate immutable identifiers and format version as AEAD associated
data (AAD). The receiver must verify that the decrypted envelope's book
and snapshot identities match the expected context.

### 8.6 Key derivation example

The following is illustrative TypeScript using libsodium's JavaScript
binding. Confirm the API signatures for the pinned package version and
add tests using fixed test vectors.

``` ts
import sodium from "libsodium-wrappers-sumo";

export interface KdfParams {
  opsLimit: number;
  memLimit: number;
}

export async function deriveKek(
  passphrase: string,
  salt: Uint8Array,
  params: KdfParams
): Promise<Uint8Array> {
  await sodium.ready;

  if (salt.length !== sodium.crypto_pwhash_SALTBYTES) {
    throw new Error("Invalid Argon2id salt length");
  }

  return sodium.crypto_pwhash(
    sodium.crypto_aead_xchacha20poly1305_ietf_KEYBYTES,
    passphrase,
    salt,
    params.opsLimit,
    params.memLimit,
    sodium.crypto_pwhash_ALG_ARGON2ID13
  );
}
```

Operational requirements:

-   Benchmark KDF parameters on the slowest supported mobile device.
-   Store the selected parameters with the envelope.
-   Enforce safe upper bounds before running a KDF on untrusted envelope
    data. Otherwise an attacker could submit parameters intended to
    exhaust memory or CPU.
-   Never log passphrases, derived keys, DEKs, plaintext XML, or
    decrypted receipts.
-   Clear temporary key buffers where the runtime permits. JavaScript
    garbage collection means reliable zeroization cannot be guaranteed.
-   Rate-limit authentication separately from local password derivation.

### 8.7 Book encryption example

``` ts
import sodium from "libsodium-wrappers-sumo";

export async function encryptBookBytes(
  plaintext: Uint8Array,
  dek: Uint8Array,
  aad: Uint8Array
): Promise<{ nonce: Uint8Array; ciphertext: Uint8Array }> {
  await sodium.ready;

  const nonce = sodium.randombytes_buf(
    sodium.crypto_aead_xchacha20poly1305_ietf_NPUBBYTES
  );

  const ciphertext = sodium.crypto_aead_xchacha20poly1305_ietf_encrypt(
    plaintext,
    aad,
    null,
    nonce,
    dek
  );

  return { nonce, ciphertext };
}

export async function decryptBookBytes(
  ciphertext: Uint8Array,
  nonce: Uint8Array,
  dek: Uint8Array,
  aad: Uint8Array
): Promise<Uint8Array> {
  await sodium.ready;

  return sodium.crypto_aead_xchacha20poly1305_ietf_decrypt(
    null,
    ciphertext,
    aad,
    nonce,
    dek
  );
}
```

Never reuse a nonce with the same key. Generate a fresh random nonce for
every encryption operation and persist the nonce alongside the
ciphertext. For systems with very high encryption volume under one key,
consider per-snapshot subkeys or rotate the DEK according to a
documented policy.

### 8.8 Key wrapping example

Use a fresh nonce and authenticate the book identity and envelope
version:

``` ts
export async function wrapDek(
  dek: Uint8Array,
  kek: Uint8Array,
  bookId: string
): Promise<{ nonce: Uint8Array; wrapped: Uint8Array }> {
  await sodium.ready;

  const nonce = sodium.randombytes_buf(
    sodium.crypto_aead_xchacha20poly1305_ietf_NPUBBYTES
  );
  const aad = new TextEncoder().encode(`saldima:dek-wrap:v1:${bookId}`);

  const wrapped = sodium.crypto_aead_xchacha20poly1305_ietf_encrypt(
    dek,
    aad,
    null,
    nonce,
    kek
  );

  return { nonce, wrapped };
}
```

The unwrap operation must use exactly the same AAD construction and
reject authentication failure.

### 8.9 Password change and recovery

Password change:

1.  Derive the old KEK locally.
2.  Unwrap the DEK.
3.  Generate a new salt.
4.  Derive a new KEK using the new passphrase.
5.  Wrap the same DEK under the new KEK with a fresh nonce.
6.  Upload the updated key envelope.
7.  Keep old envelope recovery only as long as needed for a safe
    transition, then retire it according to policy.

Recovery:

1.  Generate a high-entropy recovery secret locally.
2.  Derive or use a recovery wrapping key from that secret.
3.  Wrap the DEK.
4.  Display the recovery secret once, with clear warnings.
5.  Do not upload the recovery secret.
6.  Test recovery on a second device before declaring setup complete.

If the user loses both the passphrase and recovery material, the cloud
cannot recover the book. This is an intentional consequence of the
design.

### 8.10 Device enrollment

A device should not receive a DEK merely because it can authenticate to
the user's account.

Recommended flow:

1.  New device generates a device key pair in its secure platform
    storage.
2.  New device authenticates to the account and registers its public
    key.
3.  An already trusted device displays an approval request.
4.  The trusted device verifies the new device and encrypts a DEK
    envelope to its public key using a vetted public-key authenticated
    encryption protocol.
5.  The new device decrypts locally and stores its key material in
    Keychain/Keystore or an appropriately protected local store.
6.  The server stores public keys and encrypted envelopes only.

For multi-device key distribution, use a reviewed protocol/library
rather than inventing a public-key handshake. Define revocation and key
rotation before shipping.

------------------------------------------------------------------------

## 9. Receipt and attachment design

Receipts should not be embedded as base64 blobs inside every book
snapshot.

### 9.1 Attachment object

``` ts
export interface AttachmentManifest {
  attachmentId: string;
  bookId: string;
  transactionGuid: string;
  mediaType: string;
  byteLength: number;
  ciphertextHash: string;
  encryptionVersion: number;
  createdAt: string;
}
```

The manifest itself must be encrypted or included in encrypted book
metadata if its fields are sensitive. The cloud may need a random opaque
object ID and ciphertext length for transport, but should not receive a
plaintext transaction GUID, filename, merchant, or MIME type unless the
user explicitly accepts that metadata disclosure.

### 9.2 Upload flow

1.  Capture or select a receipt.
2.  Optionally OCR locally. Do not send receipt content to a third-party
    OCR service by default.
3.  Generate a random attachment key.
4.  Encrypt the receipt locally. For large files, use authenticated
    chunked streaming.
5.  Wrap the attachment key under the book DEK.
6.  Upload ciphertext under an opaque attachment ID.
7.  Add the encrypted attachment reference to the local book metadata.
8.  Sync the updated book snapshot.
9.  On another device, download ciphertext, unwrap the attachment key,
    authenticate/decrypt, and display locally.

### 9.3 Resumable upload

Use chunked upload for large attachments:

-   Each chunk is independently authenticated or handled through a
    vetted streaming AEAD construction.
-   Include sequence number and attachment ID in authenticated context.
-   Do not concatenate unauthenticated chunks and treat the result as
    trusted.
-   Keep a local upload queue with retry state.
-   Make upload idempotent using attachment ID plus chunk index.
-   A partially uploaded object is not visible as complete until the
    server confirms finalization.

------------------------------------------------------------------------

## 10. Multi-book model

A user can own multiple independent books. Each book has its own
identity, encryption context, version graph, and synchronization state.

### 10.1 Identity

``` ts
export interface BookIdentity {
  bookId: string;            // random UUID, stable for life of book
  createdAt: string;
  formatFamily: "gnucash-xml";
  schemaVersion: number;
}
```

Never use a filename as a book identity. Users can rename files and can
have two books with the same display name.

### 10.2 Local catalog

A local catalog can track:

``` ts
export interface LocalBookCatalogEntry {
  bookId: string;
  displayName: string;
  localCurrentSnapshotId: string;
  cloudBookId?: string;
  syncEnabled: boolean;
  lastSuccessfulSyncAt?: string;
  syncState: "local-only" | "in-sync" | "pending-upload" |
             "pending-download" | "conflict" | "error";
}
```

The catalog is local application metadata, not an alternate accounting
database.

### 10.3 Book isolation

-   Each book has a distinct DEK.
-   Each book has a distinct snapshot ancestry graph.
-   Each book has its own attachment namespace.
-   Syncing one book must not implicitly upload another.
-   A device can be authorized for some books and not others.
-   Book deletion must distinguish local deletion from cloud deletion.
-   Cloud deletion should use a tombstone and explicit confirmation,
    with a retention/recovery period.

### 10.4 Multiple books and duplicate imports

If the user imports a file that appears to be an existing book:

-   Do not merge based only on filename or display name.
-   Compare known book identity metadata if present.
-   Compare stable GUID sets and content fingerprints as supporting
    evidence.
-   Ask whether to open as a separate copy, replace a local copy, or
    reconcile with an existing book.
-   If identity cannot be proven, default to a new independent book.

------------------------------------------------------------------------

## 11. Snapshot sync protocol

### 11.1 Whole-book snapshots, not event sync

The synchronization protocol exchanges encrypted whole-book snapshots.
It does not exchange individual transaction events or server-interpreted
accounting operations.

The client may internally compare objects and transactions to produce a
safe merge. That is a local implementation detail; the cloud only sees
encrypted blobs and opaque ancestry metadata.

### 11.2 Snapshot identity

``` ts
export interface SnapshotDescriptor {
  bookId: string;
  snapshotId: string;
  parentSnapshotIds: string[];
  deviceId: string;
  createdAt: string;
  ciphertextHash: string;
  ciphertextByteLength: number;
  envelopeVersion: number;
}
```

A snapshot is immutable. `parentSnapshotIds` has:

-   zero parents for the initial snapshot,
-   one parent for a normal linear edit,
-   two parents for a merge snapshot.

Use random UUIDs for identifiers. Do not use timestamps as ordering
authority.

### 11.3 Version graph

``` text
                 V1
                /  \
               /    \
            V2A      V2B
               \    /
                \  /
                 V3
```

V2A and V2B are independent descendants of V1. A client downloads both,
decrypts them, performs a three-way merge using V1 as the common
ancestor, validates the result, and uploads V3 with both V2A and V2B as
parents.

### 11.4 Cloud API outline

``` text
POST   /v1/books
GET    /v1/books
GET    /v1/books/{bookId}/heads
GET    /v1/books/{bookId}/snapshots/{snapshotId}
PUT    /v1/books/{bookId}/snapshots/{snapshotId}
POST   /v1/books/{bookId}/attachments/{attachmentId}/begin
PUT    /v1/uploads/{uploadId}/chunks/{chunkIndex}
POST   /v1/uploads/{uploadId}/complete
GET    /v1/books/{bookId}/attachments/{attachmentId}
POST   /v1/devices
POST   /v1/devices/{deviceId}/revoke
```

The server validates authentication, authorization, payload size,
ancestry references, and ciphertext hash. It does not decrypt the
payload or validate accounting content.

### 11.5 Upload concurrency

Use optimistic concurrency:

1.  Client fetches current cloud heads.
2.  Client determines whether its local snapshot descends from those
    heads.
3.  Client uploads immutable ciphertext.
4.  Client asks the server to register the new snapshot and its parent
    IDs.
5.  Server atomically updates the head set only if the expected head
    state still matches.
6.  If another device advanced the head, return a conflict response
    containing current head IDs.
7.  Client downloads missing heads and reconciles locally.

The server must not implement "last writer wins" for book content.

------------------------------------------------------------------------

## 12. Multi-book synchronization workflow

The following is the end-to-end sync algorithm for a local book.

``` text
START
  |
  v
Load local book + local snapshot ancestry
  |
  v
Fetch cloud head IDs
  |
  v
Are cloud heads already ancestors of local head?
  | yes
  v
Upload local head if not already uploaded
  |
  v
Attempt atomic head update
  |
  +---- success ---> mark in sync
  |
  +---- conflict --> download current cloud heads
                       |
                       v
                decrypt and validate
                       |
                       v
              find common ancestor(s)
                       |
                       v
                 three-way merge
                       |
             +---------+----------+
             |                    |
         no conflict          conflict
             |                    |
             v                    v
       validate merged      preserve branches;
       accounting model     present resolution UI
             |                    |
             v                    v
       create new snapshot   user resolves conflicts
       with both parents          |
             |                    v
             +--------------> validate
                                  |
                                  v
                           encrypt + upload
                                  |
                                  v
                            update cloud head
```

### 12.1 More than two heads

A book can have more than two concurrent heads if several devices work
offline.

Do not assume the graph always forks into exactly two branches. The
reconciliation service should:

1.  Fetch all current heads.
2.  Find a lowest common ancestor (or a suitable common ancestor set in
    a more complex DAG).
3.  Build the base state.
4.  Merge branch changes incrementally or use a multi-branch
    reconciliation plan.
5.  Preserve all source head IDs as parents of the resulting merge
    snapshot.
6.  If the merge cannot be proven safe, keep the branches and require
    user resolution.

For the first release, it is reasonable to support two-way concurrent
merges and preserve unresolved multi-head states for manual resolution.
Do not silently discard a branch.

### 12.2 Sync state machine

``` ts
export type SyncState =
  | "idle"
  | "checking"
  | "uploading"
  | "downloading"
  | "decrypting"
  | "reconciling"
  | "needs-user-resolution"
  | "finalizing"
  | "in-sync"
  | "offline"
  | "failed";
```

The UI should expose a concise state and a meaningful error. Never show
"synced" until the server confirms the snapshot/head registration and
the local metadata has been committed.

------------------------------------------------------------------------

## 13. Reconciliation model

### 13.1 Why ordinary text merge is wrong

A GnuCash book is a structured accounting graph. It contains accounts,
transactions, splits, commodities, prices, schedules, lots, and
references. A line-oriented XML merge can:

-   break parent/child references,
-   duplicate GUIDs,
-   detach splits from transactions,
-   leave transactions unbalanced,
-   delete an object still referenced elsewhere,
-   lose unknown XML extensions,
-   create an invalid book that appears to save successfully.

Reconcile domain objects by stable identity and relationships. Use XML
text only as a serialization format.

### 13.2 Object identity

Use GnuCash GUIDs as stable identity for existing objects. New objects
receive new random GUIDs before serialization.

Example normalized types:

``` ts
export interface Account {
  guid: string;
  name: string;
  accountType: string;
  parentGuid: string | null;
  commodityId: string;
  fields: Record<string, unknown>;
}

export interface Transaction {
  guid: string;
  currencyId: string;
  postedAt: string;
  enteredAt: string;
  description: string;
  splitGuids: string[];
  fields: Record<string, unknown>;
}

export interface Split {
  guid: string;
  transactionGuid: string;
  accountGuid: string;
  quantityNumerator: bigint;
  quantityDenominator: bigint;
  valueNumerator: bigint;
  valueDenominator: bigint;
  memo?: string;
  reconcileState?: string;
  fields: Record<string, unknown>;
}
```

Use exact rational arithmetic for monetary quantities and values. Do not
use JavaScript floating-point numbers for accounting amounts.

### 13.3 Three-way merge rule

For each object field, compare:

-   `base`: value in common ancestor,
-   `local`: value in the local branch,
-   `remote`: value in the remote branch.

Rules:

  Local vs base           Remote vs base       Result
  ----------------------- -------------------- -----------------------------
  unchanged               changed              take remote
  changed                 unchanged            take local
  same change             same change          take either identical value
  different changes       different changes    conflict
  object absent in both   absent               absent
  deleted locally         unchanged remotely   delete
  unchanged locally       deleted remotely     delete
  deleted on one side     modified on other    conflict

Do not apply these rules blindly to every field. Some fields are
derived, some have special merge semantics, and some objects must be
handled atomically.

### 13.4 Generic field merge example

``` ts
export type MergeResult<T> =
  | { kind: "merged"; value: T }
  | { kind: "conflict"; base: T; local: T; remote: T };

export function mergeScalar<T>(
  base: T,
  local: T,
  remote: T,
  equals: (a: T, b: T) => boolean = Object.is
): MergeResult<T> {
  const localChanged = !equals(local, base);
  const remoteChanged = !equals(remote, base);

  if (!localChanged && !remoteChanged) {
    return { kind: "merged", value: base };
  }

  if (localChanged && !remoteChanged) {
    return { kind: "merged", value: local };
  }

  if (!localChanged && remoteChanged) {
    return { kind: "merged", value: remote };
  }

  if (equals(local, remote)) {
    return { kind: "merged", value: local };
  }

  return { kind: "conflict", base, local, remote };
}
```

For object fields, use a canonical deep equality function that handles
rational values, dates, optional fields, and normalized XML values. Do
not compare object references.

### 13.5 Object-level merge example

``` ts
export type ObjectMerge<T> =
  | { kind: "merged"; value: T | null }
  | { kind: "conflict"; reason: string; base: T | null;
      local: T | null; remote: T | null };

export function mergeObject<T>(
  base: T | null,
  local: T | null,
  remote: T | null,
  equals: (a: T, b: T) => boolean
): ObjectMerge<T> {
  if (base === null) {
    if (local === null) return { kind: "merged", value: remote };
    if (remote === null) return { kind: "merged", value: local };
    if (equals(local, remote)) return { kind: "merged", value: local };

    return {
      kind: "conflict",
      reason: "Both branches independently created an object with the same identity",
      base, local, remote
    };
  }

  if (local === null && remote === null) {
    return { kind: "merged", value: null };
  }

  if (local === null) {
    if (equals(base, remote!)) return { kind: "merged", value: null };
    return {
      kind: "conflict",
      reason: "Object was deleted locally but modified remotely",
      base, local, remote
    };
  }

  if (remote === null) {
    if (equals(base, local)) return { kind: "merged", value: null };
    return {
      kind: "conflict",
      reason: "Object was modified locally but deleted remotely",
      base, local, remote
    };
  }

  // Existing object on all three branches: merge fields individually.
  return mergeDomainObjectFields(base, local, remote);
}
```

`mergeDomainObjectFields` is intentionally domain-specific. It should
enumerate supported fields, apply field-specific policies, and preserve
extension data. Do not use unrestricted object spread to resolve
conflicts.

### 13.6 Transaction atomicity

A transaction and all its splits form an atomic accounting unit.

When a transaction changes:

-   Compare the transaction and its split set together.
-   A transaction's split membership is part of its semantic state.
-   Never merge half of a transaction from one branch with half from
    another.
-   Validate that every split references an existing account and
    transaction.
-   Validate that the transaction balances in its transaction currency
    using exact rational arithmetic.
-   If both branches independently edit the same transaction, treat it
    as a transaction-level conflict unless a safe, explicitly
    implemented field-level merge is possible.
-   A new transaction created on one branch and a different new
    transaction created on the other branch can usually both be retained
    because their GUIDs differ.

### 13.7 Transaction merge skeleton

``` ts
export interface TransactionAggregate {
  transaction: Transaction;
  splits: Split[];
}

export function transactionEquals(
  a: TransactionAggregate,
  b: TransactionAggregate
): boolean {
  return canonicalTransaction(a) === canonicalTransaction(b);
}

export function mergeTransaction(
  base: TransactionAggregate | null,
  local: TransactionAggregate | null,
  remote: TransactionAggregate | null
): ObjectMerge<TransactionAggregate> {
  return mergeObject(
    base,
    local,
    remote,
    transactionEquals
  );
}
```

The first production version should prefer a clear conflict over a risky
automatic merge. More granular transaction merging can be added after
there are extensive tests and proven accounting invariants.

### 13.8 Account hierarchy merge

Accounts have parent relationships. Merge account objects first, then
validate the resulting hierarchy:

-   Every non-null parent GUID exists.
-   No account is its own parent.
-   No parent cycle exists.
-   Required root account constraints are satisfied.
-   Commodity references exist.
-   Account types and commodity constraints are valid.

If two branches move an account to different parents, raise a conflict.
If one branch renames an account and the other changes its parent, those
fields may be merged independently if the domain rules allow it.

### 13.9 Deletion handling

Never interpret missing XML as a deletion without a base snapshot.

A deletion is determined by comparing the object identity set against
the common ancestor. Use tombstones in the reconciliation plan, not
necessarily in the serialized GnuCash XML.

Before accepting a deletion, check references:

-   account referenced by splits,
-   commodity referenced by accounts/prices,
-   transaction referenced by attachment metadata,
-   scheduled transaction references,
-   lot or price references.

A delete that leaves dangling references is rejected or converted into a
user conflict.

### 13.10 Conflict object and UI

``` ts
export interface ReconciliationConflict {
  conflictId: string;
  objectType: "account" | "transaction" | "split" |
              "commodity" | "price" | "lot" | "extension";
  objectGuid: string;
  fieldPath?: string;
  reason: string;
  baseSummary: string;
  localSummary: string;
  remoteSummary: string;
  resolution?: "keep-local" | "keep-remote" | "manual";
}
```

The UI should explain the accounting impact, not expose raw XML as the
primary experience. For example:

> Transaction "Office supplies" was edited on both devices. The local
> version is dated October 12 and has a total of \$86.40; the remote
> version has a total of \$92.15. Choose which version to keep or edit a
> combined transaction.

Keep both branches until the user confirms resolution. A resolution
action creates a new snapshot with both branch heads as parents.

------------------------------------------------------------------------

## 14. Reconciliation pipeline

A robust merge should be a staged pipeline:

``` text
1. Download encrypted branch snapshots
2. Verify ciphertext hashes and envelope metadata
3. Decrypt locally
4. Decompress and parse XML
5. Validate source snapshots independently
6. Resolve common ancestor(s)
7. Build normalized object indexes by GUID
8. Compute base/local/remote changes
9. Merge independent object changes
10. Detect deletes vs modifications
11. Merge transaction aggregates atomically
12. Validate references and account hierarchy
13. Validate exact transaction balancing
14. Preserve unknown XML extensions
15. Serialize candidate XML
16. Reparse candidate XML
17. Run full accounting invariants
18. Present conflicts or commit merge
19. Create immutable snapshot with all merged heads as parents
20. Encrypt and upload
21. Atomically register the new cloud head
```

Never replace the current local book with a merge candidate before the
candidate passes validation. Store the candidate separately until it is
accepted.

------------------------------------------------------------------------

## 15. Multi-book reconciliation scenarios

### Scenario A: Two devices edit the same book independently

Initial state:

``` text
Cloud head: V1
Phone local: V1
Web local:   V1
```

The phone creates V2P. The web app creates V2W. Syncing the phone first
makes V2P a cloud head. When web syncs, it discovers V2P and recognizes
that its local V2W is a sibling.

The web client downloads V2P and V1, performs a three-way merge, then
creates V3 with parents `[V2P, V2W]`.

### Scenario B: Two devices edit different transactions

-   Phone adds a grocery transaction with new GUID T-A.
-   Web adds a utility transaction with new GUID T-B.
-   Neither branch modifies the other's objects.
-   Both transactions can be retained.
-   Validate each transaction's splits, account references, and balance.
-   Create a merged snapshot.

### Scenario C: Two devices edit the same transaction

-   Phone changes the amount of transaction T-1.
-   Web changes the account split of transaction T-1.
-   Unless the engine can prove these edits are semantically independent
    and valid, create a transaction conflict.
-   Keep both source versions.
-   Let the user choose or manually create a corrected transaction.

### Scenario D: Desktop upload is behind cloud

-   Cloud head is V5.
-   User opens an older local desktop copy derived from V3 and uploads
    it.
-   The client must identify that the desktop file is not descended from
    V5.
-   It creates a desktop-import branch from V3.
-   The client downloads V5 and attempts reconciliation with V3 as
    common ancestor.
-   If no reliable ancestry can be established, do not auto-merge.
    Import as a separate book or request user direction.

### Scenario E: User has multiple books

-   Book A is synced on phone and web.
-   Book B is local-only on phone.
-   Book C is synced only on web.
-   Syncing Book A must not upload B or download C unless the user has
    enabled those books for that device.
-   The book catalog should display per-book sync state.

### Scenario F: More than two concurrent devices

-   Phone creates V2P.
-   Web creates V2W.
-   Tablet, offline, creates V2T.
-   Cloud may have multiple heads.
-   The reconciliation engine must preserve all branches.
-   It can merge incrementally, but the final merge snapshot must
    include ancestry that makes all contributing heads ancestors.
-   If the engine cannot safely merge one branch, retain it as an
    unresolved head.

------------------------------------------------------------------------

## 16. Sync client pseudocode

``` ts
export async function synchronizeBook(
  bookId: string,
  deps: SyncDependencies
): Promise<SyncOutcome> {
  const local = await deps.localBooks.getCurrent(bookId);
  const cloudHeads = await deps.remote.getHeads(bookId);

  if (cloudHeads.length === 0) {
    const uploaded = await deps.uploadSnapshot(local);
    await deps.remote.registerHead({
      bookId,
      snapshotId: local.snapshotId,
      parentSnapshotIds: local.parentSnapshotIds,
      expectedHeads: []
    });
    await deps.localBooks.markSynced(bookId, uploaded.snapshotId);
    return { kind: "in-sync", snapshotId: uploaded.snapshotId };
  }

  const relation = await deps.ancestry.compare(
    local.snapshotId,
    cloudHeads.map(h => h.snapshotId)
  );

  if (relation.kind === "local-descends-from-all-cloud-heads") {
    await deps.uploadIfNeeded(local);
    const result = await deps.remote.tryAdvanceHeads({
      bookId,
      newSnapshotId: local.snapshotId,
      parentSnapshotIds: local.parentSnapshotIds,
      expectedHeads: cloudHeads.map(h => h.snapshotId)
    });

    if (result.kind === "advanced") {
      await deps.localBooks.markSynced(bookId, local.snapshotId);
      return { kind: "in-sync", snapshotId: local.snapshotId };
    }
  }

  const remoteBranches = await deps.downloadAndDecryptHeads(bookId, cloudHeads);
  const merge = await deps.reconciler.reconcile({
    bookId,
    localSnapshot: local,
    remoteSnapshots: remoteBranches
  });

  if (merge.kind === "conflicts") {
    await deps.localBooks.savePendingReconciliation(bookId, merge);
    return { kind: "needs-resolution", conflicts: merge.conflicts };
  }

  await deps.validator.validateOrThrow(merge.bookBytes);

  const mergedSnapshot = await deps.snapshots.create({
    bookId,
    parentSnapshotIds: [
      local.snapshotId,
      ...cloudHeads.map(h => h.snapshotId)
    ],
    plaintextBookBytes: merge.bookBytes
  });

  await deps.uploadSnapshot(mergedSnapshot);

  const advanced = await deps.remote.tryAdvanceHeads({
    bookId,
    newSnapshotId: mergedSnapshot.snapshotId,
    parentSnapshotIds: mergedSnapshot.parentSnapshotIds,
    expectedHeads: cloudHeads.map(h => h.snapshotId)
  });

  if (advanced.kind === "head-race") {
    // Another device advanced while this merge was running.
    // Keep the candidate snapshot and retry from the new head set.
    return { kind: "retry-required" };
  }

  await deps.localBooks.commitMergedSnapshot(bookId, mergedSnapshot);
  return { kind: "in-sync", snapshotId: mergedSnapshot.snapshotId };
}
```

This is architectural pseudocode. Production code needs cancellation,
offline handling, retry/backoff, upload idempotency, storage
transactions, and careful treatment of multiple cloud heads.

------------------------------------------------------------------------

## 17. Server-side data model

The server stores opaque objects and coordination metadata only.

### 17.1 Example tables

``` text
users
  user_id
  authentication_metadata
  created_at

devices
  device_id
  user_id
  public_key
  status
  created_at
  revoked_at

books
  book_id
  owner_user_id
  created_at
  deleted_at

snapshots
  snapshot_id
  book_id
  ciphertext_object_key
  ciphertext_hash
  ciphertext_size
  envelope_version
  created_by_device_id
  created_at

snapshot_parents
  snapshot_id
  parent_snapshot_id

book_heads
  book_id
  snapshot_id

attachments
  attachment_id
  book_id
  ciphertext_object_key
  ciphertext_hash
  ciphertext_size
  created_at

device_key_envelopes
  book_id
  device_id
  encrypted_key_envelope
  envelope_version
```

The database must not contain plaintext account names, transaction
descriptions, payees, amounts, receipt filenames, or transaction GUIDs.

### 17.2 Server validation

The server should validate:

-   caller authorization for the book,
-   device status,
-   payload and metadata size limits,
-   UUID syntax,
-   ciphertext hash,
-   parent snapshot existence and same-book ownership,
-   no self-parenting or cycles,
-   snapshot immutability,
-   expected-head compare-and-swap,
-   upload completion state,
-   attachment object ownership.

It should not attempt to validate the accounting content because it
cannot decrypt it.

------------------------------------------------------------------------

## 18. Security and privacy controls

### 18.1 Web deployment

-   Strict Content Security Policy.
-   No third-party scripts.
-   No analytics or tracking pixels by default.
-   Self-host fonts, icons, WASM, and dependencies.
-   Subresource Integrity where external immutable resources are
    unavoidable; preferably avoid external runtime resources entirely.
-   Separate static application hosting from the ciphertext API.
-   Short-lived authenticated sessions.
-   CSRF protection for cookie-based sessions.
-   Rate limits and abuse controls.
-   Dependency pinning and automated vulnerability scanning.
-   Reproducible or verifiable builds where practical.
-   Signed release artifacts.
-   Secrets never embedded in client bundles.

### 18.2 Logging and telemetry

Never log:

-   plaintext XML,
-   account names,
-   payee or transaction descriptions,
-   account balances,
-   receipt images or OCR output,
-   passphrases,
-   KEKs or DEKs,
-   decrypted attachment contents.

Operational telemetry should be opt-in where possible and limited to
non-sensitive diagnostics such as app version, error category, latency,
and coarse resource metrics. Scrub request bodies and URLs.

### 18.3 Backup and recovery

-   Keep immutable encrypted snapshots.
-   Use object-store versioning or equivalent.
-   Verify ciphertext hashes after upload and download.
-   Periodically test restore to a clean device.
-   Document that losing all passphrases/recovery material means losing
    access to encrypted cloud data.
-   Do not claim that cloud backups are recoverable by Saldima
    personnel.

### 18.4 Threat model checklist

  -----------------------------------------------------------------------
  Threat                  Main controls           Residual risk
  ----------------------- ----------------------- -----------------------
  Cloud database breach   Client-side encryption; Metadata and ciphertext
                          no server keys          sizes exposed

  Object-store breach     AEAD-encrypted objects  Traffic/access patterns
                                                  may be visible

  Malicious network       TLS plus application    Timing and size
  observer                encryption              metadata

  Stolen account password Device authorization;   Account takeover may
                          encrypted keys          disrupt access

  Stolen unlocked device  OS secure storage; app  Active session may
                          lock; device revoke     expose plaintext

  Malicious web           CSP, signed builds,     First-party JavaScript
  deployment              deployment controls     can still exfiltrate
                                                  plaintext

  Corrupt or malicious    AEAD, hash, parser      Resource exhaustion
  snapshot                limits, validation      must be bounded

  Merge bug               Branch preservation,    Complex edge cases
                          invariants, test corpus remain

  Lost password           User-held recovery      No server-side recovery
                          secret                  backdoor
  -----------------------------------------------------------------------

------------------------------------------------------------------------

## 19. XML compatibility and test strategy

Compatibility is a core product feature. Build a corpus of real books
from supported GnuCash releases, with permission and sensitive data
removed.

### 19.1 Round-trip test

For every fixture:

1.  Open with official GnuCash and record version.
2.  Import into Saldima.
3.  Serialize without edits.
4.  Open the serialized file in official GnuCash.
5.  Compare important object counts and values.
6.  Reopen in Saldima.
7.  Verify unknown XML extensions remain present.
8.  Repeat after a small edit and after a merge.

### 19.2 Test categories

-   Empty book.
-   Small personal book.
-   Long-running book.
-   Many accounts.
-   Multiple currencies.
-   Price database.
-   Scheduled transactions.
-   Lots and gains.
-   Reconciliation states.
-   Notes and metadata.
-   Attachments.
-   Unknown XML nodes.
-   Duplicate/malformed GUIDs.
-   Missing references.
-   Large transactions.
-   Very large books.
-   Corrupt gzip.
-   Truncated XML.
-   Unsupported XML version.

### 19.3 Accounting invariants

At minimum:

-   GUID uniqueness.
-   Every reference resolves.
-   Every split belongs to exactly one transaction.
-   Every split references an existing account.
-   Transaction balance is exact in the transaction currency.
-   Account hierarchy is acyclic.
-   Commodity references resolve.
-   Rational values have valid denominators.
-   Required root/system objects exist.
-   Reconciliation states remain valid.
-   Scheduled transaction references are valid.
-   Deletions do not leave dangling references.

### 19.4 Merge test matrix

For every object type, test:

-   local-only addition,
-   remote-only addition,
-   same addition on both branches,
-   local-only edit,
-   remote-only edit,
-   same edit on both branches,
-   divergent edit,
-   delete vs unchanged,
-   delete vs edit,
-   parent/reference change,
-   unknown extension change,
-   malformed input,
-   merge output round-trip.

Use property-based tests for merge symmetry and invariants. Example:
when local and remote are identical, merge should be deterministic and
conflict-free.

------------------------------------------------------------------------

## 20. Performance plan

Do not optimize based on guesses. Benchmark actual books and synthetic
books on desktop browsers and lower-end supported phones.

Test at least:

-   1,000 transactions,
-   10,000 transactions,
-   50,000 transactions,
-   100,000 transactions,
-   250,000 transactions.

Measure:

-   compressed and expanded XML size,
-   file read time,
-   gzip decompression time,
-   XML parse time,
-   normalization/indexing time,
-   account register query time,
-   transaction edit time,
-   serialization time,
-   gzip compression time,
-   encryption/decryption time,
-   local persistence time,
-   upload/download time,
-   peak memory.

Implementation recommendations:

-   Parse XML once per load.
-   Build indexes by GUID, account, date, and transaction.
-   Do not retain duplicate full-size string copies unnecessarily.
-   Keep the XML document and normalized model memory footprint under
    observation.
-   Use Web Workers for parse/serialize/crypto work that would otherwise
    block the UI.
-   Keep the UI responsive with progress indicators for large books.
-   Use incremental UI rendering for long registers.
-   Preserve the canonical XML document; optimize indexes, not the
    underlying storage decision.

------------------------------------------------------------------------

## 21. Development sequence

### Phase 1 --- XML compatibility foundation

-   Create repository and dependency boundaries.
-   Implement file detection and gzip handling.
-   Parse GnuCash XML.
-   Build GUID indexes.
-   Preserve unknown XML.
-   Serialize and round-trip fixtures.
-   Validate files with official GnuCash.

**Exit criterion:** Saldima can open, inspect, make a controlled edit,
save, and reopen a representative corpus without damaging unsupported
data.

### Phase 2 --- Core accounting engine

-   Account tree.
-   Commodities and prices.
-   Transactions and splits.
-   Exact rational arithmetic.
-   Register queries.
-   Accounting invariants.
-   Basic reports.

**Exit criterion:** Core workflows operate offline on local XML books.

### Phase 3 --- Local-first web/mobile product

-   Book catalog.
-   Atomic local persistence.
-   Import/export.
-   Responsive UI.
-   Receipt capture and local attachment links.
-   Mobile shell and secure storage bridge.

**Exit criterion:** Web and mobile can independently operate without
accounts or network connectivity.

### Phase 4 --- Encryption and device security

-   Argon2id and envelope format.
-   DEK generation and wrapping.
-   Snapshot encryption.
-   Attachment encryption.
-   Recovery flow.
-   Device enrollment and revocation.
-   Security tests and threat-model review.

**Exit criterion:** No plaintext book or receipt content leaves the
client in test captures.

### Phase 5 --- Cloud storage and snapshot graph

-   Account authentication.
-   Book registry.
-   Immutable encrypted snapshot storage.
-   Head compare-and-swap.
-   Attachment transport.
-   Device registry.
-   Conflict state handling.

**Exit criterion:** Two clients can upload/download encrypted snapshots
without server-side decryption.

### Phase 6 --- Reconciliation

-   Ancestor lookup.
-   Three-way object comparison.
-   Account merge.
-   Transaction aggregate merge.
-   Delete/modify conflict handling.
-   Candidate validation.
-   Conflict UI.
-   Multi-head preservation.

**Exit criterion:** Concurrent independent changes merge correctly;
unsafe changes produce explicit conflicts without data loss.

### Phase 7 --- Desktop exchange

-   XML import/export.
-   Desktop file format detection.
-   Explicit adapter for supported SQLite-backed desktop books if
    required.
-   Manual upload/download workflow.
-   Divergence detection and branch preservation.

**Exit criterion:** A user can deliberately exchange a book with
official GnuCash without installing any desktop component.

------------------------------------------------------------------------

## 22. Critical implementation decisions still to make

These decisions should be recorded as architecture decision records
before production:

1.  **Engine language:** TypeScript first, or Rust/WASM core from the
    beginning?
2.  **Mobile shell:** shared WebView UI or fully native UI?
3.  **Browser storage adapter:** OPFS-first with IndexedDB fallback, or
    IndexedDB-first?
4.  **Desktop SQLite import:** which exact GnuCash versions and
    conversion path are supported?
5.  **Key distribution protocol:** choose a reviewed
    libsodium-compatible device enrollment approach.
6.  **Recovery model:** user-held recovery key, trusted-device recovery,
    or both?
7.  **Snapshot retention:** how many historical snapshots are retained
    and how are they pruned?
8.  **Merge support boundary:** which GnuCash object types can be
    automatically merged in the first release?
9.  **Attachment lifecycle:** retention, deduplication, orphan cleanup,
    and deletion semantics.
10. **Supported GnuCash versions:** define and test a compatibility
    matrix.

Do not block offline accounting on the cloud, device enrollment, or
merge implementation. Those are later layers.

------------------------------------------------------------------------

## 23. Non-negotiable design principles

-   XML is the canonical Saldima web/mobile book format.
-   No SQLite in Saldima web/mobile accounting storage.
-   Offline operation is complete and independent.
-   Cloud sync is optional and detachable.
-   Encryption occurs before upload.
-   The cloud never receives plaintext books or receipts.
-   The cloud never performs accounting merges.
-   Sync exchanges whole-book encrypted snapshots, not transaction event
    streams.
-   Reconciliation uses stable GUIDs and domain invariants.
-   Transactions and splits are atomic merge units.
-   Unsafe merges preserve branches and ask the user.
-   Desktop GnuCash remains official and unmodified.
-   Desktop exchange is explicit/manual; no daemon or file watcher.
-   Unknown GnuCash XML data should survive round trips.
-   No custom cryptographic primitives.
-   No silent last-write-wins for accounting data.
-   No successful-sync indication before server confirmation.
-   Never sacrifice a valid local book to a failed save, import, or
    merge.

------------------------------------------------------------------------

## Appendix A --- Example package dependencies

A starting `package.json` workspace dependency set could look like this.
Pin versions in the lockfile after checking current releases,
compatibility, and security advisories.

``` json
{
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "typecheck": "tsc --build",
    "test": "vitest run",
    "test:e2e": "playwright test",
    "lint": "eslint ."
  },
  "devDependencies": {
    "typescript": "PINNED_VERSION",
    "vite": "PINNED_VERSION",
    "vitest": "PINNED_VERSION",
    "@playwright/test": "PINNED_VERSION",
    "eslint": "PINNED_VERSION",
    "prettier": "PINNED_VERSION"
  },
  "dependencies": {
    "libsodium-wrappers-sumo": "PINNED_VERSION"
  }
}
```

Do not copy placeholder version strings into a release. Choose and pin
actual versions after dependency review. The browser's built-in DOM/XML,
compression, file, and fetch APIs do not need npm packages.

## Appendix B --- Example domain command boundary

Keep UI actions as commands against the application service rather than
allowing screens to mutate XML nodes directly.

``` ts
export interface BookCommands {
  createAccount(input: CreateAccountInput): Promise<void>;
  renameAccount(accountGuid: string, newName: string): Promise<void>;
  createTransaction(input: CreateTransactionInput): Promise<void>;
  editTransaction(
    transactionGuid: string,
    input: EditTransactionInput
  ): Promise<void>;
  deleteTransaction(transactionGuid: string): Promise<void>;
  validate(): Promise<ValidationReport>;
  save(): Promise<SnapshotDescriptor>;
}
```

Each command should:

1.  Validate inputs.
2.  Apply a domain operation.
3.  Recompute affected indexes.
4.  Run relevant invariants.
5.  Mark the local book dirty.
6.  Save through the atomic persistence layer.
7.  Emit a UI-safe result without leaking sensitive values into logs.

## Appendix C --- Example merge result types

``` ts
export type ReconciliationOutcome =
  | {
      kind: "merged";
      bookBytes: Uint8Array;
      parentSnapshotIds: string[];
      warnings: string[];
    }
  | {
      kind: "conflicts";
      conflicts: ReconciliationConflict[];
      preservedBranchSnapshotIds: string[];
    }
  | {
      kind: "invalid-input";
      errors: string[];
    };
```

A conflict is not a failed sync. It is a safe state in which all source
branches remain recoverable and the user can decide how to proceed.

## Appendix D --- Production-readiness checklist

-   [ ] XML fixtures from supported GnuCash versions.
-   [ ] Unknown-node preservation tests.
-   [ ] Exact rational arithmetic.
-   [ ] GUID uniqueness and reference validation.
-   [ ] Atomic local writes and crash recovery.
-   [ ] Encryption test vectors.
-   [ ] KDF parameter bounds.
-   [ ] Nonce generation and uniqueness strategy.
-   [ ] Device enrollment and revocation review.
-   [ ] Recovery-key UX and tested restore.
-   [ ] No plaintext in network captures.
-   [ ] No sensitive values in logs or telemetry.
-   [ ] CSP and no third-party runtime scripts.
-   [ ] Immutable snapshot upload and head CAS.
-   [ ] Multi-head preservation.
-   [ ] Transaction-atomic reconciliation.
-   [ ] Delete/modify conflict tests.
-   [ ] Merge candidate validation.
-   [ ] Receipt chunk authentication.
-   [ ] Restore to a clean device.
-   [ ] Explicit desktop import/export tests.
-   [ ] Lower-end mobile performance benchmarks.
-   [ ] Dependency and license inventory.
-   [ ] Security review before public launch.
