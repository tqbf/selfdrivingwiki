---
timestamp: 2026-07-18T141449Z
title: "2026-07-18 — Issue #192: \"Go to Original\" bookmark context-menu action (branch `bookmark-go-to-original`)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-18 — Issue #192: "Go to Original" bookmark context-menu action (branch `bookmark-go-to-original`)

## Progress


**Problem:** Right-clicking a bookmark offered only Open / Open in Background /
Open With / Edit / Delete. To reach the page/source itself the user had to
double-click → open the bookmark detail → click "Show in List" — two clicks plus
a view switch.

**Fix:** Added a single-selection "Go to Original" item at the top of the
bookmarks context menu. It reveals the bookmark's target in its sidebar section
(Pages / Sources / Chats) without opening a reader tab, reusing the existing
"Show in List" reveal mechanism (`WikiStoreModel.requestSidebarReveal(_:)`)
that `PageDetailView` / `SourceDetailView` / `ChatView` already use — it
switches the sidebar tab, clears any search hiding the target, and scrolls to +
selects the row.

Wiring: an `onGoToOriginal: (WikiSelection) -> Void` callback was threaded
through `BookmarksCallbacks` and `BookmarksOutlineView` (both `.init` sites in
the representable) and connected in `BookmarksContainerView` to
`store.requestSidebarReveal(selection)`. The VC's `goToOriginalAction` resolves
the clicked node's target to a `WikiSelection` via a shared
`revealSelection(for:)` helper (also used to DRY up `openableSelections`).
Gated single-selection + openable leaf only (pageRef / sourceRef / chatRef);
hidden for folders and multi-selection batches.

Changes:
- `Sources/WikiFS/Bookmarks/BookmarksOutlineView.swift` — new menu item + action,
  `revealSelection(for:)` helper; `BookmarksCallbacks` and `BookmarksOutlineView`
  gain `onGoToOriginal`; `openableSelections` refactored to reuse
  `revealSelection`.
- `Sources/WikiFS/Bookmarks/BookmarksContainerView.swift` — wire
  `onGoToOriginal` → `store.requestSidebarReveal(selection)`.
- `Tests/WikiFSTests/BookmarksMultiSelectMenuTests.swift` — updated the 3
  `BookmarksCallbacks(...)` call sites for the new field; added 5 tests
  (visibility for leaf/folder/batch + page/chat target reveal mapping).

**Build/Tests:** `make version prompts && swift build` clean; fast test tier
2,503 tests in 213 suites pass.

## Verification

Historical verification remains in the progress record above.
