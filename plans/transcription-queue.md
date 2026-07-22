# Issue #842 — Route transcription through the queue engine

**Goal:** make `SourceDetailView.runTranscription()` enqueue a durable queue
job instead of running inline, and reveal that job in the Activity window —
matching how extraction and ingestion are already queued.

**Scope:** YouTube + podcast (Apple/RSS) transcription. No daemon work; no
live chat. PR1 = queue infrastructure + worker + enqueue (no nav). PR2 =
reveal-job navigation (shared with #837).

## PR1 scope (corrected per §9)

- Add `.transcription` to `QueueKind` + ALL compile-breaking switch sites (C2):
  `QueueEngine` (dispatch + arrays + snapshot literal), `QueueActivityTracker`
  (×2: `.started` + `removeItem`), `OperationNotifier` (enum + switch arm),
  `QueueStore` (array literal in `pruneHistory`), `ActivityWindowView`
  (`kindLabel`).
- Add `transcriptionLimit` (default 2) to `QueueEngineConfig`.
- Add `transcribingSourceIDs` to `QueueActivityTracker` +
  `isTranscribing(sourceID:)` (C3).
- Worker + factory + provider mirroring extraction (`QueueTranscriptionProvider`,
  `QueueTranscriptionWorker`, `AppQueueTranscriptionProvider`).
- Migrate `runTranscription()` to enqueue. Replace (don't delete) `isTranscribing`
  with a computed property from `tracker.transcribingSourceIDs` (C5). Drop the
  `transcribeError` inline rendering.
- Activity-window branches: `queueTitle`, `kindLabel`, empty-state, icon, autosave
  name (C7 — convert ternaries to switches).
- Tests for every new switch arm + tracker + worker + provider.
- `swift build` clean is the gate (C2). `swift test` must pass full suite.

## PR2 scope (corrected per §9)

- Parameterize `openActivityWindow` with `QueueKind` (C1).
- Add `pendingSelectionQueue` guard (C4).
- `SourceDetailView` sets `pendingSelectionItemID` + calls the parameterized
  opener (reuse #840's existing seam, NOT a new class).
- `headVersion` refresh via store change event (C6).

## §9 Plan-Review Corrections (AUTHORITATIVE)

### C1 — PR2's navigation mechanism reuses already-merged PR #840
`QueueActivityTracker.pendingSelectionItemID` (line 130) is the
pending-selection rendezvous. `ActivityWindowView.consumePendingSelectionIfNeeded()`
(lines 116-121) reads + clears on `.onAppear` (line 71) and
`.onChange(of: pendingSelectionItemID)` (line 78-80). `PageDetailView.swift:303-306`
is the proven seam. Drop the `PendingActivitySelection` class entirely.

### C2 — Adding `.transcription` breaks exhaustive switches; PR1 will NOT compile
Compile-breaking switch sites:
1. `QueueEngine.swift:571-576` — `switch item.queue` capacity dispatch. Also add
   `transcriptionLimit` to `QueueEngineConfig` (default 2).
2. `QueueActivityTracker.swift:520` (`.started`) and `:662` (`removeItem`).
3. `OperationNotifier.swift:155-163` — `operationKind(for:)` + `OperationKind` enum.
4. `QueueStore.swift:761` — array literal (not a switch, but silently skips).

Also: `QueueEngine.swift:121, 209, 554` — array literals that skip transcription.
`QueueEngine.swift:321-323` — snapshot `qs` dict literal.

### C3 — `QueueActivityTracker` source-tracking for transcription is missing
Add a `transcribingSourceIDs` set (mirror `extractingSourceIDs`), wire it in the
`.started` (`:520`) and `removeItem` (`:662`) switch arms, and expose
`isTranscribing(sourceID:)`.

### C4 — Add a `pendingSelectionQueue` guard (PR2)
Add `pendingSelectionQueue: QueueKind?` alongside `pendingSelectionItemID`.

### C5 — Don't delete `isTranscribing`; derive it from the tracker
Replace `isTranscribing` with a computed property derived from
`tracker.transcribingSourceIDs`. Wire it into the `:824/:1643/:1662` disabled guards.

### C6 — `headVersion` refresh after async enqueue (PR2)
Confirm `appendProcessedMarkdown` emits via `mutate()` → `ResourceChangeEvent`,
and that `SourceDetailView` observes it to call `processedMarkdownHead`.

### C7 — Broaden the switch-site audit
Convert ternaries (`queueTitle` at `ActivityWindowView:43`,
`queueWindowAutosaveName` at `MenuBarItemController:480`, icon at `:387`,
empty-state at `:208`) to switches.

### C8 — Remove `PendingActivitySelection.swift` from file checklist (PR2)

## Architecture

- **New `.transcription` QueueKind** — distinct from `.extraction` because
  extraction's `ExtractionResolution` is PDF-shaped (`pdfData`,
  `convert(pdfData:)`, `ExtractionBackend`). A transcript is a network/subprocess
  fetch keyed by video ID / feed URL with no local bytes.
- **Protocol** `QueueTranscriptionProvider`: `resolveTranscription(...) ->
  TranscriptionResolution?` + `persistTranscription(...)`.
- **`TranscriptionResolution`**: a `@Sendable () async throws -> String` fetch
  closure + technique tag. No `pdfData`.
- **Worker** `QueueTranscriptionWorker.execute`: resolve → fetch → persist.
- **Factory** `QueueTranscriptionWorkerFactory`: `providerID(for:)` (pre-check via
  resolve) + `worker(for:)`.
- **App provider** `AppQueueTranscriptionProvider`: `@MainActor`, bridges
  `SessionLookupBox` → `store.sourceOrigin` + builds the right detached fetch per
  provider (YouTube/RSS/Apple). `persistTranscription` calls
  `store.appendProcessedMarkdown(origin: .transcript, ...)`.
- **Wiring** in `WikiFSApp`: add `.transcription: transcriptionFactory` to
  `CompositeWorkerFactory(factories:)`.
- **UI trigger** `runTranscription()`: `QueueItemRequest(queue: .transcription, ...)`
  → `queueEngine.enqueue` → (PR2: reveal the new job).
- **Capacity**: single provider id `"transcription"`, limit 2 (no local-subprocess
  serialization constraint).

## File change checklist (PR1)

| File | Change |
|---|---|
| `Sources/WikiFSCore/Core/QueueTypes.swift` | + `case transcription` |
| `Sources/WikiFSCore/Core/QueueStore.swift` | + `.transcription` in `pruneHistory` array |
| `Sources/WikiFSEngine/QueueWorker.swift` | + `transcriptionLimit` on `QueueEngineConfig` |
| `Sources/WikiFSEngine/QueueEngine.swift` | + `.transcription` in dispatch switch + array literals + snapshot dict |
| `Sources/WikiFSEngine/QueueTranscriptionProvider.swift` | **NEW** — protocol + `TranscriptionResolution` + error |
| `Sources/WikiFSEngine/QueueTranscriptionWorker.swift` | **NEW** — worker + factory |
| `Sources/WikiFS/Queue/AppQueueTranscriptionProvider.swift` | **NEW** — `@MainActor` provider |
| `Sources/WikiFS/Queue/QueueActivityTracker.swift` | + `transcribingSourceIDs` + `.transcription` arms |
| `Sources/WikiFS/Queue/OperationNotifier.swift` | + `.transcription` in enum + switch |
| `Sources/WikiFS/Queue/ActivityWindowView.swift` | `.transcription` branches (title, label, empty, icon, CTA) |
| `Sources/WikiFS/Window/WikiFSApp.swift` | wire transcription provider/factory |
| `Sources/WikiFS/Window/MenuBarItemController.swift` | transcription window + autosave + menu item |
| `Sources/WikiFS/Sources/SourceDetailView.swift` | enqueue + replace `isTranscribing`; delete `transcribeError` |
| `Tests/WikiFSTests/QueueTranscriptionTests.swift` | **NEW** |
