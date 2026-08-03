# Plan: Delete key on selected bookmark deletes it (#744)

## Goal
Selecting a bookmark row/folder in the bookmarks outline and pressing **Delete** or **Backspace** should delete it — the standard macOS convention for deleting a selected item in a list/outline. Today it does nothing; deletion requires a right-click → context menu → Delete.

## Current state
- `Sources/WikiFS/Bookmarks/BookmarksOutlineView.swift:834-836` — `deleteAction(_:)` is the existing `@objc` action wired to the context menu's "Delete" item and a `onDelete` callback. It already does the right thing (deletes the current selection). Reuse it — do NOT write a new deletion code path.
- There is **no** `keyDown(with:)` / `deleteBackward(_:)` / `deleteForward(_:)` handling on the outline view or its controller, so the Delete/Backspace keys are unhandled.

## Fix
Add keyboard handling that invokes the existing `deleteAction(_:)` (or the `onDelete` callback it calls) when Delete/Backspace is pressed on the current selection. Idiomatic AppKit options (pick the one that fits the existing structure — read the view/controller setup first):
- Override `keyDown(with:)` on the `NSOutlineView` subclass (if there is one) or the hosting `NSViewController`, and when `event.specialKey == .delete` (or `event.charactersIgnoringModifiers` is `"\u{7f}"` / `"\u{08}"`), forward to `deleteAction(_:)` gated on a non-empty `selectedRowIndexes` / `selectedRow != -1`.
- OR override `deleteBackward(_:)` (the responder-chain action for the Backspace key in lists) and call `deleteAction(_:)`; that's the more "macOS-native" path (binding the Delete command) and avoids raw key-event parsing.
- Prefer `deleteBackward(_:)` if the outline view is a responder and the existing pattern is action-based (no key-event parsing); fall back to `keyDown` if the responder chain isn't set up.

## Guardrails
- **Only invoke the existing `deleteAction(_:)`** — do not reimplement deletion. The bug is "no key binding," not "delete is broken."
- Only fire on a non-empty selection; if `selectedRow == -1`, do nothing (fall through to default).
- Must not fire on a text-edit field (there's a bookmark rename/edit text field — Backspace should edit there, not delete). If a text field is the first responder, the event must reach it first (responder-chain `deleteBackward` naturally handles this, which is another reason to prefer it).
- No `print` — use `DebugLog` if any diagnostic is needed (house rule).
- No bare `try?` (house rule).
- This is a keyboard/responder behavior — NOT unit-testable. Validate in the running app (`make run`): select a bookmark → Delete → it's gone; select a folder → Delete → folder + children gone; rename a bookmark → Backspace edits the name (does NOT delete).

## Files
- `Sources/WikiFS/Bookmarks/BookmarksOutlineView.swift` — add the `deleteBackward(_:)` (or `keyDown`) override calling `deleteAction(_:)`, gated on selection. (If there's an outline-view subclass already, add it there; else on the hosting controller.)

## Build/test
`make build && make test`. Push the branch, open a PR with `Closes #744`. **Do NOT merge to main.** Scratch in `tmp/` inside your own worktree.
