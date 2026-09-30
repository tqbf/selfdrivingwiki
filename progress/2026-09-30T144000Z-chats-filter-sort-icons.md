---
timestamp: 2026-09-30T144000Z
title: Chats header filter and sort menu icons
branch: feature/chats-sort-filter-icons
status: complete
---

# Chats header filter and Sort by menu icons

## Progress

Completes the sidebar-header treatment for the last section (#241, #1298,
#1299, #1300, #1301): the Chats header now has filter and sort menu icons in
its action cluster, matching Pages, Sources, and Bookmarks.

- **Sort icon** (`arrow.up.arrow.down`): a dropdown that offers Last Updated
  / Newest First / Title A–Z. `ChatSortOrder` is a pure display sort over
  `[ChatSummary]`. Last Updated is the default and reproduces the store's
  native `ORDER BY updated_at DESC`, so the list order stays as today until
  the user picks another order. Title A–Z sorts on the title the row shows
  (`ChatsCellView.rowTitle`, empty title shows as "New Chat"), so the A–Z
  order matches the screen.
- **Filter icon** (`line.3.horizontal.decrease`): a "Show" date-window
  filter — All / Active Today / This Week / This Month. Chats have no kind
  dimension (`ChatKind` has one case), so activity recency is the filter
  axis. `ChatDateFilter` compares `updatedAt` (bumped on every message
  append) at calendar granularity against an injected `now` and `calendar`,
  the same shape as `PageDateFilter`. `all` (the default) returns the list
  unchanged.
- The filter and the sort do not apply during search. Search results are
  relevance-ranked by the engine. Pages and Sources follow the same rule.
- The "No matching chats" empty state now also triggers for an active date
  window that matches nothing.
- Both choices are `@State` in the container and reset on sidebar-section
  switches, like the other sections.

### The list now renders the computed rows

`ChatsListView` computed its own rows from the store
(`chatSearchQuery.isEmpty ? chats : chatSearchResults`). The container now
owns search, filter, and sort. `ChatsListView` takes
`chats: [ChatSummary]` and renders exactly that array, the same contract as
`SourcesListView.sources` and `PagesListView.pages`. This avoids the defect
the Pages header had in its first cut (#1301), where the filter narrowed
only the overlay and the rows stayed stale.

### Reveal keeps the target row visible

A sidebar reveal ("Show in Sidebar" from a chat detail view, or a bookmark
"Go to Original") must land on a visible row. `SidebarView` now drops
`chatSearchQuery` for a `.chat` reveal when the target is not in the
results, the same as it does for pages and sources. `AgentToolsView` drops
the date filter when a `.chat` reveal cannot find its row. The filter state
resets on section switch, so only the mounted case needs that reset.

## Verification

- `make build` and `make test` — green.
- `WIKIFS_APP_TESTS=1 swift test --filter ChatsSortFilterTests` — 10 tests
  pass. The sort tests cover each order, the "New Chat" title fallback in
  A–Z, and the id tie-break. The filter tests cover each window against
  fixed dates that span today, this week, the previous week, and the
  previous month, plus the `updatedAt == now` boundary.
- Menu contents cannot be driven from the `swift test` CLI host (the
  menu-tracking limitation documented in #1298). Manual eyes-on still due:
  the filter icon menu lists All / Active Today / This Week / This Month and
  narrows the list. The sort icon menu lists Last Updated / Newest First /
  Title A–Z and reorders it.
