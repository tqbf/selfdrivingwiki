---
timestamp: 2026-07-17T162951Z
title: "2026-07-17 — Issue #488: Delete dead content-sniff forwarder shims (branch `cleanup/dead-sniff-forwarders`)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-17 — Issue #488: Delete dead content-sniff forwarder shims (branch `cleanup/dead-sniff-forwarders`)

## Progress


**Shipped.** Removed 81 lines of dead forwarder shims left over from the
`ContentSniff` extraction. All real callers use `ContentSniff.mimeType(of:)`
(or `FormatMaterializer.dispatch`, which now calls it directly).

**Deleted from `URLFetchService.swift`** (zero production callers — only
tests/forwarders referenced them):
- `shouldSniff`, `sniffContentType` — 1-line forwarders to FormatMaterializer.
- `stemFromURL` — dead; comment admitted "backward compat"; `nameHint(for:)`
  is the production path.
- `sanitizeStem`, `ensureExtension`, `textExtension` — dead forwarders (only
  test callers or zero callers); canonical copies live on `FormatMaterializer`.

**Kept** (real production callers): `URLFetchService.normalizedMIME`
(WebsiteSnapshotExtractor), `decodeText` (SourceMaterializer),
`binaryExtension` (WebsiteSnapshotExtractor).

**`FormatMaterializer.swift`:** inlined the `sniffContentType` forwarder —
`dispatch` now calls `ContentSniff.mimeType(of:)` directly. Kept `shouldSniff`
(real switch logic, not a forwarder; used internally by `dispatch`). Note:
the issue's premise that the FormatMaterializer methods were "only called by
the dead shim" was incorrect — they have an internal caller (`dispatch`);
only the `URLFetchService` versions were truly dead.

**Tests:** deleted duplicate `URLFetchServiceTests` copies (canonical versions
already exist in `FormatMaterializerTests`). Migrated
`stemFromURLPrefersPathThenHost` → `nameHintPrefersPathThenHost` (tests the
production replacement). Migrated `FormatMaterializerTests.sniffContentType`
to call `ContentSniff.mimeType(of:)` directly. Removed `URLFetchService` from
the `ExtensionCheckGuardTests` allowlist (no longer contains extension checks).

## Verification

Historical verification remains in the progress record above.
