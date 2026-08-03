# Markdown Anchors — section + passage links, footnote citations

**Status:** Implemented on `feature/markdown-anchors`. 725 tests pass.
**Builds on:** [`phase-b-source-wikilinks.md`](phase-b-source-wikilinks.md) (the `[[source:…]]`
parser, `wiki://source` scheme, `selectSource`, `LinkType`). Phase B is merged.
**New feature** — not part of `sources-redesign.md`; extends the wikilink system with
in-document anchors and footnote citations.

## Goal

Let a wiki link point at a *place inside* a document, not just the document:

- `[[Page#Section]]` — navigate to a page, scroll to the heading `Section`.
- `[[source:Paper#"the results show a 30% improvement"]]` — navigate to a source, scroll to
  the passage that quotes.
- `[[#"…"]]` / `[[#Section]]` — scroll within the current page.

…and let all of the above appear inside **footnotes**, so an agent can cite evidence at the
passage level (`[^1]: supported by [[source:Paper#"…"]]`).

## The model (load-bearing)

- **Pages cite by heading slug** (`[[Page#Section]]`). Pages are agent-authored, so
  headings are reliable and the slug is stable and agent-controlled.
- **Sources cite by quoted passage** (`[[source:Name#"…"]]`). Source markdown comes from
  PDF extraction — it may have no heading where the cited passage is, and any id we
  *inserted* into the text would be clobbered by re-extraction. So the locator is a
  **text quote**, and ids are generated at **render time, never stored**. Nothing lives in
  the source text, so re-extraction can't remove it; if the quote drifts, we snap to the
  nearest match or just open the source. (W3C Text-Quote-Selector / RFC-5147 pattern.)
- **No explicit `{#id}` syntax in v1.** It dissolved once sources went quote-based — pages
  don't need it (auto-slugs), and sources can't rely on it (extraction).
- **One render surface.** Pages, sources (`SourceDetailView` reuses `MarkdownPreview`,
  `:333`), the changelog, and the system prompt all render through `MarkdownPreview`. Anchor
  work lands once and covers all of them. Footnotes are already linkified
  (`MarkdownPreview.renderedMarkdown` runs `linkified` over body + every footnote
  definition, `:71-77`), so `[[…#…]]` inside a footnote works for free.

## Decisions (locked)

1. **Pages → heading slug; sources → text quote.** Same renderer, different fragment
   semantics, resolved by *slug-match first, quote-search second* (so `[[source:X#Results]]`
   still snaps to a "Results" heading if one exists).
2. **Render-time ids, nothing stored.** Headings get `.id(slug)`; paragraphs get a
   sequential id. The source/page text is never mutated to carry anchors — extraction-safe.
3. **Navigate-then-scroll via a pending anchor in nav state.** `selectPage`/`selectSource`
   gain an `anchor:` param; the destination `MarkdownPreview` consumes it on load.
4. **Quote = whitespace-normalized substring match**, distinctive snippet expected;
   surrounding `"` optional (stripped if present).
5. **Agent must be taught the conventions** (footnote grammar + cite-by-quote) in
   `SystemPrompt` — first-class workstream, not an afterthought.

---

## 1. Parser — split the `#fragment`

`WikiLinkParser.ParsedLink` (post-Phase B: `linkType/target/linkText`) gains a `fragment`.
The `#fragment` is **not** part of the resolution target (so `replaceLinks`/source
resolution still keys on the base name):

```swift
public struct ParsedLink: Equatable, Sendable {
    public let linkType: LinkType
    public let target: String        // BASE only (no "#fragment")
    public let fragment: String?     // everything after the first "#", verbatim
    public let linkText: String
    public init(linkType: LinkType = .page, target: String,
                fragment: String? = nil, linkText: String) { … }
}
```

**Split before classifying** — splitting *after* classification mishandles `[[#Section]]`
(`classify` would never see an empty base). On the raw target, split on the **first** `#`
only: everything before → `base`, everything after → `fragment` (kept verbatim, so a quote
like `"C# is a language"` is preserved — an inner `#` is fine for substring matching). Then
`classify(base)`: empty base → same-page; `source:` prefix → `.source`; else `.page`. Strip
surrounding `"` from the fragment at *resolution* time (§4), not parse time, so the stored
fragment is exactly what the author typed after the first `#`.

Extract this as one shared helper — `WikiLinkParser.splitFragment(_ rawTarget) -> (base:
String, fragment: String?)` — and call it from **both** `parse()` and `linkified()`
(`linkified` keeps its own regex copy, per Phase B), so the `#` rule lives in one place
(same lesson as Phase B's `classify`). De-dup key stays `(linkType, base)` for the link
graph — the fragment doesn't affect which page/source row is written; `linkified` rewrites
every occurrence (no dedup), so `[[Page#A]]` and `[[Page#B]]` render independently.

**Accepted limitation:** a `#` in a page/source *title* terminates the base early (first
`#` wins, matching URL fragment semantics) — don't put `#` in titles. Cited passages may
contain `#` freely.

## 2. Rendering — carry the fragment in the URL

`WikiLinkMarkdown.markdownLink` gains a `fragment:` param and appends a percent-encoded
`#fragment`:

```
wiki://page?title=Page#Section              (resolved page + heading)
wiki://source?title=Paper#the%20results…    (resolved source + quote)
wiki://missing?title=Ghost#Section          (unresolved — still carries fragment)
wiki://anchor#Section                       (same-page — host "anchor", no title)
```

- `target(from:)` keeps returning the `title` query value (the **base**); the fragment no
  longer pollutes it.
- Add `fragment(from url:) -> String?` returning the URL-decoded `url.fragment`.
- `resolvedKind(from:)` (Phase B) extends to recognize host `"anchor"` as same-page.

The `isResolved` closure is unchanged — resolution is page/source-level; the fragment is
best-effort at click time.

## 3. Render-time block ids + the block list

**Headings already have `.id(slug)`** — Textual's `StructuredText.Heading` applies
`.id(content.slugified())` at `Heading.swift:24` (lowercased, spaces→`-`, alphanumeric
filter, collapsed runs — effectively GFM slug). No custom `HeadingStyle` is needed for
heading-scroll; `ScrollViewReader.scrollTo(slug)` works out of the box. The spike confirmed
this by wrapping `MarkdownPreview`'s `ScrollView` in a `ScrollViewReader` and building clean
(the `scrollToAnchor` param + 50ms layout-delay scroll live in `MarkdownPreview.swift`).

**Paragraphs need a custom `ParagraphStyle`** that applies `.id(“p\(n)”)` (sequential,
consumed in document order). A pre-parse of the rendered markdown builds the ordered block
list used both to feed the style and to resolve quote fragments:

```swift
// Custom paragraph style (heading ids are already handled by Textual)
ParagraphStyle:  .id(“p\(n)”)     // sequential, consumed in document order
```

```swift
// Built once per render in MarkdownPreview, walked in document order:
struct AnchorBlock { let id: String; let kind: Kind; let text: String }  // heading | paragraph
let blocks: [AnchorBlock] = AnchorBlock.parse(renderedBody)              // headings + paragraphs only
```

> **Architecture confirmed (spike):** `BlockContent` is `BlockVStack { ForEach(runs) {
> Block(intent:…) } }` (`BlockContent.swift:14-22`) — one SwiftUI view per block. There is
> **no `NSTextView`/`NSTextContainer`/`NSViewRepresentable`** anywhere in StructuredText.
> Headings already carry `.id(slug)`; paragraph ids need the custom style. Safe degradation:
> v1 guarantees **heading-slug scroll** (reliable); quote-scroll snaps to the nearest
> preceding heading (or no-op) if paragraph-id alignment proves unreliable.

Lists, tables, and code blocks are **not** id'd in v1 — a quote inside one resolves to the
nearest preceding id'd block (degraded precision, documented).

## 4. Fragment resolution — slug first, then quote

Pure function over the block list, used by both same-page scroll and the destination on
load:

```swift
func resolveAnchor(_ fragment: String, in blocks: [AnchorBlock]) -> String? {
    let f = fragment.trimmingCharacters(in: .init(charactersIn: "\"")).wikiNormalized
    if let h = blocks.first(where: { $0.kind == .heading && slug($0.text) == f }) {
        return h.id                                   // 1) exact heading-slug match
    }
    if let b = blocks.first(where: { $0.text.wikiNormalized.contains(f) }) {
        return b.id                                   // 2) quote (substring) match
    }
    return nil                                        // not found → navigate-only, no scroll
}
```

(`wikiNormalized` = the shared whitespace collapser from Phase B; slug = GFM rules. Keep
matching case-sensitive by default — citations should match the source verbatim.)

## 5. Navigation — pending anchor

`selectPage`/`selectSource` (Phase B) grow an `anchor:` param; the model stashes a
pending anchor tagged with the target selection so a stale one can't misfire:

```swift
@discardableResult
public func selectPage(byTitle title: String, anchor: String? = nil) -> Bool {
    guard let id = resolve… else { return false }
    pendingScrollAnchor = anchor.map { (selection: .page(id), fragment: $0) }
    openTab(.page(id)); return true
}
// selectSource(byDisplayName:anchor:) mirrors it → .source(id)
```

`MarkdownPreview` wraps its `ScrollView` in a `ScrollViewReader` and consumes the anchor
once its blocks exist:

```swift
ScrollViewReader { proxy in
    ScrollView { … StructuredText(markdown: renderedBody) … }
        .task(id: renderedBody) {                 // rebuilds when the body (or its blocks) change
            guard let (sel, frag) = store.pendingScrollAnchor,
                  sel == currentSelection,
                  let id = resolveAnchor(frag, in: blocks) else { return }
            // layout may not be settled yet — hop once
            Task { try? await Task.sleep(for: .milliseconds(50)); proxy.scrollTo(id, anchor: .top) }
            store.pendingScrollAnchor = nil
        }
}
```

> The `Task.sleep` hop is the known SwiftUI workaround for `scrollTo`-before-layout being a
> no-op. Validate the exact timing in the prototype; macOS 13+ `ScrollViewReader` is the
> target API. **Apply `swiftui-pro` here at implementation** (not installed this session).

## 6. Same-page anchors

`[[#"…"]]` / `[[#Section]]` → base empty → render as `wiki://anchor#<fragment>`. The
`OpenURLAction` (already in `MarkdownPreview`, `:53`) gets a new branch: host `"anchor"` →
resolve the fragment against the *current* preview's blocks and `proxy.scrollTo`. No
navigation.

## 7. Footnotes — already work

`WikiFootnoteMarkdown` (`[^id]` references + `[^id]: <markdown>` definitions, auto-renumbered
to 1,2,3…, multi-line indented continuations, `WikiFootnoteMarkdown.swift:31-33`) renders
definitions through `linkified` (`MarkdownPreview.swift:75`). So a footnote like

```
See the discussion in [[source:Smith2023#"the effect vanishes above 40°C"]].
```

becomes a live, scrolling link with no footnote-specific code. Confirm multi-line definition
support and that `linkified` runs on continuation lines (it does — it operates on the joined
definition string).

## 8. Agent instructions — `SystemPrompt`

The agent's `## Conventions` section (`SystemPrompt.swift:60-`) currently documents
`[[wiki links]]` but not footnotes, anchors, or (verify) `[[source:…]]`. Extend it:

- **Footnotes:** `[^id]` inline + `[^id]: definition` on its own line; id is any label
  (auto-numbered in output); definitions may span indented continuation lines and may
  contain `[[links]]`.
- **Cite a source passage by distinctive quote:**
  `[[source:Smith2023#"the effect vanishes above 40°C"]]` — pick a snippet unique to that
  passage; it survives re-extraction and needs no heading.
- **Cite a page section by heading:** `[[Overview#Methodology]]` (heading → slug).
- **Slug rules** (so page-section fragments match): lowercase, spaces→`-`, drop punctuation,
  `-1/-2` on duplicates.
- **Same-page:** `[[#Methodology]]`.
- A worked footnote example tying it together.

Also confirm Phase B's `[[source:Name]]` is documented (the citation pattern depends on it).

## 9. Edge cases / gotchas

- **Quote distinctiveness:** the agent/user must quote enough to be unique; document this.
- **Fragment encoding is two layers — don't conflate them.** The *parser* splits on the
  first `#` and keeps the remainder **raw** (`"C# is a language"` stays intact; the parser
  never sees percent-encoded text). The *renderer* percent-encodes that fragment — including
  any inner `#`, spaces, and quotes — when building the URL, so it doesn't terminate the URL
  fragment early; `fragment(from:)` decodes on read.
- **Resolution target stays the base:** `resolveTitleToID`/`resolveSourceByName` must never
  see the fragment — the parser split in §1 guarantees this.
- **Heading slug stability:** renaming a cited heading breaks `[[Page#Section]]` (same class
  as page rename). v1 accepts this; the Phase B/D rename-rewrite pattern is the future fix.
- **Re-extraction:** quote-based anchors are immune (nothing stored). If a re-extraction
  changes the passage wording, the quote falls back to nearest-match or navigate-only.

---

## Tests

- `WikiLinkParserTests`: `[[Page#Section]]` → `(target:"Page", fragment:"Section")`;
  `[[source:X#"a b"]]` → `(target:"X", fragment:"a b")`; `[[#S]]` → `(target:"", fragment:"S")`;
  alias form `[[Page#S|alias]]`; dedup keys on base.
- `WikiLinkMarkdownTests`: rendered URLs carry the encoded `#fragment` for page/source/missing
  hosts; same-page → `wiki://anchor#…`; `target(from:)` returns base, `fragment(from:)`
  returns the fragment.
- `AnchorBlock`/resolution: slug match beats quote; quote substring match; dedup slugs;
  not-found → nil.
- `MarkdownPreview`/model: `selectPage(_:anchor:)` stashes + the destination consumes it;
  same-page `wiki://anchor` scrolls the current preview.

## Gate

- `swift build` clean; `swift test` green.
- **Manual:** (1) `[[Overview#Methodology]]` navigates to Overview and scrolls to the
  Methodology heading. (2) A footnote `[^1]: [[source:Paper#"…"]]` scrolls to the quoted
  passage in the source's rendered markdown. (3) Re-extracting the PDF does not break an
  existing quote citation (re-resolves against the new HEAD). (4) Unknown section/quote →
  navigates without scrolling. (5) `[[#Section]]` scrolls within the current page.

## Out of scope

- **Annotation overlay** (Hypothesis-style persistent highlights + a separate citations
  table) — the durability-max upgrade if quote-based proves insufficient; its own phase.
- **Explicit `{#id}` anchors** — dropped (see model).
- **Heading-rename link rewriting** — future, consistent with page/source rename.
- **List/table/code-block-precise scroll** — v1 snaps to nearest heading/paragraph.
- **PDF page markers** (`#p=12`) — possible coarse complement if pdf2md emits page
  boundaries; not now.

## Implementation order (prototype-first)

1. **~~Spike: `scrollTo` into a styled block.~~** ✅ Done. Headings already carry `.id(slug)`
   from Textual (`Heading.swift:24`); `ScrollViewReader` wrapper + `scrollToAnchor` param
   landed in `MarkdownPreview.swift`. Architecture confirmed — no custom HeadingStyle needed.
2. **Parser `#`-split** — the `splitFragment` helper, `fragment` on `ParsedLink`, handle
   `[[#…]]` (empty base), tests. Pure, isolated.
3. **URL construction + `linkified` threading** — `markdownLink(fragment:)`,
   `fragment(from:)`, same-page `wiki://anchor` host; `linkified` calls `splitFragment`
   then `classify(base)` (no duplicated `#` logic).
4. **Render-time block ids** — custom paragraph style for `.id("p\(n)")`, `AnchorBlock.parse()`,
   confirm paragraph ordering.
5. **Navigation + scroll** — `selectPage(anchor:)` / `selectSource(anchor:)`, pending-anchor
   state, `ScrollViewReader` consumption, same-page `wiki://anchor` dispatch.
6. **`SystemPrompt`** — last; depends on the final syntax.

## Open decisions

1. **Quote-match case sensitivity.** Default case-sensitive (verbatim citation); fall back
   to case-insensitive if no exact match? Recommend: exact first, case-insensitive second.
2. **Same-page `[[#…]]` in v1 or defer?** Cheap once the machinery exists; recommend include.

> **Implementation skills:** apply `swiftui-pro` (ScrollViewReader/scrollTo timing, custom
> block styles), `macos-design` (heading/scroll UX), and `typography-designer` (heading
> hierarchy) per `CLAUDE.md` when writing the code — these skills are not installed in the
> current session.
