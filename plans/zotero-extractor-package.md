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
- **The package** (`tools/zotero/zotero`, PEP 723; `pyzotero` for the
  metadata GETs, streaming `requests` for the file download) accepts
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
  `wikictl extractor sync zotero` creates one byteless `.zotero` source per key (URL =
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
  The store seam is acquisition-neutral — `attachAcquiredBytes` and
  `setAcquisitionProvenance` on the `WikiStore` protocol — so a second
  acquisition package reuses it unchanged; only the retained DB columns
  keep their historical `zotero_*` names (compat contract).
- **Credentials.** App startup seeds default credential grants from a
  per-package table in `ReviewedExtractorBootstrap` (one row:
  `(zotero, zotero-api-key, .zoteroAPIKey())`); adding a second reviewed
  package with a default host credential is one row. Each grant binds the
  package's requirement to its reference pinned to the requirement
  fingerprint, idempotent, and never resurrected over a revocation whose
  seed-marker fingerprint is unchanged. Value resolution flows through the
  standard per-operation credential-file path. An unset Keychain value
  surfaces as the typed missing-credential state.

## Removed

`ZoteroClient`, `ZoteroLocalStorage`, `ZoteroMaterializer`,
`ingestFromZotero` + `ZoteroFetchError`, `AddFromZoteroSheet` and its
picker wiring, `ZoteroIntegrationPlugin`/`ZoteroIntegrationConfig`,
`ZoteroClientProvider` and its service key + factory plumbing,
`HostCredentialActions.verifyZotero` (the Settings Test Connection button),
`ContentSniff`'s `.zoteroMetadata` evidence origin, the zotero-named CLI
family (`wikictl zotero sync` → `wikictl extractor sync zotero`),
`ZoteroCredentialStore` (the generic `KeychainCredentialService` +
`.zoteroAPIKey()` owns the Keychain), and the zotero-named store mutators
(`attachZoteroAttachment`/`setZoteroProvenance` → the acquisition-neutral
`attachAcquiredBytes`/`setAcquisitionProvenance`). Kept:
`SourceProvider.zotero` display data, the DB columns and read/write paths,
`SourceSummary.zoteroItemKey/Title`, `SourceDetailView` provenance +
`zotero://select` deep link, and `ZoteroSettingsView` (now API key +
library ID only).

> **Superseded (2026-09-20):** `ZoteroSettingsView` and its Extraction-tab
> pane are gone. Extractor-kind policy comes from package data, so no kind
> keeps a host-owned account pane: the API-key value is entered in the
> package's generic Configure… dialog (`PackageCredentialValuesSection`,
> one write-only value row per declared requirement, bound through
> `bindingReference`), and the library ID stays a `ZoteroConfig` sidecar
> read by `wikictl extractor sync`.

## Dependency decision

The package runs a HYBRID HTTP stack, chosen per seam:

- **Metadata (item envelopes) → `pyzotero`.** The two metadata GETs
  previously hand-rolled URL construction and the `Zotero-API-Key` /
  `Zotero-API-Version` headers; the library owns that grammar and tracks
  upstream API changes for us. Verified against the released client
  (pyzotero 1.15.2): `Zotero.item(key)` returns the decoded API object
  itself — a bare dict with top-level `key`/`version`/`data` (the
  `retrieve` wrapper passes JSON responses through as `retrieved.json()`;
  the readthedocs return-type note claiming a list is stale) — so the
  package's `.get("data")` unwrap and `isinstance` guards are unchanged.
  Errors map to the same bounded, no-URL/no-key messages: pyzotero maps
  401/403 → `UserNotAuthorisedError` ("rejected the credentials"), 404 →
  `ResourceNotFoundError` ("not found"), other non-200 → `HTTPError`
  (generic API error); httpx2 transport failures map to the metadata
  request failure. Tests patch a `_make_client` factory seam — pyzotero
  rides `httpx2`, so patching `requests.get` can never intercept metadata.
- **Attachment file download → streaming `requests` (kept).** The 128 MiB
  byte-cap abort and the per-chunk deadline self-report are protocol
  properties. pyzotero's `file()` materializes the whole body in memory
  before returning, so it can enforce neither; `zot.file` adoption would
  regress both typed self-reports until worked around.
- **`pyzotero-cli` rejected.** It is an interactive CLI wrapper
  (`pyzotero authorize`, prompts), the wrong shape to embed in a managed
  one-shot protocol process, and its credentials-through-argv pattern would
  violate the credential-file boundary.

Escape hatch: if Zotero's file endpoint ever streams sensibly through the
library, or write operations / conditional GETs become needed, revisit the
download seam.

## Deferred (deliberately)

Picker UI, Authorize/Revoke credential UI, app-launch auto-sync, item-key
selection policy, conditional (If-Modified-Since-Version) re-download —
all sequenced behind the later UI work. ~~Manifest-declared syncability
(packages advertising a sync configuration in their registration data and
the CLI discovering syncable packages from the catalog, instead of the
compiled `Package` enum) also belongs to that cycle: it needs the picker's
config surface to define what "syncable" means.~~ **Delivered** — decoupled
from the picker: syncable now means a registration carries a `sync`
declaration (manifest revision 3), the CLI discovers syncable packages from
the machine catalog ∪ reviewed overlay, and one generic engine serves every
declared package. Reference:
[`docs/architecture/extractor-package-manifest.md`](../docs/architecture/extractor-package-manifest.md)
§"Sync declarations (manifest revision 3)".
