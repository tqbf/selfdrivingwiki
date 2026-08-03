---
timestamp: 2026-07-16T032543Z
title: "#183 — \"Show In List\" sidebar reveal for pages & sources"
branch: null
status: historical
timestamp_source: git-commit
---

# #183 — "Show In List" sidebar reveal for pages & sources

## Progress


A "Show in List" button (next to "Reveal in Finder") in `PageDetailView` and
`SourceDetailView` that surfaces the current page/source in the sidebar: opens
the sidebar if collapsed, switches to the right section, clears a search that
would hide the row, then scrolls to + selects it.

**Mechanism** — mirrors the existing `pendingScrollAnchor` "set once, consume
once" cross-view signal (issue #183 design):

- `WikiStoreModel` — `pendingSidebarReveal: WikiSelection?` +
  `pendingSidebarRevealVersion: Int` (monotonic, observed via `.onChange` so a
  repeat request re-fires even when the value is unchanged), with
  `requestSidebarReveal(_:)` (producer) and `consumePendingSidebarReveal()`
  (consumer, called by the list view after scroll+select).
- `ContentView` — `.onChange(of: pendingSidebarRevealVersion)` un-collapses the
  sidebar (`columnVisibility = .all`) when it's `.detailOnly`, so the target
  section's list is actually mounted.
- `SidebarView` — `.onChange(of: pendingSidebarRevealVersion)` sets
  `selectedSection` to `.pages`/`.sources` from the `WikiSelection` case and
  clears the section's search query (`searchQuery`/`sourceSearchQuery`) only
  when the target isn't in the filtered results (clearing resets
  `searchResults`/`sourceSearchResults` synchronously, so the full list is
  visible for row lookup).
- `PagesListViewController` / `SourcesListViewController` — new
  `revealAndSelect(id:)`: looks up the row, selects it (bypassing the
  `reconcileHighlight` multi-select guard — an explicit user action wins over a
  Cmd/Shift selection), and `scrollRowToVisible(_:)`. Driven from
  `updateNSViewController`, which reads `pendingSidebarReveal` (also registers
  the observation so the method re-runs on change), then consumes.
- `PageDetailView` / `SourceDetailView` — `Button("Show in List",
  systemImage: "sidebar.left")` calling `requestSidebarReveal(.page(id))` /
  `.source(id)`. Works without a mounted File Provider (unlike Reveal in Finder).

**Build/tests:** `swift build` clean; `swift test` — 1466 tests pass.

---

### Issue #229 — PDF source add by URL can fail "database is locked" (PR #247)

**Problem.** `DisplayNameResolver.resolve()` — which invokes PDFKit's
whole-file parse for PDFs — ran **inside** `SQLiteWikiStore.addSource`'s
`mutate()` closure, under the recursive lock and before the write transaction
opened. For a large PDF this parse can take seconds, delaying the `BEGIN` long
enough for another writer (File Provider, daemon, concurrent write) to hold the
DB write lock past the 5 s `busy_timeout`, surfacing as "database is locked".

**Fix.** Two-part:
1. **Out of the locked path:** `addSource` (and `addSnapshotImage`) now compute
   `ext` / `mime` / `displayName` **before** `mutate()` acquires the recursive
   lock. The locked body keeps only the dup-check SELECT + INSERT transaction.
   Added a `resolvedDisplayName: String??` parameter to `addSource` (and a
   `WikiStore` protocol-extension convenience overload since protocol methods
   can't have default args) so callers can skip the in-method parse entirely.
2. **Off the main actor:** `WikiStoreModel.preResolveDisplayName()` runs
   `DisplayNameResolver.resolve()` on a `Task.detached` for **PDFs only**
   (non-PDFs return `nil` → resolve inline). Wired into `addURLViaWebsite`,
   `addFiles`, and `ingestFromZotero`.

**Key files:** `SQLiteWikiStore.swift` (`addSource` / `addSnapshotImage`),
`WikiStore.swift` (protocol + extension), `WikiStoreModel.swift`
(`preResolveDisplayName`, `storeMaterialized`, three ingest paths).

**Build/tests:** `swift build` clean; `swift test` — 1930 tests pass
(1927 existing + 3 new for the `resolvedDisplayName` tri-state bypass).

## Verification

Historical verification remains in the progress record above.
