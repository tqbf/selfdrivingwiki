---
timestamp: 2026-07-19T210831Z
title: "2026-07-19 — Issue #674: Double-click to toggle collapsed/expanded headers + chat blocks (branch `feature/double-click-expand`)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-19 — Issue #674: Double-click to toggle collapsed/expanded headers + chat blocks (branch `feature/double-click-expand`)

## Progress


**Problem.** Collapsible headers and chat collapsible blocks only toggled
on a single click of the disclosure chevron / `<summary>`. There was no
double-click affordance, so users expecting macOS-typical double-click to
toggle had no shortcut.

**Scope.**

- `Sources/WikiFS/Editor/CollapsibleDetailHeader.swift` — added
  `.onTapGesture(count: 2)` on the `titleRow` HStack that flips `isExpanded`
  with the same `.easeInOut(duration: 0.2)` animation as the chevron
  Button. SwiftUI's gesture arbitrator preserves the chevron Button's
  single-click (its own gesture wins single taps) and EditableTitle's
  rename `onTapGesture(count: 2)` (innermost wins inside the title bounds);
  double-taps on the rest of the header (icon, padding) now toggle. Used
  by `PageDetailView`, `SourceDetailView`, `ChatView` — three sites, one
  fix.
- `Sources/WikiFS/Chats/ChatWebView.swift` — added a `dblclick` listener
  to the `document` in `shellHTML`'s `<script>` that finds the closest
  `<summary>` ancestor and flips its parent `<details>` `open` attribute.
  Covers every `<details>` in the transcript (thinking blocks via
  `.row-thinking.collapsible`, feed tool blocks via
  `.row-tool.collapsible`, chat tool blocks via `.chat-tool`). The
  browser's native single-click toggle continues to fire for each click
  of the pair; the trailing `dblclick` flips `open` once more so a
  double-click nets to a single flip from the starting state.

**No new tests.** Both surfaces are gesture/JS-handler additions to
view-layer code; the project has no SwiftUI gesture test harness and the
JS runs inside `WKWebView` (no JS test infra). `swift test` (~1.5 min)
run cleanly on `feature/double-click-expand`.

## Verification

Historical verification remains in the progress record above.
