# Source Web Reader (large-source render path)

## Overview

The native markdown reader (`MarkdownPreview` → Textual `StructuredText`)
beachballs on large sources (500 KB+) because it lays out the **entire**
document synchronously, with no virtualization. Measured headless on a 513 KB
source (`Tests/WikiFSTests/ReaderRenderPerfTests`): preprocessing (footnote
expand + wiki-link linkify) ≈ 165 ms, Markdown→`AttributedString` parse ≈ 91 ms
— together < 260 ms. Live-run preprocessing timings are ≤ 180 ms. So the
observed freeze is **layout** (SwiftUI/Textual measuring every block), not
parsing or preprocessing — the headless benchmark predicted this and a live A/B
confirmed it.

A `WKWebView` prototype (`Sources/WikiFS/SourceWebView.swift`, behind
`@AppStorage("debug.webReader")`) renders the same markdown via the browser
engine, whose layout is windowed. Direct A/B on a 500 KB+ source confirmed it is
**much faster** than the native reader. This plan productionizes that path: a
real markdown→HTML converter, full feature parity with the native reader,
app-matched theming, and **size-gating** so the native reader stays the default
for normal pages (where it is excellent and already has working selection /
links / anchors / quote-highlight).

Branch: `feat/source-web-reader`, branched from `perf/reader-render-freeze`
(which holds the prototype + instrumentation + the `#1` anchor-preprocessing
dedupe).

## Decisions Locked In

1. **Size-gated, additive.** The web reader is used only for sources above a
   threshold; below it the existing native `MarkdownPreview` is **unchanged**.
   No regression for the common case (pages + small sources).
2. **Native reader stays.** Not a replacement — the two coexist. Selection,
   link hit-testing, quote highlight, and anchor scrolling already work natively
   for small docs and remain the path there.
3. **Async load on the web path.** Conversion runs off-main; `loadHTMLString`
   on main. There is **no** Textual selection-geometry constraint on this path
   (that constraint is specific to the native reader's overlay), so deferring is
   safe — validated by the prototype.
4. **Web reader is for *sources*, not pages.** Large content comes from
   ingested/extracted sources; pages are short (ISSUES.md). Initially gate inside
   the source detail view. (Pages could opt in later by size.)

## Architecture

### Reader selection
A resolver picks the reader by content size:

- `head.content.utf8.count <= threshold` → `MarkdownPreview` (native).
- else → `SourceWebView` (web).

`threshold` is an `@AppStorage` (tunable); provisional default ~96 KB, finalized
in Phase 0 from measurement (the size at which native layout exceeds a comfort
budget). The debug "Web" checkbox stays as a force-on override for A/B testing.

### Prewarm the WebContent process
A `WKWebView`'s first use in a process pays a one-time WebContent-process launch
(cold start). Prewarm by creating one off-screen `WKWebView` at app launch
(e.g., in `WikiFSApp`) and discarding it — this spawns the process so the first
real source opens without the cold-start hit. Each `SourceDetailView` still
creates its own `WKWebView` (a web view can attach to only one hierarchy), but
the process is already warm. **Phase 0 measures first-vs-subsequent open; if
cold-start is negligible, skip the prewarm.**

### Markdown → HTML
Replace the prototype's minimal converter with a real one. **Decision needed**
(see Open Decisions); recommend **Apple `swift-markdown`** (`import Markdown`) —
pure Swift, no C dependency, Apple-maintained, parses full GFM (tables,
footnotes, task lists) to a DOM we walk with a `MarkupVisitor` to emit HTML
(~200 lines, full control). Alternative: **cmark-gfm** via a SwiftPM package
(C, faster, native HTML incl. tables/footnotes, but adds a C dependency).

Wiki-link + footnote semantics are applied as a **shared pre-pass on the
markdown string** — reuse `WikiFootnoteMarkdown` + `WikiLinkMarkdown`
(WikiFSCore), the *same* code the native reader uses — so both readers have
identical link/footnote behavior, then the converter renders to HTML.

## Feature Parity (port from the native reader)

- **Wiki links.** `[[Page]]`, `[[source:Name]]`, `[[Page#frag]]`, `[[Page|alias]]`
  → `<a href="wiki://…">`, routed by the navigation delegate to
  `store.selectPage` / `selectSource` (prototype already does this). Match the
  native reader's resolved-vs-ghost coloring (resolved → link color, missing →
  red) via a render-time class on the `<a>`.
- **Footnotes.** `WikiFootnoteMarkdown` already rewrites `[^n]` refs + defs; the
  converter renders them as numbered superscript links + a definitions section,
  with the same numbering the native reader shows.
- **Anchor scrolling.**
  - *Same-page* `#heading` clicks: native browser scroll (heading ids are GFM
    slugs, matching `AnchorBlock.makeSlug`).
  - *External* anchor-on-open (`[[source:Name#sec]]` from elsewhere): wire
    `pendingAnchor` through the store's `consumePendingScrollAnchor` path → JS
    `scrollIntoView` after `didFinish`. (The prototype has the hook; it just
    needs to consume the store's pending anchor instead of a passed-in one.)
  - *Quote anchors* (`[[source:Name#"quote"]]`): see highlight below.
- **Quote highlight.** Port the native `WikiLinkStylingParser` highlight to the
  web: after load, if a quote fragment is pending, run JS to wrap the first
  match in a `<mark>` and scroll to it. Reuse `resolveAnchor`'s quote-matching
  for locating the text.

## Theming

Match the native reader so the web view doesn't feel foreign: mirror
`PageEditorMetrics.readableContentWidth` and content insets, the app's body font
and color tokens, and code-block styling. Light/dark via `prefers-color-scheme`
(prototype already does this). *(Per memory: `swiftui-pro` /
`typography-designer` / `macos-design` skills aren't installed — mirror the
in-repo reader patterns, e.g. `ZoteroSettingsView`, instead.)*

## Selection & Find

`WKWebView` gives native text selection for free. Find-in-page (⌘F) is **out of
scope for v1** (the native reader doesn't have it either) — noted as a follow-up.

## Implementation Phasing

- **Phase 0 — finish measurement (small).** Rebuild with the unbuffered
  `ReaderTiming` (already coded, needs a rebuild to take effect), then on a real
  500 KB source measure `webview.appear-to-painted` first-vs-second open
  (cold-start?) and native layout time vs size to pick the threshold. Lock the
  prewarm + threshold decisions here.
- **Phase 1 — real converter + read/navigation parity.** Add the converter,
  share the `WikiFootnoteMarkdown` / `WikiLinkMarkdown` pre-pass, wire `wiki://`
  routing + same-page anchors + ghost-link coloring. The web reader is then
  feature-complete for reading + navigation on large sources.
- **Phase 2 — anchors + highlight.** External anchor-on-open
  (`consumePendingScrollAnchor`) + quote highlight (`<mark>`).
- **Phase 3 — theming pass.** Type/colors/width to match the native reader;
  dark-mode check.
- **Phase 4 — wire the size gate.** Replace the debug toggle with the size
  resolver; add the prewarm if Phase 0 calls for it; delete the prototype's
  minimal `MarkdownToHTML` converter.

## Testing

- **Unit:** extend `ReaderRenderPerfTests` with markdown→HTML fidelity cases
  (tables, footnotes, wiki links, code, blockquotes) against expected HTML. The
  shared pre-pass is already covered by `WikiFootnoteMarkdownTests` /
  `WikiLinkMarkdownTests`.
- **Perf gate:** the benchmark must show web `appear-to-painted` ≪ native for a
  500 KB doc; the threshold is chosen from these numbers.
- **Manual A/B:** the "Web" checkbox stays for direct comparison during
  development.

## Open Decisions

1. **Markdown converter: `swift-markdown` (recommended) vs `cmark-gfm` vs
   extend-the-minimal.** `swift-markdown` = pure Swift, no C dep, full GFM AST,
   we write the HTML visitor. `cmark-gfm` = C, faster, native HTML, adds a C
   SwiftPM dependency. *(Needs your call.)*
2. **Size threshold value.** Picked in Phase 0 from measurement; provisional
   default ~96 KB.
3. **Prewarm.** Include iff Phase 0 shows a meaningful first-open cold-start.

## Non-goals (v1)

- Replacing the native reader for small docs.
- Find-in-page.
- The manual `TextEditor` editing path (separate large-doc concern).
- Math rendering (Textual has it; the web path would need KaTeX — follow-up).
