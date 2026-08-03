# Plan: Dragging a bookmark folder into another folder moves it, doesn't copy (#743)

## Goal
Dragging a bookmark **folder** onto another folder in the bookmarks outline
should **move** the folder (the folder node itself becomes a child of the
target). Today it instead recreates every leaf (page/source/chat ref) under
the folder as new bookmarks in the target — leaving the original folder in
place — effectively a copy-by-contents.

## Root cause (from issue #743)
In `Sources/WikiFS/Bookmarks/BookmarksOutlineView.swift`:

- `pasteboardWriterForItem` (L335-350) writes **two** representations for a
  folder drag: the private `com.selfdrivingwiki.bookmark-node-id` type (for
  intra-tree move/reorder) AND a `SidebarDragPayloadList` of every leaf
  reachable under the folder, via `leafPayloads(under:)` (L346, L354-361). The
  payload list is a deliberate feature for dropping a folder onto the
  **welcome screen** to open its contents as tabs (#150).
- `validateDrop` (L506-543) and `acceptDrop` (L545-593) both check
  `firstSidebarPayload(from:)` **before** falling through to the private
  bookmark-node-id move/reorder path. Because a folder's pasteboard item
  always carries a `SidebarDragPayloadList`, `firstSidebarPayload` returns
  non-nil for a folder drag onto ANY target — including another bookmark folder
  in the same outline — so it takes the "sidebar-item drop → create a bookmark
  for each payload" branch (`acceptSidebarPayloadDrop`) and never reaches
  `moveAll(toParentID:startingAt:)` / `store.moveBookmarkNode(...)`.

The correct intra-tree move path (`moveAll`, L572-580, which handles "drop node
onto folder" at L582-583) is only reached for leaf refs, never for folders,
because folders never pass the sidebar-payload check.

## Fix (the ordering fix the issue proposes)
`validateDrop`/`acceptDrop` must distinguish:

- **Drop onto the bookmarks outline itself** (same outline) → prefer the
  **intra-tree bookmark-node-id move** path when the drag originated from the
  outline; never interpret a folder drag within the outline as a
  sidebar-payload drop.
- **Drop onto an external target** (e.g. the welcome screen) → the
  `SidebarDragPayloadList` is the right interpretation (keep this working —
  it's the #150 feature).

Concretely: when the drop target is the bookmarks outline AND the drag's
pasteboard carries the private `bookmarkNodeID` type (i.e. the drag originated
from this outline), check `bookmarkNodeID`/use the move path **first**, and
only fall back to `firstSidebarPayload` when the drag is external (no
`bookmarkNodeID` type, or `draggingSource` is not the outline).

Signals verified in the code:

- The `bookmarkNodeID` pasteboard type presence is the cleanest "drag
  originated from this outline" signal (`SidebarDragPasteboardItem` only sets
  it for bookmark rows, and it's the `com.selfdrivingwiki.bookmark-node-id`
  private UTType).

## Implementation notes

- The store's `moveBookmarkNode`
  (`Sources/WikiFSCore/Store/GRDBWikiStore.swift:5621`) already rejects moving
  a node into itself or any of its descendants (cycle prevention at L5635-
  5647), so a folder-into-own-descendant drop is a safe no-op at the store
  level. We additionally guard in `validateDrop` to advertise `[]` for that
  case so the cursor gives no drop affordance.

## Guardrails / non-regressions
- **Do NOT break the welcome-screen drop (#150):** dropping a folder onto the
  welcome screen must still open its leaf contents as tabs. That target is NOT
  the outline, so the "external target → sidebar payload" branch must still
  fire. Verify with the #150 behavior in the running app.
- Do NOT change `pasteboardWriterForItem` / `leafPayloads` — the pasteboard
  writer is correct (both representations are needed for the two distinct drop
  targets). The bug is purely in `validateDrop`/`acceptDrop` ordering.
- Keep leaf (page/source) drags working exactly as today (they already hit
  the move path correctly).
- No `print` — `DebugLog` only; no bare `try?`.

## Files
- `Sources/WikiFS/Bookmarks/BookmarksOutlineView.swift` — reorder the
  `validateDrop` (L506-543) and `acceptDrop` (L545-593) checks so an
  intra-outline drag (pasteboard carries `bookmarkNodeID`) takes the move path
  before the sidebar-payload path.

## Build/test
`make build && make test`. This is a drag-drop/outline behavior — NOT unit-
testable; validate in the running app (`make run`):

1. Drag a folder onto another folder → folder **moves** (original gone from
   old parent, now under the target).
2. Drag a leaf bookmark onto a folder → still moves (regression-safe).
3. Drag a folder onto the welcome screen → still opens its contents as tabs
   (regression-safe #150).
4. Drag a folder into one of its own descendants → no-op (no corruption).

Push the branch, open a PR with `Closes #743`. **Do NOT merge to main.**
