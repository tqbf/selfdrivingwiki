---
timestamp: 2026-07-18T200823Z
title: "2026-07-18 — Mermaid diagram tabs: Reader / Rendered / Split (branch `mermaid-source-detail-tabs`)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-18 — Mermaid diagram tabs: Reader / Rendered / Split (branch `mermaid-source-detail-tabs`)

## Progress


**Problem:** Mermaid diagram sources (`.mmd` files or markdown containing
```mermaid fenced blocks) rendered like ordinary markdown — a single Reader tab.
A diagram source had no dedicated "rendered SVG" view or side-by-side
source/rendered split, unlike PDFs (Reader/PDF/Split) and media
(Reader/Media/Split, from #586/#590).

**What changed (4 files), rebased onto the post-#590 `main`:**

1. **`MimeType`** (`Sources/WikiFSTypes/MimeType.swift`) — added `text/mermaid` +
   `text/x-mermaid` constants, a `mermaidVariants` set, and `isMermaid(_:)`
   (case-insensitive predicate, `nil` → false). Mirrors the markdown predicates.

2. **`MermaidSourceDetector`** (`Sources/WikiFSCore/Sources/MermaidSourceDetector.swift`,
   new) — pure, unit-tested gate. `isMermaidSource(mimeType:filename:content:)`
   is true when the MIME is a mermaid variant, the filename ends in `.mmd`, or
   the content contains a fenced ```mermaid block (reuses
   `MermaidValidator.mermaidBlocks`, the pure line scanner — no JS).
   `renderableMarkdown(from:)` wraps a standalone `.mmd` source in a ```mermaid
   fence so the reader's render pipeline picks it up, and passes embedded-mermaid
   markdown through unchanged (so headings/outline stay intact).

3. **`SourceDetailView`** (`Sources/WikiFS/Sources/SourceDetailView.swift`),
   adapted to #590's `availableTabs` / `tabLabel` system:
   - Added `.rendered` to `FileContentTab` (rawValue "Rendered"). The existing
     `tabLabel` returns its `rawValue` for non-media tabs, so no label helper
     change was needed.
   - `availableTabs` gains a mermaid branch → `[.reader, .rendered, .split]`,
     placed after the PDF branch so a PDF whose extracted text mentions mermaid
     stays a PDF.
   - `tabbedContent` handles `.rendered`; `splitContent`'s right pane branches
     to `renderedMermaidContent` for mermaid (vs the player/PDF).
   - `renderedMermaidContent` draws the diagram by wrapping the source and
     handing it to the existing `WikiReaderView` (Mermaid 10.9.6 in WKWebView) —
     no separate web view or JS wiring.
   - `markdownContent` now renders a native source's raw bytes via the reader
     when there's no processed-markdown head, so a `.mmd` Reader tab shows its
     source instead of "No Processed Markdown".
   - Edit button sources its buffer from `currentMarkdownContent` (so a native
     `.mmd` edits its raw source) and switches off the `.rendered` tab when
     editing (mirrors the PDF/Media guard).

**Rendering note:** no new WKWebView or Mermaid JS plumbing. The reader already
inlines the vendored Mermaid lib + bootstrap when a page contains a
`language-mermaid` code block; the Rendered tab just feeds it a fenced source.

**Build/Tests:** `make version prompts` ✓; `swift build` clean ✓;
fast tier **2603 tests / 221 suites passed** (+13 new in
`MermaidSourceDetectorTests`).

## Verification

Historical verification remains in the progress record above.
