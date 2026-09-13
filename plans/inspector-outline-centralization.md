# Inspector outline centralization

Status: implemented on `bugfix/chat-outline-switch`. One pipeline renders the
right-inspector Outline pane for pages, sources, and chats.

## Problem

The app built the outline three times. Each detail view constructed its own
`RightSidebarRegistration` with an `outline: () -> AnyView` closure and its own
`@AppStorage` tab and width keys. Pages and sources rendered through
`PageOutlineView`, whose `@State headings` populated in `.onAppear` and
`.onChange(of: markdown)`. Chats rendered through `ChatInspectorOutlineView`
with value rows. Only the shell was shared:
`WindowRightInspectorController` → `ContentView`'s `RightSidebarHostView` →
`DetailInspectorView`.

The closure plus view-local `@State` lifecycle produced the operator-visible
bug. The Outline pane opened completely blank for a page and for the
`iZ_hhezC1mA` source, although registration logs proved the content existed.
The live source registered with `markdownChars=32570 outlineTab=true` and the
pane still drew nothing.

Hosted reproductions passed for every isolated path: the page-to-page journey,
the source mount, and the source mount with `renderer_source_preferences`
dropped (the operator's live wiki misses that table). The failure lived in the
triplicated lifecycle dynamics that only the real window composition exercised.
The chat surface needed its own fix during the investigation - eager entry
values, deferred registration, and a chat-only refresh modifier - which
confirmed the divergence.

## Design

Every subject follows the chat surface's proven shape: values, not closures.

```
PageDetailView ──┐
SourceDetailView ─┤─► InspectorOutlinePayload ─► RightSidebarRegistration
ChatDetailView ──┘        (Equatable value)          │
                                                    ▼
                                    WindowRightInspectorController
                                                    │ accepts while subject is active
                                                    ▼
                       DetailInspectorView ─► InspectorOutlineView (one renderer)
```

Core types live in `Sources/WikiFS/Detail/InspectorOutline.swift`:

- `OutlineHeading` - one markdown outline row: anchor-slug `id`, display text,
  level, and the UTF-16 `charOffset` of the heading's line start.
- `InspectorOutlinePayload` - the registered value: `subject`, a two-case
  `content` (`.headings([OutlineHeading])` or `.chatTurns([ChatOutlineEntry])`),
  and `highlightedItemID` for caret tracking. Derived `rowCount`, `isEmpty`,
  and `contentKindDescription` serve the tests and the acceptance log.
- `InspectorOutlineSelection` - a row tap routed back to the producer:
  `.heading(OutlineHeading)` or `.chatTurn(ChatOutlineEntry.ID)`.
- `InspectorOutlineView` - the single renderer. It reproduces the former
  `PageOutlineView` row styling (indentation by level, hover cursor,
  active-heading highlight, auto-scroll on highlight change) and the former
  chat row styling (timestamps, tap-gesture rows, copy menu). An empty payload
  renders an explicit empty state, never blank space.

`Sources/WikiFS/Detail/OutlineParser.swift` holds the pure parsing:

- `OutlineParser.headings(in:)` - moved verbatim from the former
  `PageOutlineView.parseHeadings`. Fence tracking, ATX level validation,
  whitespace after `#`, empty-text guards, inline markup stripping, and
  `AnchorBlock.makeSlug` dedup all behave exactly as before. The parser emits
  no logs.
- `OutlineParser.activeHeadingID(caretUTF16Offset:headings:)` - the last
  heading whose `charOffset` is at or before the caret. Producers pass
  `caretCharIndex ?? -1` when no caret exists. Same UTF-16 coordinate space as
  the editors' `NSTextView` ranges.

`RightSidebarRegistration` now carries `outline: InspectorOutlinePayload` plus
one typed `onOutlineSelect: (InspectorOutlineSelection) -> Void`. No
view-producing closure survives; a registration cannot outlive state a closure
captured.

## Refresh trigger

`Sources/WikiFS/Detail/SidebarRegistrationRefresh.swift` generalizes the
chat-private modifier. Each producer derives its payload in the body:

- Page: `OutlineParser.headings(in: store.draftBody)` plus the caret-derived
  `highlightedItemID`.
- Source: the same derivation over `currentMarkdownContent`, gated by
  `showsSourceOutlineTab`; nil or inapplicable markdown yields an empty payload.
- Chat: `.chatTurns(presentation.outlineEntries)`; the Phase-0 hydration
  gating and loaded presentation are unchanged.

The modifier observes the one `Equatable` payload and re-registers on change.
Because the payload holds the entries, the chat-only `projectionInput` trigger
is gone. Registration churn stays low: a payload changes only when the rows or
the highlight bucket change, not on every keystroke.

## Log seams

Exactly two outline-content seams remain, both on `DebugLog.tabs`:

1. `Inspector outline payload accepted: subject=… kind=… rows=… isEmpty=…` in
   `WindowRightInspectorController.updateRegistration` - one line per accepted
   payload.
2. `Inspector outline redraw: subject=… rows=…` in `InspectorOutlineView`.

The pre-existing stale-registration rejection log stays; it is registration
lifecycle, not outline content. All transitional lines are gone: the per-surface
`registration published` lines, the chat `registration deferred` line, the
per-surface redraw logs, `PageOutline parsed`, `Inspector outline branch`, and
`Right inspector subject replaced`.
`InspectorOutlineLoggingContractTests` scans `Sources/WikiFS` and enforces the
exact allowed set.

## Evidence and mechanism

The live trace from the redraw-instrumented build never arrived, so the exact
failure frame is unconfirmed. The refactor does not depend on it: the closure
plus `@State` class that produced the blank pane no longer exists. Every
registration carries rows as values, the renderer is one view, and the hosted
tests now cover the previously untested dimension - cross-type subject swaps
(chat → page, page → source, source → chat) with the inspector open.

## Tests

- `OutlineParserTests` - parse semantics plus `activeHeadingID` boundaries and
  a 95K-character single-heading transcript under 50 ms.
- `InspectorOutlineHostedTests` - payload assertions for page and source, the
  cross-type swap journey with pixel oracles, caret-move tests for the page
  editor and the editable source, and the empty-state render check.
- `ChatOutlineRehydrationHostedTests` - the first accepted chat registration
  carries a non-empty `.chatTurns` payload; the pixel oracle stays as a visual
  backstop.
- `InspectorTabTests` and `MetadataPanelHostedTests` - registration fixtures on
  the value API.

## Out of scope

- What counts as an outline entry. Chat turn derivation is untouched.
- The missing `renderer_source_preferences` migration on existing wikis. The
  operator's live wiki hits a SQLite error at every source registration. The
  missing-table hosted test proves it is not outline-related; it deserves its
  own migration fix.
- Any extractor or transcript-content change.
