---
timestamp: 2026-07-19T231648Z
title: "2026-07-19 — Issue #680: wiki-link autocomplete in the page/source editor (branch `editor-autocomplete`)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-19 — Issue #680: wiki-link autocomplete in the page/source editor (branch `editor-autocomplete`)

## Progress


**Problem:** When editing a page or source in markdown edit mode, the user
could drag-drop a sidebar item to insert a canonical wikilink (#616, #623)
but had no fuzzy-completion path while typing `[[page:Erl…` directly into the
editor. The chat composer had just shipped fuzzy autocomplete (#436, #638,
#650) and #684 generalized the panel's `present()` API to take a caret rect +
placement (`Placement.above` / `.below` / `.auto`) — explicitly in preparation
for editor reuse. #680 wires that reuse.

**Solution:** Extract the chat composer's autocomplete pipeline into a
reusable controller, then host the controller in `ScrollableTextEditor` (the
NSTextView-backed editor for both `PageDetailView` and `SourceDetailView`).

- `Sources/WikiFS/Editor/WikiLinkAutocompleteController.swift` (new, ~500
  lines) — `@MainActor final class` owning the dropdown panel, the debounced
  Tantivy fetch, the local ↑/↓/Escape `NSEvent` monitor, and the
  canonical-link insertion. Takes (hooksProvider, debounceProvider,
  scheduleDebounceProvider, placement, widthProvider) closures so the host
  (`ComposerTextView.Coordinator` for chat, `ScrollableTextEditor.Coordinator`
  for the editor) supplies the AppKit-specific bits and a placement
  preference (chat → `.above`, editor → `.below`). The chat composer's
  `AutocompleteHooks` is now a `typealias` to the new top-level
  `WikiLinkAutocompleteHooks` so the existing tests compile unchanged; same
  for `DebounceHandle` → `WikiLinkAutocompleteDebounceHandle`. Includes two
  pure kind-mapping helpers (`tantivyKind(for:)`,
  `parsedLinkType(from:)`) named to avoid colliding with the existing
  `SidebarDropBuilder.linkType(for: SidebarDragPayload.Kind)` overload (both
  enums share `.page` / `.source` / `.chat` cases, so a call like `linkType(for:
  .source)` would be ambiguous if both overloads existed under the same name).
  Also includes a `textBinding: (@MainActor (String) -> Void)?` hook the host
  sets so the canonical inserted form syncs to the SwiftUI `@Binding`
  synchronously (don't wait for the next `textDidChange` notification).
- `Sources/WikiFS/Editor/ComposerTextView.swift` — the chat composer's
  `Coordinator` deleted ~270 lines of inlined autocomplete state and
  pipeline code, replaced with `autocompleteController: WikiLinkAutocompleteController?`
  built lazily from the parent's hooks in `ensureAutocompleteController()`.
  `textDidChange` and `textView(_:doCommandBy:)` delegate to the controller.
  Behavior is unchanged (chat composer tests pass without modification). The
  composer-specific `ComposerTextView.keyAction(for:modifiers:autocompleteOpen:)`
  static helper and `.send`/`.insertAutocomplete`/`.insertNewline`/`.unhandled`
  enum all stay on `ComposerTextView` — the composer needs the `.send`
  branch (plain Return → send message) that the editor doesn't.
- `Sources/WikiFS/Editor/ScrollableTextEditor.swift` — added the
  `autocomplete: WikiLinkAutocompleteHooks?`, `autocompletePlacement:
  ChatAutocompletePanel.Placement = .below`, `autocompleteDebounce: UInt64`,
  `autocompleteScheduleDebounce: ((...) -> WikiLinkAutocompleteDebounceHandle)?`
  parameters and a new `dismantleNSView` that calls
  `coordinator.teardownAutocomplete()` (mirrors the chat composer's teardown
  so a stale SwiftUI hosting view can't leak). The coordinator's
  `textDidChange` routes to the controller; `textView(_:doCommandBy:)` is
  new and consumes plain Return when the dropdown is open (otherwise falls
  through — the editor doesn't have a `.send` path).
- `Sources/WikiFS/Editor/SidebarDropBuilder.swift` — new
  `wikiLinkAutocompleteHooks(store: WikiStoreModel) -> WikiLinkAutocompleteHooks?`
  factory that builds the fetch + format closures from `store.tantivySearch`
  (mirrors `ChatView.chatAutocompleteHooks` at
  `Sources/WikiFS/Chats/ChatView.swift:736`). Same Tantivy fuzzy
  `search.autocomplete(partial:kinds:distance:2,limit:8)` query path and
  same `DroppedLinkFormatter.link(...)` canonical-form builder. Returns `nil`
  when no Tantivy service is attached (wiki closed) — the editor behaves
  exactly as before autocomplete was added.
- `Sources/WikiFS/Pages/PageDetailView.swift` — passes the autocomplete
  hooks from `store` into `ScrollableTextEditor` in `editorContent`.
- `Sources/WikiFS/Sources/SourceDetailView.swift` — same wiring in
  `markdownContent`.

**Panel reuse (#684):** The chat composer's `ChatAutocompletePanel` already
had (a) `enum Placement { case above, below, auto }`, (b)
`present(caretRect:in:placement:...)` — caret-rect + placement-aware, (c)
`static caretRect(in: NSTextView) -> NSRect?` mapped from the live layoutManager
to screen coordinates, (d) the pure `origin(caretRect:panelSize:windowFrame:placement:...)`
helper. #680 reuses all four via the new controller — no panel changes were
required. The chat composer keeps `.above` (composer lives at the bottom of the
chat window); the editor uses `.below` (a tall NSTextView mid-window has more
room below the caret than above). `ChatAutocompletePanelPlacementTests` (8
tests, from #684) already cover the placement math for both directions.

**Tests:** `Tests/WikiFSTests/EditorAutocompleteHostedTests.swift` (new, 12
tests) mirrors `ComposerAutocompleteHostedTests`: trigger detection, debounce
+ cancel stale in-flight partials, no-trigger / closed brackets / newline /
overlong-paste guards, source/chat kind routing, nil hooks (no wiki), and
editor-specific `shouldConsumeReturn` cases (editor doesn't have `.send` —
plain Return with dropdown closed falls through to insert a newline;
Shift/Option/Cmd + Return never consume; plain Return with dropdown open
commits the selected row and replaces the trigger span with the canonical
`[[page:ULID|Title]]` form). The existing chat composer's 8 hosted tests +
4 `ChatAutocompleteSelectionTests` + 8 `ChatAutocompletePanelPlacementTests`
+ `TantivyAutocompleteTests` all pass unchanged — the controller extraction is
behavior-preserving for the chat path.

**Build/Tests:** `make version prompts` ✓; `swift build` ✓; full `swift
test` ✓ — **3043 tests / 259 suites pass**, no regressions (was 3033; +10
net new tests in the new editor suite — the 2 non-controller tests in the
new file were ported from parallel chat-suite ones).

**Status:** PR open (branch `editor-autocomplete`), not merged. Closes #680.

## Verification

Historical verification remains in the progress record above.
