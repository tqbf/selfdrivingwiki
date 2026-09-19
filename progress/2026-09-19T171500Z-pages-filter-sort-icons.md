---
timestamp: 2026-09-19T171500Z
title: Pages header filter and sort menu icons
branch: feature/pages-sort-filter-icons
status: complete
---

# Pages header filter and Sort by menu icons

## Progress

Completes the sidebar-header treatment (#241, #1298, #1299, #1300): the
Pages section now has filter and sort menu icons in its header action
cluster, matching the other sections.

- **Sort icon** (`arrow.up.arrow.down`): the former "Sort by" caption row
  (Last Updated / Newest First / Title A–Z, bound to
  `store.pageSortOrder`) moved into a dropdown. Model-level sort, the store
  re-queries — behavior unchanged. The icon tints accent while a non-default
  (non-Last Updated) sort is active.
- **Filter icon** (`line.3.horizontal.decrease`): new "Show" date-window
  filter — All / Edited Today / This Week / This Month — chosen because
  `WikiPageSummary` carries only title + dates (no author, flags, or
  source-count for a content filter). Display-only: `PageDateFilter` is a
  pure predicate over `updatedAt` compared at calendar granularity against
  an injected `now` and `calendar`, so the windows are unit-testable with
  fixed dates. `all` (the default) returns the list unchanged.
- The filter does not apply during search: search results are
  relevance-ranked by the engine (the same rule the sort follows and the
  Sources header uses). The "No matching pages" empty state now also
  triggers for an active date window that matches nothing.
- Both icons are always visible (the former rows were always visible).
  Both choices are `@State` and reset on sidebar-section switches, like the
  other sections.

## Verification

- `make build` and `make test` — green.
- `WIKIFS_APP_TESTS=1 swift test --filter PagesDateFilterTests` — 5 tests
  pass (each window against fixed dates spanning today / this week /
  previous week / previous month, `updatedAt == now` boundary).
- Manual eyes-on (menu contents can't be driven from the `swift test` CLI
  host, the menu-tracking limitation documented in #1298): the filter
  icon's menu lists All / Edited Today / This Week / This Month and narrows
  the list; the sort icon's menu lists Last Updated / Newest First /
  Title A–Z and reorders it.
