---
timestamp: 2026-07-13T160604Z
title: "2026-07-13 — Multi-window UI — per-wiki windows (Phase 2b of #358)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-13 — Multi-window UI — per-wiki windows (Phase 2b of #358)

## Progress


**Multi-window is implemented.** The plan lives at
`plans/multi-window-ui.md`. Users can now open multiple wiki windows
simultaneously, each with its own `WikiSession` — a long ingest in wiki A's
window does not block a query in wiki B's window. Two windows over the SAME
wiki share one session (one store, one bus, one gate).

**New types:**
- **`SessionManager`** (`Sources/WikiFSEngine/SessionManager.swift`) —
  `@MainActor @Observable`. Owns the `[wikiID: WikiSession]` cache.
  `session(for:descriptor:)` is create-or-get (same wiki ID returns the
  existing session). `releaseSession(for:)` flushes + removes.
  `flushAllSessions()` flushes all active. `frontmostWikiID` /
  `frontmostSession` for `VacuumCommands` resolution.
- **`RootScene`** (`Sources/WikiFS/RootScene.swift`) — per-window entry
  point. Receives `wikiID: String?`, resolves the session via
  `sessionManager`, owns per-window `scenePhase` (flush-on-background +
  search-index backfill), vacuum alert, and `.onDisappear` session release.

**What changed:**
- `@State session` + `SessionRef` → `@State sessionManager: SessionManager`
- `WindowGroup { RootView(session:) }` → two WindowGroups: single-identity
  main (launch + MRU wiki) + `WindowGroup(for: String.self)` (additional
  wiki windows). Both use `RootScene`.
- `.onChange(of: registry.activeWikiID)` session creation → moved into
  `RootScene` (per-window via `resolveSession(for:)`).
- `.onChange(of: scenePhase)` + vacuum `.alert` → moved into `RootScene`.
- `WikiChangeBridge`: `weak var session` → `var sessionLookup` closure.
  `flush(wikiID:)` pokes all matching sessions' buses.
- `FileProviderSpike`: `subscribeActiveStoreBus` (single) →
  `subscribeBus(for:bus:)` + `unsubscribeBus(for:)` (multi-dict).
- `WikiSwitcher`: `registry.select(id)` → `openWindow(value: id)` default,
  `registry.select(id)` Option+click (in-window switch).
- `VacuumCommands`: `session: WikiSession?` → `sessionManager` (resolves
  `frontmostSession`).
- `ExtractionCompareContext` gained `wikiID` field (so the compare window
  resolves the correct session). `ExtractionCompareWindow` takes
  `sessionManager` instead of `session`.
- `WikiRegistryClient.flushActiveStore` signature: `(() -> Void)?` →
  `((String) -> Void)?` (passes the wiki ID being exported/deleted).
- `RootView.session`: `WikiSession?` → `WikiSession` (non-optional;

**Files changed (13 total):**
- 3 new: `SessionManager.swift`, `RootScene.swift`, `SessionManagerTests.swift`
- 10 modified: `WikiFSApp`, `RootView`, `WikiSwitcher`, `WikiChangeBridge`,
  `ExtractionCompareSheet`, `FileProviderSpike`, `VacuumCommands`,
  `SourceDetailView`, `WikiRegistryClient`, `FPIfSubscriberDebounceTests`
- Tests: `SessionManagerTests` (9 tests) + updated `WikiChangeBridgeTests`
  (4 tests). All pass. `swift build` clean, fast-tier (2305 tests) green.

**What does NOT change:** the daemon, the File Provider extension, `wikictl`
store writes, Darwin notification routing, SQLite concurrency invariants,
agent config, `ExtractionCoordinator`, `settingsLauncher`, `WikiSession`
itself, `WikiRegistryClient` (except the `flushActiveStore` signature).

## Verification

Historical verification remains in the progress record above.
