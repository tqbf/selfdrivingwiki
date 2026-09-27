# Fetcher packages

Status: implemented (this change). Feature branch `feature/fetcher-packages`.

## Problem

Acquisition (Zotero attachments) lived inside the extractor world as a fake
kind: the `zotero` extractor kind, a `.zotero` backend kind, a
`.zoteroAttachment` content kind gated on the origin provider, and
Zotero-named provenance columns. A package that only DOWNLOADS a source is
not a converter. The kind confused two contracts:

- which operation family a registration runs (conversion), and
- which byteless sources a package can acquire (acquisition).

## Design

A package registration declares an explicit **role** (manifest revision 4):

- `extractor` — converts content it is handed. Declares one or more
  operation `kinds`. Unchanged from revisions 1–3.
- `fetcher` — acquires ONE remote source per request. Declares NO kinds; its
  `mimeTypes` are the claimed input MIME set (the synthetic source MIMEs of
  the byteless sources it can acquire). Requires protocol revision 5, the
  `remote-url` transport, and the `network` capability.

The role is package data. Nothing infers it from URL transport, MIME,
provider, or package ID.

### Wire protocol (revision 5)

- A revision-5 EXTRACTOR request keeps the revision-3 shape and adds only
  `role: "extractor"`.
- A revision-5 FETCH request (`ExtractorFetchRequest`) carries `role:
  "fetcher"`, the claimed input MIME, one validated `remoteURL`, a bounded
  display `originalFilename` (no path separators — stored as data, never
  resolved as a path), and no `kind`/`inputTransport`/`inputPath`.
- Results add the explicit tag `resultType` (`source-bytes` or `markdown`)
  plus an optional validated `originalFilename` on `source-bytes`. A fetcher
  must state exactly ONE type; `source-bytes` requires a concrete
  non-Markdown MIME; an empty `source-bytes` result fails the fetch so it
  can never loop as a byteless source. Revisions ≤ 4 reject the new fields
  (fail closed).

### Routing

- `FetcherRouteID(mimeType:)` and `routeFetchers` in `ExtractionConfig` —
  a selection namespace disjoint from `routeExtractors`, so a same-MIME
  extractor can never replace a fetcher selection or the reverse.
- Bundled `default-routes.json` gains `routeFetchers` with
  `application/zotero` → the reviewed Zotero lineage; the retired Zotero
  EXTRACTOR route is dropped (saved records of that shape fail decode and
  are skipped non-fatally).
- The registry gains a kind-free namespace: `ExtractionAdapterKey
  .installedFetcher(reference:)` and `ExtractionBackendAdapter.fetcher(
  ProcessPackageFetcher)`. A fetcher needs no `ExtractorKind` and no
  `ExtractionBackendKind` — both `.zotero` cases are retired.
- `prepareFetcher(sourceMIMEType:)` resolves the effective fetcher route,
  pins the exact revision, and rejects missing or incompatible selections
  (including a registration that no longer claims the MIME).

### Acquisition flow (app and daemon share it)

`FetchRouteDecision.resolve` is the shared pure decision: a byteless source
with a validated plan URL whose MIME is claimed by an ACTIVE fetcher
registration resolves as a fetch; a source with acquired bytes resolves by
its actual MIME into the standard format route. No origin-provider branch.

The worker case is `.fetch` with a typed `FetchOutcome`:

- `markdown` — append a package-provenance Markdown version, mark the source
  `complete`. No format job.
- `sourceBytes` — persist the blob (declared MIME, ext from MIME, validated
  display filename, neutral `external_item_key`/`external_item_title`, the
  exact fetch producer) and write the `formatJobPending` marker in the SAME
  wiki-store transaction; then enqueue (outside that transaction) the
  follow-on `.extraction` item keyed by a typed dedupe key.

### Queue dedupe and recovery

`QueueItemRequest` carries an optional typed `dedupeKey`
(`QueueItemDedupeKey.followOnFormatExtraction(wikiID:sourceID:
acquiredContentVersionID:)`). `QueueStore.enqueue` inserts with
`ON CONFLICT(dedupe_key) DO NOTHING` and selects the row by key inside the
same transaction, so a repeat insert — including from the other host —
returns the SAME item (any state). Queue migration v11 adds the nullable
unique `dedupe_key` column.

`FetchFormatJobRecovery` runs on wiki open (app session boot) and on first
dispatch (daemon): for each `formatJobPending` marker it enqueues the
deduped item if absent, and settles the marker to `complete` when the
deduped item already completed (including after a user retry succeeds). A
failed format item stays for the existing retry path. A wiki neither host
opens waits for its next open.

### Provenance neutrality

- `sources.zotero_item_key`/`zotero_item_title` →
  `external_item_key`/`external_item_title` (store migration v55; values
  move, nothing drops). `SourceSummary.externalItemKey/externalItemTitle`.
- A returned parent identifier is acquisition METADATA — it is never copied
  into `source_versions.external_identity`.
- `SourceProvider.zotero` remains only as the displayed origin label
  ("Zotero / PDF", the `zotero://` deep link).

### The reviewed Zotero package

`tools/zotero` + the generated `ExtractorPackages/Zotero` now speak the
fetcher contract: manifest revision 4, protocol revision 5, version 1.1.0,
digest pinned in `ReviewedExtractorPackages`. Same credential, sidecar,
URL template, and item-key rules. It emits `resultType: "markdown"` for
Markdown/plain-text attachments and `resultType: "source-bytes"` (true MIME
plus display filename) for PDF/HTML. Old Zotero package revisions and saved
Zotero extractor-route selections are NOT supported — the feature has not
shipped; catalog records carrying the retired kind are skipped at read time
with their reservations preserved.

## Out of scope

Confluence and Slack packages, multi-result fetches, and periodic sync.

## Key files

- Types: `Sources/WikiFSTypes/Extractor/{ExtractorManifest,ExtractorIdentity,
  ExtractorProtocol,ExtractorPackageCatalog,ExtractorRoute}.swift`
- Config/routes: `Sources/WikiFSCore/Integrations/ExtractionConfig.swift`,
  `Sources/WikiFSCore/Extractor/ExtractorRoute{Defaults,Selection}.swift`,
  `Sources/WikiFSCore/Resources/Extraction/default-routes.json`
- Engine: `Sources/WikiFSEngine/{ExtractorPackagePluginDefinitionFactory,
  ExtractionServiceKeys,ProcessExtractionServices,ProcessExtractorProvider,
  QueueExtractionProvider,QueueExtractionWorker,ExtractorRouteTableBuilder,
  FetchRouteDecision,FetchFormatJobRecovery}.swift`
- Hosts: `Sources/WikiFS/Queue/AppQueueExtractionProvider.swift`,
  `Sources/wikid/DaemonQueueExtractionProvider.swift`,
  `Sources/WikiFS/Sources/ExtractionSettingsView.swift`
- Stores: `Sources/WikiFSCore/Store/GRDBWikiStore.swift` (v55),
  `Sources/WikiFSCore/Core/QueueStore.swift` (v11)
- Package: `tools/zotero`, `ExtractorPackages/Zotero`,
  `scripts/sync-extractor-packages.sh`
