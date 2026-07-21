# Plan: Omnibox cleanup — Wiki Selector to sidebar

## Goal
Simplify the toolbar to a single clean omnibox:
1. Move `WikiSwitcher` from the toolbar's trailing `.primaryAction` into the
   **sidebar's title/header area** — so it collapses when the sidebar is hidden
   (clicking the left panel toggle).
2. Keep the Back/Forward/Home nav cluster in the toolbar.
3. Leave only `[Back/Forward/Home] [Omnibox]` + `[ChangeLog toggle]` in the
   toolbar.

## Files changed
| File | Change |
|---|---|
| `Sources/WikiFS/Window/SidebarView.swift` | Add `WikiSwitcher` at the top of the sidebar header |
| `Sources/WikiFS/Window/ContentView.swift` | Remove the `WikiSwitcher` `ToolbarItem`; drop the now-unused `wikiName:` arg + `activeWikiName` |
| `Sources/WikiFS/Editor/AddressBarView.swift` | Drop `wikiName` (switcher is gone); pass `switcherExtra: 0`; remove `headlineTextWidth` + `baselineSwitcherName` |
| `Sources/WikiFSCore/Core/OmniboxLayout.swift` | Retune `trailingWithSwitcher` (180→110) — only the ChangeLog toggle remains in the toolbar |
| `Tests/WikiFSAppTests/OmniboxLayoutTests.swift` | Recompute expected widths for the retuned trailing reservation |
| `Tests/WikiFSAppTests/AddressBarLayoutHostedTests.swift` | Drop the `wikiName:` arg from the hosted constructor |

## Acceptance criteria
- [x] `WikiSwitcher` appears at the top of the sidebar (above the section selector).
- [x] When the sidebar is collapsed, the `WikiSwitcher` disappears with it.
- [x] Toolbar has only `[Back/Forward/Home] [Omnibox]` + `[ChangeLog toggle]`.
- [x] Omnibox expands to fill the toolbar width (trailing switcher reservation removed).
- [x] `make build && make test` passes.
- [x] No `print`; no bare `try?`.

## Notes
- The Home button stays in `AddressBarView` (issue #280) — only the `WikiSwitcher`
  leaves the toolbar.
- `OmniboxLayout` keeps its API (`switcherExtra` is now always `0` from the view);
  only `Metrics.default.trailingWithSwitcher` is retuned from 180 (switcher +
  transcript) to 110 (the single ChangeLog toggle). Hosted tests assert *deltas*,
  which are invariant to the reservation value.
