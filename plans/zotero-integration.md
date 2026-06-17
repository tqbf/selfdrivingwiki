# Zotero integration: browse library, ingest PDF/Markdown attachments

## Why

The user keeps a Zotero reference library and runs a companion Python tool
(`zotero-extraction`, outside this repo) that converts PDF attachments to
Markdown and uploads the `.md` back into Zotero as a sibling attachment on the
same item. This feature lets the user browse that Zotero library from inside
Self Driving Wiki and pull an item's PDF and/or `.md` attachment straight into
the wiki, through the **existing** ingest pipeline (the same one drag-and-drop
and "Add from URL" already use) — no new storage mechanism, no new write
surface, no change to the File-Provider-mount-is-read-only invariant.

## Research findings (verified empirically against a live Zotero library)

- The Zotero Web API (`api.zotero.org`) returns enough metadata
  (`data.key`, `data.filename`, `data.linkMode`) to compute an attachment's
  local path directly: `~/Zotero/storage/<key>/<filename>`. Both common link
  modes (`imported_file`, `imported_url`) resolve correctly; only the rare
  `linked_file`/`linked_url` modes lack a local copy.
- Reading that local file is safe mid-sync: Zotero's own sync client (its
  open-source GitHub repo, `chrome/content/zotero/xpcom/storage/{zfs,
  storageLocal}.js`) downloads fully to a temp file, then does one atomic
  `OS.File.move` into `storage/<key>/<filename>` for the common single-file
  case (plain PDF/Markdown, not a multi-file web-snapshot ZIP, which extracts
  entry-by-entry with no such guarantee — out of scope for this feature). A
  reader sees the fully-old or fully-new file, never a torn write.
- Decision: talk to the Zotero Web API directly via `URLSession` in Swift —
  not by shelling out to the `zot` CLI (pyzotero-cli) or to Python — to keep
  the app dependency-free and keep a search-as-you-type picker fast (no
  subprocess-spawn latency per keystroke).

## Decisions for v1

- **No network-download fallback.** If an attachment isn't already synced to
  `~/Zotero/storage`, the user gets a clear "sync in Zotero first" error
  rather than the app downloading it via `GET /items/<key>/file`.
- **Credentials are app-wide**, not per-wiki — one Zotero API key + library ID
  for the whole app.
- **Search is live and debounced** against the Zotero API per keystroke — no
  session-scoped cache.
- **Multi-select ingest** — the picker lets the user check multiple
  attachments on one item (e.g. the PDF *and* its converted `.md`) and ingest
  them in one action.

## Architecture

Two PRs.

### PR1 — Core (landed)

Pure/testable logic, no UI, no live Keychain wiring into the app:

- `Sources/WikiFSCore/ZoteroClient.swift` — talks to `api.zotero.org`. Mirrors
  `URLIngestService`'s testability shape (`RequestFetcher` protocol + pure
  `decodeItems`/`decodeAttachments`/`buildSearchRequest`/`buildChildrenRequest`
  statics), but takes a `URLRequest` (not a bare `URL`) since every Zotero
  call needs `Zotero-API-Key`/`Zotero-API-Version` headers attached by the
  client. `searchItems`, `childAttachments`, `verifyConnection`.
- `Sources/WikiFSCore/ZoteroLocalStorage.swift` — pure path composition
  (`localPath`) + an injectable-existence-check `resolve(_:zoteroDir:
  fileExists:) -> AttachmentSource` (`.local(URL)` / `.unavailable(reason:)`),
  mirroring `PathPreflight`'s injection shape.
- `Sources/WikiFSCore/ZoteroConfig.swift` — non-secret config (`libraryID`,
  `zoteroDirOverride`), JSON load/save following `WikiRegistry`'s pattern
  exactly, stored once at the app-container root (`zotero-config.json`,
  sibling to `wikis.json`) — app-wide, not nested in `WikiDescriptor`.
- `Sources/WikiFSCore/ZoteroCredentialStore.swift` — the API key, which is a
  secret and does NOT go in `ZoteroConfig`'s JSON. `ZoteroCredentialStore`
  protocol, `KeychainZoteroCredentialStore` (generic-password Keychain item;
  no entitlement needed — `WikiFS.entitlements` has no App Sandbox), and
  `InMemoryZoteroCredentialStore` for tests.
- `WikiStoreModel.ingestFromZotero(_:zoteroDir:)` (in `WikiStoreModel.swift`)
  — resolves the attachment via `ZoteroLocalStorage.resolve`, reads bytes off
  the main actor, and calls the existing public `ingestFile(filename:data:)`
  seam (the same one drag-ingest uses) — no new storage path.
  `ZoteroIngestError.unavailable(String)` surfaces the "not synced" case.

All covered by `swift-testing` tests in `Tests/WikiFSTests/` (`ZoteroClient
Tests`, `ZoteroLocalStorageTests`, `ZoteroConfigTests`,
`ZoteroCredentialStoreTests`, `WikiStoreModelZoteroIngestTests`) — fakeable
end-to-end, no real network or Keychain access in CI.

### PR2 — Settings + picker UI (not yet built)

- `Sources/WikiFS/ZoteroSettingsView.swift` — the app's first Settings
  surface (`Settings { }` scene in `WikiFSApp.swift`, `⌘,`). Fields: API key
  (`SecureField`, Keychain-backed), library ID, Zotero directory override
  (`NSOpenPanel`), "Test Connection" → `ZoteroClient.verifyConnection()`,
  errors via the existing `.alert` pattern
  (`FileProviderSetupWarning`/`LaunchLocationWarning` in `WikiFSApp.swift`).
- `Sources/WikiFS/AddFromZoteroSheet.swift` — mirrors `AddFromURLSheet`'s
  `Phase`/`Metrics` shape: debounced search → item list → checkbox
  multi-select of an item's `.pdf`/`.md` attachments → "Add Selected" calls
  `ingestFromZotero` per selection, collect-and-continue on per-item failure.
- Entry point: a second "Add from Zotero…" button next to "Add from URL…" in
  `SidebarView.swift`, disabled with a `.help` tooltip (not hidden) until
  Settings are configured.
- No automated test for the live-API path — a manual smoke test against the
  user's real library (search, ingest both a PDF and its converted `.md`,
  confirm byte-identical) stands in for it, plus exercising "Test Connection"
  with a deliberately wrong key.

## Critical files

- `Sources/WikiFSCore/URLIngestService.swift` — testable-fetcher + pure
  dispatch pattern `ZoteroClient` mirrors.
- `Sources/WikiFSCore/WikiStoreModel.swift` — `ingest(fileURLs:)`, `ingestURL`,
  `ingestFile(filename:data:)`, and now `ingestFromZotero`.
- `Sources/WikiFSCore/WikiRegistry.swift` — JSON load/save pattern
  `ZoteroConfig` follows.
- `Sources/WikiFSCore/PathPreflight.swift` — pure/injectable resolve-with-
  result pattern `ZoteroLocalStorage.resolve` follows.
- `Sources/WikiFS/AddFromURLSheet.swift` — UI shape `AddFromZoteroSheet` (PR2)
  will mirror.
- `Tests/WikiFSTests/URLIngestServiceTests.swift` and
  `WikiStoreModelURLIngestTests.swift` — exact test-double patterns mirrored
  for the new Zotero test files.
