# Bookmarks Tab — Hierarchical Tree with Folders and Refs

## Overview

The Bookmarks sidebar section renders a user-defined tree of folders, page references,
and source references. This gives the user a topic-oriented, persistent organizational
layer on top of the flat Pages/Sources lists.

## Data Model

### Schema (v16/v17)

```sql
CREATE TABLE bookmark_nodes (
    id            TEXT PRIMARY KEY,           -- ULID
    parent_id     TEXT REFERENCES bookmark_nodes(id) ON DELETE CASCADE,
    position      INTEGER NOT NULL DEFAULT 0, -- sort order within parent
    kind          TEXT NOT NULL,              -- 'folder' | 'page_ref' | 'source_ref'
    label         TEXT,                       -- folder name; NULL for refs
    target_id     TEXT                        -- page/source id for refs; NULL otherwise
);
CREATE INDEX bookmark_nodes_parent ON bookmark_nodes(parent_id, position);
```

> The migration ladder creates this as `view_nodes` (v16) then renames to
> `bookmark_nodes` (v17). The fresh-schema fast path creates `bookmark_nodes`
> directly at v17.

### Model Types (`BookmarkNode.swift`)

- `BookmarkNode` — one row in the table (id, parentID, position, kind, label, targetID)
- `BookmarkNodeKind` — enum: `.folder`, `.pageRef`, `.sourceRef`

### Tree Assembly (`BookmarkTreeBuilder.swift`)

Pure functions (no SwiftUI) that convert flat `[BookmarkNode]` into a
`[BookmarkTreeItem]` tree:

- `buildBookmarkTree(nodes:)` — groups by parent, sorts by position, recursively builds
- `BookmarkTreeItem` — rendered tree node with `children` (`nil` = leaf, `[]` = expandable-empty)

## WikiStoreModel Integration

- `bookmarkNodes` — flat array, rebuilt from store after mutation (§3.1 pattern)
- `bookmarkTree` — computed property that calls `buildBookmarkTree`
- Mutations: `createFolder`, `addPageRef`, `addSourceRef`, `renameBookmarkNode`, `deleteBookmarkNode`, `moveBookmarkNode`

## UI Components

- `BookmarksContainerView` — the section container with a header bar (compact action buttons) and `NSOutlineView` below
- `BookmarksOutlineView` — `NSViewControllerRepresentable` wrapping `NSOutlineView` for instant selection performance
- `EditBookmarkSheet` — rename a folder
- `ItemPickerSheet` — search-and-select sheet for adding page/source refs

## Decisions

| Decision | Choice |
|----------|--------|
| Folder content | Mixed — folders can hold page refs and source refs |
| Reorganization | Native NSOutlineView drag-and-drop + context menus |
| Adding refs | Header buttons + folder context menu → search picker sheet |
| Stale refs | Rendered with warning icon, not auto-deleted |

## Non-goals

- Dynamic views / saved searches (`.dynamic` kind was cut — store + tree builder + UI were simplified)
- Adding refs from the Pages/Sources sidebar context menu
- `wikictl` CLI commands for bookmark-node CRUD

## File Provider projection (#129 slice 2b Phase D, shipped)

Bookmarks now project to the File Provider mount as a read-only `bookmarks/`
tree mirroring the sidebar structure:

- Folders → directories (`bookmark-folder:<ULID>`)
- Page refs → `<title>.md` files serving the target page's content
  (`bookmark-page-ref:<ULID>`)
- Source refs → `<filename>` files serving the target source's bytes
  (`bookmark-source-ref:<ULID>`)
- Stale refs (target deleted) → small placeholder files preserving tree shape

A `NestedResourceProjection` descriptor drives all dispatch (`node`/`children`/
`contents`/working set). A `BookmarkTokenContributor` appends a
`bookmark_nodes` count fold to the change token so any mutation re-fetches.
No schema change (the existing `bookmark_nodes` table is read as-is).
