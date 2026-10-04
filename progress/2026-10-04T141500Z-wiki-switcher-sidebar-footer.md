---
timestamp: 2026-10-04T141500Z
title: Wiki switcher pill moved from toolbar to sidebar footer
branch: feature/wiki-switcher-sidebar
status: complete
---

# Wiki switcher pill moved from toolbar to sidebar footer

## Progress

The operator asked to move the wiki selector pill out of the window toolbar.
The pill now sits in the sidebar, directly above the Strategy row.

Changes:

- `ContentView` no longer puts `WikiSwitcher` in the toolbar. The toolbar keeps
  the navigation buttons, the omnibox, and the inspector toggle.
- `SidebarView` adds `wikiSwitcherRow` above `strategyFooterRow`. Both rows use
  the same 8/6 point padding, so the footer reads as one cluster: which wiki is
  open, then that wiki's strategy.
- `WikiSwitcher` renames `toolbarLabelMaxWidth` to `labelMaxWidth`. The doc
  comment now names the sidebar footer as the host.

Behavior does not change. Click still opens the wiki in a new window.
Option+click still switches this window in place.

## Verification

- `make build` passed.
- `make test` passed (full suite).
