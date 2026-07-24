# XPC service migration — wikid from LaunchAgent to a bundled, sandboxed XPC service

**Status:** implemented (#887). Last updated 2026-07-23.

## Why

The LaunchAgent era ran `wikid` as a **bare Mach-O** at `Contents/Helpers/wikid`,
launched by launchd from a plist that the app *generated at runtime* and
installed via `launchctl bootstrap`. That path accumulated sharp edges:

- **AMFI vs. entitlements.** `codesign` can't embed a provisioning profile in a
  bare Mach-O, and AMFI kills a Mach-O that carries entitlements without an
  embedded profile. So the daemon had to run with **zero** entitlements and
  reach the App Group container via raw filesystem permissions — which in turn
  triggered `kTCCServiceSystemPolicyAppData` ("would like to access data from
  other apps") prompts, reset on every rebuild (the cdhash changes).
- **Stale-daemon races (#876).** `launchctl bootstrap` returns "already loaded"
  and leaves an old binary running; two daemons could then race on
  `queue.sqlite`. The workaround was a `bootout` → sleep → `bootstrap` dance on
  every app launch.
- **Runtime plist generation** (`DaemonLaunchAgentManager`, 191 LOC + 17 tests)
  to paper over per-developer container/bundle paths.

## What the migration does

Bundle `wikid` as a proper **XPC service** at
`Contents/XPCServices/wikid.xpc`. Because a `.xpc` is a *bundle*, `codesign`
embeds a provisioning profile into it (exactly as it does for the `.appex`), so
the daemon can finally carry real entitlements. The system — not launchd, not
the app — owns its lifecycle.

- **Transport.** Client: `NSXPCConnection(serviceName: "com.selfdrivingwiki.wikid")`
  (was `machServiceName:`). Daemon: `NSXPCListener.service()` (was
  `NSXPCListener(machServiceName:)`). The system resolves the service name to
  the bundled `.xpc` and auto-launches it on the first message.
- **`main.swift` ordering gotcha.** `resume()` on a service listener **never
  returns** — it hands control to the system run loop. So the startup log line
  and the #878 liveness heartbeat must be started *before* `resume()`. The
  trailing `RunLoop.current.run()` is unreachable in production (kept only as a
  fallback for direct/test invocation).
- **Signing.** `wikid.xpc` is signed inside-out (before the outer app), with an
  embedded profile + generated `build/wikid.entitlements`.

## Two deliberate posture changes

1. **The daemon does NOT survive app quit.** `ServiceType=Application` ties the
   service's lifetime to the host app; it terminates on app exit / idle.
   `ServiceType` governs *instancing + lifetime*, not sandboxing. The tradeoff:
   work in flight at quit resumes on next launch rather than continuing in the
   background. This is a deliberate reversal of the LaunchAgent behavior.

2. **The daemon IS sandboxed.** `wikid.xpc` carries
   `com.apple.security.app-sandbox`, unlike the un-sandboxed main app. It is
   confined to:
   - the shared SQLite DB via the App Group container (`application-groups`),
   - shared secrets via the keychain access group (`keychain-access-groups`),
   - the network via `com.apple.security.network.client` (LLM/ACP + URL fetch).

   **Open validation item:** the daemon runs the Phase C agent engine, which
   spawns subprocesses (`bun`, `claude` CLI, `podcast-token-helper`). Under App
   Sandbox those inherit confinement and may need additional exceptions. Verify
   on a real entitled signed build (needs `signing/wikid.provisionprofile`).

## Signing prerequisite

`signing/wikid.provisionprofile` is **required**. Without it, `build.sh` prints
a loud warning and falls back to ad-hoc signing the `.xpc` with **no**
entitlements — the daemon then runs un-sandboxed and can't reach the App Group
container or keychain, failing far from the cause. `signing/setup.sh` registers
the `com.selfdrivingwiki.wikid` App ID (with App Groups capability) and
generates the profile; `signing/README.md` documents the manual App-Group
binding step.

## Reconnection / retry (interacts with #878, #885)

- **#885 startup race.** If the initial `connectToDaemon()` fails, the app now
  starts `DaemonHealthMonitor.startRetrying()` (retry loop, immediate first
  ping) instead of silently staying on the local `QueueEngine` forever.
- **Restart Daemon menu item.** No more `launchctl kickstart`. It calls
  `DaemonHealthMonitor.forceReconnect()`: invalidate the connection and (if we
  were connected) fall back to the local engine, then kick an immediate
  reconnect — the system relaunches the `.xpc` on the next connection.
  `onDisconnect` fires **once** per disconnect (not re-fired when already
  disconnected).

## `wikictl` consequence (app-only reachability)

A bundled `.xpc` under `Contents/XPCServices/` is reachable **only from within
the host app's process** — `NSXPCConnection(serviceName:)` resolves against the
*calling* process's bundle, and the bare `wikictl` Mach-O has no `XPCServices/`
dir. Decision (2026-07-23): the GUI app is the sole client of `wikid`; headless
/ MCP / OpenAPI each run their *own* in-process engine (the engine stays
process-agnostic — that constraint is about in-process instantiability, which
this preserves). Consequences for `wikictl`:

- **`wiki` registry ops → direct access.** `list/create/delete/rename` operate
  directly on `wikis.json` + `<ulid>.sqlite` in the App Group container,
  mirroring `WikiDaemon.createWiki/deleteWiki/renameWiki`. The `page` path also
  dropped its daemon-first wiki resolution (it could only time out from the CLI).
- **Live chat retired.** `chat new/send/stop` drove streaming ACP sessions in
  the long-running daemon; a short-lived CLI can neither reach the app-bound
  service nor host a live conversation. They now fail fast ("live chat is only
  available in the app"). Read-only chat (`chat list/get/search/rename`, already
  direct-store) is untouched — `wikictl` stays a reader for chat.
- **Registry visibility.** CLI wiki create/delete/rename shows up in a running
  app on next launch (the app drives its registry in-process via
  `WikiRegistryClient`; only per-page Darwin notifications are watched). Same as
  the daemon's prior behavior — non-blocking for the CLI's scripting role.

## The `WikiDaemonContract` module (contract boundary made explicit)

The XPC *contract* was originally smeared across three modules — the two `@objc`
protocols lived in the 131-file `WikiFSCore`, and `WikiDaemonError` was mixed into
`WikiCtlCore`'s client transport. There was no single place that said "this is the
app↔daemon boundary."

Extracted a Foundation-only leaf module **`WikiDaemonContract`** holding exactly the
contract:

- `WikiDaemonProtocol` + `WikiDaemonEventSink` (the two `@objc` protocols) — moved
  from `WikiFSCore/Core/WikiDaemonProtocol.swift`.
- `WikiDaemonError` — moved from `WikiCtlCore/WikiDaemonConnection.swift`.
- `Contract.swift` — a module doc stating the boundary + why there are no DTO types
  here.

**Why no DTOs move.** Every payload crosses the wire JSON-encoded as `Data` (NSXPC
`@objc` protocols can't carry arbitrary `Codable`), so the protocol signatures
reference only `Data`/`String`/`Bool`/`Int` — no domain types. The contract module
is therefore a true leaf with zero domain coupling; the payload DTOs
(`WikiDescriptor`, `QueueItemRequest`, `AgentEvent`, `ChatStartRequest`,
`QueueSnapshot`, …) stay in `WikiFSCore`/`WikiFSEngine`, encoded/decoded by the typed
client (`WikiCtlCore`) and server (`wikid`) wrappers.

Dependency edges: `WikiDaemonContract ← { wikid (server), WikiFS (app —
DaemonQueueEventSink), WikiCtlCore (typed client) }`. `WikiFSCore` and `WikiFSEngine`
do **not** depend on it (their two references are doc comments). All source is
`#if os(macOS)`, so the module is empty on Linux and the edges are harmless there.

## Files

- `build.sh` — `wikid.xpc` bundle assembly, Info.plist (`XPC!` +
  `ServiceType=Application`), generated sandbox entitlements, inside-out signing,
  loud missing-profile fallback.
- `Sources/wikid/main.swift` — `NSXPCListener.service()`; heartbeat/log before
  `resume()`.
- `Sources/WikiCtlCore/WikiDaemonConnection.swift` — `serviceName:` connection.
- `Sources/WikiFS/Window/WikiFSApp.swift` — removed `DaemonLaunchAgentManager`;
  `configureHealthMonitor` wired before the connect attempt (#885).
- `Sources/WikiFS/Queue/DaemonHealthMonitor.swift` — `startRetrying()`,
  `forceReconnect()`, immediate-first-ping option.
- `Sources/WikiFS/Window/MenuBarItemController.swift` — Restart Daemon handler.
- `Sources/wikictl/main.swift` — `wiki` ops → direct registry access; `page`
  path drops daemon resolution; `chat new/send/stop` retired.
- `Makefile` — `install-daemon` reduced to a dev-mode binary copy.
- `signing/setup.sh`, `signing/README.md` — third (daemon) profile.
- **Deleted:** `Sources/WikiFS/Daemon/DaemonLaunchAgentManager.swift`,
  `Tests/WikiFSAppTests/DaemonLaunchAgentManagerTests.swift`,
  `signing/com.selfdrivingwiki.wikid.plist`.
