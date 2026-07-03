# Address bar / omnibox

**Status:** Implemented (on `feature/address-bar-omnibox`).
**Depends on:** existing semantic search (`store.searchSimilar`), tab system
(`activeTabID`, `selectPage(byTitle:)`), `WikiSelection`, `WikiSwitcher`,
reader zoom (`@AppStorage("reader.zoom")` / `ZoomScale`).

## What shipped

A Safari-style **omnibox** that lives in the **window toolbar** (a `.navigation`
toolbar item), replacing the window title. It serves two roles depending on
focus state, with no explicit mode switch required:

1. **Idle (not focused):** shows the active page's wikilink (`[[Page Title]]`)
   as the field's text — the "where am I" indicator, like a browser URL bar.
2. **Focused / typing:** becomes a semantic search field. Typing debounces into
   `store.searchSimilar(query:)` and shows a ranked suggestions panel below the
   field. Selecting a result (or pressing Enter) navigates to it.

The agent query path is deliberately **excluded** in v1. Semantic search is fast
(ms), predictable, and browser-like. Agent escalation can be added later as an
opt-in entry at the bottom of the dropdown.

## How the implementation differs from the original design

The original design placed a SwiftUI `AddressBarView` *inside the detail
`VStack`, above the tab strip*. Shipping instead moved the bar into the **window
toolbar** and introduced three supporting pieces. The reasons, and what changed:

- **Toolbar placement, not in-content VStack.** A browser address bar belongs in
  the toolbar. The omnibox is a `.navigation` toolbar item on the **detail
  column** (not the split-view root — a `.principal`/root item centers across the
  whole window, overlaps the open sidebar, and dumps the group into the `»`
  overflow). Declared on the detail column it centers within the detail region
  and survives the sidebar opening.
- **Window title removed.** `.navigationTitle("")` alone only empties the text;
  the toolbar still reserves ~160pt for the title item. `.toolbar(removing:
  .title)` drops the title item itself so the omnibox reclaims that width.
- **Back/Forward moved into the omnibox group.** The nav buttons left their
  standalone toolbar items and now sit flush-left in the omnibox's
  `.navigation` group (`chevron.left`/`chevron.right`, Cmd-[ / Cmd-]).
- **WikiSwitcher moved out of the sidebar header** into the toolbar as a
  `.primaryAction`, trailing the omnibox (like a browser profile control).
- **AppKit `NSSearchField`, not SwiftUI `TextField`.** SwiftUI `TextField`
  cannot accept first responder inside an `NSToolbar` item (the toolbar hosts
  items in a separate view tree, isolated from the window's responder chain). So
  the field is a real `NSSearchField` wrapped in `NSViewRepresentable`.
- **Suggestions in a non-activating child `NSPanel`, not a SwiftUI
  overlay/popover.** The panel never becomes key, so the search field keeps first
  responder while the user types to refine. It is attached as a child window of
  the main window so it tracks window moves.
- **`OmniboxLayout` sizing engine.** Toolbar overflow is the hard part: when the
  window narrows (or the wiki name lengthens) the switcher must drop into the `»`
  overflow and the field must *expand* to reclaim the freed space — and the width
  can't be driven by the field's own leading edge, which the toolbar yanks out of
  the window on overflow, stranding the measurement. Instead the detail column's
  width is measured with `onGeometryChange` (never in overflow) and the pure-math
  `OmniboxLayout` derives the field width from it.
- **Safari-style leading chrome.** The field carries a leading Page Menu glyph
  (Zoom + Find on Page popover) and an add-bookmark "+" that fades in on hover
  when a bookmarkable page/source is showing. These are in an `.overlay` over the
  AppKit field; the field's text is inset (`leadingTextInset`) to clear them.
- **System font, not monospaced.** The idle wikilink renders in the field's
  regular system font. `[[…]]` notation is still shown literally, but the
  monospaced "address" treatment from the original D1 was dropped in favor of
  matching the toolbar's native type.

## Non-goals (v1)

- **No URL display.** Wikilinks are the internal addressing scheme.
- **No agent query.** The bar is pure: location display + semantic search.
- **No source search.** v1 searches pages only. The `searchSimilarSources` API
  exists and mirrors the page path for a future second section.
- **No search history / suggestions.** Just live ranked results.

## Architecture

```
Window toolbar (declared on the detail column)
├── .navigation group
│   └── AddressBarView
│       ├── Back / Forward chevrons (Cmd-[ / Cmd-])
│       └── omniboxField  ── OmniboxSearchField (NSViewRepresentable)
│           │                 wraps an NSSearchField subclass that suppresses
│           │                 the built-in magnifier + clear glyphs
│           ├── .overlay(leading): readerMenuButton (Page Menu)
│           │                       + addBookmarkButton (on hover)
│           └── SuggestionsPanel (non-activating NSPanel child window)
│                              hosts AddressResultsList (SwiftUI)
├── .primaryAction: WikiSwitcher  (moved from sidebar header)
└── primaryToolbarItems()         (existing)
```

### Files

| File | Role |
| --- | --- |
| `Sources/WikiFS/AddressBarView.swift` | The SwiftUI toolbar view: nav buttons, the omnibox field, leading chrome overlays (Page Menu, add-bookmark), the suggestions list (`AddressResultsList`), `AddressBarMetrics`, and the `ReaderControlsMenu` popover. Contains `addressString`, search/navigation actions, and `fieldWidth` delegation to `OmniboxLayout`. |
| `Sources/WikiFS/OmniboxSearchField.swift` | The `NSViewRepresentable` wrapping `NSSearchField` (`AddressSearchField`/`AddressSearchFieldCell`), the `Coordinator` (delegate + keyboard nav state + focus-token handling), and `SuggestionsPanel` (borderless, non-activating `NSPanel`). |
| `Sources/WikiFS/OmniboxLayout.swift` | Pure sizing math (no UI): `fieldWidth(windowWidth:fieldLeadingX:…)` and the `fieldWidth(detailWidth:sidebarVisible:…)` overload the view calls, plus `leadingChrome`, `widthKeepingSwitcher`, `switcherFits`. Unit-tested. |
| `Sources/WikiFS/ContentView.swift` | Toolbar declaration on the detail column (`.navigation` omnibox + `.primaryAction` switcher), `addressBarFocused` state, `detailWidth` measurement via `onGeometryChange`, `.toolbar(removing: .title)`, `activeWikiName`, and the Cmd-L hidden button. |
| `Sources/WikiFS/SidebarView.swift` | `WikiSwitcher` removed from the sidebar header (it lives in the toolbar now); the sidebar starts at the section selector. |
| `Tests/WikiFSTests/OmniboxLayoutTests.swift` | Unit tests for the stretch/shrink/overflow-expand sizing math. |

## Design decisions (as implemented)

### D1: Read-only wikilink in an `NSSearchField`

When idle, the field mirrors the active selection's wikilink into its text. The
`[[…]]` notation is the wiki's native addressing scheme; showing it literally
teaches the syntax and makes copy-paste into page bodies natural. Font is the
field's regular system font (not monospaced). When the field isn't being edited,
`updateNSView` writes `locationText` into `field.stringValue`; while editing it
leaves the user's text untouched.

### D2: Click-to-edit with select-all

Browser behavior: clicking the field (or Cmd-L) focuses it and selects all text,
so typing immediately replaces the location.

- Click / Cmd-L → field becomes first responder, `selectAll`.
- Escape → clear query, defocus, restore wikilink from current page, dismiss
  panel.
- Enter (no results) → no-op.
- Enter (with results) → navigate to the arrow-selected row, or the top result
  when nothing is selected.
- Click a dropdown result → navigate to that page.
- Field loses focus to another responder (`controlTextDidEndEditing`) → clear,
  defocus, restore.

### D3: Debounced semantic search, main-actor

Follows the existing `sourceSearchQuery` pattern, at **200ms** (slightly snappier
than the sidebar's 300ms since this is the primary interaction surface):

```swift
private func runSearch(query: String) {
    searchTask?.cancel()
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { results = []; return }
    searchTask = Task {
        try? await Task.sleep(for: .milliseconds(200))
        if Task.isCancelled { return }
        results = store.searchSimilar(query: trimmed, limit: 8)
    }
}
```

`searchSimilar` runs on the main actor (query embedding + SQLite). This is safe
and consistent with every other search caller. The debounce prevents a search on
every keystroke. MiniLM inference is milliseconds.

### D4: Wikilink string construction

```swift
private var addressString: String {
    guard let selection = store.activeTab?.selection else { return "" }
    switch selection {
    case .page(let id):
        let title = store.summaries.first { $0.id == id }?.title ?? ""
        return title.isEmpty ? "" : "[[\(title)]]"
    case .source(let id):
        let name = store.sources.first { $0.id == id }?.effectiveName ?? ""
        return name.isEmpty ? "" : "[[source:\(name)]]"
    case .systemPrompt: return "[[system-prompt]]"
    case .changeLog:    return "[[log]]"
    case .ask:          return "[[ask]]"
    case .edit:         return "[[edit]]"
    case .lint:         return "[[lint]]"
    case .bookmark:     return ""
    }
}
```

Note: sources use `effectiveName` (not `displayName`). Non-page selections show a
best-effort pseudo-wikilink so the bar is never blank when something is open. If
the active tab is `nil` (empty state), the field is empty with the placeholder
"Search pages…".

### D5: Navigation from a result

```swift
private func navigate(to result: WikiPageSummary) {
    store.selectPage(byTitle: result.title)
    queryText = ""
    results = []
    isFocused = false
}
```

`selectPage(byTitle:)` reuses an open tab if the page is already open, or opens a
new one.

### D6: Suggestions panel + keyboard navigation (shipped in v1)

The dropdown is a **borderless, non-activating child `NSPanel`** (`SuggestionsPanel`)
hosting the SwiftUI `AddressResultsList`. Non-key so the search field keeps first
responder; attached as a child window so it tracks window moves; sized to the
field's width.

**Keyboard navigation was implemented in v1** (the original plan deferred it to
v1.1). Arrow-key highlight state lives on the AppKit `Coordinator` (because the
field editor, not the non-key panel, has first responder) and is pushed into the
SwiftUI list for rendering:

- ↓/↑ → move the highlight (clamped, with wrap on first move from `nil`).
- Enter → navigate to the highlighted row, or the top result when nothing is
  selected.
- The mouse wins over the keyboard: hovering a row takes the highlight so hover
  and arrow selection don't fight.
- The highlight resets whenever the result set changes, so a stale index can't
  point past the end of a shorter list.
- The top/selected row shows a `↩` glyph marking the Enter target.

### D7: Toolbar sizing — `OmniboxLayout` (new, not in original plan)

The field is given an **explicit, measurement-driven width** so it stretches from
just after the nav buttons to the trailing wiki switcher, shrinks as the window
narrows or the wiki name grows, and — once the switcher can no longer fit and
drops into the `»` overflow — expands to fill the freed trailing space.

The view measures only what it can measure reliably: the **detail column's
width** (via `onGeometryChange`, never pulled into toolbar overflow) and the
sidebar state. It does **not** measure the field's own leading edge (which the
toolbar strands on overflow). `OmniboxLayout.fieldWidth(detailWidth:
sidebarVisible: switcherExtra:)` turns those into a width:

- `switcherExtra` = rendered width of the current wiki name minus a baseline
  name (only the text-width *difference* matters; the switcher's fixed
  icon/chevron overhead cancels out).
- Leading chrome differs by sidebar state: with the sidebar shown, only the nav
  buttons sit left of the field; hidden, the detail region spans the whole
  window and also includes the traffic-light + toggle zone.
- Clamps: never below `minWidth` (120), never above `maxWidth` (1200); returns
  `minWidth` before geometry is known (width 0).

### D8: Leading chrome — Page Menu + add-bookmark (new, not in original plan)

An `.overlay(alignment: .leading)` over the field renders Safari-style controls:

- **Page Menu** (`readerMenuButton`): opens a popover (`ReaderControlsMenu`)
  with a **Zoom** row (−/percentage/`+` stepper, tap percentage for Actual Size)
  and a **Find on Page…** row. Zoom writes the shared `@AppStorage("reader.zoom")`
  value the detail views render from; Find sends the standard
  `performTextFinderAction` down the responder chain.
- **Add-bookmark "+"** (`addBookmarkButton`): revealed on hover when a
  bookmarkable page/source is showing. Adds it to the Bookmarks root via
  `store.addPageRef` / `store.addSourceRef`. The text leading inset is reserved
  whenever a bookmarkable selection is showing (not just on hover) so the text
  doesn't jump when the "+" fades in.

### D9: Cmd-L focus trigger

`ContentView` holds `@State var addressBarFocused` and passes `$addressBarFocused`
into `AddressBarView`. A hidden Cmd-L button sets it true (always focus, never
toggle — browser convention). `AddressBarView` observes `.onChange(of: isFocused)`
and bumps a `focusToken` counter; the `NSViewRepresentable`'s `updateNSView`
detects the token change and, on the main queue, makes the field first responder
and selects all. (The token-counter approach was chosen over a direct
`@FocusState` binding because the first responder is the AppKit field, not a
SwiftUI focusable.)

## Testing

### Unit tests (shipped)

`Tests/WikiFSTests/OmniboxLayoutTests.swift` covers the pure sizing math with a
fixed `Metrics`:

- Fills to the switcher on a wide window; a longer wiki name shrinks the field
  1-for-1, a shorter one grows it.
- Open sidebar pushes the leading edge and shrinks the field.
- Overflow threshold + expansion: switcher stays until the field reaches its
  floor, overflows just below it, and the field *expands* past the floor to
  reclaim freed space (jumps wider, not narrower, across the threshold).
- A long wiki name triggers overflow sooner.
- Clamps: never below `minWidth` (tiny window), never above `maxWidth` (huge
  window), returns `minWidth` before geometry is known.
- The `detailWidth` driver delegates to the core math and is sidebar-aware.

The `addressString` construction and search-debounce logic are **not** unit-tested
(`addressString` is a private computed property; debounce mirrors the existing
sidebar pattern). They are covered by the manual gate below.

### Manual gate (live app)

1. Select a page → bar shows `[[Page Title]]`.
2. Cmd-L → bar focuses, text selected, dropdown does NOT appear (query empty).
3. Type a few words → dropdown shows ranked results within ~200ms.
4. Click a result → navigates to that page, bar defocuses, shows new wikilink.
5. ↓/↑ in the dropdown → rows highlight; Enter → navigates to the highlighted
   (or top) result.
6. Escape while typing → bar defocuses, restores current page wikilink.
7. Switch tabs → bar updates to the new active page's wikilink.
8. Open the system-prompt or a source → bar shows the pseudo-wikilink.
9. Empty state (no tabs) → bar shows placeholder, typing still searches.
10. Page Menu → Zoom in/out/actual; Find on Page opens the find bar.
11. Hover a page/source → "+" appears; click → adds to Bookmarks root.
12. Narrow the window → switcher overflows into `»`; the omnibox reclaims the
    space and widens. Lengthen the wiki name → omnibox shrinks.
13. Open/close the left sidebar → omnibox reflows correctly.

## Build / lint

```bash
swift build                                            # compile
swift test --filter OmniboxLayoutTests                 # sizing math
```

(No `print` diagnostics; all logging routes through `DebugLog`.)

## Future enhancements (post-v1)

- **Agent escalation** — an "Ask the agent…" row at the bottom of the dropdown,
  opt-in, for when semantic search isn't enough.
- **Source search** — include `searchSimilarSources` results in the dropdown
  (second section).
- **Search history** — remember recent queries, show as suggestions on focus
  before typing.
- **Frecency ranking** — bias results by pages you've visited recently.
- **Middle-truncation of long wikilinks** — the `NSSearchField` currently
  tail-truncates; a center-ellipsis (browser URL-bar style) is a polish item.
