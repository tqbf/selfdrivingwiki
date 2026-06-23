# Quote Highlight + Scroll-to-Quote for Source Links

**Status:** Implemented on `main` (2026-06-22). 911 tests pass.
**Builds on:** [`markdown-anchors.md`](markdown-anchors.md) (the `[[source:Name#"…"]]`
quote-fragment parser, render-time block ids, `selectSource(anchor:)`, the
`pendingScrollAnchor` stash/consume seam) and [`phase-b-source-wikilinks.md`](phase-b-source-wikilinks.md)
(the `wiki://source` scheme). Both are merged.
**New feature** — extends markdown-anchors' *navigate-then-scroll* with two things
it doesn't do today: **highlight the exact quoted passage** and **work on PDF sources**.

## Goal

When a `[[source:Name#"quoted passage"]]` (or `[[Page#"…"]]`) link is clicked, the
destination document should **highlight the exact passage and scroll to it** — for both
markdown and PDF. The highlight **persists until the user navigates away or clicks another
quote** (matches reader/Find-highlight behavior).

## The gap (what ships today)

markdown-anchors already does *navigate-then-scroll*, but only at **block granularity** and
only for markdown:

- `MarkdownPreview.task(id: markdown)` consumes the pending fragment, `resolveAnchor(_:in:)`
  returns a **block id** only (a heading slug or `p1`/`p2`/…), and `proxy.scrollTo(id, .top)`
  lands you on the *paragraph/heading* containing the quote (`Sources/WikiFS/MarkdownPreview.swift:94-104`,
  `Sources/WikiFSCore/AnchorBlock.swift:153-170`). The quote itself is **not highlighted**;
  in a long paragraph the user still has to hunt for it.
- **PDF sources do nothing.** `SourceDetailView`'s PDF path (`pdfOnlyContent` →
  `PDFViewWrapper(data:)`, `Sources/WikiFS/PDFViewWrapper.swift`) never consumes the anchor, so
  a quote link into a PDF source just opens the PDF at the top.
- **Latent scroll bug:** `MarkdownPreview.task(id: markdown)` doesn't re-fire when a *second*
  quote link targets the already-open source (markdown unchanged), so repeat quote clicks to
  the same tab don't re-scroll. Fixing this is bundled in.

## Decisions (locked)

1. **Markdown highlight reuses the per-run attribute pattern.** `WikiLinkStylingParser`
   already mutates specific `AttributedString` ranges to recolor missing links red
   (`Sources/WikiFS/WikiLinkStylingParser.swift:46-59`), and those per-run attributes survive
   Textual's `WithInlineStyle` `keepNew` merge. We extend the same mechanism to set
   `.backgroundColor` on the quote's exact range — no new rendering seam.

2. **Whitespace-tolerant substring search, first match.** The extracted markdown may wrap the
   quote across lines or collapse spaces differently than the link author wrote. So matching
   normalizes whitespace (mirror `resolveAnchor`'s `wikiNormalized` in `AnchorBlock.swift:154-156`):
   build a normalized haystack + an index map (normalized index → original `AttributedString.Index`),
   `range(of:)` the normalized quote, map the bounds back, take the **first** match. O(n), fine for
   document sizes. No match → no-op (the existing block scroll still positions the user; no crash).

3. **Highlight color is the semantic Find color.** `Color(NSColor.findHighlightColor)` adapts to
   light/dark automatically; fall back to `.yellow.opacity(0.35)` if the system color is unavailable.

4. **The quote is bridged into the parser via `@State`.** The parser needs the quote in `body`,
   but the anchor is consumed in `.task`. So `MarkdownPreview` holds `@State highlightQuote: String?`,
   builds `WikiLinkStylingParser(highlightQuote: highlightQuote)`, and the consume task assigns it
   → rebuilds `StructuredText` with highlighting. This is a one-time post-navigation state change,
   not per-frame, so it's safe under the synchronous-render invariant (`MarkdownPreview.swift:9-16`).

5. **Persistence:** `.onChange(of: markdown) { highlightQuote = nil }` clears stale highlight on
   document change; a *different* quote to the same open doc bumps the anchor version (§7) → re-consume
   → overwrites the highlight.

6. **Scroll stays block-level.** `resolveAnchor` returns only a block id, and per-substring scroll ids
   are out of scope — so we keep `ScrollViewReader.scrollTo(blockId, …)`. Polish: choose the anchor by
   block kind — `.center` for paragraphs, `.top` for headings — so the highlighted substring is more
   likely in view. The highlight gives the precise visual cue within the block.

7. **Re-click reactivity via an anchor-version counter.** Add `pendingScrollAnchorVersion: Int` to
   `WikiStoreModel`, incremented wherever `pendingScrollAnchor` is assigned (`selectPage`, `selectSource`).
   Key the consume task on a small `Hashable` wrapper (`.task(id:)` needs `Hashable`, not a raw tuple):
   `struct RenderKey: Hashable { let markdown: String; let anchorVersion: Int }`. This makes both
   scroll and highlight fire on repeat quote clicks.

8. **PDF uses PDFKit's native search + selection.** `PDFViewWrapper` gains `highlightQuote: String?` and
   runs `document.findString(quote, options: [.caseInsensitive])` → `selections.first` →
   `pdfView.currentSelection = sel; pdfView.scrollSelectionToVisible(nil)`. PDFKit renders `currentSelection`
   as the translucent yellow highlight *and* scrolls to it — highlight + scroll in two lines.

9. **Anchor consumption point is split to avoid a race.** Markdown consumes inside `MarkdownPreview`
   (covers pages and markdown-rendered sources). PDF-only sources consume inside `SourceDetailView`
   (`pdfOnlyContent`, i.e. `isPDF && !hasMarkdown`) — that path has no `MarkdownPreview` in the tree, so
   there's no double-consume. Quote-click lands on the default Markdown tab for extracted PDFs, so the
   markdown side handles the common case; the PDF path is only hit for un-extracted PDFs.

## Design

### Markdown — precise substring highlight

Extend `WikiLinkStylingParser` (`Sources/WikiFS/WikiLinkStylingParser.swift`):

```swift
@MainActor
struct WikiLinkStylingParser: MarkupParser {
    private let highlightQuote: String?          // NEW
    init(highlightQuote: String? = nil) { self.highlightQuote = highlightQuote }

    func attributedString(for input: String) throws -> AttributedString {
        var result = try base.attributedString(for: input)
        recolorLinks(in: &result)
        if let q = highlightQuote?.trimmedAndNormalized { highlightQuote(q, in: &result) }
        return result
    }

    /// Set `.backgroundColor` on the first whitespace-normalized occurrence of `quote`.
    private func highlightQuote(_ quote: String, in string: inout AttributedString) {
        guard let range = Self.quoteRange(quote, in: string) else { return }
        string[range].backgroundColor = Color(NSColor.findHighlightColor
                                              ?? .controlAccentColor)
    }

    /// Pure, testable: first normalized occurrence → original AttributedString range, or nil.
    static func quoteRange(_ quote: String, in string: AttributedString) -> Range<AttributedString.Index>? { … }
}
```

Wire it from `MarkdownPreview` (`Sources/WikiFS/MarkdownPreview.swift`): add
`@State private var highlightQuote: String?`; build `WikiLinkStylingParser(highlightQuote: highlightQuote)`;
replace the `.task(id: markdown)` with a `.task(id: RenderKey(markdown, store.pendingScrollAnchorVersion))`
that consumes the anchor, sets `highlightQuote`, parses blocks, and scrolls with a kind-aware anchor; add
`.onChange(of: markdown) { highlightQuote = nil }`.

### Re-click reactivity

In `WikiStoreModel` (`Sources/WikiFSCore/WikiStoreModel.swift`):

```swift
public private(set) var pendingScrollAnchorVersion: Int = 0
// …in selectPage / selectSource, wherever pendingScrollAnchor is assigned:
pendingScrollAnchorVersion += 1
```

### PDF — find + select + scroll (pdf-only sources)

`PDFViewWrapper` (`Sources/WikiFS/PDFViewWrapper.swift`):

```swift
struct PDFViewWrapper: NSViewRepresentable {
    let data: Data
    var highlightQuote: String? = nil

    func makeNSView(context: Context) -> PDFView { … set document … }
    func updateNSView(_ view: PDFView, context: Context) {
        // set document when data changes; when highlightQuote is set and doc loaded:
        if let q = highlightQuote?.trimmed,
           let doc = view.document,
           let sel = doc.findString(q, options: [.caseInsensitive]).first {
            view.currentSelection = sel
            view.scrollSelectionToVisible(nil)
        }
    }
}
```

`SourceDetailView` (`Sources/WikiFS/SourceDetailView.swift`): add `@State private var pdfQuote: String?`;
set it in a `.task` keyed on `(file.id, store.pendingScrollAnchorVersion)` via a `Hashable` wrapper, but
**only consume when `isPDF && !hasMarkdown`**; pass `pdfQuote` to `PDFViewWrapper(data:highlightQuote:)`
in `pdfView`.

## Files to modify

| File | Change |
| --- | --- |
| `Sources/WikiFS/WikiLinkStylingParser.swift` | `init(highlightQuote:)`, `highlightQuote(_:in:)`, pure `quoteRange(_:in:)`. |
| `Sources/WikiFS/MarkdownPreview.swift` | `@State highlightQuote`; wire into parser; `RenderKey` task; `.onChange(markdown)` clear; kind-aware scroll anchor. |
| `Sources/WikiFS/PDFViewWrapper.swift` | `highlightQuote` param + PDFKit `findString`/`currentSelection`/`scrollSelectionToVisible`. |
| `Sources/WikiFS/SourceDetailView.swift` | `@State pdfQuote`; consume on PDF-only path; pass to `PDFViewWrapper`. |
| `Sources/WikiFSCore/WikiStoreModel.swift` | `pendingScrollAnchorVersion` counter (increment in `selectPage`/`selectSource`). |

**Reused, untouched:** `AnchorBlock.swift` (`resolveAnchor` + normalization), `WikiLinkParser.swift`
(`splitFragment` keeps the quote verbatim), `WikiLinkMarkdown.swift` (fragment extraction).

## Tests

Extend `Tests/WikiFSTests/` (a new `QuoteHighlightTests`, plus regression asserts in `AnchorBlockTests`):

- `WikiLinkStylingParser.quoteRange` — exact match; whitespace-tolerant match (quote spans a newline
  / extra spaces in haystack); no-match → nil; picks the **first** occurrence when the quote repeats.
- Integration — build an `AttributedString` via `WikiLinkStylingParser(highlightQuote:)`; assert the
  matched subrange carries `.backgroundColor` and that link runs keep their foreground colors.
- Regression — `resolveAnchor` block resolution unchanged.

PDF (PDFKit + `NSView`) isn't unit-testable here → manual verification only.

## Verification (manual, end-to-end)

- **Markdown source/page:** click a `[[source:X#"…"]]` (and `[[Page#"…"]]`) link → lands on the doc,
  quote highlighted, scrolled into view. Click a second quote to the same open doc → highlight moves.
  Navigate away → highlight clears.
- **PDF source (un-extracted):** click a quote link → PDF opens, passage selection-highlighted and scrolled to.
- **Edge:** quote with no verbatim match → no highlight, still scrolls to containing block (no crash).
- **Edge:** repeated heading text, quote inside a long paragraph → first match chosen, paragraph centered.

Build/test gates:

```
swift build
swift test --filter QuoteHighlightTests
swift test --filter AnchorBlockTests
```

## Out of scope

- **Per-substring scroll ids** (true sub-paragraph scroll precision) — block-level scroll + substring
  highlight is sufficient.
- **Persistent highlight annotations on the PDF** — we use ephemeral `currentSelection`, not saved annotations.
- **Split-tab quote sync** — in Split mode both markdown and PDF are in the tree; the markdown side
  consumes. Quote-click lands on the default Markdown tab, so this only matters after a manual tab switch.
- **`AnchorBlock` coverage for quotes inside lists/tables/code** — pre-existing degraded precision; unchanged.
