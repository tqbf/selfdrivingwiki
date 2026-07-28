---
timestamp: 2026-07-26T203531Z
title: "fix: menu-bar wiki selection opens the typed wiki scene"
branch: null
status: historical
timestamp_source: git-commit
---

# fix: menu-bar wiki selection opens the typed wiki scene

## Progress


**Bug.** The status menu stored `WikiID` in each wiki item’s
`representedObject`, but `openWikiWindow(_:)` cast it to `String`, so every
click returned at the guard. A second mismatch remained behind it:
`OpenWindowBridge` transported raw `String` values while the actual scene is
`WindowGroup(for: WikiID.self)`, so even a successful cast would target no
registered scene.

**Fix.** `OpenWindowBridge.openWiki` now carries `WikiID` end-to-end. The
status-menu action casts the represented object to `WikiID`, and reopen plus
Activity-window navigation callers pass the typed ID directly. This matches the
existing scene identity and prevents future raw-string routing mistakes at
compile time. The pre-existing `WindowMenuCommands` implementation remains the
native window list: visible wiki windows are listed after Window ▸ Bring All to
Front using their registry display names and focus when selected.

**Tests.** Added a Swift Testing regression that builds the real AppKit status
menu, dispatches the wiki item’s target/action, and verifies the exact `WikiID`
reaches the window bridge. `swift build --build-tests` and
`swift test --filter MenuBarItemMaintenanceMenuTests` pass (2 tests).

## Verification

Historical verification remains in the progress record above.
