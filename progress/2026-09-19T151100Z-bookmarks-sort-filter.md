---
timestamp: 2026-09-19T151100Z
title: Bookmarks header sort and filter controls (#241)
branch: feature/bookmarks-sort-filter
status: complete
---

# Bookmarks header sort and filter controls (#241)

## Progress

The Bookmarks header gained a "Show" kind-filter picker (All / Folders /
Pages / Sources / Chats) and a "Sort by" picker (Custom Order / Name A–Z /
Date Added / Date Updated). They copy the Sources filter row and the Pages
sort row exactly. Both rows show only when at least one bookmark exists, the
same gate as the search bar.

Sorting is display-only. New `BookmarkSortOrder.sortedSiblings` is a pure
function over `[BookmarkNode]`; it never touches the store or the persisted
`position` column. `BookmarksOutlineViewController.reloadData` applies it
per sibling group when it rebuilds the tree. Custom Order stays the default
and renders the persisted order directly.

Other decisions worth recording:

- `filterNodes` gained a `kindFilter` parameter with a default of `.all`, so
  the existing search call sites and tests compile unchanged. The ancestor
  walk moved into a `visibleNodes(matching:)` core; search and kind compose
  as one predicate before expansion.
- Under Name A–Z, the outline's change signature includes the resolved
  title, so a page rename (which changes only `store.summaries`) still
  invalidates the tree. `buildTitleIndex(for:)` builds the titles once per
  reload pass, so sorting and signature checks stay linear.
- Drag gating: under a non-manual sort, between-sibling moves are refused;
  drop-ON-folder and root drops stay allowed (reparenting works under every
  sort). `acceptDrop` re-checks the gate as defense in depth. Copy drops
  (wiki links, sidebar payloads) are untouched.
- Sort and filter choices live in `@State` in the container, like the
  Sources filter. They reset when the user switches sidebar sections.

### Hosted test contingency

The plan's primary AC.9 check (drive the mounted pickers) is not drivable
from the `swift test` CLI host: SwiftUI fills an NSPopUpButton's menu lazily,
and every route into menu tracking wedges the host — the nested run loop
never releases without a real user event. Programmatic text edits also never
reach the SwiftUI search state. Per the plan's flagged contingency, the
picker menu-item titles, the "Name A–Z" selection reorder, the filter empty
state, and the "No matching bookmarks" overlay render fall to a manual
operator check. The hosted suite still asserts, automatically: both pickers
mount when bookmarks exist, both disappear when the store is empty, and the
default outline renders position order.

## Verification

- `WIKIFS_APP_TESTS=1 swift test --filter "<the seven new suites>"` — 32
  tests, all pass (pure sort/filter, reorder gate matrix, direct-VC ordering,
  drag wiring with an `NSDraggingInfo` stub, store-backed rename re-sort,
  hosted header checks).
- `WIKIFS_APP_TESTS=1 swift test --filter "BookmarksSearchTests|BookmarksMultiSelectMenuTests"`
  — 25 tests pass, unmodified.
- `make build` — green.
- Full `make test` — see the PR; run before opening it.
- Manual operator check (flagged contingency): the picker menu contents,
  "Name A–Z" reorder from the mounted header, filter empty state, and the
  "No matching bookmarks" overlay.
