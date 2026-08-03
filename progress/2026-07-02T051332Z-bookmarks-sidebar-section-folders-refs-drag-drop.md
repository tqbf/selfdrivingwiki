---
timestamp: 2026-07-02T051332Z
title: "2026-07-01 — Bookmarks sidebar section (folders, refs, drag-drop)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-01 — Bookmarks sidebar section (folders, refs, drag-drop)

## Progress


A user-defined hierarchical tree of folders, page references, and source
references in a fourth sidebar tab, rendered via `NSOutlineView` for instant
selection performance. Designed and reviewed against native macOS patterns
(Apple HIG sidebar guidance); all reviewer findings (H1–H4, M1–M6, L1–L8)
addressed before merge. See [`plans/bookmarks-tree.md`](plans/bookmarks-tree.md).

- **Schema v16/v17** — `bookmark_nodes` table (self-referencing `parent_id`
  with `ON DELETE CASCADE`, `position` for ordering, `kind` for
  folder/page_ref/source_ref). Fresh-schema fast path creates at v17;
  migration ladder creates `view_nodes` (v16) then renames (v17).
- **Store CRUD** — `listBookmarkNodes`, `createBookmarkNode` (with sibling
  position shift + defense-in-depth renumber), `updateBookmarkNode`
  (label-only), `deleteBookmarkNode` (cascade + renumber), `moveBookmarkNode`
  (shift to avoid ties, renumber, **cycle prevention** via parent-chain walk).
  All renumber methods are `throws` (no `try?` swallowing).
- **Core types** — `BookmarkNode`, `BookmarkNodeKind` (`BookmarkNode.swift`);
  `BookmarkTreeBuilder.swift` with pure-logic `buildBookmarkTree()`;
  `BookmarkTreeItem` rendered-tree type.
- **Model** — `bookmarkNodes` array, `bookmarkTree` computed property; mutation
  methods (createFolder, addPageRef, addSourceRef, renameBookmarkNode,
  deleteBookmarkNode, moveBookmarkNode). `createFolder` returns the new node id.
- **UI** — `BookmarksContainerView` (header bar with compact trailing-edge
  action buttons per Apple HIG), `BookmarksOutlineView` (NSOutlineView wrapper
  with cached parent→children map, content-aware reload detection, expand-state
  preservation across reloads, native drag-and-drop with cycle-safe acceptDrop),
  `EditBookmarkSheet`, `ItemPickerSheet`, `BookmarkDestinationSheet`.
- **Tests** — `BookmarkNodeStoreTests` (schema, CRUD, cascade delete, position
  renumbering, move/reorder, stale refs, **cycle prevention** — 4 tests) +
  `BookmarkTreeBuilderTests` (tree assembly, empty folders, selection). 1248
  tests pass.

## Verification

Historical verification remains in the progress record above.
