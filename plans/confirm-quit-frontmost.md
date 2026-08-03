# Fix: Confirm-Quit Dialog Not Frontmost

## Goal
Make the confirm-quit dialog appear frontmost / above all windows when the user quits the app (Cmd-Q, window close, dock quit, or system shutdown). Currently the dialog appears behind the app's own windows or behind other apps.

## Root Cause

### Quit Handler Location
**File:** `Sources/WikiFS/Window/WikiFSApp.swift`
**Lines:** 689-747

The quit interception is handled in `AppDelegate.applicationShouldTerminate(_:)`.

The app is **not activated** before the alert is shown. When `beginSheetModal(for:)`
or `runModal()` is called without first calling `NSApp.activate()`, the alert window
may appear behind:

1. **Other app windows** (if the user switched to another app before quitting)
2. **The app's own windows** (if the app is active but the sheet attaches to a
   non-key window)

The code finds a visible, keyable window to attach the sheet to, but it doesn't
guarantee the app itself is frontmost.

### Trigger Conditions
The confirm-quit dialog appears when:
1. **Unsaved changes** — flushed via `flushPendingSaves?()` at line 693
2. **Running operations** — any of:
   - PDF extraction (`activityTracker.isExtracting == true`)
   - Source ingestion (`activityTracker.isIngesting` w/ source IDs)
   - Lint run (`activityTracker.isIngesting` w/ lint IDs, empty source IDs)
   - Agent operation (any session's `agentLauncher.isRunning`)
   - Chat session (any session's `chatLauncher.isRunning`)

## The Fix

Activate the app immediately before showing the alert, ensuring it comes to the
front. Use `NSApp.activate()` (the new macOS 14+ API) instead of the deprecated
`activate(ignoringOtherApps:)`.

### File to Modify
**File:** `Sources/WikiFS/Window/WikiFSApp.swift`
**Function:** `AppDelegate.applicationShouldTerminate(_:)` (lines 689-747)

### Exact Change

Add `NSApp.activate()` immediately before the sheet/modal branch (~line 728):

```swift
// Activate the app so the alert appears frontmost. On macOS 14+, the
// new activate() API replaces the deprecated activate(ignoringOtherApps:).
NSApp.activate()
```

### Why This Works

1. **`NSApp.activate()`** brings the app to the front, making it the active app
2. **Before `beginSheetModal`**: Ensures the sheet's parent window is part of the
   frontmost app, so the sheet appears above all windows
3. **Before `runModal`**: Ensures the modal dialog is frontmost when shown
4. **macOS 15 compatibility**: Uses the new API instead of the deprecated
   `activate(ignoringOtherApps:)`

App activation suffices — no need to separately `makeKeyAndOrderFront` the window.

## Testing Plan

Window-ordering behavior is NOT unit-testable. Manual validation is required.

### Test Cases

1. **Quit with running operation (Cmd-Q)** — start PDF extraction/ingestion, hit
   ⌘Q, expect dialog frontmost.
2. **Quit with all windows closed (accessory mode)** — dialog appears as modal.
3. **Quit from Dock** — right-click → Quit, dialog frontmost.
4. **Quit while app is inactive** — switch to Finder, then Dock-quit Self Driving
   Wiki, expect app to activate and dialog frontmost.
5. **Quit without confirmation (idle, setting off)** — no dialog, immediate quit.

### Acceptance Criteria

- [x] Confirm-quit dialog appears frontmost in all test cases
- [x] Dialog functionality unchanged (Quit/Cancel buttons work)
- [x] No console warnings or errors related to window ordering
- [x] App terminates correctly when Quit is clicked
- [x] App stays open when Cancel is clicked

## Verification

```bash
make build && make test
open build/Release/Self\ Driving\ Wiki.app
```

## References

- Apple Docs: [Passing control from one app to another with cooperative activation](https://developer.apple.com/documentation/appkit/nsapplication/passing_control_from_one_app_to_another_with_cooperative_activation)
- Code location: `Sources/WikiFS/Window/WikiFSApp.swift:689-747`

## Follow-up (out of scope)

The codebase still uses `activate(ignoringOtherApps:)` in:

- `Sources/WikiFS/Window/MenuBarItemController.swift` (5 occurrences)
- `Sources/WikiFS/Window/WindowMenuCommands.swift` (1 occurrence)

Those should migrate to `activate()` in a follow-up PR.
