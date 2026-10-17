---
timestamp: 2026-10-17T161005Z
title: Sidebar footer merges the wiki switcher and the Strategy button
branch: feature/sidebar-strategy-button
status: complete
---

# Sidebar footer merges the wiki switcher and the Strategy button

## Progress

The sidebar footer showed two stacked rows: the wiki switcher pill and a
Strategy row. The footer now shows one row. The wiki switcher stays on the
left with its full menu (wiki list, New Wiki…, Rename, Export, Delete,
Import Wiki Backup). A compact Strategy button sits to its right.

The button keeps the old row's behavior. It opens (or focuses) the Strategy
tab through `openTab(.strategy)`, targets the active wiki, and highlights
with the accent color while the Strategy tab is selected. The old "Edited"
capsule becomes a small accent dot on the button when the strategy draft has
unsaved changes. The full "Edited" marker still shows in the strategy
editor, so no draft state is lost. The tooltip names the wiki and adds
"unsaved edits" while the dot shows.

The button reuses the section selector bar's visual language: a 26-point
square icon button with a 6-point corner radius. New `SidebarMetrics` holds
these values, and the section bar now reads them too, so both selector rows
share one source for the shared sizes.

`SidebarView.wikiSwitcherRow` and `strategyFooterRow` are replaced by
`wikiFooterRow` and `strategyButton`. The `WikiSwitcher` doc comment points
at the new row name.

## Verification

- `make build` — the app compiles and signs.
- `make test` — the full `swift test --parallel` suite passes.
- No manual UI run happened. The operator should confirm the footer layout
  at narrow sidebar widths and the dot behavior after editing strategy text.
