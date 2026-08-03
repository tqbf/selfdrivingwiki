---
timestamp: 2026-08-02T000000Z
title: Issue 1043 tab pinning and menu icons
branch: feat/tab-pinning-menu-icons
status: complete
---

# Issue 1043 tab pinning and menu icons

## Progress

The tab context menu can pin and unpin a tab.

Pinned tabs show a pin icon. They keep their current item when normal navigation
opens a different item. The app opens an unpinned tab for the new item.

The menu uses SF Symbols for Pin, Unpin, Close, Close Others, Close Tabs After,
and Close All. The close/reopen path keeps the full tab state, including the
pin state.

## Verification

`swift test --filter EditorTabTests` passed 64 tests.

`make test` passed 3,028 tests in 247 suites.
