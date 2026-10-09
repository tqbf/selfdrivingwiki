---
timestamp: 2026-10-09T003125Z
title: Tabs can be reordered by click-and-drag (#1388)
branch: feature/reorder-tabs-by-drag
status: complete
---

# Tabs can be reordered by click-and-drag (#1388)

## Progress

Users can press and hold a tab, drag it left or right across the tab bar, and
release it at the wanted position.

- `WikiStoreModel.moveTab(id:to:)` moves a tab to a final index. The active tab
  is tracked by ID, so it stays active through the move. Pin state, edit mode,
  and stashed drafts travel with the tab.
- `TabBarLayout.insertionIndex(fromIndex:dragOffset:tabWidth:tabCount:)` and
  `targetIndex(fromIndex:slot:)` hold the drop-target math in Core so it is
  testable without a view. A swap happens once the drag passes a quarter of a
  tab width (`TabBarLayout.dragSwapThresholdFraction`); each further slot
  takes a full width of travel.
- `TabBarItemView` adds a `DragGesture` (4 pt start distance) that competes
  with the existing tap gesture. A press released without moving stays a click;
  a press that moves becomes a drag. The right-click context menu is untouched.
- `TabBarView` offsets the dragged tab with the cursor, draws a 2 pt accent
  insertion line at the drop slot, and commits the move on release. The strip
  does not reflow mid-drag. When the overflow chevron is showing, the drop
  target is anchored on neighbor tab IDs so the visible order maps back to the
  store order.

## Verification

- `make build` — passes.
- `swift test --filter "TabBarLayoutTests|EditorTabTests"` — 87 tests pass,
  including 8 new `moveTab` tests and 6 new `insertionIndex`/`targetIndex`
  tests.
- `make test` — full suite passes.
