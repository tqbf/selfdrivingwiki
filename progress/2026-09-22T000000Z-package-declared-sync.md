---
timestamp: 2026-09-22T000000Z
title: package-declared acquisition sync, manifest revision 3
branch: feature/package-declared-sync
status: complete
---

# Package-declared acquisition sync (manifest revision 3)

Plan: the approved `plan-002.md` (package-declared acquisition sync). Branch
`feature/package-declared-sync`, built on the `feature/zotero-extractor-package`
tree (PR #1304's surface) merged in as substrate — the plan was authored
against that state.

## Progress

- **Manifest revision 3**: registrations may declare an optional `sync`
  object — `configFileName`, `urlTemplate` (placeholders from declared
  fields plus `{itemKey}`, sample-interpolation must form an absolute HTTPS
  URL), `fields` (unique names, exactly one list field, bounded patterns
  that must compile at decode), `itemValidation` (length bounds plus
  alphabet OR pattern), and `sourceMIMEType` (defaulting to the
  registration's single MIME). A sync declaration supports at most one
  REQUIRED credential requirement; zero is allowed so a second package can
  sync with no reviewed binding. `V3CodingKeys` follows the
  `credentialRequirements` pattern: the `sync` key is emitted only when
  non-nil, so revision-1/2 canonical bytes and package digests are
  unchanged — proven by computing the same fixture's digest on the
  pre-change substrate (byte-identical) and pinning it as a golden test.
- **Catalog read tolerance**: a record whose persisted `manifestRevision`
  is newer than this build understands is skipped with a diagnostic
  (`skippedUnknownRevisionRecordCount`, never encoded), not
  `corruptCatalog` for the whole read. The v2-era poisoning class, closed
  for v3.
- **Generic engine**: `ZoteroSync` + `ZoteroConfig` are deleted.
  `ExtractorPackageSync.syncItems(store:declaration:packageIdentity:config:sourceMIMEType:enqueue:force:)`
  ports the flow with every package fact from the declaration: URL from
  the interpolated template, provenance agent name from the package ID's
  last label, URL-identity dedupe, `--force` re-enqueue, and a typed
  invalid-item failure. `ExtractorSyncSidecar` loads the declared config
  file (unknown keys ignored — old files keep loading), validates required
  fields and list items against the declaration, and hard-fails duplicate
  items (a deliberate strictness delta: the old engine deduped silently).
- **CLI discovery**: `wikictl extractor sync <name> [--force]` keeps its
  grammar, but the name stays a raw string through the parser; the command
  discovers syncable packages at execution time from the durable machine
  catalog ∪ the process's reviewed overlay (the
  `ReviewedOverlayCatalogReader` union), resolving the newest record per
  package lineage, and the unknown-package error lists the discovered
  names. The API-key gate generalized to the registration's required
  credential requirement resolved through the compiled reviewed bindings —
  absent → typed hard failure; unreadable (`verificationFailed`) → the
  same deferral note as before. `build.sh` now stages `ExtractorPackages/`
  beside `build/wikictl` so the bare binary's overlay root resolves.
- **Zotero package**: manifest revision 3, version 1.0.2, with the sync
  declaration (same `zotero-config.json`, the file endpoint template, the
  8×A–Z0–9 key list). Digest regenerated through the packaging workflow.
- **Neutrality**: `zoteroRegistrationIsDataDriven` mirrors the podcast
  scan (no `.zotero` kind comparisons; the package ID literal only in the
  reviewed-identity table), and `Sources/WikiCtlCore` + `Sources/wikictl`
  joined `scannedRoots` so the discovery path is covered.

## Verification

- `swift test` suites: `ExtractorSyncDeclarationTests` (15),
  `ExtractorSyncSidecarTests` (13), `ExtractorPackageSyncTests` (7),
  `ExtractorSyncCommandTests` (15, including the second-package fixture:
  a different template/alphabet, no credentials, zero host changes).
- `swift run extractor-package-tool validate ExtractorPackages/Zotero` and
  `protocol-smoke` against the committed fixtures — green with the new
  digest.
- `scripts/sync-extractor-packages.sh --check` — green.
- `make build` / `make test` — green (after updating the reviewed-package
  gate to revision 3 and the unsupported-revision fixture to 4).
- Documented deltas (not regressions): load-time item validation is
  intentionally stricter than the old engine (which validated nothing in
  production), and duplicate list items hard-fail instead of deduping.
