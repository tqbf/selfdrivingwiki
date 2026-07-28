---
timestamp: 2026-07-19T213403Z
title: "2026-07-19 — Fix chat autocomplete panel positioning (branch `fix-autocomplete-pos`)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-19 — Fix chat autocomplete panel positioning (branch `fix-autocomplete-pos`)

## Progress


**Problem.** The chat composer's `[[kind:partial` autocomplete dropdown
(`ChatAutocompletePanel`) appeared several lines above the caret instead of
just above the current line. Two compounding bugs in `present(above:)` at
`Sources/WikiFS/Chats/ChatAutocompletePanel.swift:80`:

1. The panel anchored to the **entire NSTextView's bounds**
   (`anchor.convert(anchor.bounds, to: nil)`) rather than the caret line —
   for a 3-line default composer, the anchor's top is 3 lines above the
   caret, so the panel was 3 lines too high before even counting the panel
   gap math.
2. The above-placement math added `frame.height` to the origin Y
   (`rectOnScreen.maxY + frame.height + 4`), leaving a panel-height-plus-4pt
   gap between the anchor's top and the panel's bottom — visually "a panel
   too high". The below-fallback math in the same method matched the omnibox's
   correct below-placement math, so only the above path was wrong.

**Scope.**

- `Sources/WikiFS/Chats/ChatAutocompletePanel.swift` — replaced
  `present(above: NSView)` with caret-relative positioning, generalized so
  the editor autocomplete (#680, not yet implemented) can reuse the same
  panel with different placement heuristics. New API:
  - `enum Placement { case above, below, auto }` — preferred direction.
    `.above` is the chat composer convention (composer is near the bottom
    of the chat window, so below-caret is clipped); `.below` will be the
    editor convention (the editor is tall, more room below the caret);
    `.auto` picks whichever side has more room tie-broken to `.above`.
  - `nonisolated static func origin(caretRect:panelSize:windowFrame:placement:gap:horizontalOffset:)`
    — pure, testable origin computation. No AppKit state access (only
    `NSRect`/`NSPoint`/`NSSize`/`CGFloat` arithmetic on value types). The
    "room above/below" math is measured against the caret rect, not the
    window — so `.auto` is genuinely caret-relative, not window-relative.
  - `func present(caretRect:in:placement:gap:horizontalOffset:)` — instance
    method: computes the origin via the static helper, sets the frame,
    attaches as a child window (`addChildWindow(_:ordered:)`) so it tracks
    window moves, keeps the parent-window attachment idempotent via the
    `parent == nil` guard.
  - `@MainActor static func caretRect(in textView: NSTextView) -> NSRect?`
    — canonical AppKit recipe for the screen-coordinate caret-line rect:
    `ensureLayout(for:)` → `glyphRange(forCharacterRange:length:0)` →
    `lineFragmentRect(forGlyphAt:effectiveRange:)` (gets the line's full
    height, important so "above vs below" measures against the full line,
    not a 0-height point) → `textContainerOrigin` offset →
    `convert(_:to: nil)` → `convertToScreen(_:)`. Handles the empty-document
    case (no glyphs → fall back to `textContainerOrigin`) and the
    end-of-document caret case (`glyphRange.location == glyphCount` →
    clamp to `glyphCount - 1`).
- `Sources/WikiFS/Editor/ComposerTextView.swift` — `Coordinator.presentPanel()`
  now calls `ChatAutocompletePanel.caretRect(in: anchor)` and passes the
  result to `panel.present(caretRect:in:placement:)`. Defensive fallback:
  if `caretRect(in:)` returns nil (no `layoutManager`, `textContainer`, or
  `window` — shouldn't happen in practice but defensive), falls back to the
  text view's bounds converted to screen coordinates; the new positioning
  math is still applied, so the fallback gives the correct "4pt gap above
  the view's top" behavior even without a caret rect. Adds an explicit
  `guard let window` early-return so a `nil` window doesn't try to attach
  the panel (matches the original silent return semantics).
- `Tests/WikiFSTests/ChatAutocompletePanelPlacementTests.swift` — NEW;
  10 pure tests for `ChatAutocompletePanel.origin(...)`, covering `.above`
  / `.below` placement + their no-room fallbacks, `.auto` picking the
  roomier side (with tie → above), default gap (4pt, matches historical),
  custom gap, and horizontal offset.

**Why didn't I write a live-NSWindow integration test for `caretRect(in:)`?**
The existing `ComposerAutocompleteHostedTests` already exercises
`presentPanel()` end-to-end (via `applyResults` → `presentPanel()` →
`caretRect(in:)` → `present(caretRect:in:)`), so the integration path is
covered. A focused test asserting the exact line-fragment rect / screen
coordinate would be brittle under font-dependent line metrics; the pure
`origin(...)` tests cover the policy decisions (above/below/auto/fallback)
exhaustively, which is where the bug was.

**Build/test.** `make version prompts && swift build` clean;
`swift test` — 3021 tests in 258 suites all pass (including the 10 new
`ChatAutocompletePanelPlacementTests`). Run time ~30s.

**No new logs.** No `DebugLog` calls added — the panel's existing
silent-return-on-nil-window convention was preserved, and no error paths
were introduced (the new fallback to view-bounds positioning is a
defensive measure for state that is technically possible but doesn't fire
in practice; `caretRect(in:)` succeeds whenever the composer has a
window, which is `presentPanel()`'s only caller's precondition).

## Verification

Historical verification remains in the progress record above.
