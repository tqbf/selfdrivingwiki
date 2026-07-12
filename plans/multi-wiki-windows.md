# Multi-wiki multi-window isolation (#358)

**Status: design.** This doc covers opening multiple wikis simultaneously in
separate macOS windows with full agent isolation. Roadmap context:
[`llm-wiki.md`](llm-wiki.md) Phase 0 established the one-wiki-at-a-time
switcher; this extends it to concurrent independent windows.

**Relationship to the daemon (#187):** the full gRPC daemon is sequenced last
in the roadmap. Rather than either blocking multi-window on the daemon or
building a throwaway in-app refactor, this design takes a **hybrid approach**:
extract wiki registry + store ownership into a lightweight local daemon first
(XPC, no gRPC yet). Multi-window becomes a thin-client concern — each window
holds an XPC session bound to a wiki. When the full daemon lands later, the XPC
surface upgrades to gRPC and gains remote access, but the per-window client
model survives unchanged.

## Definition of done

- Two (or more) wiki windows open side-by-side, each showing a different wiki.
- A lightweight local daemon (`wikid`) owns the wiki registry and store
  lifecycle; the app is a client.
- Each window holds its own session to the daemon, with its own launcher,
  transcript, and generation gate.
- Agents spawned in window A cannot see, block, or interact with agents in
  window B.
- WikiSwitcher in each window's toolbar opens a *new* window for a different
  wiki (default) or switches the current window's wiki (Option+click).
- File Provider domains and Darwin notification routing work correctly for all
  open wikis, not just "the active one."

## Isolation guarantee

Isolation is at the **data + process** layer: separate SQLite file, separate
`wikiRoot`, separate `AgentLauncher` / `GenerationGate` / transcript per
session. Agent configuration (LLM provider, API keys, permission mode) remains
**app-wide** — all wikis share the same credentials. The trust boundary is: two
agents in different windows will never read/write the same database or contend
on the same generation gate, but they authenticate with the same API key and
obey the same permission mode.

**Tradeoff acknowledged:** N windows × per-window gate limits = N× the
concurrent API calls. With app-wide API keys, this can hit provider rate limits
if multiple wikis ingest simultaneously. This is acceptable for the expected
two-to-three-window case; if it becomes a problem, a shared token-bucket rate
limiter can be added later without changing the per-window gate architecture.

---

## 1. Architecture: the lightweight daemon (`wikid`)

### What the daemon owns

The daemon is a new SPM executable target (`wikid`) that extracts two
responsibilities out of the app:

1. **Wiki registry** — the `WikiRegistry` (create / delete / rename /
   enumerate wikis, MRU tracking). Today this is `WikiManager`'s role.
2. **Per-wiki store lifecycle** — open / close `WikiStoreModel` instances on
   demand, one per wiki. The daemon is the sole writer; clients get a session
   handle.

The daemon does **not** yet own agent execution, PDF extraction, or ingestion
orchestration — those stay in the app process for now (they move to the daemon
in the full #187 extraction). This keeps the extraction small and focused.

### What the daemon does NOT own (yet)

| Responsibility | Stays in app | Moves to daemon in #187 |
|----------------|-------------|------------------------|
| `AgentLauncher` (spawning `claude -p`) | Yes | Yes |
| `ExtractionCoordinator` / PDF backends | Yes | Yes |
| `GenerationGate` | Yes (per-window) | Yes |
| Agent config (provider, keys, permissions) | Yes | TBD |
| `wikictl` process spawning | Yes | Yes |

### Transport: XPC

The daemon communicates with the app via **XPC** — macOS-native, zero-config
for local IPC, type-safe with `@objc` protocols or `Codable` messages. No
network stack, no auth needed for localhost.

XPC is the right choice for "same-machine, same-user" and aligns with the
daemon's scope: it only serves local clients. When #187 lands, the XPC surface
either upgrades to gRPC or the daemon offers both (XPC for local, gRPC for
remote).

### Daemon lifecycle

- **Launch:** The app auto-launches `wikid` via `NSXPCConnection` on first
  use (or via `launchd` agent plist for persistence across app restarts).
- **Idle:** The daemon stays alive as long as any client has an open session.
  It can idle-exit after a timeout if no sessions are active.
- **Crash recovery:** XPC connections auto-reconnect. The daemon re-opens
  stores on demand. No persistent state beyond `wikis.json` and the SQLite
  files (which are durable on disk).

---

## 2. Daemon API surface

The daemon exposes a minimal XPC interface:

```swift
@objc protocol WikiDaemonProtocol {
    // Registry
    func listWikis(reply: @escaping ([WikiEntry]) -> Void)
    func createWiki(name: String, reply: @escaping (String) -> Void)  // returns wikiID
    func deleteWiki(id: String, reply: @escaping (Bool) -> Void)
    func renameWiki(id: String, name: String, reply: @escaping (Bool) -> Void)

    // Store lifecycle
    func openStore(wikiID: String, reply: @escaping (Bool) -> Void)
    func closeStore(wikiID: String, reply: @escaping () -> Void)

    // Change token for resync (per-wiki, per #129 event bus design)
    func changeToken(wikiID: String, reply: @escaping (UInt64) -> Void)
}
```

**Store access model:** The daemon opens the SQLite store and the app gets
direct read access to the same file via `WikiReadPool` (as it does today).
Writes go through the daemon's store instance. This avoids serializing every
read over XPC while keeping write ownership centralized.

**Event delivery:** The daemon posts Darwin notifications per wiki (the
existing `WikiChangeBridge` mechanism). Each window's `WikiChangeBridge`
subscription routes events to the correct window — same mechanism as today but
without the single-active-wiki gate.

---

## 3. Per-window state in the app

With the daemon owning registry and store lifecycle, the app becomes a
multi-window client. Each window holds per-window state:

### `WikiWindowState`

```swift
@Observable
final class WikiWindowState {
    let wikiID: String
    let store: WikiStoreModel          // read pool + write proxy to daemon
    let agentLauncher: AgentLauncher   // per-window, spawns claude -p
    let chatLauncher: AgentLauncher    // per-window
    let generationGate: GenerationGate // per-window gate
    let extractionCoordinator: ExtractionCoordinator
}
```

### Window creation via `WindowGroup(for:)`

Follow the existing `ExtractionCompareContext` pattern — mutable state is
created *inside* the per-window view as `@State`, not passed from the app
struct:

```swift
// In WikiFSApp:
WindowGroup(for: String.self) { $wikiID in
    if let wikiID {
        WikiWindowView(wikiID: wikiID, daemonConnection: daemon)
    }
}

// In WikiWindowView:
struct WikiWindowView: View {
    let wikiID: String
    let daemonConnection: WikiDaemonConnection
    @State private var windowState: WikiWindowState?

    var body: some View {
        Group {
            if let state = windowState {
                RootView(state: state)
            } else {
                ProgressView("Opening wiki…")
            }
        }
        .task {
            await daemonConnection.openStore(wikiID: wikiID)
            windowState = WikiWindowState(
                wikiID: wikiID,
                daemonConnection: daemonConnection
            )
        }
    }
}
```

Each window gets its own `@State` instance — SwiftUI guarantees per-view-identity
storage, so two windows with different `wikiID` values get independent state.

---

## 4. `WikiManager` dissolves

`WikiManager` currently owns `activeWikiID`, `activeStore`, and the wiki
registry. Under the daemon model it splits cleanly:

- **Registry role** → moves to the daemon (`listWikis`, `create`, `delete`,
  `rename`). The app queries the daemon for the wiki list.
- **Active store binding** → dissolves. There is no single "active" wiki.
  Each window holds its own `wikiID` and `store`.
- **`onActiveStoreDidChange`** → dissolves. Each window manages its own
  lifecycle.

### Consumers of `activeStore` / `activeWikiID` that must change

Every site below currently reads `manager.activeStore` or `manager.activeWikiID`.
Each must be reworked to read from the per-window `WikiWindowState` instead:

| File | Usage | Change |
|------|-------|--------|
| `RootView.swift:21` | `manager.activeStore` | Read from `state.store` |
| `ContentView.swift:235,243` | `manager.activeWikiID` | Read from `state.wikiID` |
| `SidebarView.swift:192` | `manager.activeWikiID` | Read from `state.wikiID` |
| `ChatView.swift:340,606,616,634` | `manager.activeWikiID` | Read from `state.wikiID` |
| `PagesListView.swift:389,436,440` | `manager.activeWikiID` | Read from `state.wikiID` |
| `WikiSwitcher.swift:116,121` | `manager.activeWikiID` | Read from `state.wikiID` |
| `AgentOperationRunner.swift:273,536,658` | `manager.activeWikiID` | Accept `wikiID` as parameter |
| `VacuumCommands.swift:27,30,33` | `manager.activeStore` | Read from `state.store` |
| `ExtractionCompareSheet.swift:27` | `manager.activeStore` | Read from `state.store` |
| `WikiFSApp.swift:160,174,191,205,277-283` | Various active store hooks | Move into `WikiWindowView` |

---

## 5. File Provider and Darwin notification routing

### FileProviderSpike — per-window subscription

Each `WikiWindowState` subscribes its own store's event bus to FP domain
signaling. Window A signals wiki A's domain; window B signals wiki B's domain.

### WikiChangeBridge — route to all matching windows

The bridge currently gates bus emission on `manager.activeWikiID == wikiID`.
With no single active wiki, the bridge routes to *every open window* whose
`wikiID` matches:

```
Darwin notification (wikiID: "abc") arrives
  → bridge looks up all open WikiWindowState instances with wikiID == "abc"
  → emits on each matching store's eventBus
```

**Implementation:** `WikiChangeBridge` holds a `[String: [WikiEventBus]]`
registry. Each `WikiWindowState` registers its bus on init and deregisters on
teardown.

---

## 6. WikiSwitcher UX

The existing `WikiSwitcher` toolbar item changes behavior:

- **Click** a wiki entry → opens a **new window** for that wiki via
  `openWindow(value: wikiID)`.
- **Option+click** a wiki entry → **switches** the current window to that wiki
  (tears down current `WikiWindowState`, creates a new one for the selected
  wiki).
- The current window's wiki is indicated with a checkmark; other wikis show
  no indicator (since they may or may not be open in other windows).

---

## 7. Teardown: switching and closing

When a window switches wiki (Option+click) or closes:

1. **Cancel in-flight agents.** Any running `claude` / `wikictl` processes
   spawned by the window's `AgentLauncher` must be terminated. The launcher
   already tracks child processes — call its cancellation/drain method.
2. **Flush pending saves.** `store.flushPendingSaves()` (already exists).
3. **Close daemon session.** `daemonConnection.closeStore(wikiID:)` — tells
   the daemon this window is done with the wiki. The daemon may keep the store
   open if other windows use the same wiki, or idle-close it.
4. **Deregister from WikiChangeBridge.** Remove the window's event bus from the
   bridge's routing table.
5. **Release state.** Dereference `WikiWindowState` — ARC + deinit handles
   cleanup.

This ensures no leaked agents from a previous wiki persist in a window that now
shows a different wiki.

---

## 8. Migration path to full daemon (#187)

This design is explicitly staged to carry forward:

| This design (hybrid) | Full daemon (#187) |
|----------------------|--------------------|
| `wikid` owns registry + store lifecycle | `wikid` gains agent execution, PDF extraction, ingestion |
| XPC transport | XPC → gRPC (or both: XPC local, gRPC remote) |
| App holds `AgentLauncher` per window | `AgentLauncher` moves to daemon; window gets streaming RPC |
| App spawns `claude -p` directly | Daemon spawns agents; app observes via event stream |
| Darwin notifications for change events | gRPC server-stream (#129 event bus serialized) |
| `WikiReadPool` reads SQLite directly | FP extension + app become network clients of daemon |

The per-window `WikiWindowState` survives both stages — it's always "a view
model bound to a wiki session." What changes is whether the session is XPC or
gRPC, and whether agent execution is local or daemon-side.

---

## 9. What does NOT change

- **Data layer:** Per-wiki SQLite databases, `WikiRegistry`, `wikis.json`.
- **Pipeline operations:** `ingestSources()`, query, lint are already
  store-parameterized.
- **File Provider extension:** Already per-domain, binds to one wiki via
  `domain.identifier`.
- **GenerationGate internals:** Lane-aware FIFO design is done. Multi-wiki
  instantiates one gate per window.
- **Agent config:** Provider, API keys, permission mode remain app-wide.
- **`wikictl` CLI:** No changes — already takes a wiki ID argument.

---

## 10. Key risks

| Risk | Mitigation |
|------|------------|
| API rate limits with N concurrent gates | Acceptable for 2–3 windows; add shared rate limiter later if needed |
| Leaked agent processes on window close | Explicit teardown sequence (§7) terminates child processes |
| Two windows open the same wiki | Allow it — daemon dedup: same store instance, two read pools. WAL-safe. |
| XPC complexity for a "lightweight" daemon | Keep the surface minimal (§2); XPC is battle-tested on macOS |
| Daemon crash loses in-flight writes | SQLite WAL + `flushPendingSaves` before operations minimize window. XPC auto-reconnects. |
| `ScenePhase` / lifecycle hooks assume single wiki | Audit all `.onChange(of: scenePhase)` to operate per-window |
| Daemon adds a process to manage | `launchd` agent plist handles start/restart; XPC auto-launches on first use |
