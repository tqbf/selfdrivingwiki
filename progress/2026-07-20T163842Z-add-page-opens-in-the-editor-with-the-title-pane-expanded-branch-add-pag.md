---
timestamp: 2026-07-20T163842Z
title: "2026-07-20 — \"Add Page\" opens in the editor with the title pane expanded (branch `add-page-editor-default`)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-20 — "Add Page" opens in the editor with the title pane expanded (branch `add-page-editor-default`)

## Progress


**Problem.** Clicking "Add Page" (welcome screen button or sidebar `+`) opened
the new page in the **rendered/preview** view, which shows an empty page. The
user expected to land on the **source editor**, and the collapsible title pane
expanded so Save/Cancel are immediately reachable. See
`plans/add-page-editor-default.md`.

**Fix.** One model change + one view change, both minimal and per-tab (not
global):

- **`WikiStoreModel.newPageInNewTab`** (`Sources/WikiFSCore/Store/WikiStoreModel.swift`)
  — after `openTab`, call `setTabEditing(tabID: activeTabID, isEditing: true)` so
  the freshly-created tab carries edit mode as a creation-time property.
  Navigation-opened tabs keep `isEditing == false` (their `EditorTab` default), so
  the scope guard is automatic. No new store mutator → no #129 emission work.
- **`PageDetailView.onAppear`** (`Sources/WikiFS/Pages/PageDetailView.swift:189`) —
  previously only recorded `lastKnownActiveTabID`; now ALSO seeds `isEditing`
  from `store.activeTab?.isEditing` (and expands the header when seeding edit
  mode). This closes the first-mount seeding gap: `.onChange(of:
  store.activeTabID)` only fires on *subsequent* tab switches, so without the
  `.onAppear` seed a tab created with `isEditing == true` would still render the
  preview branch on first paint. The existing `.onChange(of: store.selection)`
  in-tab-navigation guard (`activeTabID == lastKnownActiveTabID`) is preserved
  and is NOT triggered by the new-page path (a real `activeTabID` change), so
  the editor does not flip back to preview.

Header expansion is free — no new state. The existing `.onChange(of: isEditing)`
coupling (`if newValue { isHeaderExpanded = true }`) expands the header whenever
edit mode is entered; the `.onAppear` seed sets `isHeaderExpanded = true`
directly for belt-and-suspenders on the first paint.

**Why the per-tab seam (not `@AppStorage`).** `EditorTab.isEditing` is already
the persisted per-tab source of truth that tab-switching restores from. Setting
it `true` at creation makes "new pages start editing" a natural property of the
tab. A global `@AppStorage("defaultEditMode")` was rejected — it would force
EVERY page open into edit mode and violate "respect last mode for navigation."

**Files changed:**
- `Sources/WikiFSCore/Store/WikiStoreModel.swift` — `newPageInNewTab` (2 lines
  added: the `if let id = activeTabID { setTabEditing(...) }`).
- `Sources/WikiFS/Pages/PageDetailView.swift` — `.onAppear` expanded from 1 line
  to seed `isEditing` + `isHeaderExpanded`.
- `Tests/WikiFSTests/EditorTabTests.swift` — updated
  `newPageInNewTab_createsPageAndOpensTab` to assert `tabs[0].isEditing == true`;
  added `newPageInNewTab_setsActiveTabEditingTrue` and
  `newPageInNewTab_doesNotAffectOtherTabs` (scope guard).
- `Tests/WikiFSTests/PageDetailViewHostedTests.swift` (new) — mounts the REAL
  `PageDetailView` in an `NSWindow` and inspects the NSView subtree to prove the
  view-layer seeding works (see Verification below).

**Verification.** Two layers, because the `.onAppear` seeding is not unit-testable
by assertion on `@State`:

1. **Model-level** (Swift Testing, `EditorTabTests`) — `newPageInNewTab` sets
   `activeTab.isEditing == true` / `isActiveTabEditing == true`; other tabs are
   unaffected (scope guard).
2. **View-level** (new `PageDetailViewHostedTests`) — mounts the real
   `PageDetailView` in an `NSWindow` and walks the NSView subtree.
   `contentAndOutline` switches on `isEditing`: editor branch →
   `ScrollableTextEditor` (NSTextView); reader branch → `WikiReaderView`
   (WKWebView). The new-page case asserts NO `WKWebView` appears in the subtree
   after a 2s poll (editor rendered); the navigation case asserts a `WKWebView`
   IS present (reader rendered). This pins the exact `.onAppear` seeding behavior
   that the task flagged as non-unit-testable, deterministically and CI-gated —
   following the `docs/skills/reproducing-live-ui-bugs` hosted-view pattern.

**Live-app check.** `make build` produced a signed `build/Self Driving Wiki.app`;
the app launched and ran without crashing. (The hosted tests above provide
stronger, reproducible evidence than manual clicking, and don't depend on
screen/accessibility access.)

**Result:** 3135 suites / 3135 tests pass (was 3133/264; +2 EditorTabTests
already counted in the first run, +1 suite/2 tests for the hosted view tests).
`make build` + `make check` clean.

## Verification

Historical verification remains in the progress record above.
