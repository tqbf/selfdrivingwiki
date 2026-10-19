---
timestamp: 2026-10-19T011646Z
title: Sidebar section sorts persist across section switches
branch: fix/sidebar-sort-persistence
status: complete
---

# Sidebar section sorts persist across section switches

## Progress

The Sources, Bookmarks, and Chats headers held their display sort in a
view-local `@State`. `SidebarView.bookmarksOrList` is a `switch` over the
selected section. The switch tears the active section view down and rebuilds
it on every section change. A view-local `@State` died with it, so the sort
reset each time the operator switched sections and came back. Pages did not
have the bug because its sort is `store.pageSortOrder`, which lives on the
app-lifetime model.

The fix moves the three sorts to `SidebarView`, above the switch, and passes
them into the section views as bindings:

- `sourceSort: SourcesContainerView.SourceSortOrder` (default `lastUpdated`)
- `bookmarkSortOrder: BookmarkSortOrder` (default `manual`)
- `chatSortOrder: ChatSortOrder` (default `lastUpdated`)

The defaults match the former view-local defaults, so first-run behavior does
not change. The sort semantics are display-only and did not change. The
Bookmarks kind filter and the Chats date filter stay view-local on purpose:
the report was about sort, and both filters have reveal flows that reset them
deliberately.

An earlier design put the sorts on `WikiStoreModel` next to
`pageSortOrder`. That needs the sort enums in `WikiFSCore`, and
`ChatSortOrder.sorted` resolves titles through `ChatsCellView` — an
app-target SwiftUI view. Lifting state to `SidebarView` gives the same
lifetime without a target-layering refactor.

## Verification

- `make build` passes.
- `make test` passes (4661 tests, 478 suites).
- `WIKIFS_APP_TESTS=1 make test` passes, including the hosted
  `BookmarksHeaderHostedTests`, updated to construct
  `BookmarksContainerView` with `sortOrder: .constant(.manual)`.
- Manual: the operator checks that a sort picked in one section still holds
  after switching to another section and back. Hosted menu-interaction tests
  cannot drive the pickers (see the note in `BookmarksHeaderHostedTests`).
