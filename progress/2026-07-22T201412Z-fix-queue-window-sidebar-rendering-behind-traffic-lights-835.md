---
timestamp: 2026-07-22T201412Z
title: "fix: Queue window sidebar rendering behind traffic lights (#835)"
branch: null
status: historical
timestamp_source: git-commit
---

# fix: Queue window sidebar rendering behind traffic lights (#835)

## Progress


**Symptom:** the Agent Queue / Extraction Queue window's sidebar `List`
rendered its first rows up into the title bar, behind the red/yellow/green
traffic-light buttons. The sidebar `List` also extends edge-to-edge under
the title bar — the hand-built `NSWindow` didn't provide the correct
title-bar inset.

**Root cause:** the Activity window was a hand-built `NSWindow`
(`MenuBarItemController.showQueueWindow`) with `toolbarStyle = .unified` +
`titleVisibility = .hidden`, hosting a `NavigationSplitView` whose `.toolbar`
carries only a trailing `.primaryAction` item. `.listStyle(.sidebar)` was
already applied (since the file's first commit `c695b55`) — it set the sidebar
*appearance* but did not establish the sidebar's top safe-area inset. With the
unified toolbar background at its default `.automatic` (transparent while
idle) and no leading/principal toolbar content, SwiftUI treated the toolbar as
floating/transparent, reserved no toolbar region, and the sidebar `List`
started at the very top of the window — behind the traffic lights. The main
wiki window (`ContentView`) avoids this implicitly via its `.navigation` +
`.principal` toolbar items.

**Fix (two-part):** (1) `.toolbarBackground(.visible, for: .windowToolbar)` on
the `NavigationSplitView` in `ActivityWindowView.swift` — pins the toolbar
background so SwiftUI reserves the toolbar region and insets the sidebar
below it. (2) Migrated the queue window from a hand-built `NSWindow` to a
scene-managed `WindowGroup(for: QueueKind.self)` in `WikiFSApp`, matching the
pattern already used for the compare windows. The system now owns the window
— title-bar inset, traffic-light clearance, frame persistence, and state
restoration all come for free. Eliminated ~120 lines of manual `NSWindow`
lifecycle code (#635's frame-autosave validation/repair machinery). PR #839.

**Verified:** `make build` ✓ + `swift test` ✓ (3499 tests, 295 suites).

## Verification

Historical verification remains in the progress record above.
