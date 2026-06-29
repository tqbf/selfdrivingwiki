# MLX MiniLM Implementation Plan — Phase 3: Off-main Backfill + Metal Safety

**Goal:** Move per-chunk embedding from `@MainActor` to a background `Task.detached`
when `MiniLMEmbedder` is active (no `Task.yield()` jank mitigation), and handle
the **Metal backgrounding risk**: MLX submits Metal GPU work that crashes with
`Insufficient Permission` if the app is backgrounded mid-inference, so the backfill
must pause while inactive and resume on foreground.

**Architecture:** `WikiStoreModel.backfillMissingEmbeddings()` branches on the
active embedder: MiniLM → `Task.detached(priority: .utility)` (no yields); NLEmbedder
fallback → preserves the existing `@MainActor` + `Task.yield()` path (avoid the
`BNNSFilterApplyBatch` crash). A new `AppStateObserver` sets an atomic
`isAppActive` flag on `willResignActive`/`didBecomeActive`; the MiniLM backfill
loop checks it before each inference and yields/sleeps while inactive. `SQLiteWikiStore`
is `@unchecked Sendable` (thread-safe via `SQLITE_OPEN_FULLMUTEX`).

**Tech Stack:** Swift 6.0, macOS 15, Swift concurrency (`Task.detached`),
`NSApplication` notifications, os_log

**Scope:** Phase 3 of 4. Produces the backfill concurrency change in
`WikiStoreModel.swift` + `SQLiteWikiStore.swift` Sendable conformance + the
`AppStateObserver`.

**Codebase verified:** 2026-06-29

---

## Acceptance Criteria Coverage

### AC5: No UI jank during backfill (+ survives backgrounding)
- The app launches and the first backfill completes with no UI jank (off-main) and no crash — including surviving a background/foreground cycle mid-backfill.

### AC2 (latency, re-measured)
- Per-chunk latency ≤ ~20 ms on Metal/GPU, re-verified via wall-time of full-corpus backfill.

### AC4: Search quality parity
- Hybrid search (FTS + vec + RRF) returns equivalent-or-better results to NLEmbedding (manual).

---

## Task 1: Make WikiStore Sendable; mark SQLiteWikiStore @unchecked Sendable

**Files:**
- Modify: `Sources/WikiFSCore/WikiStore.swift`
- Modify: `Sources/WikiFSCore/SQLiteWikiStore.swift`

Under Swift 6, `Task.detached` closures are `@Sendable`; the store property is
`any WikiStore`, so the **protocol** must conform to `Sendable` (the compiler
checks against the declared type, not the runtime type).

```swift
// WikiStore.swift
public protocol WikiStore: Sendable { ... }
```
```swift
// SQLiteWikiStore.swift
public final class SQLiteWikiStore: WikiStore, @unchecked Sendable { ... }
```
(`SQLiteWikiStore` is thread-safe via `SQLITE_OPEN_FULLMUTEX`; `@unchecked` is correct.)

```bash
git add Sources/WikiFSCore/WikiStore.swift Sources/WikiFSCore/SQLiteWikiStore.swift
git commit -m "feat: WikiStore: Sendable + SQLiteWikiStore @unchecked Sendable"
```

---

## Task 2: Add AppStateObserver (Metal backgrounding safety — NEW)

**Files:**
- Create: `Sources/WikiFSCore/AppStateObserver.swift`

MLX submits Metal GPU work. If the macOS app is backgrounded mid-inference, Metal
crashes with `Insufficient Permission` (`mlx-swift-examples` issue #230). The
backfill checks this flag before each inference and pauses while inactive.

```swift
import AppKit
import Foundation

/// Tracks whether the app is in the foreground, so the MiniLM backfill can avoid
/// submitting MLX/Metal GPU work while backgrounded (which crashes with
/// `Insufficient Permission`). ANE/CoreML did not have this constraint; MLX does.
public final class AppStateObserver: @unchecked Sendable {
    public static let shared = AppStateObserver()

    private let lock = NSLock()
    private var _isActive = true

    public var isActive: Bool {
        lock.withLock { _isActive }
    }

    private var observers: [NSObjectProtocol] = []

    public func start() {
        let nc = NSWorkspace.shared.notificationCenter
        // macOS app "active" = frontmost app. Use NSWorkspace notifications (not
        // NSApplication, which only fires for within-app key-window changes).
        observers.append(nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == Bundle.main.bundleIdentifier else { return }
            self?.set(true)
        })
        observers.append(nc.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == Bundle.main.bundleIdentifier else { return }
            self?.set(false)
        })
    }

    private func set(_ active: Bool) {
        lock.withLock { _isActive = active }
        DebugLog.store("AppStateObserver: app \(active ? "active" : "backgrounded")")
    }
}
```

> **Note:** Choose the notification source that matches how "backgrounded"
> manifests the Metal crash on this OS — `NSWorkspace.did(De)activateApplication`
> (app lost/gained frontmost) is the usual trigger. If live testing shows the
> crash fires on a different signal (e.g. `NSApplication.willResignActive`), use
> that instead. The invariant is: do NOT submit Metal work while the flag is false.

Start it at app launch (WikiFS app entry / `WikiStoreModel` init):
`AppStateObserver.shared.start()`.

```bash
git add Sources/WikiFSCore/AppStateObserver.swift
git commit -m "feat: AppStateObserver — pause Metal work when app is backgrounded"
```

---

## Task 3: Add nonisolated backfillBackground helper (Metal-safe)

**Files:**
- Modify: `Sources/WikiFSCore/WikiStoreModel.swift`

Like the existing `backfill()` (`@MainActor`), but nonisolated, no `Task.yield`,
and Metal-backgrounding-aware:

```swift
/// Off-main backfill for MiniLMEmbedder. Thread-safe; no Task.yield. Pauses
/// (does NOT submit Metal work) while the app is backgrounded.
nonisolated private func backfillBackground(
    kind: String,
    work: [(id: PageID, text: String)],
    storeChunks: (PageID, [Data]) throws -> Void
) {
    guard EmbeddingService.isAvailable else { return }
    var embedded = 0
    for (id, text) in work {
        // Metal safety: wait while backgrounded before submitting GPU work.
        while !AppStateObserver.shared.isActive {
            Thread.sleep(forTimeInterval: 0.5)
        }
        let blobs = EmbeddingService.chunks(for: text).compactMap {
            EmbeddingService.embeddingBlob(for: $0)
        }
        guard !blobs.isEmpty else { continue }
        do {
            try storeChunks(id, blobs)
            embedded += 1
        } catch {
            DebugLog.store("backfill[\(kind)][\(id.rawValue)] store failed — \(error)")
        }
    }
    DebugLog.store("backfill[\(kind)]: embedded \(embedded) of \(work.count) docs (off-main)")
}
```

```bash
git add Sources/WikiFSCore/WikiStoreModel.swift
git commit -m "feat: add nonisolated Metal-safe backfillBackground helper"
```

---

## Task 4: Refactor backfillMissingEmbeddings() — MiniLM off-main, NLE on-main

**Files:**
- Modify: `Sources/WikiFSCore/WikiStoreModel.swift`

Current (`backfillMissingEmbeddings()` at ~:1296) creates `Task { ... }`
(`@MainActor`) with `Task.yield()` between chunks. Replace the body to branch:

```swift
public func backfillMissingEmbeddings() {
    let isMiniLM = EmbeddingService.selectedEmbedderIdentifier() == MiniLMEmbedder.identifier

    if isMiniLM {
        // MiniLM/MLX is safe off-main (ModelContainer.perform serializes).
        // Fetch work arrays synchronously here on @MainActor, then detach.
        let pageWork   = store.missingPageEmbeddingWork()
        let sourceWork = store.missingSourceEmbeddingWork()
        let capturedStore = store

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await EmbeddingService.configure()   // idempotent; loads MiniLM
            self.backfillBackground(kind: "page", work: pageWork) { id, chunks in
                try capturedStore.storePageChunks(id: id, chunks: chunks)
            }
            self.backfillBackground(kind: "source", work: sourceWork) { id, chunks in
                try capturedStore.storeSourceChunks(id: id, chunks: chunks)
            }
        }
    } else {
        // NLEmbedder fallback: must stay @MainActor (BNNSFilterApplyBatch crashes off-main).
        Task { [weak self] in
            await EmbeddingService.configure()
            await self?.backfill(kind: "page",   work: self?.store.missingPageEmbeddingWork() ?? [],
                store: { [weak self] id, chunks in try? self?.store.storePageChunks(id: id, chunks: chunks) })
            await self?.backfill(kind: "source", work: self?.store.missingSourceEmbeddingWork() ?? [],
                store: { [weak self] id, chunks in try? self?.store.storeSourceChunks(id: id, chunks: chunks) })
        }
    }
}
```

```bash
git add Sources/WikiFSCore/WikiStoreModel.swift
git commit -m "feat: backfill MiniLM embeddings off-main via Task.detached (Metal-safe)"
```

---

## Task 5: Verify no Task.yield on the MiniLM path + thread check

```bash
grep -n "Task.yield\|backfillBackground" Sources/WikiFSCore/WikiStoreModel.swift
```
Expected: `Task.yield()` appears ONLY in the legacy `backfill()` (NLE path), not in `backfillBackground()`.

Add a temporary log to `backfillBackground()`:
`DebugLog.store("backfill[\(kind)] starting on thread: \(Thread.current.isMainThread ? "MAIN (BAD)" : "background")")`
Build, run with a corpus, check Console.app (subsystem `com.selfdrivingwiki.debug`):
expect `background`, NOT `MAIN (BAD)`. Remove the log after verifying.

---

## Task 6: Wall-time + backgrounding smoke test (manual)

1. Build with the model dir bundled (`./build.sh`); confirm
   `all-MiniLM-L6-v2` appears in the app bundle.
2. Move/delete the app's existing `wiki.db` (force full re-embed).
3. Launch, time first backfill (expect seconds-to-a-minute, not minutes).
4. **Backgrounding test:** during backfill, cmd-Tab away for ~10s, then return.
   Expect: no crash; Console shows `AppStateObserver: app backgrounded`/`active`;
   backfill resumes and completes.
5. During backfill: pages render immediately, scroll/search responsive (no jank).
6. After backfill: semantic search returns results; Console shows
   `vec_distance_cosine` active (not LIKE fallback).

---

## Task 7: Manual search quality evaluation (AC4)

5–10 queries spanning factual / conceptual / troubleshooting / cross-document /
keyword-heavy / semantic-only. Pass: each returns ≥ 2 relevant results in the top
3; no empty results after backfill; no off-topic top result. Record in
`tmp/minilm-quality-eval.md` (not committed).
