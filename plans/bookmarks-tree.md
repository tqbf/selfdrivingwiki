# Bookmarks Tab — Hierarchical Tree with Folders and Refs

## Overview

The Bookmarks sidebar section renders a user-defined tree of folders, page references,
source references, and chat references. This gives the user a topic-oriented,
persistent organizational layer on top of the flat Pages/Sources/Chats lists.

## Data Model

### Schema (v16/v17)

```sql
CREATE TABLE bookmark_nodes (
    id            TEXT PRIMARY KEY,           -- ULID
    parent_id     TEXT REFERENCES bookmark_nodes(id) ON DELETE CASCADE,
    position      INTEGER NOT NULL DEFAULT 0, -- sort order within parent
    kind          TEXT NOT NULL,              -- 'folder' | 'page_ref' | 'source_ref' | 'chat_ref'
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
- `BookmarkNodeKind` — enum: `.folder`, `.pageRef`, `.sourceRef`, `.chatRef`

### Tree Assembly (`BookmarkTreeBuilder.swift`)

Pure functions (no SwiftUI) that convert flat `[BookmarkNode]` into a
`[BookmarkTreeItem]` tree:

- `buildBookmarkTree(nodes:)` — groups by parent, sorts by position, recursively builds
- `BookmarkTreeItem` — rendered tree node with `children` (`nil` = leaf, `[]` = expandable-empty)

## WikiStoreModel Integration

- `bookmarkNodes` — flat array, rebuilt from store after mutation (§3.1 pattern)
- `bookmarkTree` — computed property that calls `buildBookmarkTree`
- Mutations: `createFolder`, `addPageRef`, `addSourceRef`, `addChatRef`, `renameBookmarkNode`, `deleteBookmarkNode`, `moveBookmarkNode`, `retargetBookmarkNode`

## UI Components

- `BookmarksContainerView` — the section container with a header bar (compact action buttons, Show/Sort menu icons, and search) and `NSOutlineView` below
- `BookmarksOutlineView` — `NSViewControllerRepresentable` wrapping `NSOutlineView` for instant selection performance
- `EditBookmarkSheet` — rename a folder or retarget a page/source/chat reference
- `ItemPickerSheet` — search-and-select sheet for adding page/source refs

## Decisions

| Decision | Choice |
|----------|--------|
| Folder content | Mixed — folders can hold page refs, source refs, and chat refs |
| Reorganization | Native NSOutlineView drag-and-drop + context menus |
| Adding refs | Header buttons + folder context menu → search picker sheet |
| Stale refs | Rendered with warning icon, not auto-deleted |

## Retarget validation

Leaf bookmark editing now supports retargeting an existing page/source/chat
reference to another typed target. Retargeting validates the destination row
inside the same store write transaction and rejects:

- missing bookmark rows
- folders passed to the retarget mutation
- missing page/source/chat targets

The edit sheet keeps the sheet open and shows the store error instead of
silently dismissing on a failed retarget.

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

## Sort and filter controls (#241)

The Bookmarks header has two menu icons in its action cluster (hidden when
no bookmarks exist):

- **Filter** (`line.3.horizontal.decrease`) — dropdown holding the "Show"
  kind filter: All / Folders / Pages / Sources / Chats, current choice
  checked. Tints accent while a non-default filter is active.
- **Sort** (`arrow.up.arrow.down`) — dropdown holding the display order:
  Custom Order / Name A–Z / Date Added / Date Updated, current choice
  checked. Tints accent while a non-default (non-manual) sort is active.

The search bar sits under the header, styled like the sibling sections. A
filter or search that matches nothing shows "No matching bookmarks".

### Display-only guarantee

Sorting never rewrites the persisted `position` column. `sortedSiblings`
(`BookmarkDisplayOrder.swift`) is a pure function over `[BookmarkNode]`; the
store takes no part in it. Custom Order is `position` ascending — exactly the
persisted drag-and-drop order, and the default. Drag-and-drop reordering
keeps working and keeps writing `position` under every sort choice.

### Semantics

| Sort | Key | Tie-break |
|------|-----|-----------|
| Custom Order | `position` ascending | — |
| Name A–Z | resolved title, localized case-insensitive | `position` ascending |
| Date Added | `createdAt` descending | `position` ascending |
| Date Updated | `updatedAt` descending | `position` ascending |

Titles resolve from folder labels and page/source/chat names. A rename that
only changes a page title (not the node row) appends the resolved title to
the outline's change signature under Name A–Z, so the next reload re-sorts.
`reloadData` builds a title index once per pass, so sorting and signature
checks stay linear.

The kind filter keeps every node of the chosen kind plus all ancestor folders,
so hits inside nested folders stay visible. Search and kind compose as one
predicate before ancestor expansion.

### Drag-and-drop gating

Under a non-manual sort the display order ignores `position`, so
between-sibling insertion is meaningless. `isReorderAllowed` gates intra-
outline moves: drop-ON-folder and root drops stay allowed (reparenting works
under every sort); leaf insertions are refused. `acceptDrop` re-checks the
gate as defense in depth, so a sort change between validate and accept
cannot smuggle a move through. Wiki-link and sidebar-payload copy drops are
unaffected — they create nodes, and the sorted view places them.

### Accepted limitations

- Filter and sort choices live in `@State` in the container, so they reset
  when the user switches sidebar sections. The Sources filter behaves the
  same way.

Under Name A–Z, `filteredNodes` reads the model title arrays even when the
search is empty, so the container's `@Observable` dependency tracks renames:
a page/source/chat rename re-renders the header and re-sorts the outline
without any node change.
