# Multi-select pages/sources → bookmark them into a chosen folder

Implements [#151](https://github.com/tqbf/selfdrivingwiki/issues/151).

## Problem

Bookmarking was folder-first: the only path to create refs was from *inside*
the Bookmarks section (`BookmarksContainerView.onAddPage`/`onAddSource` →
`ItemPickerSheet`), where you already know the folder and pick the items. There
was no path from the Pages/Sources lists themselves — you couldn't say "I have
these 5 pages selected, drop them all into a folder."

## Design

The inverse of `ItemPickerSheet`: the item selection is fixed (a multi-row
selection from Pages/Sources), and the user picks **or creates** the destination
folder. Confirming creates one `BookmarkNode` (`pageRef`/`sourceRef`) per
selected item under the chosen folder via the existing
`WikiStoreModel.addPageRef` / `addSourceRef`.

### What was already in place

- Multi-row selection in both lists: `PagesListViewController` and
  `SourcesListViewController` already set `allowsMultipleSelection = true`, and
  their context menus already compute an "effective selection"
  (selected ∪ clicked) for batch Open/Share/Lint/Ingest.
- All store primitives existed: `createFolder(parentID:name:)`,
  `addPageRef(parentID:pageID:)`, `addSourceRef(parentID:sourceID:)`.
- `WikiStoreModel` is `@Observable`, and `bookmarkNodes` is a stored observable
  property — so a sheet that reads it re-renders automatically when
  `createFolder` calls `reloadBookmarkNodes()`.

### What was added

1. **`BookmarkNode.displayPath(id:in:)`** (`WikiFSCore/BookmarkNode.swift`) — a
   pure helper that walks the `parentID` chain to render
   `"Research / Papers"`, so same-named folders are disambiguated in the
   picker. Capped at 64 hops so a corrupted parent cycle can't hang the UI.
   Unit-tested (`BookmarkNodeDisplayPathTests`).

2. **`BookmarkTargetPickerSheet`** (`WikiFS/BookmarkTargetPickerSheet.swift`)
   + `BookmarkTargetPickerContext`. Mirrors `ItemPickerSheet`'s chrome (same
   420×480 size, same search-bar style) but:
   - Single-select (radio-style) over existing folders, not multi-select over
     items.
   - An inline "New folder name" + **Create** button that calls
     `store.createFolder(parentID: nil, name:)`, after which the new folder
     appears in the list (live `@Observable` refresh) and auto-selects.
   - Header and footer count are noun/count-aware (`Add 3 Pages to Bookmarks`
     vs. `Add Page to Bookmarks`).
   - `onConfirm` receives the chosen `parentID` (`nil` is allowed by the store
     but the sheet requires a folder selection — or a freshly created one —
     before **Add** enables).

3. **`onAddToBookmarks`** added to both `PagesListCallbacks` and
   `SourcesListCallbacks`. Wired into a new **Add to Bookmarks…** context-menu
   item in each list (after the Open group, before Share), with batch counts
   ("Add 3 Pages to Bookmarks…"). Reuses the existing
   `menuItem(_:systemImage:action:payload:)` helper + `@objc` action pattern.

4. **Sheet hosts**: `PagesContainerView` and `SourcesContainerView` each own a
   `@State private var addToBookmarksContext: BookmarkTargetPickerContext?`
   and present the sheet with `.sheet(item:)`. The confirm closure loops over
   the fixed ids calling `store.addPageRef` / `store.addSourceRef` with the
   chosen `parentID`.

## Scope

- Works for all-pages or all-sources selections (the per-list kind).
- Cross-list multi-select (some pages + some sources at once) is **out of
  scope** — it doesn't fall out naturally because the two lists are separate
  `NSTableView`s with independent selections, and the issue explicitly defers
  it.

## Tests

- `BookmarkNodeDisplayPathTests` — root label, nested join, unknown id,
  nil-label skip, parent-cycle cap (5 cases).
- Full suite green (1398 tests).
- Live UI (multi-select → context menu → sheet → inline Create → Add → refs
  appear in the Bookmarks tree) needs interactive verification — see PROGRESS.
