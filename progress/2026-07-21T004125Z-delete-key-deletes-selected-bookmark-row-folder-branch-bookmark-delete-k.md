---
timestamp: 2026-07-21T004125Z
title: "2026-07-20 — Delete key deletes selected bookmark row/folder (branch `bookmark-delete-key`, #744)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-20 — Delete key deletes selected bookmark row/folder (branch `bookmark-delete-key`, #744)

## Progress


**Problem.** Selecting a bookmark row/folder in the bookmarks outline and
pressing Delete/Backspace did nothing — deletion required right-click →
context menu → Delete. There was no `keyDown` / `deleteBackward` /
`deleteForward` handling on the outline view or its controller.

**Fix.** Added `deleteBackward(_:)` and `deleteForward(_:)` overrides on
`BookmarksNSOutlineView` (the existing `NSOutlineView` subclass) that
forward to a `deleteSelection()` method on `BookmarksOutlineViewController`
when a row is selected. `deleteSelection` builds the effective node list
from the outline's current selection and routes through the **same**
`deleteAction(_:)` / `onDelete` callback the context-menu "Delete" item
uses — no separate deletion path. When a text field is editing (rename), it
is the first responder and consumes `deleteBackward` itself, so Backspace
edits the name instead of deleting the bookmark. See
`plans/bookmark-delete-key.md`.

## Verification

Historical verification remains in the progress record above.
