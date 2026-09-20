---
timestamp: 2026-09-19T220000Z
title: wikictl extractor family, neutral host seams, pyzotero metadata
branch: feature/zotero-extractor-package
status: complete
---

# `wikictl extractor` family, acquisition-neutral host seams, pyzotero metadata

Plan: [`plans/zotero-extractor-package.md`](../plans/zotero-extractor-package.md).
Branch `feature/zotero-extractor-package` (PR #1304). Follow-up to
[`2026-09-19T200000Z-zotero-extractor-package.md`](2026-09-19T200000Z-zotero-extractor-package.md).

## Progress

- **CLI family**: `wikictl zotero sync` is now `wikictl extractor sync
  <package> [--force]`. `ExtractorSyncCommand` holds a `Package` enum and a
  per-package private entry; unknown packages are usage errors naming the
  supported set; the parse accepts the package positionally before the
  options bag. The API-key hard gate moved into the zotero entry
  (`ZoteroSyncError.apiKeyNotConfigured`); the generic command's `Failure`
  knows only `unknownPackage`. `ZoteroCredentialStore` is deleted — the
  generic `KeychainCredentialService` + `.zoteroAPIKey()` owns the Keychain.
- **Neutral store seam**: `attachZoteroAttachment`/`setZoteroProvenance` are
  now `attachAcquiredBytes`/`setAcquisitionProvenance` on the `WikiStore`
  protocol + `GRDBWikiStore` + both queue providers. Same bodies, same
  single-`mutate()` transactions, same writes to the retained
  `zotero_item_key`/`zotero_item_title` columns (compat contract). The
  protocol file now names no package at all (architecture test restored to a
  blanket negative). Typed operation shapes that genuinely differ per kind
  (`prepareZoteroAttachment()`, `ExtractorKind.zotero`, provider routing,
  `ZoteroConfig`, `ZoteroSettingsView`, provider display data) stay — the
  neutrality contract allows typed operation seams and per-package config.
- **Seeding table**: `ReviewedExtractorBootstrap`'s inline zotero seeding is
  a `reviewedCredentialSeeds` table iterated generically (fingerprint from
  the installed record → marker check → grant → marker write). Revocation
  safety unchanged: the marker decides, record presence is never consulted.
  New hosted `ReviewedCredentialSeedingTests` (fixture bundle from the
  repo's `ExtractorPackages/Zotero` tree) covers first-publish grant + marker,
  revoke → republish stays revoked, and stale marker fingerprint → re-grant.
- **pyzotero metadata (hybrid)**: the package's two metadata GETs go through
  the `pyzotero` client (`Zotero(libraryID, "user", apiKey)` via a
  `_make_client` factory seam); the file download keeps streaming `requests`
  for the byte-cap abort and mid-stream deadline self-report. Verified
  against released pyzotero 1.15.2: `item()` returns the bare API object, so
  the envelope unwrap and guards are unchanged; 401/403 →
  `UserNotAuthorisedError`, 404 → `ResourceNotFoundError`, other →
  `HTTPError` — mapped to the same bounded no-URL/no-key messages.
  `pyzotero-cli` rejected (interactive; credentials-through-argv). Package
  deps: PEP 723 + pyproject + `uv.lock` regenerated; PROVENANCE names the
  direct set and licenses (requests Apache-2.0, pyzotero BlueOak-1.0.0,
  transitives feedparser/bibtexparser/whenever/httpx2). New pinned digest
  `591062da…` in both golden locations.
- **Docs**: design doc gained the CLI grammar, the neutral-seam + seeding
  notes, and a "Dependency decision" section (evidence + escape hatch);
  PLAN.md row updated; user guide already used the new grammar.

## Verification

`swift build`, `swift test --filter "ExtractorSync|Zotero"`, `make test`,
`WIKIFS_APP_TESTS=1 make test`, package pytest (67)/ruff/pyright, package
validate + protocol-smoke + drift check with the new digest,
`ReviewedExtractorPackageTests`, extractor-kind-neutrality contract, and the
new seeding suite. App-graph triage: bare `WIKIFS_APP_TESTS=1 swift test`
failed 31 suites without prerequisites; after `make version prompts` only
`YouTubeEmbedWebViewTests` fails, and it fails identically on `main` (same
two assertions) — pre-existing, unrelated to this branch, documented in the
PR.

## Deliberately deferred

Picker UI, Authorize/Revoke UI, app auto-sync, conditional re-download, and
manifest-declared syncability (packages advertising sync config in
registration data; the CLI discovering syncable packages from the catalog) —
sequenced behind the later UI cycle that defines what "syncable" means.
