---
timestamp: 2026-07-16T032543Z
title: "Queue Engine — Phase 4: Extraction Through the Queue (2026-07-14)"
branch: null
status: historical
timestamp_source: git-commit
---

# Queue Engine — Phase 4: Extraction Through the Queue (2026-07-14)

## Progress


**Status:** Complete. All 78 queue tests pass across 4 suites. Build clean.

**What:** All PDF extraction flows through the central extraction queue.
The `QueueExtractionWorkerFactory` + `QueueExtractionWorker` resolve the
extractor + PDF bytes via the `QueueExtractionProvider` protocol, check
`readiness()`, call `convert()` with progress reporting, and persist the
result. `waitForCompletion(of:)` lets callers (AgentOperationRunner,
SourceDetailView) await extraction results synchronously.

**QueueActivityTracker:** `@Observable @MainActor` class that observes
`QueueEngine.events` and replaces the launcher's extraction slot machinery
(`isExtracting`, `extractionLog`, `extractionPID`, `extractingSourceIDs`,
`extractTask`, `stopExtraction`). Injected via `.environment()`.

**Retired from AgentLauncher:** `awaitExtractionSlot`,
`releaseExtractionSlot`, `isExtractionSlotBusy`, `extractionWaiters`,
`ExtractionWaiter`, `extractPDF`, `stopExtraction`, `extractionLog`,
`isExtracting`, `extractionPID`, `extractingSourceIDs`, `extractTask`.
Local-pdf2md limit-1 is now enforced by the engine's capacity config, not
the slot.

**Files:** `Sources/WikiFSEngine/QueueExtractionProvider.swift`,
`Sources/WikiFSEngine/QueueExtractionWorker.swift`,
`Sources/WikiFS/QueueActivityTracker.swift`,
`Sources/WikiFS/WikiFSApp.swift` (wiring), view migrations across
SourceDetailView, SourcesContainerView, ContentView, WikiDetailView,
PdfExtractionView, ExtractionSettingsView, AgentActivitySidebar, SidebarView.

**Build/tests:** `swift build` clean; 78 queue tests pass across 4 suites.


---

## Verification

Historical verification remains in the progress record above.
