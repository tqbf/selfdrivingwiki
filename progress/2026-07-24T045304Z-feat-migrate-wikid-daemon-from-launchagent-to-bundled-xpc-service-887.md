---
timestamp: 2026-07-24T045304Z
title: "feat: Migrate wikid daemon from LaunchAgent to bundled XPC service (#887)"
branch: null
status: historical
timestamp_source: git-commit
---

# feat: Migrate wikid daemon from LaunchAgent to bundled XPC service (#887)

## Progress


**Goal:** eliminate the LaunchAgent-based daemon lifecycle (bare Mach-O +
runtime-generated plist + launchctl bootout/bootstrap) by bundling wikid as
a **sandboxed** XPC service at `Contents/XPCServices/wikid.xpc`. The system now
manages lifecycle (auto-launch on demand, idle termination), the binary is
always at the right path, provisioning profiles embed properly (it's a
bundle), and no LaunchAgent plist is needed.

**Intentional behavior changes (decided, not accidental):**
- **The daemon no longer survives app quit.** With a bundled `ServiceType=Application`
  XPC service, the system ties the daemon's lifetime to the host app — it
  terminates on app exit (or on idle). This is the desired posture: no
  orphaned daemon, no stale-binary races. Tradeoff: work in flight at quit
  (a long extraction/ingestion) does not continue in the background; it
  resumes on next app launch. The LaunchAgent era explicitly kept the daemon
  alive across quit; that is deliberately reversed here.
- **The daemon is now sandboxed.** Unlike the main app (which runs
  un-sandboxed because it spawns `bun`/`claude`/ACP backends and does
  arbitrary FS), `wikid.xpc` carries `com.apple.security.app-sandbox` and is
  confined: it reaches the shared SQLite DB ONLY via the App Group container
  (`application-groups`), secrets ONLY via the keychain access group, and the
  network ONLY via `com.apple.security.network.client` (for LLM/ACP + URL
  fetch). **Follow-up to validate on a real signed build:** the daemon spawns
  agent subprocesses (bun, claude CLI, podcast-token-helper); under App
  Sandbox those inherit the confinement and may need additional exceptions.

**What changed:**
- **build.sh** — wikid is bundled at
  `Contents/XPCServices/wikid.xpc/Contents/MacOS/wikid` with an Info.plist
  (`CFBundlePackageType=XPC!`, `ServiceType=Application`). Being a bundle
  means the provisioning profile embeds properly (codesign CLI can embed in
  bundles, not bare Mach-Os), so the daemon now carries `app-sandbox` +
  `network.client` + `application-groups` + `keychain-access-groups`
  entitlements — no AMFI kills, no TCC prompts. Signed inside-out before the
  outer app (same as the .appex). **The daemon provisioning profile
  (`signing/wikid.provisionprofile`) is now REQUIRED** — without it the build
  prints a loud warning and signs the `.xpc` un-sandboxed with no
  entitlements (dev fallback that cannot reach the shared container).
  `signing/setup.sh` generates the profile; `signing/README.md` documents it.
- **WikiDaemonConnection** — `NSXPCConnection(serviceName:)` instead of
  `NSXPCConnection(machServiceName:)`. The system resolves the service name
  to the `.xpc` bundle and auto-launches on first message.
- **wikid/main.swift** — `NSXPCListener.service()` instead of
  `NSXPCListener(machServiceName:)`. For bundled XPC services, the system
  provides the listener singleton; `resume()` never returns (hands control
  to the system's run loop).
- **Deleted** `DaemonLaunchAgentManager.swift` (191 LOC) + its 17 tests +
  `signing/com.selfdrivingwiki.wikid.plist`. No more runtime plist
  generation, no `launchctl bootout/bootstrap/kickstart`.
- **WikiFSApp.swift** — removed all `DaemonLaunchAgentManager` usage
  (`bootoutAndBootstrap()` in init, `daemonManager` property). The daemon
  connection is now established in `connectToDaemon()` which the system
  auto-launches on first `NSXPCConnection(serviceName:)`.
- **#885 startup race fix:** `connectToDaemon()` now starts the health
  monitor's retry loop (`startRetrying()`) if the initial connection fails,
  instead of silently staying on the local QueueEngine. The retry loop keeps
  trying — the system launches the XPC service on-demand.
- **DaemonHealthMonitor** — new `startRetrying()` (start in `.disconnected`
  state with ping loop active) + `forceReconnect()` (invalidate + reconnect;
  used by the Restart Daemon menu item).
- **MenuBarItemController** — Restart Daemon calls
  `healthMonitor.forceReconnect()` instead of `launchctl kickstart`.
- **Makefile** — `install-daemon` simplified (dev-mode binary copy to
  container dir only; no launchctl/plist plumbing).
- **wikictl (app-only consequence)** — the bundled XPC service is only
  reachable from within the host app's process, so the standalone `wikictl`
  CLI can no longer use the daemon. Rerouted its `wiki` registry ops
  (list/create/delete/rename) to **direct** `WikiRegistry` + `GRDBWikiStore`
  access against the App Group container (mirrors `WikiDaemon.createWiki`
  etc.), and dropped the daemon-first wiki resolution from the `page` path
  (it could only time out). **Retired** the live-chat commands
  (`chat new/send/stop`) — they drove streaming ACP sessions inside the
  long-running daemon, which a short-lived CLI can't host; they now fail fast
  with "live chat is only available in the app". Read-only chat
  (`chat list/get/search/rename`, already direct-store) is untouched, so
  `wikictl` stays a reader for chat. Registry-level CLI changes are visible to
  a running app on next launch (the app drives its registry in-process via
  `WikiRegistryClient`; only per-page Darwin notifications are watched) — same
  as the daemon's prior behavior.

**Tests:** 7 new tests (startRetrying/forceReconnect state transitions,
service name invariant). Full suite: 3858 tests pass. Existing daemon
invalidation tests guard on a live health check (skip gracefully in CI
without a running daemon).

**Evidence:**
- `make prompts version keychain && swift build` ✓ (35s, 0 errors)
- `swift test` ✓ (3858 tests, 0 failures)
- `swift test --filter 'DaemonHealthMonitorTests|WikiDaemonConnectionHealthTests'` ✓ (19 tests)

**Files touched:**
- `build.sh` — XPC bundle creation + signing
- `Sources/wikid/main.swift` — NSXPCListener.service() entry point
- `Sources/WikiCtlCore/WikiDaemonConnection.swift` — serviceName connection
- `Sources/WikiFS/Window/WikiFSApp.swift` — removed DaemonLaunchAgentManager, #885 retry
- `Sources/WikiFS/Queue/DaemonHealthMonitor.swift` — startRetrying + forceReconnect
- `Sources/WikiFS/Window/MenuBarItemController.swift` — Restart Daemon handler
- `Makefile` — simplified install-daemon
- `Tests/WikiFSAppTests/DaemonHealthMonitorTests.swift` — 7 new tests
- `Tests/WikiFSTests/KeychainSecretStoreTests.swift` — comment fix (XPC path)
- **Deleted:** `Sources/WikiFS/Daemon/DaemonLaunchAgentManager.swift`,
  `Tests/WikiFSAppTests/DaemonLaunchAgentManagerTests.swift`,
  `signing/com.selfdrivingwiki.wikid.plist`

---

## Verification

Historical verification remains in the progress record above.
