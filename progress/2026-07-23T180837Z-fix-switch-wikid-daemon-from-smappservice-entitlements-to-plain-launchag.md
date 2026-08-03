---
timestamp: 2026-07-23T180837Z
title: "fix: Switch wikid daemon from SMAppService + entitlements to plain LaunchAgent"
branch: null
status: historical
timestamp_source: git-commit
---

# fix: Switch wikid daemon from SMAppService + entitlements to plain LaunchAgent

## Progress


**Goal:** AMFI killed the wikid daemon at launch because the bare Mach-O had
`application-groups` + `keychain-access-groups` entitlements but no embedded
provisioning profile — `codesign` CLI can't embed profiles in non-bundle
binaries. An unsandboxed daemon (like Paseo's) doesn't need ANY entitlements:
it reads `~/Library/Group Containers/...` directly via filesystem permissions.

**What changed:**
- **build.sh** — stripped ALL entitlements from the daemon codesign. Removed
  `WIKID_ENTITLEMENTS` generation (heredoc + variable), removed
  `--entitlements` from the daemon codesign command, added ad-hoc signing for
  wikid in the fallback path. Kept `KEYCHAIN_ACCESS_GROUP` (the APP still uses
  it for keychain access groups). Removed the plist copy to
  `Contents/Library/LaunchAgents/` (the app generates the plist at runtime).
- **`DaemonLaunchAgentManager`** (new, `Sources/WikiFS/Daemon/`) — replaces
  `SMAppService`. Generates the LaunchAgent plist at runtime with correct
  runtime paths (container dir for dev mode, app bundle for production),
  writes it to `~/Library/LaunchAgents/`, bootstraps via
  `launchctl bootstrap gui/<uid> <path>`, restart via
  `launchctl kickstart gui/<uid>/com.selfdrivingwiki.wikid`. The daemon
  survives app quit (launchd manages it independently — KeepAlive + RunAtLoad).
- **WikiFSApp.swift** — removed `import ServiceManagement`, replaced
  `SMAppService.agent(plistName:).register()` with
  `DaemonLaunchAgentManager.bootstrap()`. The `unregisterDaemon` hook is now a
  no-op (daemon survives quit); the hook stays so the terminate flow is
  unchanged.
- **MenuBarItemController.swift** — removed `import ServiceManagement`;
  `restartDaemon` now calls `DaemonLaunchAgentManager.restart()` (launchctl
  kickstart) via an injected `daemonRestartHandler` closure.
- **signing/com.selfdrivingwiki.wikid.plist** — switched from `BundleProgram`
  (SMAppService-specific) to `ProgramArguments` with a shell wrapper that
  finds the daemon binary (container dir || app bundle). Added `RunAtLoad`.
- **Makefile** — updated `install-daemon` to match the new plist format (no
  more `BundleProgram` removal), no more entitlements generation/signing, uses
  `launchctl bootstrap/bootout` (modern API) instead of `load/unload`.

**Tests:** `DaemonLaunchAgentManagerTests` (17 tests) — plist structure,
serialization, path construction, shell command, install-to-disk, and
crash-safety of bootstrap/restart in a non-launchd environment. Full suite
(3803 tests) passes.

**Files touched:**
- `Sources/WikiFS/Daemon/DaemonLaunchAgentManager.swift` — NEW
- `Tests/WikiFSAppTests/DaemonLaunchAgentManagerTests.swift` — NEW
- `Sources/WikiFS/Window/WikiFSApp.swift` — SMAppService → DaemonLaunchAgentManager
- `Sources/WikiFS/Window/MenuBarItemController.swift` — SMAppService → launchctl kickstart
- `build.sh` — strip daemon entitlements, remove plist bundling
- `Makefile` — update install-daemon for new plist format
- `signing/com.selfdrivingwiki.wikid.plist` — BundleProgram → ProgramArguments

## Verification

Historical verification remains in the progress record above.
