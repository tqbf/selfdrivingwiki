# Editor Wiki-link Autocomplete (#680)

**Status:** Implemented (branch `editor-autocomplete`, PR pending). Closes #680.
**Status:** Implementation + tests merged into the branch; unreleased upstream.
**Predecessors:** #616/#623 (drag sidebar items into editor — same canonical
link forms); #436/#638/#650 (chat composer autocomplete); #684 (panel
placement generalized to `.above`/`.below`/`.auto`).

## What this adds

When editing a page or source in markdown edit mode, typing `[[page:Erl…`
(or `[[source:Name…`, `[[chat:Title…`, or bare `[[Foo`) in the editor now
fires the same Tantivy fuzzy autocomplete the chat composer uses, surfaces
the ranked hits in a dropdown at the caret, and inserts the canonical
`[[kind:ULID|Title]]` form on selection (Return or click). Identical UX to
the chat composer, anchored below the caret (the editor is a tall NSTextView
with more room below than above; the chat composer's `.above` placement is
driven by being clamped to the bottom of the chat window).

## Reuse model

#684 generalized the panel's API:

```swift
enum Placement { case above, below, auto }

func present(
    caretRect: NSRect, in window: NSWindow,
    placement: Placement = .above,
    gap: CGFloat = 4, horizontalOffset: CGFloat = 0
)

static func caretRect(in textView: NSTextView) -> NSRect?

static func origin(
    caretRect: NSRect, panelSize: NSSize, windowFrame: NSRect,
    placement: Placement, gap: CGFloat = 4, horizontalOffset: CGFloat = 0
) -> NSPoint
```

The editor reuses ALL four (no panel changes required). The chat composer
passes `.above`; the editor passes `.below`.

The Tantivy fetch path is shared via the same `WikiLinkAutocompleteHooks`
factory (`SidebarDropBuilder.wikiLinkAutocompleteHooks(store:)`), mirroring
the chat composer's `ChatView.chatAutocompleteHooks`. Both build the canonical
link via `DroppedLinkFormatter.link(for:id:displayName:)`, so the same
ULID-pinned `[[kind:ULID|Title]]` form lands at the caret whether it arrives
by typing-and-autocomplete (editor) or drag-and-drop (#616) or typing-and-
autocomplete (chat composer).

## Refactor: WikiLinkAutocompleteController

The chat composer's autocomplete pipeline was previously inlined in
`ComposerTextView.Coordinator` (#436/#638/#650/#661). #680 extracts it into a
reusable `@MainActor final class WikiLinkAutocompleteController` so the chat
composer (`ComposerTextView`) and the editor (`ScrollableTextEditor`) share
one implementation. The chat composer was refactored WITHOUT behavior change
— its hosted tests pass unmodified. The composer-specific `.send`/`.insertNewline`
distinction stays on `ComposerTextView.keyAction`, since `.send` (plain
Return when dropdown closed → send message) is composer-only; the editor
just lets plain Return fall through to NSTextView's default newline insert.

## File touch map (implementation)

| File | Change |
| --- | --- |
| `Sources/WikiFS/Editor/WikiLinkAutocompleteController.swift` | New. Reusable controller + hooks struct + debounce handle. |
| `Sources/WikiFS/Editor/ComposerTextView.swift` | Coordinator delegates to controller; `AutocompleteHooks` / `DebounceHandle` are now typealiases to the new top-level types (chat tests unchanged). |
| `Sources/WikiFS/Editor/ScrollableTextEditor.swift` | Added `autocomplete`, `autocompletePlacement`, `autocompleteDebounce`, `autocompleteScheduleDebounce` params; `dismantleNSView` tears down the controller. |
| `Sources/WikiFS/Editor/SidebarDropBuilder.swift` | New `wikiLinkAutocompleteHooks(store:)` factory. |
| `Sources/WikiFS/Pages/PageDetailView.swift` | Passes the autocomplete hooks into the editor. |
| `Sources/WikiFS/Sources/SourceDetailView.swift` | Same. |
| `Tests/WikiFSTests/EditorAutocompleteHostedTests.swift` | New, 12 tests mirroring `ComposerAutocompleteHostedTests`. |

## Acceptance criteria

1. ✓ Detect `[[` + open-link prefix at the caret.
2. ✓ Debounce + cancel stale in-flight queries (150ms production; `ManualScheduler` for tests).
3. ✓ Filter results by kind from the prefix (`source:`/`page:`/`chat:`/bare).
4. ✓ Show the panel at the caret, preferred `.below` for the editor.
5. ✓ ↑/↓ navigate; Escape dismisses; plain Return commits the selected row.
6. ✓ Inserted text uses the canonical ULID form: `[[page:ULID|Title]]` etc. (same form as drag-wikilinks #616).
7. ✓ `swift test` — full suite passes (3043 tests / 259 suites).
8. ✓ Chat composer behavior unchanged (8 hosted tests + 4 selection tests + 8 panel placement tests + Tantivy autocomplete tests pass unmodified).

## Follow-ups (out of scope here)

- **`.auto` placement for the editor** — currently the editor pins `.below`;
  the panel already supports `.auto` (picks the roomier side). Will become
  valuable when the editor's NSTextView sits in a short / split-view window
  where below-caret room is constrained. The math is already tested in
  `ChatAutocompletePanelPlacementTests`.
- **Spans across the alias `|`** — the prefix scanner bails on `|` because
  `[[page:Foo|al…]]` is an aliased link (alias text isn't autocompleteable
  against the index). Could be relaxed to support alias autocomplete in a
  future iteration.
- **Type-display on hover for ambiguous matches** — when two ULIDs share a
  title (rare for pages, possible for sources), the dropdown could show the
  ULID tail in a tertiary caption. Not user-visible today.
