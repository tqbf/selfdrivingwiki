---
timestamp: 2026-09-19T160000Z
title: Sources header Show row becomes a filter menu icon
branch: feature/sources-filter-icon
status: complete
---

# Sources header Show row becomes a filter menu icon

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

## Verification

- `make build` — green.
- `make test` — green (default gate; no existing suite asserts the removed
  row).
- Manual eyes-on (menu contents can't be driven from the `swift test` CLI
  host, same menu-tracking limitation documented in the #241 work): the
  filter icon's menu lists All, Ready, Processed with the current choice
  checked, and selecting a filter narrows the list.
