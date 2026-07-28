---
timestamp: 2026-07-05T025317Z
title: "2026-07-04 — Multi-select pages/sources → bookmark them all into a chosen folder (#151)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-04 — Multi-select pages/sources → bookmark them all into a chosen folder (#151)

## Progress


Bookmarking was folder-first: the only entry point was from inside the Bookmarks
section (`BookmarksContainerView.onAddPage`/`onAddSource` → `ItemPickerSheet`),
where the folder is known and you pick items. There was no path from the
Pages/Sources lists — you couldn't bookmark a multi-row selection in one gesture.
Implements [#151](https://github.com/tqbf/selfdrivingwiki/issues/151).

- **`onAddToBookmarks` callback + "Add to Bookmarks…" menu item** — both
  `PagesListCallbacks` and `SourcesListCallbacks` gain an `onAddToBookmarks`
  closure; both lists add an **Add to Bookmarks…** context-menu item after the
  Open group, batch-count-aware ("Add 3 Pages to Bookmarks…"). Reuses the
  existing effective-selection logic (selected ∪ clicked) and `@objc` action
  pattern — multi-select was already wired in the `NSTableView`s.
- **`BookmarkTargetPickerSheet`** (`WikiFS/BookmarkTargetPickerSheet.swift`,
  new) — the inverse of `ItemPickerSheet`: the item selection is fixed and the
  user picks-or-creates the destination folder. Single-select (radio-style)
  over existing folders; an inline "New folder name" + Create button calls
  `store.createFolder(parentID: nil, name:)`, after which the new folder
  appears immediately (live `@Observable` refresh of `bookmarkNodes`) and
  auto-selects. Header/footer are noun+count-aware. Confirming calls
  `onConfirm(parentID)`; the container loops the fixed ids through
  `store.addPageRef` / `store.addSourceRef`. Mirrors `ItemPickerSheet`'s chrome
  (420×480, same search-bar style) for visual consistency.
- **`BookmarkNode.displayPath(id:in:)`** (`WikiFSCore/BookmarkNode.swift`) — a
  pure helper walking the `parentID` chain to render `"Research / Papers"` so
  same-named folders disambiguate in the picker. Capped at 64 hops so a
  corrupted parent cycle can't hang the UI.
- **Sheet hosts** — `PagesContainerView` and `SourcesContainerView` each own a
  `@State addToBookmarksContext: BookmarkTargetPickerContext?` and present the
  sheet via `.sheet(item:)`.
- **Tests** — `BookmarkNodeDisplayPathTests` (5 cases: root label, nested join,
  unknown id, nil-label skip, parent-cycle cap). Full suite green: 1398 tests.
- **Docs** — added `plans/multi-select-bookmark.md`; indexed it in `PLAN.md`;
  corrected the stale `BookmarkDestinationSheet` aspirational name in the
  bookmarks-tree row to the real `BookmarkTargetPickerSheet`.
- **Not yet verified live** — the interactive flow (multi-select → context menu
  → sheet → inline Create → Add → refs appear in the Bookmarks tree) compiles
  and passes tests but needs a human to click through it in the running app;
  no schema change so no migration risk.

## Verification

Historical verification remains in the progress record above.
