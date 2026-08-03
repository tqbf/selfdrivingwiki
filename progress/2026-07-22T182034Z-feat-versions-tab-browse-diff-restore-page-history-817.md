---
timestamp: 2026-07-22T182034Z
title: "feat: Versions tab — browse/diff/restore page history (#817)"
branch: null
status: historical
timestamp_source: git-commit
---

# feat: Versions tab — browse/diff/restore page history (#817)

## Progress


**Goal:** a "Versions" surface that browses page versions at any point in time,
diffs any two versions side-by-side, and restores a previous version. The
backend (append-only `page_versions`, `MarkdownDiff`/`SplitDiff`,
`SplitDiffView`, `WikiReaderView`, provenance) already existed; this PR fills
the 6 concrete gaps from `plans/history-versions.md` §9. **Pages only** (R4) —
sources keep their existing `ExtractionCompareSheet`.

**Investigation → plan:** `plans/history-versions.md` holds the read-only
investigation (§1–§11) + the handoff plan with acceptance criteria AC.1–AC.11
(§"Implementation plan"), written against the plan-review corrections R1–R9.

**Restore semantics (operator override of R1):** restore is **append-only**.
A NEW `store.restorePage(pageID:to:)` appends a new `page_versions` node that
reuses the target's `blob_hash` (CAS dedup — zero new blob bytes), records a
`'restore'` PROV activity (badged orange in the history list), and repoints
HEAD to the new node. History is never mutated; the restore is itself an
auditable node. The existing `store.revertPage` (ref-repoint) is left AS-IS
for `wikictl page revert` backward-compat (it has another caller in
`WikiCtlCore/PageCommand.swift`). Mirrors the source-side split between
`setActiveMarkdown` (repoint) and `revertProcessedMarkdown` (append).

**Files touched:**
- **New:** `Sources/WikiFS/Pages/PageVersionCompareSheet.swift` (the
  `PageVersionCompareContext` + `PageVersionCompareWindow` +
  `PageVersionCompareSheet` — a ~370-LOC resizable non-modal window mirroring
  `ExtractionCompareSheet`, fed by `pageEditHistory` + `pageVersionBody`),
  `Tests/WikiFSTests/PageVersionSelectionTests.swift` (diff-wiring + history
  invariants).
- **Edit (store):** `Sources/WikiFSCore/Store/WikiStore.swift`
  (`pageVersionBody(versionID:)` READ + `restorePage(pageID:to:)` on the
  protocol), `Sources/WikiFSCore/Store/GRDBWikiStore.swift` (`pageVersionBody`
  via `dbWriter.read` JOIN on `page_versions → blobs` — emits nothing;
  `restorePage` via `mutate()` — appends node + `'restore'` activity +
  repoints ref + updates `pages` mirror),
  `Sources/WikiFSCore/Store/WikiStoreModel.swift`
  (`pageVersionBody(for:)` + `restorePage(for:to:)` wrappers).
- **Edit (UI):** `Sources/WikiFS/Detail/ProvenancePanel.swift` (optional
  `onCompareVersions` closure → a page-only "Compare Versions…" button;
  `'restore'` badge color), `Sources/WikiFS/Detail/DetailInspectorView.swift`
  (thread the closure through), `Sources/WikiFS/Pages/PageDetailView.swift`
  (`@Environment(\.openWindow)` + `openVersionsWindow()` entry point),
  `Sources/WikiFS/Window/WikiFSApp.swift` (register the
  `WindowGroup("Compare Versions", for: PageVersionCompareContext.self)`).
- **Edit (tests):** `Tests/WikiFSTests/PageVersionTests.swift` (AC.1
  `pageVersionBody` reads + AC.2 model wrapper + AC.3 `restorePage`
  append/head/badge), `Tests/WikiFSTests/StoreEmissionTests.swift`
  (`restorePageEmitsPageUpdated`).
- **Docs:** `plans/history-versions.md` (investigation + AC plan),
  `PLAN.md` (index row), this file.

**Reuse as-is (zero changes):** `MarkdownDiff`/`SplitDiff`/`Diff3`,
`SplitDiffView` (the diff renderer — fed two `pageVersionBody` reads),
`WikiReaderView` (rendered preview — bound to the LIVE store per R8 so
wiki/ghost links resolve against current state), all existing store versioning
methods, the refs/blobs schema.

**Naming (R7):** user-facing label is "Versions" / "Compare Versions"; the
`InspectorTab.history` enum case is unchanged (its rawValue is persisted in
`@AppStorage`).

**Tests:** `swift test --filter PageVersionTests|PageVersionSelectionTests|restorePageEmitsPageUpdated`
→ 37 pass. Full suite: 3463 pass; 3 pre-existing failures in
`ACPIngestPlanTests` / `QuotaFallbackIntegrationTests` (`startCount → 0` —
ACP provider backends never started) are unrelated to this change (this PR
touches only page-versioning files; the ACP/`WikiFSEngine` domain is untouched).

## Verification

Historical verification remains in the progress record above.
