---
timestamp: 2026-08-20T172500Z
title: Centralized MIME detection
branch: feature/centralized-mime-detection
status: complete
---

# Centralized MIME Detection Progress

## Progress

- Added a typed 64 KiB bounded `ContentTypeDetector`.
- Added canonical MIME normalization, ordered evidence, confidence, and conflicts.
- Added binary signatures for PDF, PNG, JPEG, GIF, WebP, ZIP, gzip, 7z, and RAR.
- Added complete-input recognition for JSON, XML, SVG, HTML, XHTML, and UTF-8 text.
- Added shared JSON Canvas validation in `WikiFSTypes`.
- Kept JSON Canvas MIME as `application/json`.
- Made renderer artifact validation reject truncated input.
- Made format dispatch use the canonical detection result.
- Threaded typed hints and results through local, website, Zotero, folder, generated, and snapshot materializers.
- Made initial, refresh, and snapshot writes re-detect from their own bytes.
- Synchronized active source and source-version MIME mirrors.
- Added conflict reporting through `DebugLog.store`.
- Added `wikictl admin repair-mime [--apply] [--json]`.
- Added a source-audit test against independent MIME policy.

## Repair behavior

The repair command uses the active ref before the maximum-version fallback. It reads a bounded blob prefix and the total length.

Dry-run mode writes nothing. Apply mode updates both active MIME mirrors in one transaction. It emits source update events only after commit.

The command skips byteless and inconclusive rows. It does not change inactive historical versions.

## Verification

- Detector and renderer policy checkpoint: 71 tests passed.
- Materializer integration checkpoint: 72 tests passed.
- Persistence and event checkpoint: 78 tests passed.
- Repair suite: 5 tests passed.
- Architecture, renderer truncation, and repair checkpoint: 12 tests passed.
- Broad MIME checkpoint: 147 behavior tests passed. One architecture-test false positive was fixed and rechecked.
- `make build` passed and produced the signed application bundle.
- `make test` passed 3,505 tests in 339 suites after review fixes.
- `swift build` passed.
- `swift test` passed 3,505 tests in 339 suites after review fixes.
- The review fixed typed HTTP MIME hint loss in app and CLI refresh paths.
- The review moved current byte-ingest paths to the neutral typed store boundary.
- The review added active-ref, inactive-history, event-count, and no-op repair tests.

### Review

- OpenAI GPT authored the implementation.
- Z.AI GLM-5.2 reviewed the final implementation with maximum reasoning.
- The review found no remaining critical or high issues after fixes.
- The review accepted independent refresh detection without parent MIME inheritance.
