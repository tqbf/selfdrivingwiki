---
timestamp: 2026-10-19T011646Z
title: Sidebar section sorts and filters persist across section switches
branch: fix/sidebar-filter-persistence
status: complete
---

# Sidebar section sorts and filters persist across section switches

## Progress

The Sources, Bookmarks, and Chats headers held their display sort and their
filters in view-local `@State`. `SidebarView.bookmarksOrList` is a `switch`
over the selected section. The switch tears the active section view down and
rebuilds it on every section change. A view-local `@State` died with it, so
the choice reset each time the operator switched sections and came back.
Pages did not have the bug because its sort is `store.pageSortOrder`, which
lives on the app-lifetime model.

The fix moves the five choices to `SidebarView`, above the switch, and passes
them into the section views as bindings:

- `sourceSort: SourcesContainerView.SourceSortOrder` (default `lastUpdated`)
- `bookmarkSortOrder: BookmarkSortOrder` (default `manual`)
- `bookmarkKindFilter: BookmarkKindFilter` (default `all`)
- `chatSortOrder: ChatSortOrder` (default `lastUpdated`)
- `chatDateFilter: ChatDateFilter` (default `all`)

The defaults match the former view-local defaults, so first-run behavior does
not change. The semantics stay display-only: sorting never rewrites the
store's native order or the Bookmarks `position` column, and filters never
change what the store returns.

The Chats date filter interacts with the sidebar reveal ("Show in Sidebar").
The reveal must land on a visible row, so `AgentToolsView` drops the filter
when it hides the reveal target. That drop previously ran only in
`.onChange(pendingSidebarRevealVersion)`, which covers the already-mounted
case. With a persisted filter, the switched-here case mounts fresh and never
sees the version change, so the same guard now also runs in `.onAppear`.
That check is safe against stale reveals: the pending reveal is nil unless
one is in flight, because the list consumes it once the row lands.

An earlier design put the choices on `WikiStoreModel` next to
`pageSortOrder`. That needs the enums in `WikiFSCore`, and
`ChatSortOrder.sorted` resolves titles through `ChatsCellView` — an
app-target SwiftUI view. Lifting state to `SidebarView` gives the same
lifetime without a target-layering refactor.

## Verification

- `make build` passes.
- `make test` passes (5031 tests, 537 suites, 0 failures).
- `WIKIFS_APP_TESTS=1 make test` did not complete green in this
  environment (2026-10-18, three attempts). Every attempt ended at the
  run-summary gate's deficit of one: a test bundle's runner died mid-run
  and left no crash report (this machine has prior `swiftpm-testing-helper`
  deaths on file; the gate exists to catch exactly this). Attempts one and
  two also timed out the `echoExistsWhileSubmitIsSuspended` chat test in
  `ChatOutgoingMessagesControllerTests` (and once a `WikiAppWebViewSessionTests`
  navigation test) — unrelated areas. The chat test passes in 0.001
  seconds when its suite runs alone. Attempt three ran 5068 hosted tests
  with zero failures, including `BookmarksHeaderHostedTests`, updated to
  construct `BookmarksContainerView` with `sortOrder: .constant(.manual)`
  and `kindFilter: .constant(.all)`.
- Manual: the operator checks that a sort or filter picked in one section
  still holds after switching to another section and back, and that "Show in
  Sidebar" still lands on a chat hidden by an active date filter. Hosted
  menu-interaction tests cannot drive the pickers (see the note in
  `BookmarksHeaderHostedTests`).
