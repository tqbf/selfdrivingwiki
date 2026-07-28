---
timestamp: 2026-07-18T135241Z
title: "2026-07-17 — Fli## 2026-07-18 — Tantivy Phase 0 build spike (branch `spike/tantivy-build-verification`)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-17 — Fli## 2026-07-18 — Tantivy Phase 0 build spike (branch `spike/tantivy-build-verification`)

## Progress


**What changed:** Added `botisan-ai/tantivy.swift` (`from: "0.3.4"`) as an SPM
dependency on `WikiFSSearch` + `WikiFSTests`. Verified the pre-built
`libtantivy-rs.xcframework` resolves under bare `swift build` (no Xcode, no
xcodebuild) and the UniFFI FFI bridge works end-to-end. Findings doc:
`plans/tantivy-build-spike-results.md`.

**Result: ✅ Phase 0 PASSED — Phase 1 (shadow index) unblocked.**

- `swift build` succeeds in 68 s (exit 0). Zero warnings in the build log.
- XCFramework macOS slice is a **universal binary** (`arm64` + `x86_64`,
  confirmed via `lipo -archs`) — contradicts the design doc's §1.2 "Intel
  likely unsupported." Intel Macs ARE supported.
- `@TantivyDocument` macro expands cleanly under `-warnings-as-errors` (the
  expanded Codable/CodingKeys is type-checked in `WikiFSTests`, which has
  strict settings). No Swift 6 concurrency warnings.
- Binary delta: +12 MB (debug executable 98 MB → 110 MB). Within the <20 MB
  threshold.
- Smoke test (`TantivySmokeTests.swift`): create index → `@TantivyDocument` with
  `@IDField`/`@TextField` → index one doc → search → verify hit + score.
  Passes in 0.11 s. Fast, untagged (runs in the fast CI tier).
- No symbol conflicts with `CSqliteVec` — disjoint namespaces.

**API confirmed:** `TantivySwiftIndex<T>(path:)` generic actor,
`index(doc:)` auto-commits, `TantivySwiftSearchQuery<T>(queryStr:defaultFields:)`
with macro-synthesized `CodingKeys`. No `SnippetGenerator` exposed (confirms
design doc §4.3 fallback: client-side highlighting for Phase 1).

**Not done here:** Tantivy is NOT wired into the search pipeline. No production
code in `Sources/WikiFSCore/` imports it yet — only the smoke test does.
Phase 1 implements `TantivySearchService` + `TantivyIndexer` +
`WikiSearchDocument` + event bus subscription.

## Verification

Historical verification remains in the progress record above.
