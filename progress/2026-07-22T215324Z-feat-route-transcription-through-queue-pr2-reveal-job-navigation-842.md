---
timestamp: 2026-07-22T215324Z
title: "feat: Route transcription through queue PR2: reveal-job navigation (#842)"
branch: null
status: historical
timestamp_source: git-commit
---

# feat: Route transcription through queue PR2: reveal-job navigation (#842)

## Progress


**Goal:** when a transcription is running/queued for a source, clicking
Transcribe navigates the user to that job in the Activity window — mirroring
the "View Lint" pattern from #837. PR1 (#845, merged) added the
`.transcription` QueueKind + worker + enqueue; PR2 adds the navigation.

**Files touched:**
- **C1 — Parameterize `openActivityWindow` with `QueueKind`:**
  `Sources/WikiFS/Environment/ActivityWindowEnvironmentKey.swift`
  (the closure type changed from `(() -> Void)?` to
  `((QueueKind) -> Void)?` so callers can target the ingestion, extraction,
  or transcription Activity window),
  `Sources/WikiFS/Window/OpenWindowBridge.swift`
  (`openActivityWindow` property follows),
  `Sources/WikiFS/Window/MenuBarItemController.swift`
  (the assignment at `start()` forwards the `queue` argument through
  `openQueueWindow?(queue)`),
  `Sources/WikiFS/Window/WikiFSApp.swift`
  (`appEnvironment` signature + all three call sites: main `WindowGroup`,
  wiki `WindowGroup(for: String.self)`, and the Activity
  `WindowGroup(for: QueueKind.self)` — the last now routes the queue argument
  to `openQueueWindow?(queue)` instead of hardcoding `.ingestion`),
  `Sources/WikiFS/Pages/PageDetailView.swift`
  (the two `openActivityWindow?()` calls now pass `.ingestion`),
  `Sources/WikiFS/Detail/ProvenancePanel.swift`
  (the `openActivityWindow?()` call now passes `.ingestion`).
- **C4 — `pendingSelectionQueue` guard:**
  `Sources/WikiFS/Queue/QueueActivityTracker.swift`
  (added `var pendingSelectionQueue: QueueKind? = nil` alongside
  `pendingSelectionItemID`; cleared in `stop()`),
  `Sources/WikiFS/Queue/ActivityWindowView.swift`
  (`consumePendingSelectionIfNeeded()` now checks
  `pendingSelectionQueue == queue` before consuming — prevents a
  cross-window race when both `.transcription` and `.ingestion` windows
  exist: a lint pending-selection is not consumed by the transcription
  window, and vice versa).
- **C5 — `transcriptionItemID(for:)` + SourceDetailView navigation:**
  `Sources/WikiFS/Queue/QueueActivityTracker.swift`
  (added `itemToTranscriptionSourceIDs` tracking dict populated in the
  `.transcription` arm of `.started`, cleared in `removeItem` and `stop()`;
  added `func transcriptionItemID(for sourceID: PageID) -> QueueItem.ID?`
  that resolves the running transcription job for a given source — mirroring
  `lintItemID(for:wikiID:)` from #837),
  `Sources/WikiFS/Sources/SourceDetailView.swift`
  (added `@Environment(\.openActivityWindow)`; the Transcribe button swaps
  to "View Transcription" with `checkmark.seal.fill` icon when
  `isTranscribing` is true, stays enabled, and on tap sets
  `tracker.pendingSelectionItemID` + `tracker.pendingSelectionQueue = .transcription`
  then calls `openActivityWindow?(.transcription)` — reusing #840's existing
  `pendingSelectionItemID` seam, NOT building a new class; when not
  transcribing, the button enqueues as before; the `.disabled` guard was
  split: disable for the enqueue path but not for the navigate path).
- **C6 — `headVersion` refresh via store change event:**
  `Sources/WikiFS/Sources/SourceDetailView.swift`
  (added `.onChange(of: store.sources)` that re-reads
  `processedMarkdownHead` when not editing — picks up the
  `ResourceChangeEvent(.source, .updated)` from
  `appendProcessedMarkdown` → `mutate()` → bus → `reloadFromStore()` →
  `reloadSources()` → `sources` bump; works across windows so another wiki
  window viewing the same source sees the new transcript without the
  initiating view's post-completion refresh),
  `Tests/WikiFSTests/StoreEmissionTests.swift`
  (added `appendProcessedMarkdownTranscriptOriginEmitsSourceUpdated` —
  verifies the `.transcript` origin emits a `ResourceChangeEvent(.source,
  .updated)`, mirroring the existing `.extraction` origin test).
- **Tests:** `Tests/WikiFSAppTests/QueueIngestionTests.swift`
  (11 new tests in `QueueActivityTrackerLintItemIDTests`:
  `pendingSelectionQueue` defaults/stop, `transcriptionItemID` resolution,
  nil-when-idle, no-cross-kind-conflation with extraction, cleanup on
  completion/cancellation, cross-kind ID non-conflation).

**Reused #840's navigation seam** — `pendingSelectionItemID` +
`consumePendingSelectionIfNeeded()` — no new `PendingActivitySelection`
class. The `pendingSelectionQueue` guard extends the seam to be
queue-aware, preventing cross-window consumption when both
`.transcription` and `.ingestion` Activity windows are open.

**Verified:** `make version prompts && swift build` clean (128s); `swift
test` — 3665 tests in 303 suites passed (21.9s). The 11 new tracker tests
+ 1 new emission test pass via
`swift test --filter "transcription|pendingSelection|transcriptOrigin|appendProcessedMarkdown"`.

## Verification

Historical verification remains in the progress record above.
