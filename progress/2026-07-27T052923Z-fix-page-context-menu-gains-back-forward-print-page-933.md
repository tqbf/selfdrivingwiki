---
timestamp: 2026-07-27T052923Z
title: "fix: page context menu gains Back / Forward / Print Page… (#933)"
branch: null
status: historical
timestamp_source: git-commit
---

# fix: page context menu gains Back / Forward / Print Page… (#933)

## Progress


**Scope.** Right-clicking the rendered page in the reader — on content, not on a
link — now shows Back, Forward, and Print Page… alongside WebKit's own items, in
Safari's order. Link right-clicks are unchanged. Full design:
[`plans/issue-933-page-context-menu.md`](plans/issue-933-page-context-menu.md).

**Decisions.**
- Navigation reads the **store**, not WebKit. The reader renders with
  `loadHTMLString`, so `WKWebView.canGoBack` is permanently `false`; the real
  history is `WikiStoreModel.backStack`/`forwardStack`, already driving the
  toolbar chevrons (⌘[ / ⌘]) and `SwipeNavigation`. The menu calls
  `canNavigateBack` / `navigateBack()` directly — no duplicated `Bool` state,
  no stringly selectors. Per-window correctness is free: `WikiReaderRep` injects
  each web view's `store` from that window's session.
- Enablement is validated at **display** time. `NSMenu.autoenablesItems` is on
  for WebKit's menu, so AppKit re-derives state through `NSMenuItemValidation`
  just before display. `NSMenuItem.wikiItem(_:isEnabled:action:)` now takes a
  closure and `ClosureMenuItemTarget` conforms to `NSMenuItemValidation`; the
  value is still applied up front so an item is correct before any validation
  pass. (Confirmed with a throwaway probe that `NSMenu.update()` does call
  `validateMenuItem(_:)` and overrules a stale stored value.)
- Printing is **one** mechanism: `ReaderPrinting.run(for:)` calls
  `WKWebView.printOperation(with:)`, so the job is the live DOM the user is
  looking at rather than a parallel print-only render that could disagree.
  `NSPrintInfo.shared` is copied (it is process-wide state), and the panel runs
  sheet-modal on the web view's window so the main actor never blocks.
  `WikiReaderWebView.printRenderedPage` is a narrowly typed seam
  (`@MainActor (WKWebView) -> Void`) that production never reassigns — it exists
  so tests can prove the item targets *this* reader without a print panel.
- **No key equivalents** on the context-menu items: Safari's page menu shows
  none, no other in-app context menu in this codebase sets one, and ⌘[ / ⌘]
  already live on the toolbar. Ellipsis on "Print Page…" because it opens a
  panel.
- Back / Forward sit above WebKit's Reload with no divider (one navigation
  group); Print opens the group below and Share was moved to join it, anchored
  off the Print item rather than a recomputed WebKit index.

**Verification.**
- `make version keychain prompts` then `swift build --build-tests` — passed.
- `swift test --filter 'PageContextMenu'` — 15 tests in 2 suites passed.
- `swift test --filter
  'WikiLinkMenuNSItemsTests|WikiLinkMenuBuilderTests|SourceDetailWebViewMenuTests|QuoteHighlightWebViewTests|TransclusionEmbedTests|NavigationHistoryTests|BookmarksMultiSelectMenuTests|MenuBarItemMaintenanceMenuTests|PageDetailViewHostedTests'`
  — 103 tests in 9 suites passed.
- `swiftlint lint --strict` (via `make lint`) — 0 violations in 374 files, no new
  bare `try?`. `git diff --check` — clean.
- The full `make test` suite was **not** run to completion locally (it is CI's
  job — it was still going after ~25 minutes and was stopped). Every suite it
  did reach recorded zero issues.

**Not covered.** The print panel itself. Presenting `NSPrintOperation` in a unit
test would put a modal panel on screen (and CI has no printer), so tests pin
everything up to the call and `ReaderPrinting.run(for:)` is the small
straight-line remainder. Paper output and page breaks across long code blocks
need a human with a printer or a Save-as-PDF run.

## Verification

Historical verification remains in the progress record above.
