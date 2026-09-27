---
timestamp: 2026-09-27T180000Z
title: Fetcher packages — a first-class package role
branch: feature/fetcher-packages
status: complete
---

# Fetcher packages — a first-class package role

## Progress

Implemented `plans/fetcher-packages.md`: fetchers are a first-class package
role. One source result per fetch; the host stores it and routes non-Markdown
bytes through the selected format extractor.

## What landed

- **Manifest revision 4** (`ExtractorPackageRole`): explicit `extractor` /
  `fetcher` registration role. Fetchers declare no kinds and no filename
  extensions; their `mimeTypes` are the claimed input MIME set. Fetchers
  require protocol revision 5 and the `network` capability. A sync
  declaration's `sourceMIMEType` must be one of the fetcher's claims.
  Revision 4 canonical encoding always writes `role`; revisions 1–3 never
  do, so old package digests are unchanged. The `zotero` extractor kind is
  retired; catalog records carrying it are skipped at read time (bounded
  count, reservations preserved, bytes never rewritten).
- **Protocol revision 5**: tagged request envelope
  (`ExtractorRequestEnvelope`). Revision-5 extractor requests add only
  `role: "extractor"`; fetch requests (`ExtractorFetchRequest`) carry role,
  claimed MIME, validated URL, and a path-free bounded display filename.
  Results carry the explicit `resultType` (`source-bytes` / `markdown`) plus
  an optional validated `originalFilename`. Absent/contradictory tags,
  empty acquisitions, wrong byte counts, and binary-as-Markdown all fail
  before persistence. Revisions ≤ 4 reject every new field.
- **Routing**: `FetcherRouteID` + `routeFetchers` (disjoint selection
  namespace), bundled default for `application/zotero`, kind-free
  `.installedFetcher` registry namespace and `.fetcher` adapter case. The
  `.zotero` cases in `ExtractorKind`/`ExtractionBackendKind` are retired.
  `prepareFetcher(sourceMIMEType:)` pins the exact revision and rejects
  missing/incompatible selections.
- **Acquisition flow**: one shared pure decision
  (`FetchRouteDecision.resolve` — no origin-provider branch), one worker
  case `.fetch` with a closed `FetchOutcome`. `source-bytes` persists the
  blob + neutral provenance + validated filename + `formatJobPending`
  marker (with exact producer) in ONE wiki-store transaction, then queues
  the follow-on format job outside it. `markdown` appends a
  package-provenance Markdown version and completes the source.
- **Queue dedupe + recovery**: `QueueItemRequest.dedupeKey` (typed,
  wiki+source+acquired-version scoped), `ON CONFLICT DO NOTHING` +
  same-transaction select (queue migration v11), and
  `FetchFormatJobRecovery` on wiki open (app) / first dispatch (daemon).
  Crash between blob and enqueue is recoverable; a second host can never
  create a second format job; a completed deduped item settles the marker.
- **Provenance neutrality**: `sources.zotero_item_*` →
  `sources.external_item_*` (store v55, values preserved); byteless
  `application/zotero` rows backfilled to fetch `pending`. A returned
  parent identifier is metadata, never `source_versions.external_identity`.
  `SourceProvider.zotero` remains the display label only.
- **Zotero package** (`tools/zotero` → generated `ExtractorPackages/Zotero`):
  version 1.1.0, manifest revision 4, protocol revision 5, role fetcher,
  digest pinned in `ReviewedExtractorPackages`. Same credential, sidecar,
  URL template, and item-key rules; emits typed results. `wikictl extractor
  sync zotero` unchanged. Settings shows the fetcher role ("Fetch" handles
  column, "Fetch: application/zotero" route row, role detail line).
- **Docs**: protocol + manifest architecture pages, user guide, maintainer
  skill, `plans/fetcher-packages.md`, this entry.

## Deliberately not supported

Old Zotero package revisions and saved Zotero extractor-route selections
(the feature never shipped). Confluence/Slack, multi-result fetches,
periodic sync.

## Verification

`make build`-equivalent full `swift build` green; Zotero `uv run pytest`
(70 tests), Ruff, Pyright green; `extractor-package-tool validate` +
`protocol-smoke` green on the regenerated package; `make
extractor-packages` drift check green. Full `swift test` run recorded in
the PR.
