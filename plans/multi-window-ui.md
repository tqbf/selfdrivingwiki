# Multi-window UI — per-wiki windows (`WindowGroup(for: String.self)`)

**Status:** Phase 2b of #358. Builds on the Phase 2a `WikiManager` dissolution
(`plans/dissolve-wikimanager.md`), which split `WikiManager` into
`WikiRegistryClient` (app-scoped) + `WikiSession` (per-active-wiki). This step
makes sessions truly per-window: each window holds its own `WikiSession`,
keyed by the wiki ID passed to `WindowGroup(for: String.self)`.

**Decisions (confirmed with operator):**
- **M1: `WindowGroup(for: String.self)` — wiki ID is the window value.**
  `String` is already `Codable + Hashable`, so no wrapper type needed (unlike
  `ExtractionCompareContext`). Each window's `RootView` receives the wiki ID
  from the scene's `$wikiID` binding and creates/resolves a `WikiSession` for
  it.
- **M2: `SessionManager` — an `@Observable` class in `WikiFSEngine` that owns
  the live `WikiSession` cache.** Replaces `@State session: WikiSession?` +
  `SessionRef` in `WikiFSApp`. Holds a `[wikiID: WikiSession]` dictionary.
  Creating a session for a wiki ID that already has one returns the existing
  session (so opening the same wiki twice doesn't double-open the DB). Windows
  weak-reference their session; the manager strong-references them so they
  survive while any window is open.
- **M3: `WikiChangeBridge` routes to all matching sessions.** The bridge's
  `weak var session: WikiSession?` becomes a lookup closure injected from the
  app: `sessionLookup: (String) -> [WikiSession]`. The bridge's `flush(wikiID:)`
  pokes the bus of every session whose `wikiID` matches — so a `wikictl` write
  to wiki A updates all windows showing wiki A.
- **M4: `FileProviderSpike.subscribeActiveStoreBus` → multi-subscribe.**
  Currently subscribes to ONE bus at a time (drops the previous). In
  multi-window, each active session's bus needs its own subscription. Change
  to a `[wikiID: token]` dictionary so each session's bus is independently
  subscribed. Unsubscribe on session teardown.
- **M5: per-window `scenePhase` via a `RootScene` helper view.** SwiftUI
  `scenePhase` attached to a `WindowGroup(for:)` scene is per-window. The
  `.onChange(of: scenePhase)` + the vacuum alerts move into a `RootScene`
  view (instantiated inside the `WindowGroup(for: String.self)` closure) so
  each window gets its own scenePhase, flush-on-background, and search-index
  backfill. **`VacuumCommands` stays at the scene level** — `.commands` is a
  `Scene` modifier (not a `View` modifier), so it can't go on `RootScene`.
  Instead, `VacuumCommands` resolves the frontmost window's session via
  `SessionManager.frontmostWikiID` (updated by per-window scenePhase
  transitions).
- **M6: `WikiSwitcher` — `openWindow(value:)` by default, Option+click =
  in-window switch.** The toolbar switcher's wiki list items call
  `openWindow(value: wiki.id)` (opens a new window or focuses an existing one
  — `WindowGroup(for:)` deduplicates by `==`). Option+click on a wiki item
  calls `registry.select(wiki.id)` instead (replaces the current window's
  wiki, keeping one window). `registry.select` sets `activeWikiID` for MRU
  tracking — and `RootScene` observes `registry.activeWikiID` alongside its
  own `wikiID` to detect an in-window switch request: when `activeWikiID`
  changes AND matches no other window's wikiID, the current window swaps its
  session. This is the Safari/Xcode pattern.
- **M7: `registry.activeWikiID` is deprecated as the session driver.** In
  multi-window there's no single "active wiki" — each window has its own.
  `activeWikiID` stays for MRU tracking (which wiki to open on launch) AND
  for in-window switching (Option+click sets it; `RootScene` observes it to
  swap its session — see M6). But the old `.onChange(of: activeWikiID)`
  session-creation handler is removed. The launch path: the main window's
  `RootScene` takes an **optional** `wikiID: String?` (nil before
  `activateMostRecent()` runs in `.task`); `resolveSession()` is a no-op
  until `wikiID` becomes non-nil. After `activateMostRecent()` sets
  `activeWikiID`, the main `RootScene` observes the change and sets its
  own `wikiID` to match, then resolves the session.
- **M8: Backward-compatible single-window behavior.** Launching with no
  wiki ID (the first launch) opens the MRU wiki (or seeds one). The user can
  still use the app single-window — multi-window is additive (open new wiki
  windows from the switcher), not mandatory.

---

## Goal

Make it possible to open multiple wiki windows simultaneously, each holding
its own `WikiSession` with independent store, launchers, gate, and event bus.
A user can be running an ingest in wiki A while browsing/querying wiki B in a
second window — full isolation, no blocking, no state leakage.

---

## Implementation Summary

### Before (Phase 2a)

```
WikiFSApp
  └─ @State registry: WikiRegistryClient  ← app-scoped: registry + activeWikiID
  └─ @State session: WikiSession?         ← ONE session, swapped on select()
  └─ @State sessionRef: SessionRef         ← closure bridge to the one session
  └─ changeBridge: WikiChangeBridge (weak var session)
  └─ fileProvider: FileProviderSpike (subscribeActiveStoreBus: ONE bus)

WindowGroup {                      ← single-identity, app-scoped
    RootView(session: session, ...)    ← ONE session
}
.onChange(of: registry.activeWikiID)   ← creates/destroys the ONE session
```

### After (Phase 2b)

```
WikiFSApp
  └─ @State registry: WikiRegistryClient  ← app-scoped: registry + MRU
  └─ @State sessionManager: SessionManager ← owns [wikiID: WikiSession] cache
  └─ @State fileProvider: FileProviderSpike (multi-subscribe)
  └─ @State settingsLauncher: AgentLauncher (app-scoped, Settings only)
  └─ @State extractionCoordinator: ExtractionCoordinator (shared)
  └─ changeBridge: WikiChangeBridge (sessionLookup closure)

WindowGroup(for: String.self) { $wikiID in   ← per-wiki-ID windows
    RootScene(wikiID: wikiID, sessionManager:, registry:, ...)
        .onChange(of: scenePhase) { ... }    ← per-window scenePhase
}
.onChange(of: registry.wikis) { changeBridge?.refreshObservations() }
```

### The new `SessionManager` type

**`SessionManager`** (`Sources/WikiFSEngine/SessionManager.swift`) — own file
in Engine since it manages `WikiSession` instances (an Engine type):

```swift
@MainActor @Observable
public final class SessionManager {
    /// Live sessions keyed by wiki ID. A wiki open in multiple windows
    /// shares ONE session (one store, one bus, one gate).
    public private(set) var sessions: [String: WikiSession] = [:]

    /// The wiki ID of the frontmost window. Updated by per-window scenePhase
    /// transitions. Used by `VacuumCommands` (at the scene level) to resolve
    /// the correct session for the menu-bar "Vacuum/Lint/Activity Log" actions.
    public var frontmostWikiID: String?

    /// The shared extraction coordinator (created once at app scope).
    public let extractionCoordinator: ExtractionCoordinator
    public let containerDirectory: URL
    public let pdf2mdScriptPathResolver: () -> String?

    public init(
        containerDirectory: URL,
        extractionCoordinator: ExtractionCoordinator,
        pdf2mdScriptPathResolver: @escaping () -> String?
    ) { ... }

    /// Get or create a session for `wikiID`. If a session already exists for
    /// this wiki (open in another window), returns the existing instance —
    /// so two windows over the same wiki share one store + bus + gate.
    public func session(for wikiID: String, descriptor: WikiDescriptor) -> WikiSession

    /// Remove a session from the cache (called when the last window for a
    /// wiki closes). Flushes pending saves before removal.
    public func releaseSession(for wikiID: String)

    /// Flush pending saves for ONE session (used by the registry's
    /// `flushActiveStore` closure before export/delete of a specific wiki).
    public func flushSession(for wikiID: String)

    /// Flush pending saves for ALL active sessions (app background / quit).
    public func flushAllSessions()

    /// All active wiki IDs (for bridge routing + FP multi-subscribe).
    public var activeWikiIDs: Set<String> { Set(sessions.keys) }

    /// All live sessions (for bridge flush routing).
    public var allSessions: [WikiSession] { Array(sessions.values) }
}
```

### Key design point: sharing sessions across windows

Two windows open on the same wiki share ONE `WikiSession` — one store, one
bus, one gate. This is correct: they're the same wiki's DB, so they must see
each other's edits immediately (via the shared `WikiEventBus`). A second
window over the same wiki is a second *view* onto the same model, not a second
*store*. `WindowGroup(for:)` deduplicates by `==` on the value, so it won't
open two windows for the same wiki ID anyway — but `SessionManager` handles
the case where the user opens wiki A, then closes that window, then opens
wiki A again (the session was released on close, a fresh one is created).

---

## Implementation Plan

### What happens to each responsibility

| Current (Phase 2a) | After (Phase 2b) | Notes |
|---|---|---|
| `@State session: WikiSession?` | `SessionManager.sessions[wikiID]` | Per-window, not app-scoped |
| `@State sessionRef: SessionRef` | Gone — `SessionManager` is a class | The manager IS the reference holder |
| `.onChange(of: registry.activeWikiID)` session creation | Created in `RootScene.task` via `sessionManager.session(for:)` | Per-window |
| `registry.activeWikiID` drives session select | Stays for MRU launch — but NOT session creation | `activeWikiID` = "which wiki to open on launch," not "which session is active" |
| `scenePhase` handler on `WikiFSApp.body` | Per-window on `RootScene` | Each window flushes its own session on background |
| `changeBridge.session` (weak, single) | `changeBridge.sessionLookup` (closure → `[WikiSession]`) | Routes to all matching sessions |
| `fileProvider.subscribeActiveStoreBus` (one bus) | `fileProvider.subscribeBus(for wikiID:, bus:)` (multi) | One subscription per active session |
| `WikiSwitcher` → `registry.select(id)` | `openWindow(value: id)` + Option+click → `registry.select(id)` | Multi-window by default |
| `VacuumCommands(session:)` app-scope | `VacuumCommands` inside `RootScene` — per-window session | Each window vacuums its own wiki |
| Vacuum `.alert` on app body | `.alert` on `RootScene` | Per-window |
| `settingsLauncher` (app-scoped) | Unchanged | Still app-scoped for Settings |
| ExtractionCompareWindow | Takes `SessionManager` instead of `session` | Resolves session from `sessionManager.session(for:)` |

### View tree rewire

| View | Current | After |
|---|---|---|
| `WikiFSApp.body` | `WindowGroup { RootView(session:, ...) }` + `.onChange(of: scenePhase)` + `.onChange(of: activeWikiID)` + `.commands { VacuumCommands }` + vacuum `.alert` | `WindowGroup(for: String.self) { $wikiID in RootScene(wikiID:, ...) }` — no per-scene session creation, no app-scope scenePhase |
| `RootView` | Takes `session: WikiSession?` | Takes `session: WikiSession` (non-optional inside `RootScene`), `registry`, `fileProvider` |
| `RootScene` (new) | Doesn't exist | A `View` inside `WindowGroup(for: String.self)` that creates/resolves the session, owns per-window scenePhase, owns vacuum alerts |
| `WikiSwitcher` | `registry.select(wiki.id)` | `openWindow(value: wiki.id)` + Option+click → `registry.select(wiki.id)` |
| `WikiChangeBridge` | `weak var session: WikiSession?` | `var sessionLookup: @MainActor (String) -> [WikiSession]` |
| `FileProviderSpike` | `subscribeActiveStoreBus(_ bus:, wikiID:)` (one at a time) | `subscribeBus(for wikiID:, _ bus:)` (multi — `[wikiID: token]`) |

### The files that change

#### New files (2)

| File | Module | Purpose |
|---|---|---|
| `Sources/WikiFSEngine/SessionManager.swift` | WikiFSEngine | `SessionManager` — the `[wikiID: WikiSession]` cache + `session(for:)` / `releaseSession(for:)` / `flushAllSessions()`. |
| `Sources/WikiFS/RootScene.swift` | WikiFS | Per-window scene view: receives `wikiID`, resolves/creates the session, owns `.onChange(of: scenePhase)`, vacuum alerts, `.task` lifecycle, session release on disappear. |

#### Modified files (8)

| File | What changes |
|---|---|
| `WikiFSApp.swift` | `WindowGroup { }` → `WindowGroup(for: String.self) { $wikiID in RootScene(...) }`. `@State session` + `SessionRef` → `@State sessionManager: SessionManager`. `.onChange(of: scenePhase)` + `.onChange(of: registry.activeWikiID)` + `.commands { VacuumCommands }` + vacuum `.alert` → move into `RootScene`. `.task` stays on app body for bootstrap/wire/bridge creation. Launch: open MRU wiki ID as the initial window. **Note: `body` + `.task` are effectively redesigned (>60% of substantive lines change) — the implementation agent should rewrite them wholesale, not surgically edit. `init()` and helper types (`LaunchLocationWarning`, `FileProviderSpike.wire`) stay as-is.** |
| `RootView.swift` | `session: WikiSession?` → `session: WikiSession` (non-optional — `RootScene` guarantees it exists). Remove the `if let session` guard. |
| `WikiSwitcher.swift` | Wiki list items → `openWindow(value: wiki.id)` (multi-window). Option+click → `registry.select(wiki.id)` (in-window switch). Add `@Environment(\.openWindow)`. |
| `WikiChangeBridge.swift` | `weak var session: WikiSession?` → `var sessionLookup: @MainActor (String) -> [WikiSession]`. `flush(wikiID:)` pokes `sessionLookup(wikiID)` — all matching sessions' buses. |
| `ExtractionCompareSheet.swift` | `ExtractionCompareWindow(session: WikiSession?)` → `ExtractionCompareWindow(sessionManager: SessionManager, wikiID: String?)`. Resolves `sessionManager.session(for: wikiID)` for the store. **Also add `wikiID: String` to `ExtractionCompareContext`** (it has only `sourceID` + `filename` — without a wikiID the compare window can't resolve the correct session in multi-window). Update `==` / `hash(into:)` to include both `sourceID` + `wikiID`. Update every `openWindow(value: ExtractionCompareContext(...))` call site to pass the wikiID. |
| `FileProviderSpike.swift` | `subscribeActiveStoreBus` → `subscribeBus(for wikiID:, bus:)` with a `[wikiID: token]` dictionary. Add `unsubscribeBus(for wikiID:)`. |
| `VacuumCommands.swift` | Move from app-scope `Commands` to inside `RootScene` — each window's menu vacuums its own session. |
| `WikiFSApp.swift` `FileProviderSpike.wire(into:)` | `registry.flushActiveStore` → `sessionManager.flushSession(for:)`. The `flushActiveStore` closure signature changes from `(() -> Void)?` to `((String) -> Void)?` so the registry can pass the wiki ID being exported/deleted. No more `SessionRef`. |

#### Test files (2)

| File | What changes |
|---|---|
| `Tests/WikiFSTests/WikiSessionTests.swift` | Add `testSessionManagerReturnsSameSessionForSameWikiID`, `testReleaseSessionFlushesAndRemoves`, `testFlushAllSessions`. |
| `Tests/WikiFSTests/WikiChangeBridgeTests.swift` | Update `flush(wikiID:)` tests to use `sessionLookup` closure instead of `weak var session`. Add `testFlushPokesAllMatchingSessions`. |

### RootScene — the per-window entry point

```swift
// Sources/WikiFS/RootScene.swift

struct RootScene: View {
    /// The wiki ID for this window. Nil before the MRU wiki is resolved at
    /// launch (the main window's `.task` sets this from `registry.activeWikiID`
    /// after `activateMostRecent()`). Additional windows receive their wiki ID
    /// from `WindowGroup(for: String.self)`'s binding.
    @State var wikiID: String?
    @Bindable var registry: WikiRegistryClient
    @Bindable var sessionManager: SessionManager
    let fileProvider: FileProviderSpike

    @State private var session: WikiSession?
    @State private var isSceneActive = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let session {
                RootView(session: session, registry: registry, fileProvider: fileProvider)
                    // Vacuum alert — per-window, per-session.
                    .alert(
                        "Vacuum Orphaned Storage",
                        isPresented: Binding(
                            get: { session.pendingVacuumAll != nil },
                            set: { if !$0 { session.pendingVacuumAll = nil } }
                        ),
                        presenting: session.pendingVacuumAll
                    ) { report in
                        if report.isEmpty {
                            Button("OK", role: .cancel) {}
                        } else {
                            Button("Cancel", role: .cancel) {}
                            Button("Vacuum", role: .destructive) { session.applyVacuumAll() }
                        }
                    } message: { report in
                        Text(report.alertMessage)
                    }
            } else if let wikiID {
                // The wiki ID is known but the session isn't resolved yet.
                ProgressView("Opening \(wikiID)…")
                    .onAppear { resolveSession(for: wikiID) }
            } else {
                // No wiki ID yet (launch, before activateMostRecent) or no
                // wikis exist at all. Show the empty-state CTA so the user
                // can create their first wiki.
                ContentUnavailableView {
                    Label("No Wikis", systemImage: "books.vertical")
                } description: {
                    Text("Create a wiki to get started.")
                } actions: {
                    Button("New Wiki", systemImage: "plus") {
                        Task { await registry.createWiki(displayName: "My Wiki") }
                    }
                }
            }
        }
        .task {
            // Launch path: if wikiID is nil (main window on first launch),
            // activate the MRU wiki. Additional windows receive their wikiID
            // from the WindowGroup binding and skip this.
            if wikiID == nil {
                registry.activateMostRecent()
            }
        }
        // Observe activeWikiID for two purposes:
        // 1. Launch: activateMostRecent() sets activeWikiID → set our wikiID.
        // 2. Option+click in-window switch: WikiSwitcher calls
        //    registry.select(id), setting activeWikiID. If the new ID differs
        //    from our current wikiID AND no other window has it open, swap
        //    our session in-place.
        .onChange(of: registry.activeWikiID) { _, newID in
            guard wikiID != newID else { return }
            // If this is the main window (wikiID was nil), adopt the new ID.
            // If this is an additional window, only swap if the new ID isn't
            // already shown by another window (prevents two windows fighting
            // over the same wiki).
            if wikiID == nil || sessionManager.activeWikiIDs.subtracting([wikiID ?? ""]).contains(newID ?? "") {
                wikiID = newID
            } else if let newID {
                // In-window switch: release old session, adopt new ID.
                if let oldID = wikiID {
                    sessionManager.releaseSession(for: oldID)
                    fileProvider.unsubscribeBus(for: oldID)
                }
                wikiID = newID
                session = nil
                resolveSession(for: newID)
            }
        }
        .onDisappear {
            // Release the session when the window closes. If another window
            // has the same wiki open, the session is still in the cache (the
            // other window's RootScene will re-resolve it).
            if let wikiID {
                sessionManager.releaseSession(for: wikiID)
                fileProvider.unsubscribeBus(for: wikiID)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { session?.store.flushPendingSaves() }
            isSceneActive = (phase == .active)
            // Track frontmost window for VacuumCommands.
            if phase == .active, let wikiID {
                sessionManager.frontmostWikiID = wikiID
            }
            if phase == .active { Task { await session?.upgradeSearchIndex() } }
        }
    }

    private func resolveSession(for wikiID: String) {
        guard session == nil else { return }
        guard let descriptor = registry.wikis.first(where: { $0.id == wikiID }) else { return }
        let s = sessionManager.session(for: wikiID, descriptor: descriptor)
        session = s
        // Wire the File Provider bus subscription for this wiki's session.
        fileProvider.subscribeBus(for: wikiID, bus: s.store.eventBus)
        Task { await fileProvider.activate(id: descriptor.id, displayName: descriptor.displayName) }
        // Reap stale workspaces for this wiki.
        _ = try? s.store.reapStaleWorkspaces(ttl: 86_400)
    }
}
```

### Launch sequencing

The initial window's wiki ID is the MRU wiki (`registry.activeWikiID` after
`activateMostRecent()`). On first launch, `bootstrap(activateNow: false)`
populates `wikis` but not `activeWikiID`; `activateMostRecent()` in `.task`
sets it. The `WindowGroup(for: String.self)` needs an initial value — but
SwiftUI doesn't provide a "default window" API for value-driven `WindowGroup`.
The approach: keep a `WindowGroup` (single-identity, no `for:`) as the **main
window** that opens on launch and resolves the MRU wiki; use
`WindowGroup(for: String.self)` for **additional windows** opened from the
switcher. This is how Safari/Mail work — one main window, additional windows
opened on demand.

**Alternative:** Use `WindowGroup(for: String.self)` for everything and
open the main window programmatically with `openWindow(value: mruWikiID)` in
`.task`. Risk: SwiftUI's `WindowGroup(for:)` may show an empty window on
launch before `.task` runs. The single-identity main `WindowGroup` is safer.

**Chosen: two WindowGroups.** The main window (single-identity) hosts the MRU
wiki opening flow. `WindowGroup(for: String.self)` hosts additional wiki
windows opened from the switcher. Both use `RootScene` as their content.

### WikiSwitcher rewire

```swift
struct WikiSwitcher: View {
    @Bindable var registry: WikiRegistryClient
    @Environment(\.openWindow) private var openWindow
    ...
    
    var body: some View {
        Menu {
            ForEach(registry.wikis) { wiki in
                Button {
                    if NSEvent.modifierFlags.contains(.option) {
                        // Option+click: switch THIS window's wiki (close session,
                        // open new one in-place). Uses registry.select so the
                        // main window's .onChange re-resolves.
                        registry.select(wiki.id)
                    } else {
                        // Default: open a new window (or focus existing).
                        openWindow(value: wiki.id)
                    }
                } label: {
                    Label(wiki.displayName, systemImage: checkmark(for: wiki))
                }
            }
            ...
        }
    }
}
```

**Note:** `NSEvent.modifierFlags` is checked at action-call time, not at
click time — there's a small async gap. In practice this is reliable for
macOS menu button actions, but a more robust approach (tracking modifier
state via `NSEvent.addLocalMonitorForEvents`) could be a future refinement.
The Option+click pattern should be validated in the manual smoke test (AC6).

### WikiChangeBridge rewire

```swift
@MainActor
final class WikiChangeBridge {
    private let registry: WikiRegistryClient
    private let fileProvider: FileProviderSpike
    /// Returns all live sessions whose `wikiID` matches — injected from the
    /// app via `SessionManager`. Replaces `weak var session: WikiSession?`.
    var sessionLookup: @MainActor (String) -> [WikiSession] = { _ in [] }
    ...

    func flush(wikiID: String) {
        Task { await fileProvider.signalChange(forWikiID: wikiID) }
        // Poke ALL sessions whose wikiID matches — a wikictl write to wiki A
        // must update every window showing wiki A.
        for session in sessionLookup(wikiID) {
            session.store.eventBus?.emit(ResourceChangeEvent(
                wikiID: wikiID, kind: nil, id: "", change: .updated))
        }
    }
}
```

### FileProviderSpike multi-subscribe

```swift
// FileProviderSpike — new multi-subscribe state.
// Stores BOTH the bus ref and the token so unsubscribeBus can call
// `bus.unsubscribe(token)` (the bus instance owns its subscriber list).
private var activeBusSubscriptions: [String: (bus: WikiEventBus, token: WikiEventBus.SubscriptionToken)] = [:]

func subscribeBus(for wikiID: String, bus: WikiEventBus?) {
    ensureSignalCoalescer()
    // Drop any existing subscription for this wiki.
    unsubscribeBus(for: wikiID)
    guard let bus else { return }
    let token = bus.subscribe(nil) { [weak self] _ in
        self?.signalCoalescer?.noteChange(forWikiID: wikiID)
    }
    activeBusSubscriptions[wikiID] = (bus: bus, token: token)
}

func unsubscribeBus(for wikiID: String) {
    if let entry = activeBusSubscriptions.removeValue(forKey: wikiID) {
        entry.bus.unsubscribe(entry.token)
    }
}
```

**Note:** The `WikiEventBus` unsubscribe API needs checking — `subscribeActiveStoreBus`
currently keeps `activeStoreBus` + `activeStoreChangeToken` and calls
`oldBus.unsubscribe(token)`. In multi-window, each wiki's bus lives as long as
its session. The `FileProviderSpike` needs to hold `[wikiID: (bus, token)]` so it
can unsubscribe on session release.

---

## What does NOT change

- **The daemon (`wikid`)** — stays `wikictl`-only.
- **The File Provider extension** — reads SQLite directly, unchanged.
- **Store writes from `wikictl`** — opens its own `SQLiteWikiStore`, unchanged.
- **Darwin notification routing** — same mechanism, same posting.
- **The SQLite concurrency invariants** — method-atomic store, `WikiReadPool`,
  `mutate()` write-seam, `StoreEmissionExhaustivenessTests`. Each session =
  distinct DB file + distinct `WikiEventBus` + distinct read pool. Two windows
  over the SAME wiki share a session (one store, one bus).
- **Agent config** — provider, API keys, permission mode stay app-wide.
- **The `ExtractionCoordinator`** — shared, app-wide, passed into each session.
- **The `settingsLauncher`** — app-scoped, Settings only.
- **`WikiSession` itself** — unchanged. It's already a per-wiki type; the
  manager just caches and multiplexes them.
- **`WikiRegistryClient`** — unchanged. `activeWikiID` stays for MRU launch.

### Future direction: daemon-managed ingest queue (NOT in Phase 2b)

Currently, each `WikiSession` owns its own `GenerationGate` with lane limits
`[.ingest: 1, .interactive: 3]`. This gives **structural isolation** (a gate
on session A doesn't block session B) — which is correct for Phase 2b.
However, it means N windows could each kick off an ingest simultaneously,
overwhelming the system.

The longer-term plan: **ingestion and extraction should move to a background
queue owned by the daemon** (`wikid`), so the daemon serializes cross-wiki
ingest and manages resource contention globally. This is Phase 2b+ or Phase 3
work — it requires the daemon to own the `AgentLauncher` lifecycle (or at
least an ingest/task queue), which in turn requires the full `WikiStore`
protocol over XPC (or a write-proxy pattern). Phase 2b deliberately keeps
per-session gates in-process — the daemon-managed queue is explicitly out of
scope but the `SessionManager` + `WikiSession` split is designed to make the
handoff natural: when the daemon owns ingest, `WikiSession.agentLauncher`
becomes a thin proxy to the daemon's queue rather than a local `Process`-spawner.

---

## Acceptance Criteria

| AC | Description | Verification |
|----|-------------|-------------|
| AC1 | `SessionManager.swift` exists in `WikiFSEngine`. `RootScene.swift` exists in `WikiFS`. | `ls Sources/WikiFSEngine/SessionManager.swift Sources/WikiFS/RootScene.swift` |
| AC2 | `WikiFSApp.body` uses `WindowGroup(for: String.self)` for additional wiki windows, plus a single-identity main window for launch. | Verified by AC12 (`swift build`) — the type system enforces the structural change |
| AC3 | `@State session: WikiSession?` + `@State sessionRef: SessionRef` are gone from `WikiFSApp`. Replaced by `@State sessionManager: SessionManager`. | Verified by AC12 (`swift build`) — stale references are compile errors |
| AC4 | `WikiChangeBridge` uses `sessionLookup` closure, not `weak var session`. | Verified by AC12 (`swift build`) — a removed property is a compile error at use sites |
| AC5 | `FileProviderSpike.subscribeActiveStoreBus` is replaced by multi-subscribe `subscribeBus(for:bus:)`. | Verified by AC12 (`swift build`) — stale call sites are compile errors |
| AC6 | Opening a wiki from the switcher opens a new window (`openWindow(value:)`). Option+click switches the current window's wiki. | Manual smoke test |
| AC7 | Two windows over different wikis each have independent sessions (distinct gates, distinct launchers). A long ingest in window A does not block a query in window B. | `SessionManagerTests.testPerWindowGateIsolation` — two sessions over different wiki IDs have distinct `GenerationGate` instances |
| AC8 | Two windows over the SAME wiki share one session (same store, same bus). | `SessionManagerTests.testSameWikiIDReturnsSameSession` — calling `session(for:)` twice with the same ID returns the identical instance |
| AC9 | Closing a window releases the session (if no other window has it). Reopening creates a fresh one. | `SessionManagerTests.testReleaseSessionRemovesFromCache` |
| AC10 | `WikiChangeBridge.flush(wikiID:)` pokes all sessions whose `wikiID` matches. | `WikiChangeBridgeTests.testFlushPokesAllMatchingSessions` |
| AC11a | `SessionManager.flushAllSessions()` flushes all active sessions. | `SessionManagerTests.testFlushAllSessions` |
| AC11b | Each window flushes its own session's pending saves on background (per-window scenePhase). | Manual smoke test (SwiftUI scenePhase is runtime-only) |
| AC12 | `swift build` clean + fast-tier tests pass. | CI `swift` job green |

---

## Test Strategy

### AC → test mapping

| AC | Test | Layer |
|----|------|-------|
| AC1 | File existence check | Build |
| AC2 | Verified by AC12 (`swift build`) | Compile |
| AC3 | Verified by AC12 (`swift build`) | Compile |
| AC4 | Verified by AC12 (`swift build`) | Compile |
| AC5 | Verified by AC12 (`swift build`) | Compile |
| AC6 | Manual smoke test | Manual |
| AC7 | `SessionManagerTests.testPerWindowGateIsolation` | Unit |
| AC8 | `SessionManagerTests.testSameWikiIDReturnsSameSession` | Unit |
| AC9 | `SessionManagerTests.testReleaseSessionRemovesFromCache` | Unit |
| AC10 | `WikiChangeBridgeTests.testFlushPokesAllMatchingSessions` | Unit |
| AC11a | `SessionManagerTests.testFlushAllSessions` | Unit |
| AC11b | Manual smoke test | Manual |
| AC12 | Fast-tier CI green | CI |

### New / updated test files

**`Tests/WikiFSTests/SessionManagerTests.swift`** (new):
- `testSessionForCreatesSessionWithStore` — `session(for:descriptor:)` returns a session with a live store + event bus
- `testSameWikiIDReturnsSameSession` — two calls with the same wiki ID return the identical instance
- `testDifferentWikiIDsReturnDistinctSessions` — different wiki IDs get distinct sessions + distinct gates
- `testReleaseSessionRemovesFromCache` — after `releaseSession(for:)`, `sessions[id]` is nil
- `testReleaseSessionFlushesPendingSaves` — release calls `flushPendingSaves`
- `testFlushAllSessionsFlushesAllActive` — two sessions, `flushAllSessions()` flushes both
- `testPerWindowGateIsolation` — two sessions have distinct `GenerationGate` instances (AC7)

**`Tests/WikiFSTests/WikiChangeBridgeTests.swift`** (updated):
- Update `testFlushPokesSessionBusForActiveWiki` to use `sessionLookup` closure
- Add `testFlushPokesAllMatchingSessions` — two sessions with the same wiki ID, `flush(wikiID:)` pokes both
- Add `testFlushDoesNotPokeNonMatchingSessions` — a session with a different wiki ID is not poked

### Test infrastructure gaps

- **AC6 (multi-window open/focus behavior)** cannot be unit-tested — it
  requires SwiftUI's `WindowGroup(for:)` runtime. Manual smoke test only.
- **AC11b (per-window scenePhase flush)** — SwiftUI scenePhase is runtime-only.
  The `SessionManager.flushAllSessions()` call (app background when ALL
  windows close) is unit-testable (AC11a); the per-window flush is manual.

---

## Review Strategy

### Plan-mode review (before handoff)
- Run `plan-reviewer` subagent on the plan.
- Fix or rebut all findings with `edit_plan`, then re-run if any critical/high
  findings remain.

### Implementation review (after implementation + tests)
- Dispatch a `general-purpose` subagent to review the completed work against:
  - The acceptance criteria (AC1–AC12).
  - The SQLite concurrency invariants.
  - The SwiftUI best-practices rules (`SWIFTUI-RULES.md`, swiftui-pro skill).
  - Per-window scenePhase correctness (does flushing on background work
    per-window, not just app-scope?).
- All implementation review findings must be fixed or explicitly rebutted.

---

## Documentation Strategy

- **`PLAN.md`** — add `plans/multi-window-ui.md` to the documentation index.
- **`PROGRESS.md`** — add an entry documenting the multi-window implementation.
- **`plans/multi-wiki-daemon.md` §7** — update Phase 2b items to ✅ shipped.
- **`README.md`** — if needed, update the multi-wiki section to mention
  multi-window support.
- **`CLAUDE.md`** — update the app-layer description to note per-window
  sessions.

---

## Risks, Blockers, and Required Decisions

### R1: Two WindowGroups vs one (medium)
The plan uses a single-identity main `WindowGroup` (for launch) + a value-driven
`WindowGroup(for: String.self)` (for additional windows). If SwiftUI doesn't
support having both, the fallback is `WindowGroup(for: String.self)` for
everything with a programmatic `openWindow(value: mruWikiID)` in `.task`. Risk:
an empty window may flash on launch before the session resolves. The two-
WindowGroup approach avoids this. **Mitigation:** verify the two-WindowGroup
approach builds and launches correctly before proceeding with the rest.

### R2: WikiEventBus unsubscribe API (low)
`FileProviderSpike.subscribeActiveStoreBus` currently unsubscribes by keeping
a ref to the old bus + token. In multi-subscribe, we need `[wikiID: (bus, token)]`.
Need to verify `WikiEventBus` stores the token so `unsubscribe` works without
holding the bus ref (or we hold the bus ref in the dict). **Mitigation:**
read `WikiEventBus.swift` before implementing Step 4.

### R3: Session lifecycle on window close (medium)
SwiftUI's `onDisappear` is not reliably called when a window is closed
(at least via the close button). The session could leak if `onDisappear`
doesn't fire. **SwiftUI provides no window-dismissal callback on macOS 15**
— there is no public `WindowGroup.onDismiss` or equivalent. The fallback path
is the `SessionManager` cache: unreleased sessions linger there, flushed by
`flushAllSessions` on background. They are functionally correct (no
corruption, no double-open) but consume memory until the app exits.
**Mitigation:** `releaseSession` in `onDisappear` is the best-effort primary
path; if it doesn't fire, the session lingers harmlessly. A future cleanup
pass could add `NSWindow` delegate-based dismissal detection.

### R4: `ActiveWikiID` semantics shift (low)
`registry.activeWikiID` was "the active wiki" (drives session creation). In
multi-window there's no single active wiki. The plan keeps it for MRU launch
only. `WikiSwitcher`'s checkmark logic (`wiki.id == registry.activeWikiID`)
should change to show which wikis have open windows (`sessionManager.activeWikiIDs`).
**Mitigation:** document in the implementation; the checkmark is cosmetic.

### R5: VacuumCommands per-window (low)
`VacuumCommands` is currently app-scope `.commands`. Moving it into
`RootScene`'s `.commands` means each window's menu vacuums its own session.
This is correct but means closing all windows removes the menu items.
**Mitigation:** the main window always has a session (MRU wiki), so the
menu is always available when the app is running.

---

## Build steps

### Step 1: Create `SessionManager` (in WikiFSEngine)
- New file `Sources/WikiFSEngine/SessionManager.swift`
- `@MainActor @Observable` class holding `[wikiID: WikiSession]`
- `session(for:descriptor:)` — create-or-get
- `releaseSession(for:)` — flush + remove
- `flushAllSessions()` — flush all active
- `activeWikiIDs` / `allSessions` — for bridge + FP routing
- Gate: `swift build`

### Step 2: Create `RootScene` (in WikiFS)
- New file `Sources/WikiFS/RootScene.swift`
- Receives `wikiID: String`, `registry`, `sessionManager`, `fileProvider`
- Resolves session via `sessionManager.session(for:descriptor:)`
- Owns per-window `.onChange(of: scenePhase)` + vacuum `.alert` + `.commands`
- `.onDisappear` releases session + unsubscribes FP bus
- Gate: `swift build`

### Step 3: Rewire `WikiFSApp`
- `@State session` + `SessionRef` → `@State sessionManager: SessionManager`
- Main `WindowGroup { }` → `WindowGroup { RootScene(wikiID: mruID, ...) }`
- Add `WindowGroup(for: String.self) { $wikiID in RootScene(wikiID: wikiID, ...) }`
- `.task` — bootstrap, wire, bridge creation, set `bridge.sessionLookup`
- Remove `.onChange(of: registry.activeWikiID)` session creation
- Remove `.onChange(of: scenePhase)` + vacuum `.alert` + `.commands` (moved
  to `RootScene`)
- `registry.flushActiveStore` → `sessionManager.flushAllSessions()`
- Gate: `swift build` + fix compile errors

### Step 4: Rewire `WikiChangeBridge`
- `weak var session` → `var sessionLookup: @MainActor (String) -> [WikiSession]`
- `flush(wikiID:)` → iterate `sessionLookup(wikiID)` + poke each session's bus
- Update tests to use the closure
- Gate: `swift build`

### Step 5: Rewire `FileProviderSpike`
- `subscribeActiveStoreBus` → `subscribeBus(for wikiID:, bus:)` (multi-dict)
- Add `unsubscribeBus(for wikiID:)`
- Gate: `swift build`

### Step 6: Rewire `WikiSwitcher`
- Wiki list items → `openWindow(value: wiki.id)` (default) / `registry.select(wiki.id)` (Option+click)
- Add `@Environment(\.openWindow)`
- Checkmark → `sessionManager.activeWikiIDs.contains(wiki.id)` (if accessible)
- Gate: `swift build`

### Step 7: Rewire `ExtractionCompareWindow`
- Takes `sessionManager: SessionManager` + `wikiID: String?` instead of `session: WikiSession?`
- Resolves `sessionManager.session(for: wikiID)` for the store
- Gate: `swift build`

### Step 8: Rewrite tests
- New `SessionManagerTests.swift`
- Update `WikiChangeBridgeTests.swift` for `sessionLookup` closure
- Update `WikiSessionTests.swift` if needed
- Gate: `swift build` + `swift test` (fast tier)

### Step 9: Verify
- Build clean
- Fast-tier tests green
- Manual smoke test: open wiki A, open wiki B in new window, ingest in A,
  query in B, verify no blocking. Close a window, verify session released.
  Option+click switch in a window.
