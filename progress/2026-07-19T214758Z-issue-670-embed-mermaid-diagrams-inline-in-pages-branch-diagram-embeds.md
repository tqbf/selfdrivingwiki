---
timestamp: 2026-07-19T214758Z
title: "2026-07-19 — Issue #670: Embed mermaid diagrams inline in pages (branch `diagram-embeds`)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-19 — Issue #670: Embed mermaid diagrams inline in pages (branch `diagram-embeds`)

## Progress


**Problem.** A wiki page that wanted to inline a Mermaid diagram from a `.mmd`
source (`![[source:flow.mmd]]`) fell through to a cite link — the existing
embed pipeline only knew how to render byteful media blobs (image / audio /
video / PDF) and byteless external media (provider iframes / direct-remote /
Apple Podcasts). Diagram sources (`.mmd` / `text/mermaid`) are byteful but
none of those kinds, so they rendered as nothing useful.

**Fix.** Add a fourth `EmbedTarget.Kind` — `.diagram` — that carries the raw
Mermaid source text in a new `content: String?` field on `EmbedTarget`. The
page renderer emits `<div class='mermaid'>ESCAPED_CONTENT</div>`, and the
already-bundled `mermaid.min.js` (v11) renders it inline as SVG — no
per-embed JS, no new vendored library.

**Resolution chain (3 layers, one PR):**

1. **`EmbedTarget` (`Sources/WikiFSTypes/EmbedTarget.swift`)** — `Kind` gains
   `case diagram`; `EmbedTarget` gains `public let content: String?` (nil for
   the three media kinds, the diagram source text for `.diagram`). `init`
   defaults `content` to nil so existing call sites stay clean.

2. **`WikiRenderContext.build(from:)` (`Sources/WikiFSCore/Core/WikiRenderContext.swift`)**
   — the per-source embed-map loop now tries the Mermaid resolution path
   first, before the byteless-external descriptor path. Uses
   `MermaidSourceDetector.isMermaidSource(mimeType:filename:content:nil)`
   (the cheap mime + filename arms — no content scan, since reading every
   source's bytes during render-context build would be wasteful) and, when
   true, reads `store.sourceBytes(id:)` and decodes UTF-8. The result:
   `EmbedTarget(kind: .diagram, url: source.id.rawValue, content: text)`.
   Falls through to the descriptor path on non-mermaid sources or on
   un-decodable bytes (no half-rendered empty div).
   - **Why `WikiRenderContext` and not `ExternalEmbed`:** `ExternalEmbed`
     operates on `SourceEmbedDescriptor`, which the `embedDescriptors()`
     query filters to byteless sources only (`WHERE sv.blob_hash IS NULL`).
     A `.mmd` source is byteful, so it never reaches `ExternalEmbed`.
     The render-context loop iterates all `store.sources` and is the right
     seam for byteful-as-embed (matches how MediaEmbedPlayerView reads
     source bytes via the same store handle).

3. **`WikiLinkMarkdown.embedHTML` (`Sources/WikiFSLinks/WikiLinkMarkdown.swift`)**
   — the switch on `target.kind` gains `case .diagram`, emitting
   `<div class="mermaid">ESCAPED_CONTENT</div>`. Content is HTML-escaped via
   the existing `embedEscape` helper (the same set used for alt text:
   `&` → `&amp;`, `<` → `&lt;`, `>` → `&gt;`, `"` → `&quot;`) so the parser
   can't misread a `<` inside a Mermaid label as the start of a tag. The
   reader's existing `mermaidBootstrapJS` reads `div.textContent` (which
   un-escapes back to the raw diagram source) before rendering — that's
   the same mechanism the ` ```mermaid ` code-block path uses, so the
   reader doesn't need a new bootstrap.

**Reader change (one line):** `WikiReaderView.documentHTML`'s mermaid-lib
injection condition now triggers on either `class="language-mermaid"` (the
existing ` ```mermaid ` code-block form) OR `class="mermaid"` (the new div
form emitted by `.diagram` embeds). The bootstrap script does
`mermaid.run({ querySelector: '.mermaid' })` regardless of how the div got
there, so the rest is unchanged.

**Scope.**

- `Sources/WikiFSTypes/EmbedTarget.swift` — added `case diagram` to `Kind`
  and `public let content: String?` field; default-nil `init` param for
  backward compat with media-kind constructors.
- `Sources/WikiFSCore/Core/WikiRenderContext.swift` — per-source embed-map
  loop now tries Mermaid resolution first (cheap detection + lazy byte read)
  before falling through to the byteless-external descriptor path.
- `Sources/WikiFSLinks/WikiLinkMarkdown.swift` — `embedHTML` switch gains
  `case .diagram` returning `<div class="mermaid">ESCAPED</div>`; doc on
  `SourceEmbedInfo` updated to mention diagrams.
- `Sources/WikiFS/Reader/WikiReaderView.swift` — lib-injection condition
  extended to also match the div form (one extra `||` clause).
- `Sources/WikiFS/Sources/MediaEmbedPlayerView.swift` — `element(for:)`
  switch gains `case .diagram` returning empty string (defensive — diagrams
  never reach this media-player view; `SourceDetailView` shows no Media tab
  for `.mmd` sources so no embed target is constructed that way).
- `Tests/WikiFSTests/DiagramEmbedTests.swift` — NEW (11 tests):
  - `EmbedTarget.Kind.diagram` + `content` field (#670 §1): existence,
    backward-compat nil default, kind-equality.
  - `WikiRenderContext.build(from:)` (#670 §2): `.mmd` source → `.diagram`
    target carrying the raw text (resolved by filename, ext-stripped, and
    canonical id); `text/mermaid` mime source → same; non-mermaid `.md`
    source → `target == nil` (falls through to blob/cite); un-decodable
    bytes → `target == nil` (no garbled div).
  - `WikiLinkMarkdown.embedHTML` (#670 §3): `.diagram` target →
    `<div class="mermaid">…</div>` containing the (HTML-escaped) source;
    dangerous chars (`<` `>` `&`) escaped; missing target → cite link
    fallback (no half-rendered div); media embeds (iframe / audio / video)
    still render through the same switch now that `.diagram` is a fourth
    arm (#670 non-regression guard).

**Verification.**

- `make version prompts && swift build` — clean, 0 errors / 0 warnings.
- `swift test --filter DiagramEmbedTests` — 11/11 pass (~0.05 s).
- `swift test` (full suite) — **3026 tests / 258 suites pass** (~32 s).
  No regressions.

**Closes #670.** NOT merged — branch `diagram-embeds` left open for review;
PR title: "Embed mermaid diagrams inline in pages (#670)".

## Verification

Historical verification remains in the progress record above.
