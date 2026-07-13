# Multi-wiki daemon (`wikid`) — Phase 1: engine extraction + XPC daemon

**Status:** plan of record (Phase 1 startup). Supersedes the #358 design doc's
"hybrid approach" — this is daemon-first, app-in-process, multi-window UI
deferred.

**Relationship to #358 and the roadmap.** The [#358 design
doc](https://github.com/tqbf/selfdrivingwiki/issues/358) proposed a hybrid:
extract a lightweight XPC daemon while simultaneously rewiring the app to be
its first client. After grounding that design against the codebase
(`plans/architecture-roadmap.md` §2.4, §4), we are taking a different cut:

- **Engine separation first and foremost** — the structural goal is a `WikiFSEngine`
  library that holds the agent execution engine out of the app target, linkable
  by both `wikid` and the app. The daemon is *what makes the engine reachable*
  outside the app process.
- **The app stays in-process** in Phase 1 — `WikiManager` is untouched; the
  shipping app's behavior does not change. The daemon is exercised by a real
  client (`wikictl`), not by rewiring the app.
- **Multi-window UI is Phase 2** — when the app refactors from in-process
  `WikiManager` to per-window XPC sessions, `WikiManager` "dissolves." That is the
  #358 design doc's UI work; it is deferred until the daemon is battle-tested.

This **resolves the §4 fork** in `architecture-roadmap.md`: the chosen branch is
"daemon-first, app-rendezvous-later" — which the roadmap did not contemplate
(it offered "thin per-window slice now" vs "full in-process refactor now"). The
daemon-first path means the per-window model split and the `WikiManager`
dissolution both happen under a daemon that already works, not before.

**Scope is Phase 1 only.** Phase 2 (multi-window UI client) is outlined at the
end but not planned here.

---

## 1. Decisions of record

| # | Decision | Rationale |
|---|----------|-----------|
| D1 | **Full engine extraction** into a new `WikiFSEngine` library target. `AgentLauncher`, `ACPBackend`, `ClaudeCLIBackend`, `AgentOperationRunner`, `GenerationGate`, `ExtractionCoordinator`, `AgentBackend`, `AgentBackendFactory` move out of the app. | "Engine separation from the UI, first and foremost." One-time move now beats two extractions; the daemon can grow agent execution later without a second move. |
| D2 | **App stays in-process** in Phase 1. `WikiManager` path is untouched; the shipping app's behavior does not change. The daemon is green-field. | Keeps the shipping app safe; daemon is testable on its own; matches "daemon first, UI later." |
| D3 | **`wikictl` is the first real XPC client.** Its registry + wiki-resolution path routes through the daemon. | `wikictl` is already a second-writer process that resolves wikis and opens stores directly today; making it a daemon client is a small, realistic integration that proves the XPC surface without touching the app. |
| D4 | **The daemon owns the registry + store lifecycle, but is NOT yet the sole writer.** `wikictl` resolves the wiki via the daemon, then opens its own `SQLiteWikiStore` for writes (as today). "Sole writer" is deferred to Phase 2+ (it requires serializing the entire `WikiStore` protocol surface over XPC — impractical for an MVP). | The real concurrency problem today is `wikis.json` (load-mutate-save per op, not method-atomic). The daemon centralizes that. Store writes are already multi-process-safe (WAL + method-atomic store + `mutate()` event seam). The "sole writer" ambition is a later optimization, not a Phase 1 blocker. |
| D5 | **The daemon talks to `SQLiteWikiStore` directly** (which is `@unchecked Sendable`), not through `WikiStoreModel` (`@MainActor @Observable`, NOT Sendable). | XPC handlers are nonisolated; `SQLiteWikiStore` can cross actor boundaries. `WikiStoreModel` is main-actor-pinned and would need wrapping. |
| D6 | **`WikiDescriptor` is the XPC transport type** (not the design doc's `WikiEntry`, which does not exist). It is already `Codable + Sendable` and serializes to JSON `Data` for `@objc` XPC (which requires `NSSecureCoding`-compatible types). | Zero new types; `WikiDescriptor` has the right fields (id, displayName, homePageID). JSON-in-`NSData` is the standard XPC pattern for Swift `Codable` types. |
| D7 | **The daemon uses `launchd` LaunchAgent for lifecycle** (not embed-as-XPC-service). A plist in `~/Library/LaunchAgents/` keeps the daemon running; `NSXPCConnection` connects by registered service name. | `launchd` provides restart-on-crash, idle-exit, and auto-launch-on-demand. The daemon must survive across app restarts and serve `wikictl` (a separate process). An embedded XPC service would tie the daemon to the app bundle. |

---

## 2. Target layout (Package.swift)

### 2.1 Current → after

```
BEFORE:                              AFTER:
─────────                            ─────────
WikiFSCore   (lib)                   WikiFSCore     (lib, unchanged)
WikiFSMLX    (lib)                   WikiFSMLX      (lib, unchanged)
WikiFS       (app exe)              WikiFSEngine   (NEW lib)  ← agent engine extracted here
WikiCtlCore  (lib)                  WikiFS         (app exe, links WikiFSEngine)
wikictl      (cli exe)              WikiCtlCore    (lib, gains WikiDaemonXPCClient)
WikiFSFileProvider (appex)          wikid          (NEW daemon exe, links WikiFSEngine)
Tests        (WikiFSTests)           wikictl        (cli exe, links WikiCtlCore)
                                     WikiFSFileProvider (appex, unchanged)
                                     Tests          (WikiFSTests + new wikid tests)
```

### 2.2 Module dependency graph

```
                    ┌──────────┐
                    │ CSqliteVec│
                    └─────┬─────┘
                          │
                    ┌─────┴─────┐
          ┌─────────┤ WikiFSCore │──────────┐
          │         └────────────┘          │
          │              │                  │
   ┌──────┴──────┐  ┌───┴──────┐    ┌──────┴──────┐
   │ WikiFSMLX   │  │WikiFS-   │    │ WikiCtlCore │ ← gains WikiDaemonXPCClient
   └─────────────┘  │ Engine   │    └──────┬──────┘
                    └───┬──────┘           │
              ┌─────────┼──────────┐       ├── wikictl (exe)
       ┌──────┴──┐  ┌──┴───────┐  │       │
       │ WikiFS  │  │ wikid    │  │       └── (daemon XPC client)
       │ (app)   │  │ (daemon) │  │
       └─────────┘  └──────────┘  │
         links both  links only     │
         Engine+Core  Engine+Core   ACP, ACPModel
                                   (swift-acp fork)
```

### 2.3 Package.swift target declarations

**New `WikiFSEngine` library target:**

```swift
.target(
    name: "WikiFSEngine",
    dependencies: [
        "WikiFSCore",
        .product(name: "ACP", package: "swift-acp"),
        .product(name: "ACPModel", package: "swift-acp"),
    ],
    path: "Sources/WikiFSEngine",
    swiftSettings: podcastSwiftSettings
),
```

**New `wikid` executable target:**

```swift
.executableTarget(
    name: "wikid",
    dependencies: ["WikiFSEngine", "WikiFSCore"],
    path: "Sources/wikid",
    swiftSettings: podcastSwiftSettings
),
```

**Updated `WikiFS` (app) target** — replace direct `ACP`/`ACPModel` product deps
with `WikiFSEngine` (which transitively provides them):

```swift
.executableTarget(
    name: "WikiFS",
    dependencies: [
        "WikiFSCore", "WikiFSMLX", "WikiFSEngine",       // ← WikiFSEngine replaces extracted files
        .product(name: "Markdown", package: "swift-markdown"),
        // ACP/ACPModel now come transitively via WikiFSEngine
    ],
    path: "Sources/WikiFS",
    swiftSettings: podcastSwiftSettings,
    linkerSettings: [.linkedFramework("WebKit")]
),
```

**Updated `WikiCtlCore`** — gains the XPC client (so wikictl can talk to the
daemon):

```swift
.target(
    name: "WikiCtlCore",
    dependencies: ["WikiFSCore"],        // + WikiDaemonXPCClient lives here
    path: "Sources/WikiCtlCore",
    swiftSettings: podcastSwiftSettings
),
```

**Updated `WikiFSTests`** — add `WikiFSEngine` so engine tests can run:

```swift
.testTarget(
    name: "WikiFSTests",
    dependencies: ["WikiFSCore", "WikiCtlCore", "WikiFS", "WikiFSMLX",
                   "WikiFSEngine", "WikiFSFileProvider", ...],
    ...
),
```

---

## 3. Phase 1A — `WikiFSEngine` extraction

### 3.1 Files that move from `Sources/WikiFS/` → `Sources/WikiFSEngine/`

| File | Declaration | Why it moves | Coupling to resolve |
|------|-------------|-------------|---------------------|
| `AgentBackend.swift` | `public protocol AgentBackend: Sendable` + value types | Pure protocol, no UI | None — pure |
| `AgentBackendFactory.swift` | `enum AgentBackendFactory` (static) | Constructs backends | None — stateless |
| `ACPBackend.swift` | `actor ACPBackend: AgentBackend` | The ACP backend | Pulls `ACP`/`ACPModel` product deps |
| `ClaudeCLIBackend.swift` | `actor ClaudeCLIBackend: AgentBackend` | The CLI backend | Pulls `ACP`? No — Foundation + WikiFSCore only |
| `GenerationGate.swift` | `@MainActor final class GenerationGate` | Per-window/per-process gate | `@MainActor` — fine if daemon hosts a main actor |
| `ExtractionCoordinator.swift` | `@MainActor @Observable final class` | Extraction orchestration | Reads `ExtractionConfig` from disk; `@MainActor` |
| `AgentLauncher.swift` | `@MainActor @Observable final class` | Spawns agents | Reads `UserDefaults.standard` keys; `HelpersLocation.wikictlDirectory`; default `KeychainACPCredentialStore()` |
| `AgentOperationRunner.swift` | `@MainActor enum` (static methods) | Orchestrates runs | **Hardest:** takes `fileProvider: FileProviderSpike` (AppKit) + `manager: WikiManager` + `HelpersLocation.wikictlDirectory` |
| `OperationRequest.swift` | `struct OperationRequest` | Per-run intent | Uses `AgentStaging` (already in WikiFSCore) — verify staging path works from engine |
| `ACPPermissions.swift` | `PermissionPolicy` etc. | ACPBackend dep | None |
| `PermissionResolving.swift` | `protocol PermissionResolving` | ACPBackend dep | None |
| `NotificationFanout.swift` | `class NotificationFanout` | ACPBackend dep | None |
| `TurnLivenessPolicy.swift` | `nonisolated static` (pure) | ACPBackend watchdog dep | None — pure |

**Files that stay in `Sources/WikiFS/` (app target, UI-coupled):**
- `FileProviderSpike.swift` — imports `AppKit` + `FileProvider`, `NSFileProviderManager`/`NSWorkspace`
- `HelpersLocation.swift` — probes `Bundle.main` for bundled `wikictl`; app-bundle-specific
- `WikiManager.swift` — stays in `WikiFSCore` (already there); app uses in-process
- All SwiftUI views (`RootView`, `ContentView`, `ChatView`, `SidebarView`, `WikiSwitcher`, etc.)
- `WikiChangeBridge.swift` — Darwin notification bridge, app-specific wiring
- `VacuumCommands.swift`, `ExtractionCompareSheet.swift`, `BlobVacuumCommands.swift` — UI

### 3.2 The one genuine decoupling: `AgentOperationRunner`

`AgentOperationRunner` is `@MainActor enum` (static methods). Every method
signature takes `fileProvider: FileProviderSpike` AND `manager: WikiManager`:

```swift
static func ingest(
    request: OperationRequest,
    launcher: AgentLauncher,
    store: WikiStoreModel,
    manager: WikiManager,                    // ← reads manager.activeWikiID
    fileProvider: FileProviderSpike,        // ← calls .signalChange() + .path
    extractionCoordinator: ExtractionCoordinator
) async
```

**Resolution:** introduce two protocol seams in `WikiFSEngine` that the app
fills with concrete conformers:

```swift
// In WikiFSEngine:
@MainActor
public protocol ChangeSignaler: AnyObject {
    func signalChange(forWikiID wikiID: String)
    func filePath(forWikiID wikiID: String) -> URL?
}

public protocol WikictlResolver: AnyObject {
    func wikictlURL() -> URL?
}
```

**App conforms** `FileProviderSpike: ChangeSignaler` (already has
`signalChange(forWikiID:)` + the path method) and provides a
`BundleWikictlResolver: WikictlResolver` backed by `HelpersLocation`.

**`AgentOperationRunner` signatures change** from `manager: WikiManager` +
`fileProvider: FileProviderSpike` to:

```swift
static func ingest(
    request: OperationRequest,
    launcher: AgentLauncher,
    store: WikiStoreModel,
    wikiID: String,                          // ← was manager.activeWikiID
    changeSignaler: any ChangeSignaler,     // ← was fileProvider: FileProviderSpike
    wikictlResolver: any WikictlResolver,   // ← was HelpersLocation.wikictlDirectory
    extractionCoordinator: ExtractionCoordinator
) async
```

This mirrors the #358 design doc's §4 table (`AgentOperationRunner.swift` →
"accept `wikiID` as parameter").

**App call sites** (the `WikiFSApp` / views that invoke
`AgentOperationRunner.ingest`/`query`/`lint`) pass the new params — one-time
mechanical change at the app boundary.

### 3.3 `AgentLauncher` UserDefaults + Keychain injection

`AgentLauncher`'s injected closures default to app-process behavior:

```swift
@ObservationIgnored var resolveUseACPBackend: () -> Bool = {
    UserDefaults.standard.bool(forKey: AgentLauncher.useACPBackendKey)
}
@ObservationIgnored var resolvePermissionMode: () -> String = {
    UserDefaults.standard.string(forKey: AgentLauncher.permissionModeKey) ?? "ask"
}
@ObservationIgnored var acpCredentialStore: any ACPCredentialStore = KeychainACPCredentialStore()
```

These are **already injectable closures** (good — the app passes its own, the
daemon would pass its own). The extraction does NOT change the defaults; it moves
`AgentLauncher` into `WikiFSEngine`, and the daemon, when it uses the engine in
a later phase, injects its own closures. In Phase 1 the daemon does not yet spawn
agents, so this is a no-op — just move the file.

**`HelpersLocation.wikictlDirectory`** — a `static` that probes `Bundle.main`.
Stays in the app. The `AgentOperationRunner` receives it via the
`WikictlResolver` protocol seam (§3.2).

### 3.4 Extraction step order

1. Create `Sources/WikiFSEngine/` directory.
2. Add the `WikiFSEngine` target to `Package.swift` (§2.3) with `ACP`/`ACPModel` deps.
3. `git mv` each file from `Sources/WikiFS/` to `Sources/WikiFSEngine/` (preserves history).
4. Add the `ChangeSignaler` + `WikictlResolver` protocols to `WikiFSEngine`.
5. Conform `FileProviderSpike` to `ChangeSignaler` in the app; add
   `BundleWikictlResolver` in the app.
6. Update `AgentOperationRunner` signatures (§3.2) — replace `manager`/`fileProvider`/`HelpersLocation` params.
7. Update all app call sites to pass the new params.
8. Update `WikiFS` target dependencies in `Package.swift`.
9. `swift build` — fix any import/access-level issues (files may need `public` on
   types that were internal to the app target).
10. `swift test` (fast tier) — confirm no regressions.

**Gate:** `swift build` clean + fast-tier tests green. The app's behavior is
identical — this is a pure relocation + seam introduction.

---

## 4. Phase 1B — `wikid` daemon

### 4.1 XPC protocol surface

```swift
// Sources/wikid/WikiDaemonProtocol.swift

import Foundation

/// The XPC contract between `wikid` and its clients. Uses `@objc` + `@escaping`
/// reply closures (standard macOS XPC). Values that are Swift `Codable` but not
/// `NSSecureCoding` (i.e. `WikiDescriptor`) are serialized to JSON and passed as
/// `Data` (which bridges to `NSData`).
@objc protocol WikiDaemonProtocol {
    // --- Registry ---

    /// List all wikis, MRU-ordered. Returns JSON-encoded `[WikiDescriptor]`.
    func listWikis(reply: @escaping (Data) -> Void)

    /// Create a new wiki. Returns JSON-encoded `WikiDescriptor` on success,
    /// or `nil` on failure.
    func createWiki(name: String, reply: @escaping (Data?) -> Void)

    /// Delete a wiki (removes registry entry + DB files). Returns true on success.
    func deleteWiki(id: String, reply: @escaping (Bool) -> Void)

    /// Rename a wiki (display name only; identity/DB untouched).
    func renameWiki(id: String, name: String, reply: @escaping (Bool) -> Void)

    /// Resolve a selector (ULID id or display name) to a `WikiDescriptor`.
    /// Returns JSON-encoded `WikiDescriptor`, or `nil` if not found.
    func resolveWiki(selector: String, reply: @escaping (Data?) -> Void)

    // --- Store lifecycle ---

    /// Open (or confirm open) the store for a wiki. The daemon holds a
    /// `SQLiteWikiStore` instance alive for this wiki. Returns true on success.
    /// Does NOT grant the client write access — the client still opens its own
    /// store for writes (sole-writer is deferred to Phase 2+).
    func openStore(wikiID: String, reply: @escaping (Bool) -> Void)

    /// Close the daemon's held-open store for a wiki (if no other client holds
    /// a session). Best-effort; the daemon may keep it open for idle-eviction logic.
    func closeStore(wikiID: String, reply: @escaping () -> Void)

    /// The current changeToken for a wiki (per #129 event bus design).
    /// Returns 0 if the store is not open.
    func changeToken(wikiID: String, reply: @escaping (UInt64) -> Void)
}
```

**Why `Data` (JSON) instead of raw types:** `@objc` XPC requires
`NSSecureCoding`-compatible types in the protocol signature. `WikiDescriptor`
is `Codable + Sendable` but not `NSSecureCoding`. Serializing to JSON `Data`
(which bridges to `NSData`) is the standard pattern. The client deserializes
back to `WikiDescriptor` via `JSONDecoder`.

### 4.2 Daemon implementation

```swift
// Sources/wikid/WikiDaemon.swift

import Foundation
import WikiFSCore

/// The daemon's in-process state. Holds the live wiki registry + open stores.
/// `SQLiteWikiStore` is `@unchecked Sendable` (method-atomic with internal
/// recursive lock), so it is safe to hold here and serve from XPC handlers.
final class WikiDaemon {
    private let containerDirectory: URL
    private var registry: WikiRegistry          // live, in-memory; mutations serialized on the daemon's queue
    private var openStores: [String: SQLiteWikiStore] = [:]  // wikiID → store

    init() throws {
        containerDirectory = try DatabaseLocation.appGroupContainerDirectory()
        registry = WikiRegistry.load(from: containerDirectory)
        // Legacy v0 migration (same logic as WikiManager.bootstrap)
        if registry.isEmpty { /* seed or migrate — reuse WikiManager's logic path */ }
    }

    // MARK: - Registry

    func listWikis() -> Data {
        try! JSONEncoder().encode(registry.wikis)
    }

    func createWiki(name: String) -> Data? {
        let descriptor = WikiDescriptor.make(displayName: name)
        // Open + seed the DB (runs bootstrap ladder)
        let dbURL = containerDirectory.appendingPathComponent(descriptor.dbFileName)
        do {
            let store = try SQLiteWikiStore(databaseURL: dbURL)
            openStores[descriptor.id] = store
        } catch { return nil }
        registry.add(descriptor)
        try? registry.save(to: containerDirectory)
        return try? JSONEncoder().encode(descriptor)
    }

    func resolveWiki(selector: String) -> Data? {
        // Mirrors WikiResolver.descriptor(forSelector:): ULID first, then displayName
        let descriptor = registry.descriptor(id: selector)
            ?? registry.wikis.first { $0.displayName == selector }
        return descriptor.flatMap { try? JSONEncoder().encode($0) }
    }

    // ... deleteWiki, renameWiki, openStore, closeStore, changeToken ...
}
```

**Key design points:**

- **Registry is live in memory**, not load-mutate-save per op. This is the
  daemon's primary value: `WikiManager` today loads `wikis.json` from disk on
  *every* mutation (`WikiManager.swift:195,210,221,232,275,295`), which is a
  race if two processes do it concurrently. The daemon serializes registry
  mutations on a single queue.
- **Store instances are `SQLiteWikiStore` directly** (Sendable), not
  `WikiStoreModel` (NOT Sendable — `@MainActor @Observable`).
- **`openStore` holds the store alive** for future agent execution. In Phase 1
  the daemon doesn't yet use it for agent execution — but the lifecycle is
  established.
- **`changeToken`** reads from the daemon's held store instance. If the store
  isn't open, it opens it, reads the token, and closes it (or keeps it open —
  idle-eviction policy).

### 4.3 XPC listener + lifecycle

```swift
// Sources/wikid/main.swift

import Foundation

let daemon = try WikiDaemon()

let listener = NSXPCListener.create()
let connection = NSXPCConnection(machServiceName: WikiDaemonXPC.serviceName)
// OR: use a listener delegate + NSXPCListenerDelegate
let interface = NSXPCInterface(with: WikiDaemonProtocol.self)
listener.delegate = WikiDaemonListener(delegate: daemon)
listener.resume()

// Keep the process alive
RunLoop.current.run()
```

**launchd LaunchAgent plist** (`com.selfdrivingwiki.wikid.plist`):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.selfdrivingwiki.wikid</string>
    <key>ProgramArguments</key>
    <array>
        <string>/path/to/wikid</string>  <!-- resolved at build/install time -->
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>AfterInitialDemand</key>
        <true/>
    </dict>
    <key>IdleTimeout</key>
    <integer>300</integer>  <!-- idle-exit after 5 min (if no XPC sessions) -->
</dict>
</plist>
```

**Lifecycle:**
- **Launch:** `launchd` starts the daemon on first demand (when a client
  connects via `NSXPCConnection(machServiceName:)`) or at login (if `RunAtLoad`).
- **Idle exit:** `IdleTimeout` (300s) — the daemon exits if no XPC connections
  are active. `launchd` will restart it on the next connection.
- **Crash recovery:** `KeepAlive.AfterInitialDemand` → `launchd` restarts on
  crash. XPC clients auto-reconnect (the next `NSXPCConnection` call triggers
  `launchd` to re-launch). The daemon re-loads the registry from disk on start
  (durable — `wikis.json` + the SQLite files are persistent).

### 4.4 The `mutate()` write-seam invariant

**Load-bearing:** the daemon routes registry mutations through its own serialized
queue, but store writes (when the daemon itself writes to a wiki's SQLite) must
go through `SQLiteWikiStore.mutate(event:_:)` — the same seam that emits
`ResourceChangeEvent` for File Provider signaling. The
`StoreEmissionExhaustivenessTests` enforce that every public mutating method on
`SQLiteWikiStore` routes through `mutate()`. The daemon inherits this
obligation: any new daemon-side mutator must also `mutate()` + emit, or the
guard fails.

In Phase 1 the daemon does NOT write to wiki stores (it only opens/holds them).
Registry mutations (create/delete/rename wiki) are not store mutations — they're
`wikis.json` mutations, handled by the daemon's own queue, not `mutate()`.

### 4.5 Checkpoint safety

The daemon must avoid `wal_checkpoint(TRUNCATE)` while clients hold read-only
connections via `WikiReadPool`. The existing
`WikiManager.checkpointDatabase` (`WikiManager.swift:437-440`) proves TRUNCATE
aborts on concurrent readers with `busy=1`. If the daemon needs to checkpoint
(e.g., on wiki delete/export), it must use `PRAGMA wal_checkpoint(PASSIVE)` or
coordinate with the app's read pool. WAL's default `auto-checkpoint` (PASSIVE,
1000 frames) is safe and already in effect.

---

## 5. Phase 1C — `wikictl` as first XPC client

### 5.1 The 3-line seam that becomes XPC

Today (`Sources/wikictl/main.swift:37-42`):

```swift
let resolver = try WikiResolver.appGroupContainer()
guard let descriptor = resolver.descriptor(forSelector: invocation.wikiSelector) else { throw ... }
let store = try SQLiteWikiStore(databaseURL: resolver.databaseURL(for: descriptor))
```

After:

```swift
let daemon = try WikiDaemonConnection.connect()
guard let descriptorData = try await daemon.resolveWiki(selector: invocation.wikiSelector),
      let descriptor = try? JSONDecoder().decode(WikiDescriptor.self, from: descriptorData) else {
    throw WikiCtlError.wikiNotFound(invocation.wikiSelector)
}
// wikictl still opens its own store for writes (sole-writer deferred — D4)
let resolver = try WikiResolver.appGroupContainer()  // for the DB path; or daemon returns it
let store = try SQLiteWikiStore(databaseURL: resolver.databaseURL(for: descriptor))
```

**What changes:**
- `resolveWiki(selector:)` goes through the daemon (XPC). The daemon holds the
  live registry; no more `wikis.json` load per invocation.
- Store opens are still direct (`SQLiteWikiStore(databaseURL:)`). This is
  intentional — serializing the full `WikiStore` protocol over XPC is Phase 2+.
- Darwin notification posting is unchanged (`DarwinNotifier.postChange`).

**What does NOT change:**
- All command families (`PageCommand`, `SourceCommand`, `WorkspaceCommand`,
  `BookmarkCommand`, `ChatCommand`, `LogIndexCommand`, `AdminCommand`) execute
  against a direct `SQLiteWikiStore` instance. They don't know about the daemon.
- `wikictl wiki list/create/delete/rename` — these route through the daemon's
  registry XPC methods instead of touching `wikis.json` directly (via
  `WikiRegistry.load/save`).

### 5.2 `WikiDaemonConnection` client

Lives in `WikiCtlCore` (already linked by `wikictl`, can also be used by the app
in Phase 2):

```swift
// Sources/WikiCtlCore/WikiDaemonConnection.swift

import Foundation

/// Thin XPC client. Connects to `wikid` via mach service name.
/// `launchd` auto-launches the daemon on first connection.
public final class WikiDaemonConnection {
    public static let serviceName = "com.selfdrivingwiki.wikid"  // matches launchd plist Label

    private let connection: NSXPCConnection

    private init(connection: NSXPCConnection) {
        self.connection = connection
    }

    public static func connect() throws -> WikiDaemonConnection {
        let connection = NSXPCConnection(machServiceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: WikiDaemonProtocol.self)
        connection.resume()
        guard let proxy = connection.remoteObjectProxy as? WikiDaemonProtocol else {
            throw WikiDaemonError.connectionFailed
        }
        return WikiDaemonConnection(connection: connection)
    }

    public func resolveWiki(selector: String) async throws -> WikiDescriptor? {
        try await withCheckedThrowingContinuation { cont in
            proxy.resolveWiki(selector: selector) { data in
                guard let data else { cont.resume(returning: nil); return }
                cont.resume(returning: try? JSONDecoder().decode(WikiDescriptor.self, from: data))
            }
        }
    }

    public func listWikis() async throws -> [WikiDescriptor] {
        try await withCheckedThrowingContinuation { cont in
            proxy.listWikis { data in
                cont.resume(returning: (try? JSONDecoder().decode([WikiDescriptor].self, from: data)) ?? [])
            }
        }
    }

    // ... createWiki, deleteWiki, renameWiki, openStore, closeStore, changeToken ...

    private var proxy: WikiDaemonProtocol {
        connection.remoteObjectProxy as! WikiDaemonProtocol
    }
}
```

### 5.3 `wikictl wiki` subcommands (new or repurposed)

`wikictl` already resolves wikis by selector. The daemon connection makes
registry operations first-class CLI verbs:

```
wikictl wiki list                          → daemon.listWikis()
wikictl wiki create --name "My Wiki"       → daemon.createWiki(name:)
wikictl wiki delete --id <ulid>            → daemon.deleteWiki(id:)
wikictl wiki rename --id <ulid> --name N   → daemon.renameWiki(id:name:)
```

These route through XPC instead of touching `wikis.json` directly. The daemon
serializes registry mutations.

---

## 6. What does NOT change in Phase 1

- **The app (`WikiFS`)** — `WikiManager` stays in-process. `bootstrap`,
  `select`, `createWiki`, `deleteWiki`, `openActive` — all unchanged. The app
  reads `wikis.json` directly (as today). The daemon and the app both read the
  same file; the daemon has a live in-memory copy, the app reloads per op (as
  today). In Phase 2 the app switches to the daemon. Phase 1's registry-race
  concern (two processes editing `wikis.json`) is mitigated because the app
  only edits on user action (create/rename/delete), which is rare and
  human-paced; the daemon serializes the programmatic side (`wikictl wiki
  create`).
- **The File Provider extension** — reads SQLite directly, unchanged.
- **Store writes from `wikictl`** — opens its own `SQLiteWikiStore`, writes
  directly. The daemon's `openStore` is separate (holds a store for future use).
  WAL + method-atomic store handles multi-writer (as it does today: the app +
  `wikictl` both write).
- **The SQLite concurrency invariants** — method-atomic store,
  `WikiReadPool` read-only connections, `mutate()` write-seam event emission,
  `StoreEmissionExhaustivenessTests`. All preserved.
- **Darwin notification routing** — `wikictl` still posts
  `DarwinNotifier.postChange(forWikiID:)` after writes. The app's
  `WikiChangeBridge` still receives and routes to the active store.
- **Agent config** — provider, API keys, permission mode stay app-wide (in
  `UserDefaults` + Keychain). The daemon does not manage agent config in
  Phase 1.

---

## 7. Phase 2 preview (out of scope — for context only)

Phase 2 is when the app becomes an XPC client and multi-window lands:

1. **~~`WikiManager` dissolves.~~** ✅ **Phase 2a shipped** (`plans/dissolve-wikimanager.md`) —
   `WikiManager` is dissolved into `WikiRegistryClient` (app-scoped registry +
   active id) + `WikiSession` (per-active-wiki store + launchers + gate). Its
   `activeStore` binding → `WikiSession.store`. Its `onActiveStoreDidChange` →
   `.onChange(of: registry.activeWikiID)` in `WikiFSApp`. Its registry role
   stays in-process (the daemon is `wikictl`-only in Phase 1); the XPC migration
   of registry ops is Phase 2b+.
2. **`WindowGroup(for: String.self)`** drives window creation by wiki ID. **(Phase 2b — not yet done)**
3. **Each window holds a `WikiSession`** (store read-pool, `AgentLauncher`,
   `GenerationGate`, extraction coordinator) — the #358 design doc's §3.
   ✅ `WikiSession` exists in `WikiFSEngine` (Phase 2a), but is single-instance
   (created from `registry.activeWikiID`, not per-window) until Phase 2b.
4. **`WikiChangeBridge` routes to all matching windows**, not just the active
   one (§5 of the design doc). **(Phase 2b — currently holds `weak var session`)**
5. **WikiSwitcher** opens a new window by default; Option+click switches the
   current window's wiki (§6). **(Phase 2b)**
6. **Sole-writer migration** — the app stops opening `SQLiteWikiStore` for
   writes; all writes route through the daemon's XPC store session. This is
   where the full `WikiStore` protocol must be available over XPC (or a
   write-proxy pattern). **(Phase 2b+)**

Phase 2 is where the #358 design doc's §1–§10 become the plan of record.

---

## 8. Acceptance criteria

| AC | Description | Verification |
|----|-------------|-------------|
| AC1 | `WikiFSEngine` library target compiles and links. App target (`WikiFS`) links it. | `swift build` clean |
| AC2 | The 8 engine files live in `Sources/WikiFSEngine/`, not `Sources/WikiFS/`. App behavior unchanged. | `git diff --stat`; `swift test` fast tier green |
| AC3 | `AgentOperationRunner` uses `ChangeSignaler` + `WikictlResolver` protocol seams; no direct `FileProviderSpike` or `HelpersLocation` references. | `grep` for `FileProviderSpike` and `HelpersLocation` in `Sources/WikiFSEngine/` returns zero hits |
| AC4 | `wikid` executable target builds. It can start, load the registry from the App Group container, and serve XPC. | `swift build`; `wikid --help` or a smoke test |
| AC5 | `wikictl wiki list` talks to the daemon via XPC and returns the same wikis as `WikiManager.wikis`. | Run with multiple wikis in the container; compare output |
| AC6 | `wikictl wiki create --name "Test"` creates a wiki through the daemon. The registry (`wikis.json`) is updated. The DB file exists and opens. | Verify via `wikictl wiki list` + `sqlite3` on the new DB |
| AC7 | `wikictl wiki delete --id <ulid>` removes the wiki from the registry + deletes the DB file. | Verify the DB file is gone + registry is updated |
| AC8 | `wikictl <command> --wiki <selector>` resolves the wiki via the daemon (`resolveWiki`), then opens its own store and executes. Write commands still work and post Darwin notifications. | Run `wikictl page upsert --wiki <selector> --title Test --body "hello"`, verify the page exists in the app (Darwin notification → bridge → reload) |
| AC9 | The daemon auto-launches via `launchd` on first XPC connection. After idle timeout, it exits. On crash, `launchd` restarts it. | `launchctl list | grep wikid`; kill the daemon, reconnect, verify recovery |
| AC10 | Fast-tier tests pass (`swift test` with the CI skip regex). No new test failures. | CI `swift` job green |

---

## 9. Build phases (executable steps)

### Phase 1A: Engine extraction (no daemon yet)

- [ ] Create `Sources/WikiFSEngine/` directory.
- [ ] Add `WikiFSEngine` target to `Package.swift` (§2.3).
- [ ] `git mv` the 13 engine files (§3.1) from `Sources/WikiFS/` to `Sources/WikiFSEngine/`.
- [ ] Add `ChangeSignaler` + `WikictlResolver` protocols to `WikiFSEngine`.
- [ ] Make types `public` that were internal (access-level adjustments).
- [ ] Conform `FileProviderSpike: ChangeSignaler` in the app.
- [ ] Add `BundleWikictlResolver: WikictlResolver` in the app.
- [ ] Update `AgentOperationRunner` signatures (§3.2).
- [ ] Update all app call sites (`WikiFSApp`, views that call `AgentOperationRunner`).
- [ ] Update `WikiFS` target deps in `Package.swift` — link `WikiFSEngine`.
- [ ] Update `WikiFSTests` deps to include `WikiFSEngine`.
- [ ] `swift build` + `swift test` (fast tier). **Gate: AC1, AC2, AC3.**

### Phase 1B: Daemon

- [ ] Create `Sources/wikid/` directory + target in `Package.swift` (§2.3).
- [ ] Write `WikiDaemonProtocol.swift` (§4.1) — `@objc` protocol.
- [ ] Write `WikiDaemon.swift` (§4.2) — registry + store holder. Reuse
      `DatabaseLocation.appGroupContainerDirectory()` + `WikiRegistry` +
      `SQLiteWikiStore` directly.
- [ ] Write `main.swift` (§4.3) — `NSXPCListener` + `RunLoop.current.run()`.
- [ ] Create the launchd plist template (`signing/com.selfdrivingwiki.wikid.plist`).
- [ ] `swift build` — `wikid` compiles and links. **Gate: AC4.**
- [ ] Smoke test: run `wikid` manually, connect with a test XPC client, verify
      `listWikis` returns the expected wikis.

### Phase 1C: wikictl as client

- [ ] Add `WikiDaemonConnection` to `WikiCtlCore` (§5.2).
- [ ] Add `WikiDaemonProtocol.swift` as a shared file (or duplicate in
      `WikiCtlCore` — XPC protocols must be visible to both sides).
- [ ] Add `wikictl wiki list/create/delete/rename` subcommands.
- [ ] Update `wikictl main.swift` — `resolveWiki` via daemon (§5.1).
- [ ] Update `wikictl wiki list` to read from the daemon.
- [ ] `swift build` + manual smoke test. **Gate: AC5, AC6, AC7, AC8.**

### Phase 1D: launchd lifecycle

- [ ] Write a `make install-daemon` target (or `signing/install-daemon.sh`)
      that copies the plist to `~/Library/LaunchAgents/` and `load -w`s it.
- [ ] Verify auto-launch, idle-exit, crash recovery. **Gate: AC9.**

### Phase 1E: Tests + docs

- [ ] Add `WikiDaemonTests` — test the daemon's registry ops against a temp
      container directory (hermetic, no real App Group).
- [ ] Add `WikiDaemonConnectionTests` — test the XPC client against an
      in-process or mock daemon.
- [ ] Run full test suite. **Gate: AC10.**
- [ ] Update `PLAN.md` doc index (§this plan).
- [ ] Update `architecture-roadmap.md` §4 (record the resolved fork).
- [ ] Update `PROGRESS.md`.

---

## 10. Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| **`AgentOperationRunner` signature change breaks app call sites** | Medium | Mechanical change (§3.2); find all call sites via `grep AgentOperationRunner` in `Sources/WikiFS/`. The runner is `@MainActor enum` (static), so no instance state to migrate. |
| **`ChangeSignaler` protocol seam is insufficient** (missing a method `FileProviderSpike` provides) | Medium | Audit `AgentOperationRunner`'s use of `fileProvider` — the audit found only `signalChange()` + `.path`. If more surface is needed, add it to the protocol. |
| **Access-level friction** — engine files were `internal` to the app; now need `public` | Low | Swift will flag each. One-time `internal` → `public` pass on moved types. |
| **launchd plist path resolution** — the `wikid` binary path in the plist must be absolute | Low | Resolve at build/install time: `$(which wikid)` or a known install prefix. A `make install-daemon` target handles this. |
| **XPC `@objc` protocol + Swift `Codable` types** — `WikiDescriptor` is not `NSSecureCoding` | Low | JSON-in-`Data` pattern (§4.1). `PageID` is `Codable + Sendable + RawRepresentable<String>` — verified XPC-safe. |
| **Registry race (app + daemon both edit `wikis.json`)** | Medium | In Phase 1 the app reloads per-op (as today); the daemon holds live. A race is possible if the app creates a wiki while the daemon is mid-mutation. **Mitigation:** the daemon serializes on its own queue and saves atomically; the app's atomic write + the daemon's in-memory copy means the worst case is one stale read (app reloads, sees the daemon's change on next op). Phase 2 removes this by making the app a daemon client. |
| **`HelpersLocation` becomes wrong in `WikiFSEngine`** | Low | `HelpersLocation` stays in the app. The `WikictlResolver` protocol is injected; the daemon would use a path-based resolver. |
| **`StoreEmissionExhaustivenessTests` fails** (new daemon mutator doesn't route through `mutate()`) | High | The daemon does NOT add new store mutators in Phase 1 (it only opens/holds stores). When it does (Phase 2+), every new mutator MUST route through `mutate()` (§4.4). |
| **Test isolation** — daemon tests need a temp App Group container | Low | Inject `containerDirectory: URL` into `WikiDaemon.init` (same pattern as `WikiManager`). Tests pass a temp dir. |
