# Dissolve `WikiManager` — per-session wiki state

**Status:** plan of record. Step 1 of #358 Phase 2 (multi-window UI).
Supersedes the "WikiManager dissolves" preview in `multi-wiki-daemon.md` §7.

**Decisions (confirmed with operator):**
- **D1: In-process file-based registry.** `WikiRegistryClient` reads/writes
  `wikis.json` directly (same as `WikiManager` today). The `wikid` daemon stays
  `wikictl`-only. The XPC client (`WikiDaemonConnection`) is already written and
  ready to swap in later — this step keeps the blast radius on the type split.
- **D2: Type split only.** Replace `WikiManager` with `WikiRegistryClient`
  (App-scoped) + `WikiSession` (one per active wiki). Keep the single
  `WindowGroup` (no `for:` parameter). Same UX — wiki switching creates/destroys
  a session, just like today's `openActive` creates/destroys a store. Multi-window
  (`WindowGroup(for: String.self)`) is a follow-up on top of this split.
- **D3: Per-session launchers + gate.** Each `WikiSession` creates its own pair
  of `AgentLauncher`s and its own `GenerationGate`. Full isolation: a long ingest
  in one wiki cannot block a query in another (they're different DB files + different gates).
  CAS + workspace machinery (W0–W4) already handles concurrent writes safely.

---

## Goal

`WikiManager` is a `@MainActor @Observable` singleton at the App level that bundles
three responsibilities: (1) the wiki registry, (2) the single "active" store +
`activeWikiID`, and (3) side-effect routing (FP domains, search upgrade, change
bridge, vacuum). It is passed as `@Bindable var manager: WikiManager` to **16
source files** — every view in the tree reads `manager.activeWikiID` (27 sites),
`manager.wikis` (11 sites), or `manager.activeStore` (9 sites). This couples every
view to a single "active wiki" concept, making per-wiki isolation impossible.

This plan splits `WikiManager` into two focused types and rewires the view tree so
views receive a per-wiki `WikiSession` instead of a global manager.

---

## Architecture

### Before

```
WikiFSApp
  └─ @State manager: WikiManager    ← singleton: registry + active store + side effects
       └─ @State agentLauncher: AgentLauncher (shared)
       └─ @State chatLauncher: AgentLauncher (shared)
       └─ @State extractionCoordinator: ExtractionCoordinator (shared)
       └─ changeBridge: WikiChangeBridge
       └─ fileProvider: FileProviderSpike

RootView(manager:)
  └─ ContentView(store: manager.activeStore, manager:)
       └─ SidebarView(store:, manager:, launcher:, ...)
       └─ WikiDetailView(store:, manager:, launcher:, ...)
       etc.
```

### After

```
WikiFSApp
  └─ @State registry: WikiRegistryClient  ← App-scoped: registry + FP domains + activeWikiID
       └─ @State fileProvider: FileProviderSpike
       └─ changeBridge: WikiChangeBridge (rewired to registry)
  └─ @State session: WikiSession?         ← per-active-wiki, swapped on select()
       └─ session.store: WikiStoreModel
       └─ session.agentLauncher (per-session)
       └─ session.chatLauncher (per-session)
       └─ session.extractionCoordinator (per-session)
       └─ session.generationGate (per-session)

RootView(session:, registry:, fileProvider:)  ← session is non-nil when a wiki is open
  └─ ContentView(store: session.store, session:, registry:)
       └─ SidebarView(store:, registry:, session:, launcher:, ...)
       └─ WikiDetailView(store:, session:, launcher:, ...)
       etc.
```

### The two new types

**`WikiRegistryClient`** (`Sources/WikiFSCore/WikiRegistryClient.swift`)
— App-scoped, observable, replaces WikiManager's registry + side-effect roles:

```swift
@MainActor @Observable
public final class WikiRegistryClient {
    public private(set) var wikis: [WikiDescriptor] = []
    public private(set) var activeWikiID: String?

    // FP domain management (injected closures — same as WikiManager today)
    @ObservationIgnored public var registerDomain: ...
    @ObservationIgnored public var removeDomain: ...
    @ObservationIgnored public var renameDomain: ...

    // Registry operations
    public func bootstrap(activateNow:) { ... }      // load + v0 migration + seed
    public func activateMostRecent() { ... }
    public func select(_ id: String) { ... }          // touch MRU + set activeWikiID
    public func createWiki(displayName:) -> WikiDescriptor { ... }
    public func deleteWiki(id:) { ... }
    public func renameWiki(id:to:) { ... }
    public func setHomePage(id:pageID:) { ... }
    public func exportWiki(id:to:) { ... }
    public func importWiki(from:displayName:) -> WikiDescriptor { ... }
    public func registerAllDomains() { ... }

    // NO activeStore, NO setSearchIndex, NO vacuum — those move to WikiSession
}
```

**`WikiSession`** (`Sources/WikiFSCore/WikiSession.swift`)
— Window-scoped, one per active wiki. Holds everything the views need for ONE wiki:

```swift
@MainActor @Observable
public final class WikiSession {
    public let wikiID: String
    public private(set) var descriptor: WikiDescriptor
    public let store: WikiStoreModel
    public let agentLauncher: AgentLauncher
    public let chatLauncher: AgentLauncher
    public let extractionCoordinator: ExtractionCoordinator

    // Vacuum/GC state (was on WikiManager — operates on the active store)
    public var pendingBlobVacuum: BlobVacuumReport?
    public var pendingVacuumAll: VacuumReport?

    // Search index upgrade (was on WikiManager)
    public func upgradeSearchIndex() async { ... }
    public func previewBlobVacuum() { ... }
    public func applyBlobVacuum() { ... }
    public func previewVacuumAll() { ... }
    public func applyVacuumAll() { ... }

    init(wikiID: descriptor: containerDirectory: fileProvider:) { ... }
}
```

---

## What happens to each responsibility

| WikiManager responsibility | Where it goes | Notes |
|---|---|---|
| `wikis` list | `WikiRegistryClient.wikis` | WikiSwitcher reads this |
| `activeWikiID` | `WikiRegistryClient.activeWikiID` | Drives session creation/destruction in `WikiFSApp` |
| `activeStore` | `WikiSession.store` | Views read `session.store` |
| `onActiveStoreDidChange` | Gone — `.onChange(of: registry.activeWikiID)` in WikiFSApp creates the new session and wires its bus | The FP bus subscription moves into session creation |
| `select(id)` | `WikiRegistryClient.select(id)` (sets activeWikiID + MRU) | The `.onChange` in WikiFSApp creates a new `WikiSession` |
| `createWiki/deleteWiki/renameWiki` | `WikiRegistryClient` | Same logic, no store management |
| `exportWiki/importWiki` | `WikiRegistryClient` | Pure registry + file ops, no store |
| FP domain closures | `WikiRegistryClient` | App-scoped, one domain per wiki |
| `pendingBlobVacuum/pendingVacuumAll` | `WikiSession` | Operates on the session's store |
| `upgradeActiveStoreSearchIndex` | `WikiSession.upgradeSearchIndex()` | One-liner on `session.store` |
| V0 migration | `WikiRegistryClient.bootstrap()` | Same one-time logic |
| `registerAllDomains()` | `WikiRegistryClient.registerAllDomains()` | Same |

---

## View tree rewire — the 27 `activeWikiID` reads

| Current read | New read | Why |
|---|---|---|
| `manager.activeWikiID ?? ""` (9 sites: AgentOperationRunner calls) | `session.wikiID` | The session is the wiki — ID is guaranteed non-nil |
| `manager.activeWikiID != nil` (4 sites: ChatView) | `session != nil` (check at ParentView level) or always true inside ContentView (session is non-nil) | |
| `manager.wikis.first(where: { $0.id == id })` (4 sites: display name/home page) | `session.descriptor.displayName` / `session.descriptor.homePageID` | The session carries the descriptor |
| `manager.activeWikiID` → WikiSwitcher checkmark (2 sites) | `registry.activeWikiID` | WikiSwitcher takes `registry` now |
| `.id(manager.activeWikiID)` ContentView rebuild (1 site) | No longer needed — each session swap creates a fresh `ContentView` via `.id(session?.wikiID)` or the session identity | |
| `manager.activeStore?.eventBus` in WikiChangeBridge (1 site) | Routes to all open sessions for that wiki ID | See below |
| WikiFSApp launch/scenePhase (4 sites) | `registry.activeWikiID` / `session?.store` | Session is created from registry state |

---

## The 16 files that change

### New files (2)

| File | Purpose |
|---|---|
| `Sources/WikiFSCore/WikiRegistryClient.swift` | Registry + FP domains + activeWikiID. Extracted from WikiManager. |
| `Sources/WikiFSCore/WikiSession.swift` | Per-wiki session: store + launchers + gate + coordinator + vacuum. |

### Deleted file (1)

| File | Reason |
|---|---|
| `Sources/WikiFSCore/WikiManager.swift` | Dissolved into WikiRegistryClient + WikiSession. |

### Modified files (16)

| File | What changes |
|---|---|
| `WikiFSApp.swift` | `@State manager` → `@State registry` + `@State session`. `.onChange(of: registry.activeWikiID)` creates/destroys session. FP wiring moves from `manager` to `registry`. |
| `RootView.swift` | Takes `session: WikiSession` + `registry: WikiRegistryClient` instead of `manager`. |
| `ContentView.swift` | Takes `session: WikiSession` + `registry: WikiRegistryClient`. `manager.activeWikiID` → `session.wikiID`. `manager.wikis` → `session.descriptor`. |
| `SidebarView.swift` | `manager` → `registry` (for WikiSwitcher) + `session` (for wikiID/displayName). |
| `WikiSwitcher.swift` | Takes `registry: WikiRegistryClient`. `manager.wikis` → `registry.wikis`. `manager.select` → `registry.select`. |
| `WikiDetailView.swift` | `manager` → `session` + `registry`. `manager.activeWikiID` → `session.wikiID`. |
| `PageDetailView.swift` | `manager.activeWikiID ?? ""` → `session.wikiID`. |
| `ChatView.swift` | `manager.activeWikiID` → `session.wikiID`. Nil checks → always true inside ContentView. |
| `LintView.swift` | `manager.activeWikiID ?? ""` → `session.wikiID`. |
| `SourcesContainerView.swift` | `manager.activeWikiID ?? ""` → `session.wikiID` (2 sites). |
| `SourcesListView.swift` | `manager.activeWikiID` / `manager.wikis` → `session.wikiID` / `session.descriptor`. |
| `PagesContainerView.swift` | `manager.activeWikiID ?? ""` → `session.wikiID`. |
| `PagesListView.swift` | `manager.activeWikiID` / `manager.wikis` → `session.wikiID` / `session.descriptor`. |
| `ExtractionCompareSheet.swift` | Takes `registry` instead of `manager` (shares the registry for live Set Active propagation). |
| `VacuumCommands.swift` | `manager.previewVacuumAll/applyVacuumAll` → `session?.previewVacuumAll/applyVacuumAll`. |
| `WikiChangeBridge.swift` | Takes `registry` + a way to reach the active session's bus. See below. |

### Test file (1)

| File | What changes |
|---|---|
| `Tests/WikiFSTests/WikiManagerTests.swift` | Renamed → `WikiRegistryClientTests` (registry CRUD + v0 migration). New `WikiSessionTests` (store lifecycle, vacuum, search upgrade). |

---

## WikiChangeBridge rewire

The bridge currently:
1. Observes Darwin notifications for every wiki in `manager.wikis`.
2. On flush: signals FP for the changed wiki, and if that wiki "is active," pokes its bus.

After:
1. Observes Darwin notifications for every wiki in `registry.wikis` (same).
2. On flush: signals FP for the changed wiki (same). To poke the bus, the bridge
   needs access to the session's store for that wiki ID. Two options:

   **(a) Bridge holds a `@ObservationIgnored var sessionLookup: (String) -> WikiSession?`**
   closure, injected by `WikiFSApp` when session is created. The bridge calls it
   on flush: `if let session = sessionLookup(wikiID) { session.store.eventBus.emit(...) }`.

   **(b) Bridge holds a `weak` reference to the current `WikiSession`** (simplest
   for the single-window phase — there's only ever one session at a time).

   **Chosen: (b)** for the single-window phase. `WikiChangeBridge` holds
   `private weak var session: WikiSession?`. `WikiFSApp` sets it whenever the
   session changes. When multi-window lands, this becomes a set or a lookup
   closure.

---

## WikiSession creation in WikiFSApp

```swift
// WikiFSApp.swift

@State private var registry: WikiRegistryClient
@State private var session: WikiSession?

// In .task (after bootstrap):
registry.activateMostRecent()

// onChange:
.onChange(of: registry.activeWikiID) { _, newID in
    guard let newID,
          let descriptor = registry.wikis.first(where: { $0.id == newID }) else {
        session = nil
        return
    }
    // Tear down old session (flushes pending saves), create new one
    session?.store.flushPendingSaves()
    session = WikiSession(
        wikiID: newID,
        descriptor: descriptor,
        containerDirectory: containerDirectory,
        fileProvider: fileProvider
    )
    // Wire the bridge
    changeBridge?.session = session
}
```

`WikiSession.init` does what `WikiManager.openActive` did:
- Opens `SQLiteWikiStore(databaseURL:)` with an `WikiEventBus`
- Creates `WikiStoreModel(store:)`
- Creates a `WikiReadPool` for off-main reads
- Creates its own `GenerationGate(laneLimits: [.ingest: 1, .interactive: 3])`
- Creates two `AgentLauncher`s sharing the gate
- Creates `ExtractionCoordinator` (or receives a shared one — see note below)

### ExtractionCoordinator: shared or per-session?

`ExtractionCoordinator` reads config from disk and is `@MainActor @Observable`. It
has no per-wiki state — it's a backend resolver + retry queue. Making it
per-session is wasteful (it would re-read the same config file). **Decision:
shared** — `WikiFSApp` creates one `ExtractionCoordinator` and passes it to each
`WikiSession`. The launchers are per-session (isolation), but the extraction
coordinator is app-scoped (no per-wiki state).

---

## What does NOT change

- **The daemon (`wikid`)** — stays `wikictl`-only. No app → daemon rewire.
- **The File Provider extension** — reads SQLite directly, unchanged.
- **Store writes from `wikictl`** — opens its own `SQLiteWikiStore`, unchanged.
- **Darwin notification routing** — same mechanism, same posting.
- **The SQLite concurrency invariants** — method-atomic store, `WikiReadPool`,
  `mutate()` write-seam, `StoreEmissionExhaustivenessTests`. All preserved.
- **Agent config** — provider, API keys, permission mode stay app-wide.
- **The single `WindowGroup`** — no `for:` parameter. One window, one session.

---

## Acceptance criteria

| AC | Description | Verification |
|----|-------------|-------------|
| AC1 | `WikiManager.swift` is deleted. `WikiRegistryClient.swift` + `WikiSession.swift` exist. | `ls Sources/WikiFSCore/Wiki*` |
| AC2 | No source file references `WikiManager`. | `rg WikiManager Sources/ -g '*.swift'` returns zero hits |
| AC3 | No view reads `manager.activeWikiID` or `manager.activeStore`. | `rg 'manager\.(activeWikiID\|activeStore)' Sources/ -g '*.swift'` returns zero hits |
| AC4 | Agent launchers + GenerationGate are per-session. Each `WikiSession` creates its own. | Code review: `WikiSession.init` creates `GenerationGate` + two `AgentLauncher`s |
| AC5 | Ingest in one wiki does not block query in another (same as today: single window, but the types allow it). | `swift build` clean + fast-tier tests green |
| AC6 | `WikiSwitcher` takes `WikiRegistryClient`, calls `registry.select`. | Code review |
| AC7 | `WikiChangeBridge` routes through the session's bus, not `manager.activeStore`. | Code review |
| AC8 | `WikiManagerTests` renamed/replaced. New tests cover registry CRUD + session lifecycle. | `swift test` fast tier green |
| AC9 | The app launches, switches wikis, ingests, queries, lints — same behavior as before. | Manual smoke test |
| AC10 | `swift build` clean + fast-tier tests pass. | CI `swift` job green |

---

## Build steps

### Step 1: Create `WikiRegistryClient` (extract from WikiManager)
- New file `Sources/WikiFSCore/WikiRegistryClient.swift`
- Move all registry logic (bootstrap, select, createWiki, deleteWiki, renameWiki, setHomePage, exportWiki, importWiki, registerAllDomains, FP closures, v0 migration)
- Keep `wikis`, `activeWikiID` as observable properties
- Drop `activeStore`, `pendingBlobVacuum`, `pendingVacuumAll`, `upgradeActiveStoreSearchIndex`, `onActiveStoreDidChange`, `openActive`, `createDatabaseIfNeeded`, `makeModelIfEmpty`
- Gate: `swift build` (WikiManager still exists — coexists)

### Step 2: Create `WikiSession`
- New file `Sources/WikiFSCore/WikiSession.swift`
- Holds: wikiID, descriptor, store, agentLauncher, chatLauncher, extractionCoordinator, generationGate
- Moves vacuum/GC + search upgrade from WikiManager
- `init` does what `WikiManager.openActive` did (open store, attach bus, create model, create read pool, create launchers)
- Gate: `swift build`

### Step 3: Rewire `WikiFSApp`
- `@State manager: WikiManager` → `@State registry: WikiRegistryClient` + `@State session: WikiSession?`
- `.onChange(of: registry.activeWikiID)` creates/destroys session
- FP `.wire(into:)` targets `registry` instead of `manager`
- Change bridge takes `registry` + `weak session`
- Gate: `swift build`

### Step 4: Rewire RootView + ContentView
- `RootView(manager:)` → `RootView(session:, registry:, fileProvider:)`
- `ContentView(store: manager.activeStore, manager:)` → `ContentView(store: session.store, session:, registry:)`
- Remove `.id(manager.activeWikiID)` — session identity handles it
- Gate: `swift build` + fix downstream compile errors

### Step 5: Rewire remaining views (12 files)
- SidebarView, WikiSwitcher, WikiDetailView, PageDetailView, ChatView, LintView, SourcesContainerView, SourcesListView, PagesContainerView, PagesListView, ExtractionCompareSheet, VacuumCommands
- Mechanical: `manager` → `session` or `registry` depending on what they read
- `manager.activeWikiID ?? ""` → `session.wikiID`
- `manager.wikis` → `registry.wikis` (WikiSwitcher only) or `session.descriptor` (display name)
- `pendingBlobVacuum/pendingVacuumAll` → from session
- Gate: `swift build`

### Step 6: Rewire WikiChangeBridge
- Takes `registry: WikiRegistryClient` + `weak var session: WikiSession?`
- `refreshObservations()` reads `registry.wikis`
- `flush(wikiID:)` calls FP + pokes `session?.store.eventBus` if `wikiID == session?.wikiID`
- Gate: `swift build`

### Step 7: Delete WikiManager + rewire tests
- Delete `Sources/WikiFSCore/WikiManager.swift`
- Rewrite `WikiManagerTests` → `WikiRegistryClientTests` (registry CRUD + v0 migration)
- New `WikiSessionTests` (store lifecycle, vacuum, search upgrade)
- Gate: `swift build` + `swift test` (fast tier)

### Step 8: Verify
- `rg WikiManager Sources/ -g '*.swift'` → zero hits
- `rg 'manager\.(activeWikiID|activeStore)' Sources/ -g '*.swift'` → zero hits
- `swift build` clean
- `swift test` (fast tier) green
