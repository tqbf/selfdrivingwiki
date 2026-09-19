---
timestamp: 2026-09-19T160000Z
title: Sources header filter icon and Sort by control
branch: feature/sources-filter-icon
status: complete
---

# Sources header filter icon and Sort by control

## Progress

Follow-up to the Bookmarks header conversion (#241, PR #1298): the Sources
sidebar header's "Show" caption row (All / Ready / Processed) is now a
filter icon in the header's action cluster, trailing-most after "Add
Folder…". The icon opens a dropdown menu holding the three filter choices
with the current one checked — the same `Menu { Picker(.inline) }` pattern
as the Bookmarks header. The icon tints accent while a non-All filter is
active, and returns to secondary at All.

Unlike the Bookmarks icons, this one is always visible: the Sources "Show"
row was never gated on list contents, so the conversion preserves that
behavior. The search bar and its position are unchanged. The container's
doc comment no longer describes a filter picker row.

No plan-doc update: no existing plan documents the Sources sidebar header
(`sources-redesign.md` covers the older model rework), so the progress entry
carries the change note.

### Follow-up: sort icon and display order

The operator then asked for a "Sort by" control on Sources. The header
action cluster gained a sort icon (`arrow.up.arrow.down`, next to the filter
icon) whose dropdown offers Last Updated / Newest First / Title A–Z, the
same `Menu { Picker(.inline) }` pattern. The icon tints accent while a
non-default sort is active.

`SourceSortOrder` is a nested enum with a pure `sorted(_:)` over
`[SourceSummary]`, applied in `visibleSources`. `lastUpdated` is the
default — it reproduces the store's native `ORDER BY updated_at DESC`, so
today's list order is unchanged until the user picks another order. Equal
keys tie-break on `id.rawValue` (a ULID, monotonic by ingest time). The
sort does NOT apply during search: search results are relevance-ranked by
the engine, and re-ranking them would destroy that — the same rule
`PagesContainerView` follows. Filter choices and sort choices both reset
when the user switches sidebar sections (`@State`).

## Verification

- `make build` — green.
- `make test` — green (default gate; no existing suite asserts the removed
  row).
- `WIKIFS_APP_TESTS=1 swift test --filter SourcesSortTests` — 5 tests pass
  (per-order ordering, ULID tie-break, default-matches-store-order).
- Manual eyes-on (menu contents can't be driven from the `swift test` CLI
  host, same menu-tracking limitation documented in the #241 work): the
  filter icon's menu lists All, Ready, Processed with the current choice
  checked, and selecting a filter narrows the list; the sort icon's menu
  lists Last Updated, Newest First, Title A–Z and selecting one reorders
  the list.
