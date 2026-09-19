# Zotero extractor package

Status: implemented (2026-09-19). Branch `feature/zotero-extractor-package`.

## Problem

The Zotero integration was hardcoded Swift: `ZoteroClient` searched the Web
API, `ZoteroLocalStorage` read `~/Zotero/storage/<key>/<filename>`, and
`ZoteroMaterializer` ingested the bytes. That path only worked for
attachments synced to disk, duplicated acquisition policy the package layer
was built to own, and carried its own picker UI and engine plugin wiring.

## Design

One reviewed package, `org.selfdrivingwiki.zotero`, acquires attachment
bytes from the Zotero Web API. The package is pure acquisition — it never
converts formats.

- **Protocol revision 4.** Two optional result-frame fields:
  `resultMIMEType` and `articleMetadata.identifier`. Absent or
  `text/markdown`, the output file IS the Markdown (the revision ≤ 3
  contract, byte-for-byte). Any other value: the output file holds source
  bytes of that MIME, and the HOST owns the format conversion.
  `markdownByteCount` stays the output-file byte count either way. Requests
  keep the exact revision-3 wire shape. A revision ≤ 3 host fails closed:
  `ExtractorProtocolSequence` rejects a result frame that carries the new
  fields against an older request, instead of silently dropping them.
- **The package** (`tools/zotero/zotero`, PEP 723, `requests` only) accepts
  one revision-4 `remote-url` request whose URL must be exactly
  `https://api.zotero.org/users/<libraryID>/items/<attachmentKey>/file`. It
  reads the API key from the request-scoped credential file
  (`credentials["zotero-api-key"]`), fetches attachment metadata, rejects
  `linked_file`/`linked_url` (no downloadable file), fetches parent metadata
  for `articleMetadata` (`identifier` = parent item key), downloads the
  file with a 128 MiB cap, and maps content to output:
  `text/markdown`/`text/plain` (or `.md`) → Markdown result with no
  `resultMIMEType`; `application/pdf` (or `.pdf`) and `text/html` (or
  `.html`) → bytes result with the true MIME; anything else → typed
  `unsupported-input`. No URL or key material ever appears in a frame
  message.
- **Config + trigger.** `zotero-config.json` gains `attachments: [String]`
  (8-character uppercase item keys, duplicates rejected at save). The
  retired `zoteroDirOverride` is no longer written; decode stays tolerant.
  `wikictl zotero sync` creates one byteless `.zotero` source per key (URL =
  the file endpoint), dedupes by source URL, and enqueues a durable
  `.extraction` job through `QueueStore.enqueue` — enqueue-only: no
  `QueueEngine`, no CLI-side waiting. The app or the wikid daemon drains
  the job on its next dispatch scan / launch.
- **Host routing.** `ExtractionKind.zotero` registers like the transcript
  kinds: kind whitelist, typed `prepareZoteroAttachment()` operation shape,
  `application/zotero` MIME fallback row, a bundled default route to the
  reviewed lineage, and a `.zotero` case in BOTH queue-extraction providers
  (`AppQueueExtractionProvider`, `DaemonQueueExtractionProvider`). Routing
  keys off `SourceProvider` (the podcast/YouTube precedent) and off the
  RESULT MIME (data) — never a policy branch on `ExtractorKind`.
- **Bytes completion.** `persistAttachmentExtraction` stores the output
  bytes as the source blob (content hash, real MIME, ext from MIME, byte
  size), populates the retained `zotero_item_key` (from
  `articleMetadata.identifier`) and `zotero_item_title` (from `title`)
  columns, sets the display name, and enqueues the follow-on `.extraction`
  item so the user's PDF/HTML route produces the Markdown version. A
  Markdown result appends a package-provenance Markdown version
  (podcast-shaped) and still populates the columns. Re-syncing changed
  bytes creates a new content version through the normal hash-diff path.
- **Credentials.** App startup seeds one authorization record binding
  `(org.selfdrivingwiki.zotero, zotero-api-key)` to the legacy
  `.zoteroAPIKey()` Keychain reference, pinned to the requirement
  fingerprint, idempotent, and never resurrected over a mismatching
  revocation. Value resolution flows through the standard per-operation
  credential-file path. An unset Keychain value surfaces as the typed
  missing-credential state.

## Removed

`ZoteroClient`, `ZoteroLocalStorage`, `ZoteroMaterializer`,
`ingestFromZotero` + `ZoteroFetchError`, `AddFromZoteroSheet` and its
picker wiring, `ZoteroIntegrationPlugin`/`ZoteroIntegrationConfig`,
`ZoteroClientProvider` and its service key + factory plumbing,
`HostCredentialActions.verifyZotero` (the Settings Test Connection button),
and `ContentSniff`'s `.zoteroMetadata` evidence origin. Kept:
`SourceProvider.zotero` display data, the DB columns and read/write paths,
`SourceSummary.zoteroItemKey/Title`, `SourceDetailView` provenance +
`zotero://select` deep link, `ZoteroCredentialStore`, and
`ZoteroSettingsView` (now API key + library ID only).

## Deferred (deliberately)

Picker UI, Authorize/Revoke credential UI, app-launch auto-sync, item-key
selection policy, conditional (If-Modified-Since-Version) re-download —
all sequenced behind the later UI work.
