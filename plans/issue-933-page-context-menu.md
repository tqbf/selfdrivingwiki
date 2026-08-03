# Issue #933 — page context menu: Back / Forward / Print

**Issue.** "Right clicking on a page should show back/forwards links and ability
to print the page." The attached screenshot is Safari's own page context menu:
`Back`, `Forward`, `Reload Page`, a divider, then `Show Page Source`,
`Save Page As…`, `Print Page…`. No comments, no acceptance criteria.

**Status.** Shipped on `fix/933-page-context-menu`.

## What the reader's context menu was

`WikiReaderWebView` (`Sources/WikiFS/Reader/WikiReaderView.swift`) is a
`WKWebView` subclass that augments WebKit's context menu by overriding
`NSView.willOpenMenu(_:with:)` — WKWebView has no public macOS menu API
(`WKUIDelegate`'s `contextMenuConfigurationForElement:` family is iOS/visionOS
only). The override has two branches:

- **Link right-click** — builds the wiki-link items via `WikiLinkMenuNSItems`
  (Add as Source / Add Bookmark / Suggest… / Find Similar… / Open in Background
  / Share…). #925's lazy `SimilarPagesMenuLoader` lives here.
- **Non-link right-click** — previously added only an inline "Share…" below
  WebKit's Reload. This is the branch #933 is about.

## Design decisions

### Navigation reads the store, not WebKit

The reader renders with `loadHTMLString`, so `WKWebView.canGoBack` is always
`false` and its back-forward list is always empty — it is *not* the page history
the user means. The real history is `WikiStoreModel.backStack` /
`forwardStack`, which already drives the toolbar chevrons (`OmniboxNavButtons`,
⌘[ / ⌘]) and the two-finger swipe monitor (`SwipeNavigation`).

So the menu items call `store.canNavigateBack` / `canNavigateForward` /
`navigateBack()` / `navigateForward()` directly. **No `Bool` navigation state is
duplicated anywhere**, and the menu cannot drift from the toolbar.

Because the web view's `store` is injected per-instance by `WikiReaderRep`
(`makeNSView` / `updateNSView`) from the window's session, a menu built in one
window navigates that window's wiki. Multi-window correctness falls out of the
existing wiring rather than needing a frontmost-window lookup.

### Enabled state is validated at display time

`NSMenu.autoenablesItems` is on by default (and WebKit's context menu uses it),
so AppKit re-derives each item's enabled state immediately before display by
asking the item's target through `NSMenuItemValidation`. `NSMenuItem.wikiItem`
therefore now takes `isEnabled` as a **closure**, and `ClosureMenuItemTarget`
conforms to `NSMenuItemValidation` and answers with it. The value is also
applied up front, so an item is correct before any validation pass and stays
correct on a menu with automatic enabling turned off.

Verified empirically (throwaway probe, not kept): `NSMenu.update()` does call
`validateMenuItem(_:)` on our targets and will overrule a stale stored value.

### Printing: one mechanism, WebKit's

The app had **no** print path at all before this change. `ReaderPrinting.run(for:)`
uses `WKWebView.printOperation(with:)`, which prints the live DOM — the same
markdown, transclusions, diagrams, and reader CSS on screen. Re-rendering the
markdown into a separate print-only document would be a second mechanism that
could silently disagree with what the user sees.

- `NSPrintInfo.shared` is **copied**, not mutated: it is process-wide state and
  scribbling half-inch margins onto it would leak into every other print job.
- The panel runs **sheet-modal** on the web view's window
  (`runModal(for:delegate:didRun:contextInfo:)` returns immediately), so the
  main actor is never blocked and each window prints its own reader. An
  unwindowed view (detached/torn down) falls back to app-modal.

`WikiReaderWebView.printRenderedPage` is a narrowly typed seam
(`@MainActor (WKWebView) -> Void`) defaulting to `ReaderPrinting.run(for:)`.
Nothing in the app reassigns it; it exists so tests can assert the item is wired
to *this* reader without presenting a real print panel.

### Labels, order, separators, key equivalents

Final non-link menu (matching the issue's Safari screenshot):

```
Back                 chevron.left    enabled iff store.canNavigateBack
Forward              chevron.right   enabled iff store.canNavigateForward
Reload               (WebKit's own)
─────────────
Print Page…          printer
Share…               (existing, omitted when the selection has no File Provider URL)
─────────────
Look Up / Translate / Services / … (WebKit's own)
```

- Back / Forward go at the very top so they read as one navigation group with
  WebKit's Reload — no divider between them.
- "Print Page…" opens the next group: it acts on the document rather than moving
  between documents. Share joins it there, anchored off the Print item itself so
  the two can't drift apart as WebKit's menu changes across macOS releases.
- **No key equivalents.** Safari's page context menu shows none, no other
  in-app context menu in this codebase sets one, and macOS advertises shortcuts
  in the menu bar and toolbar — where ⌘[ / ⌘] already live.
- A right-click **on a link** stays the link menu: no Back/Forward/Print, which
  is also Safari's behavior. #925's lazy Suggest… / Find Similar… submenu is
  untouched.
- Deliberate deviation: a right-click on a non-link **image** also gets the page
  group (Safari narrows that menu to image actions). The reader's branch is
  link-vs-not, and an extra Print / Back on an embedded diagram is a superset,
  not a wrong menu — narrowing it would mean matching more undocumented
  `WKMenuItemIdentifier*` strings for no user gain.
- Ellipsis on "Print Page…" because it opens a panel; the bare verbs don't.

### Accessibility

Each item carries an SF Symbol with an `accessibilityDescription` equal to its
title, so VoiceOver reads the command once rather than inventing a second
phrasing for the glyph. Disabled Back/Forward are reported as dimmed by AppKit
because the state comes from real validation, not a cosmetic `isEnabled`.

## Files

| File | Change |
| --- | --- |
| `Sources/WikiFS/Reader/PageContextMenuNSItems.swift` | **new** — `PageContextMenuAction` (typed label/symbol) + the builder that makes the three items and splices them into WebKit's menu |
| `Sources/WikiFS/Reader/ReaderPrinting.swift` | **new** — the single print path (`WKWebView.printOperation`, copied `NSPrintInfo`, sheet-modal) |
| `Sources/WikiFS/Reader/WikiReaderView.swift` | non-link branch of `willOpenMenu` now calls `addPageItems`; `inlineShareItem` factored out of the old `addInlineShareItem`; `printRenderedPage` seam |
| `Sources/WikiFS/Reader/WikiLinkMenuNSItems.swift` | `wikiItem(_:isEnabled:action:)` takes a closure; `ClosureMenuItemTarget` conforms to `NSMenuItemValidation` |
| `Tests/WikiFSAppTests/PageContextMenuTests.swift` | **new** — 14 tests over the real `NSMenu` path |
| `Tests/WikiFSAppTests/PageContextMenuHostedTests.swift` | **new** — hosted `NSWindow` test on the reader SwiftUI actually mounts |

## Tests

`PageContextMenuTests` drives real `NSMenu`/`NSMenuItem` objects seeded with
WebKit's item identifiers:

- labels + order (`["Back", "Forward", "Print Page…"]`), no key equivalents,
  every item has a glyph
- placement: navigation above WebKit's Reload with no divider; Print in the
  group below; correct order with *and* without a Reload item
- disabled Back/Forward with no history, after `NSMenu.update()`
- history flips both items across a `navigateBack()`
- Back/Forward navigate exactly one step; Print fires its action once
- the reader's own menu: full Safari order including Share, and Share omitted
  when the selection has no shareable URL
- Print targets the right-clicked reader, not a second reader in the same process
- the real `willOpenMenu` entry point on a non-link click, including WebKit
  builtin removal and separator collapsing
- a link right-click gains **no** page items, and #925's Suggest… submenu still
  builds with a "Searching…" placeholder and no search performed

`PageContextMenuHostedTests` mounts the real `WikiReaderView` in an `NSWindow`,
waits for SwiftUI to mount the `WikiReaderWebView` **with its store injected**,
then runs `willOpenMenu` on it — closing the gap between "the menu builder
works" and "the view the app actually creates is wired".

## Known limitation

The print **panel** itself is not covered by an automated test: presenting
`NSPrintOperation` in a unit test would put a modal panel on screen (or block on
a print subsystem that has no printers in CI). Tests pin everything up to the
call — that Print is present, enabled, fires once, and receives the correct web
view — and `ReaderPrinting.run(for:)` is the small, straight-line remainder.
Paper output, page breaks across long code blocks, and the panel's own behavior
need a human with a printer or a Save-as-PDF run.
