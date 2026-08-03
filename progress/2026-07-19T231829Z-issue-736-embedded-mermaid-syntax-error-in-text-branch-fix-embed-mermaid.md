---
timestamp: 2026-07-19T231829Z
title: "2026-07-19 — Issue #736: Embedded mermaid \"Syntax error in text\" (branch `fix-embed-mermaid`)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-19 — Issue #736: Embedded mermaid "Syntax error in text" (branch `fix-embed-mermaid`)

## Progress


**Problem.** A `.mmd` source embedded inline in a page via
`![[source:diagram.mmd]]` rendered fine in the source-detail Rendered tab
(which feeds raw text straight to mermaid), but inline in a page mermaid
reported `Syntax error in text / mermaid version 11.16.0` — for ANY diagram
that hit one of these contexts:

- a blank line inside the diagram body (CommonMark HTML block type 6 ends
  at the first blank line — the diagram content after the blank line got
  re-parsed as markdown: indented-code blocks, `<p>` wrappers, double-escaped
  `&amp;gt;`),
- the embed placed inside a list item (`<li><div class="mermaid">…</div></li>`
  left malformed HTML — the `</div>` ended up outside `</ul>`),
- the embed placed mid-paragraph (no blank lines around the embed).

**Root cause.** `WikiLinkMarkdown.embedHTML` emitted
`<div class="mermaid">ESCAPED_CONTENT</div>` directly into the page body and
relied on swift-markdown's HTML-block detection to pass it through verbatim.
CommonMark's HTML-block type-6 rule (which `<div>` falls under) only fires
for block-level HTML surrounded by blank lines AND ends at the first blank
line — so most realistic embed contexts broke the div content apart. The
HTML surviving `MarkdownHTMLRenderer` was scrambled:
`<pre><code>B --&amp;gt; C</code></pre>` ended up nested inside the div as a
real DOM child, so `div.textContent` returned literal text containing
`&gt;` instead of `>` — and mermaid rejected it.

**Fix.** Emit a **fenced code block with language `mermaid`** instead of a
raw div (`\`\`\`mermaid\n<source>\n\`\`\`\n`). A fenced code block is a
first-class markdown construct that swift-markdown parses correctly in every
context (paragraphs, lists, blockquotes, mid-paragraph, with-blank-lines) —
`MarkdownHTMLRenderer.visitCodeBlock` then emits
`<pre><code class="language-mermaid">…</code></pre>` (escaping `>` exactly
once to `&gt;`), and the reader's existing `mermaidBootstrapJS` already
converts `code.language-mermaid` elements into `<div class="mermaid">` with
the un-escaped `textContent` (`code.textContent` un-escapes `&gt;` back to
`>`). Same path every hand-written fenced ```mermaid block already uses.

**Escape hatch.** A diagram source containing a `\`\`\`` run would close the
emitted fence early; we pick a fence length strictly longer than any
backtick run in the source (`mermaidFenceLength(for:)`), per CommonMark §4.5.

**Tested.** `mermaidEmbedSurvivesMarkdownRendererInAllContexts` and
`embedDiagramSurvivesMarkdownRenderInAllContexts` run the embed through the
full pipeline (`WikiLinkMarkdown.linkified` → `MarkdownHTMLRenderer.render`)
in four contexts (paragraph-surround, blank-line-in-diagram, inside-list,
mid-paragraph) and assert: exactly one `<code class="language-mermaid">`
element survives, the diagram text is wrapped in `<pre><code>` (not `<p>`s),
and `>` is escaped exactly once to `&gt;` (no `&amp;gt;` double-escape).
`mermaidEmbedWithBackticksInSourceUsesLongerFence` pins the fence-length
escape hatch.

---

## Verification

Historical verification remains in the progress record above.
