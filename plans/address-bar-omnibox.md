# Address bar / omnibox

**Status:** Design.
**Depends on:** existing semantic search (`store.searchSimilar`), tab system
(`activeTabID`, `selectPage(byTitle:)`), `WikiSelection`.

## Goal

Add a browser-style **address bar** at the top of the detail pane — above the
tab strip — that serves two roles depending on focus state, with no explicit
mode switch required from the user:

1. **Idle (not focused):** displays the active page's wikilink
   (`[[Page Title]]`), read-only — the "where am I" indicator, like a browser
   URL bar.
2. **Focused / typing:** becomes a semantic search field. Typing debounces into
   `store.searchSimilar(query:)` and shows a ranked dropdown of matching pages.
   Selecting a result (or pressing Enter) navigates to it.

The agent query path is deliberately **excluded** from the bar in v1. Semantic
search is fast (ms), predictable, and browser-like. Agent escalation can be
added later as an opt-in entry at the bottom of the dropdown.

## Non-goals (v1)

- **No URL display.** Wikilinks are the internal addressing scheme; the
  multiple-selection / URL case from the original brainstorm is dropped.
- **No agent query.** The bar is pure: location display + semantic search.
- **No source search.** v1 searches pages only. Sources can be added later
  (the `searchSimilarSources` API exists and mirrors the page path).
- **No search history / suggestions.** Just live ranked results.

## Why this is low-risk

The entire backend already exists:

| Need | Existing API | Location |
| --- | --- | --- |
| Semantic search | `store.searchSimilar(query:limit:) -> [WikiPageSummary]` | `WikiStoreModel.swift:305` |
| Navigate to result | `store.selectPage(byTitle:) -> Bool` | `WikiStoreModel.swift:275` |
| Active page identity | `store.activeTab?.selection` → `WikiSelection.page(PageID)` | `WikiStoreModel.swift:103` |
| Page title from id | `store.summaries.first { $0.id == id }?.title` | used throughout (e.g. `PageDetailView:75`) |
| Debounced search pattern | `sourceSearchQuery` + `sourceSearchTask` (300ms) | `WikiStoreModel.swift:66` |
| Focus shortcut | hidden `.opacity(0)` Button pattern | `ContentView.keyboardShortcutButtons` |

No new store methods, no schema changes, no agent coupling. This is a pure
view-layer feature.

## Layout

### Insertion point

The detail column in `ContentView` is currently:

```swift
VStack(spacing: 0) {
    TabBarView(store: store)
    wikiDetailPane
}
```

The address bar goes **above** the tab strip (Safari / Firefox convention —
address bar on top, tabs below):

```swift
VStack(spacing: 0) {
    AddressBarView(store: store)      // NEW
    TabBarView(store: store)
    wikiDetailPane
}
```

### Visual sketch

```
┌──────────────────────────────────────────────────────┐
│  [[Lane/Keeping]]                              🔍    │  idle: wikilink, read-only
├──────────────────────────────────────────────────────┤
│  [Tab 1] [Tab 2] [Tab 3]                        ⌄   │  tab strip (unchanged)
├──────────────────────────────────────────────────────┤
│                                                      │
│                   page content                       │
│                                                      │
```

When focused and typing:

```
┌──────────────────────────────────────────────────────┐
│  how does lane keeping work                     🔍   │  editable
├──────────────────────────────────────────────────────┤
│  [[Lane Keeping]]                          0.94      │  semantic results dropdown
│  [[Steering Control]]                      0.88      │  (debounced searchSimilar)
│  [[Path Planning]]                         0.81      │
├──────────────────────────────────────────────────────┤
│  [Tab 1] [Tab 2] [Tab 3]                        ⌄   │
```

## Design decisions

### D1: Read-only wikilink, not a styled label

When idle, the bar shows the wikilink notation `[[Page Title]]` as plain
monospaced text (matching the wiki's own link syntax). This reinforces "this is
a location, not editable right now" and is visually distinct from the editable
state. Clicking or Cmd-L switches to editable mode.

Rationale: the `[[…]]` notation is the wiki's native addressing scheme. Showing
it literally teaches the user the syntax and makes copy-paste into page bodies
natural.

### D2: Click-to-edit with select-all

Browser behavior: clicking the address bar (or Cmd-L) focuses it and selects
all text, so typing immediately replaces the location. We replicate this:

- Click → `isFocused = true`, `textFieldText = wikilinkString`, select all.
- Cmd-L → same.
- Escape → `isFocused = false`, restore wikilink from current page, dismiss
  dropdown.
- Enter (empty or non-matching) → no-op (don't navigate to nothing).
- Enter (with results) → navigate to top result.
- Click a dropdown result → navigate to that page.

### D3: Debounced semantic search, main-actor

Follows the existing `sourceSearchQuery` pattern exactly:

```swift
@State private var queryText: String = ""
@State private var searchTask: Task<Void, Never>?
@State private var results: [WikiPageSummary] = []

private func runSearch() {
    searchTask?.cancel()
    let trimmed = queryText.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty {
        results = []
        return
    }
    searchTask = Task {
        // 200ms debounce — slightly snappier than the sidebar's 300ms since
        // this is the primary interaction surface.
        try? await Task.sleep(for: .milliseconds(200))
        if Task.isCancelled { return }
        results = store.searchSimilar(query: trimmed, limit: 8)
    }
}
```

**SQLite concurrency note:** `searchSimilar` runs on the main actor (query
embedding + SQLite). This is safe and consistent with every other search caller
(the "Find Similar…" menu, the sidebar). The debounce prevents a search on every
keystroke. MiniLM inference is milliseconds, not the old NLEmbedding cliff.

### D4: Wikilink string construction

For the idle display, resolve the active selection to its wikilink:

```swift
private var addressString: String {
    guard let selection = store.activeTab?.selection else { return "" }
    switch selection {
    case .page(let id):
        let title = store.summaries.first { $0.id == id }?.title ?? ""
        return title.isEmpty ? "" : "[[\(title)]]"
    case .source(let id):
        // v1: show the source's display name. Sources use [[source:Name]] syntax.
        let name = store.sources.first { $0.id == id }?.displayName ?? ""
        return name.isEmpty ? "" : "[[source:\(name)]]"
    case .systemPrompt: return "[[system-prompt]]"
    case .changeLog: return "[[log]]"
    case .ask: return "[[ask]]"
    case .edit: return "[[edit]]"
    case .lint: return "[[lint]]"
    case .bookmark: return ""
    }
}
```

Non-page selections show a best-effort pseudo-wikilink so the bar is never
blank when something is open. If the active tab is `nil` (empty state), the bar
is empty with a placeholder.

### D5: Navigation from a result

Selecting a result calls the existing API:

```swift
private func navigate(to result: WikiPageSummary) {
    store.selectPage(byTitle: result.title)
    isFocused = false
    queryText = ""
    results = []
}
```

`selectPage(byTitle:)` reuses an open tab if the page is already open, or opens
a new one — exactly the behavior we want.

### D6: Dropdown implementation

A SwiftUI `.overlay` or `popover` anchored below the bar, showing the ranked
results. Each row: page title (semibold), optional snippet/score (caption, dim).
Keyboard navigation (up/down to highlight, Enter to select) is desirable but can
be deferred to v1.1 if it complicates the initial implementation.

**Recommendation:** start with click-only selection for v1, add keyboard
up/down/Enter-in-dropdown in a follow-up. The Enter-navigates-to-top-result
behavior covers the "type and go" path without needing full dropdown keyboard
control.

## Implementation plan

### Phase 1 — `AddressBarView` (new file)

**New file:** `Sources/WikiFS/AddressBarView.swift`

A self-contained SwiftUI view:

```
struct AddressBarView: View {
    @Bindable var store: WikiStoreModel
    @State private var isFocused = false
    @State private var queryText = ""
    @State private var results: [WikiPageSummary] = []
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var fieldFocused: Bool
}
```

Components:
- **Idle state:** `Text(addressString)` in a rounded-rect container
  (`.background(.regularMaterial)`, subtle border). Monospaced font to signal
  "address." Click sets `fieldFocused = true`.
- **Focused state:** `TextField` bound to `queryText`, `.onChange(of: queryText)`
  → `runSearch()`. Placeholder: "Search pages…".
- **Dropdown:** `.overlay(alignment: .top)` below the bar, shown when
  `!results.isEmpty && fieldFocused`. `VStack` of result rows.
- **Dimissal:** Escape cancels (defocus, clear, restore). Clicking a result
  navigates. Losing focus (`.onSubmit` or tap-outside) defers to D2 behavior.

Metrics: match the tab bar's visual language — `.regularMaterial` background,
same height (~28–30pt), divider below.

### Phase 2 — Wire into `ContentView`

In `ContentView.detailColumn`, insert `AddressBarView(store: store)` above
`TabBarView`:

```swift
VStack(spacing: 0) {
    AddressBarView(store: store)      // NEW
    TabBarView(store: store)
    wikiDetailPane
}
```

### Phase 3 — Keyboard shortcut (Cmd-L)

Add a hidden button to `ContentView.keyboardShortcutButtons`:

```swift
// Cmd-L: Focus address bar
Button("") { /* focus address bar */ }
    .keyboardShortcut("l", modifiers: .command)
    .opacity(0).allowsHitTesting(false)
```

This requires a focus trigger from `ContentView` into `AddressBarView`. Options:
- **`@FocusState` binding passed down** (cleanest in modern SwiftUI).
- **A shared `@State var addressBarFocusRequest` counter** that the bar observes
  via `.onChange` and sets `fieldFocused = true`.

Recommend the `@FocusState` binding approach — pass a `FocusState<Bool>.Binding`
from `ContentView` into `AddressBarView`.

### Phase 4 — Polish

- Empty-state placeholder when no tab is open: "Search pages…" (greyed).
- Truncate long wikilinks in the idle display (`.lineLimit(1)`,
  `.truncationMode(.middle)` — like a browser truncating a long URL in the
  center).
- Animation: subtle crossfade between idle Text and focused TextField (respect
  `accessibilityReduceMotion`).
- Verify the bar doesn't intercept the existing `.dropDestination` or
  `NavigationSplitView` toolbar.

## Testing

### Unit tests (core logic)

The view itself is SwiftUI, but the logic can be extracted and tested:

- **`addressString` construction** — given a `WikiSelection.page(id)` with a
  known title, produces `[[Title]]`. Given `.source(id)`, produces
  `[[source:Name]]`. Given `nil`, produces `""`.
- **Search debounce** — verify that rapid keystrokes cancel the previous task
  and only the final query runs (follow `EditorTabTests` patterns).

### Manual gate (live app)

1. Select a page → bar shows `[[Page Title]]`.
2. Cmd-L → bar focuses, text selected, dropdown does NOT appear (query empty).
3. Type a few words → dropdown shows ranked results within ~200ms.
4. Click a result → navigates to that page, bar defocuses, shows new wikilink.
5. Escape while typing → bar defocuses, restores current page wikilink.
6. Switch tabs → bar updates to the new active page's wikilink.
7. Open the system-prompt or a source → bar shows the pseudo-wikilink.
8. Empty state (no tabs) → bar shows placeholder, typing still searches.

## Future enhancements (post-v1)

- **Keyboard navigation in dropdown** (up/down/Enter) — v1.1.
- **Agent escalation** — a "Ask the agent…" row at the bottom of the dropdown,
  opt-in, for when semantic search isn't enough.
- **Source search** — include `searchSimilarSources` results in the dropdown
  (second section).
- **Search history** — remember recent queries, show as suggestions on focus
  before typing.
- **Frecency ranking** — bias results by pages you've visited recently.
