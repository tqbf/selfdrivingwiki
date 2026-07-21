# Plan: Mouse button 5 ("back" side button) navigates back (#741)

## Goal
Standard mice with back/forward side buttons should trigger in-app back/forward navigation, the same way trackpad two-finger swipe already does. Today a physical back button on the mouse does nothing.

## Current state
`Sources/WikiFS/Window/SwipeNavigation.swift`:
- Installs an `NSEvent.addLocalMonitorForEvents(matching: .scrollWheel)` monitor (~L71) that calls `navigateBack?()` / `navigateForward()` (~L120) off swipe gestures.
- There is **no** monitor for `.otherMouseDown` / `NSEvent.buttonNumber`, so the standard AppKit signal for mouse back/forward side buttons is never observed.

The store methods to call: `WikiStoreModel.navigateBack()` / `navigateForward()` (already wired into the `navigateBack`/`navigateForward` closure properties by `SwipeNavigationModifier.body`).

## Fix
Add an `NSEvent` local monitor for `.otherMouseDown` (installed alongside the existing scroll-wheel monitor, in the same `start()`/`stop()` lifecycle) that:
- Checks `event.buttonNumber` for the conventional back (3) / forward (4) side buttons.
  - AppKit `buttonNumber` is 0-indexed; the mouse-vendor "button 4/5" map to AppKit `buttonNumber` 3 / 4.
- Calls `navigateBack?()` for button 3, `navigateForward?()` for button 4 — the same callbacks the swipe path calls (single source of truth for navigation).
- Returns `nil` from the monitor closure when it consumed the event (so it doesn't propagate); returns `event` unchanged otherwise.
- Gate: only navigate when the corresponding `canGoBack`/`canGoForward` is true (mirrors the swipe path's guard).

## Guardrails
- **Reuse the existing `navigateBack` / `navigateForward` callbacks** — do NOT call store methods directly; that would diverge from the swipe path. Single seam.
- **Match the swipe monitor's lifecycle** — install in the same `start()`/`stop()` so the mouse monitor is torn down when swipe nav is. Do NOT leak an event monitor.
- `.otherMouseDown` (not `.leftMouseDown`/`.rightMouseDown`) is correct: side buttons deliver as "other mouse" events in AppKit.
- Don't break trackpad swipe (the scroll-wheel path is untouched).
- No `print` (DebugLog if a diagnostic is needed); no bare `try?`.

## Files
- `Sources/WikiFS/Window/SwipeNavigation.swift` — add the `.otherMouseDown` local monitor alongside the scroll-wheel monitor, check `buttonNumber` 3/4, call the existing navigate callbacks.

## Build / test / validation
`make build && make test`. NOT unit-testable (hardware input). Validate in the running app (`make run`): navigate into a page; press the mouse back side button → goes back; forward button → goes forward; trackpad two-finger swipe still works (regression). Push the branch, open a PR with `Closes #741`. **Do NOT merge to main.** Scratch in `tmp/` inside your own worktree.
