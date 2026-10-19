---
timestamp: 2026-10-18T172616Z
title: Sidebar context menus show icons again and share one skeleton
branch: fix/sidebar-menu-icon-visibility
status: complete
---

# Sidebar context menus show icons again and share one skeleton

## Progress

The four sidebar row menus (Pages, Sources, Bookmarks, Chats) always set an
SF Symbol image on every item, yet the operator saw no icons at all. The
cause is platform behavior, not a missing icon: apps linked against the
macOS 27 SDK hide menu-item symbol images by default. Apple's macOS 27
release notes state "By default, `NSMenu` hides all menu item symbol images
— non-symbol images remain visible." Non-symbol images (the app icons in
the Open With submenu) kept showing, which matched the "some icons are
there" report.

## Contract

- New `NSMenuItem.setSymbolImage(_:)` sets the symbol and forces
  `preferredImageVisibility = .visible` under `#available(macOS 27.0, *)`,
  itself wrapped in `#if compiler(>=6.4)`: the property only exists in the
  macOS 27 SDK (Xcode 27, Swift 6.4), and CI builds with Xcode 26.6
  (Swift 6.3.3, macOS 26 SDK) where the symbol is absent entirely. When
  CI's image gains an Xcode with the 27 SDK, the gate lights up on its
  own. On macOS 26 runtimes the property does not exist and symbols stay
  hidden; nothing can change that there.
- The Open With submenu gains an `app.dashed` icon for "Other…" and skips
  its leading separator when no apps are registered, so no menu shows a
  leading separator.
- All four menus now share one skeleton: Open cluster first, a separator,
  the section's actions, a separator, Delete last. Pages and Sources gain
  the separator after the Open cluster (the original request). Pages,
  Sources, and Chats gain the separator before Delete in single-selection
  menus; batch menus drop the lone Rename row and keep one separator
  before Delete. Bookmarks already followed this shape.
- The hosted suite `SidebarMenuIconHostedTests` pins the contract on the
  real controllers against real temp-file stores: every non-separator item
  renders a non-nil, forced-visible image (submenus included), "New Chat…"
  and Delete are separator-preceded, and no menu shows adjacent or edge
  separators.

The reader's wiki-link context menu (`WikiLinkMenuNSItems`) still sets
symbol images without forcing visibility. It needs the same helper; it is
not part of this change.

## Verification

- `make build` — compiles and signs.
- `make test` — the default `swift test --parallel` tier passes.
- `scripts/test-optin-app-tests-reconciled.sh --expect
  SidebarMenuIconHostedTests --filter SidebarMenuIconHostedTests` — 5 tests
  pass; execution and run-summary gates green. The opt-in tier is where
  the new hosted suite lives; plain `make test` does not execute it.
- No manual UI run happened. The operator should right-click a page and a
  source on this machine (macOS 27) and confirm icons render and the Open
  cluster sits apart from the actions.
