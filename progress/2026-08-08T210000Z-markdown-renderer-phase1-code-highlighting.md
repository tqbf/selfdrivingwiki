---
timestamp: 2026-08-08T210000Z
title: Markdown renderer Phase 1 native fenced-code highlighting
branch: feature/markdown-renderers-01-code-highlighting
status: active
phase: 1
---

# Markdown renderer Phase 1 native fenced-code highlighting

## Progress

Phase 1 adds native, vendored Tree-sitter token spans for ordinary Java, Scala,
HTML/XML, Swift, and JSON/JSONC code fences in the source Web reader. It keeps
the original fence language class, preserves escaped plain-code fallback, and
does not add typed embeds, renderer packages, native attachments, or package
attachments.

The C boundary owns mutable Tree-sitter state for one synchronous invocation.
Swift validates returned byte ranges against UTF-8 boundaries, escapes every
source slice, and emits only a fixed semantic token palette. The renderer has a
256 KiB per-block limit, a 100-block document limit, and cancellation fallback.

The design and full immutable source/license provenance are in
[`plans/markdown-renderer-code-highlighting.md`](../plans/markdown-renderer-code-highlighting.md).
The tracked production-symbol and decision/error-branch inventory is
[`plans/markdown-renderer-code-highlighting-inventory.json`](../plans/markdown-renderer-code-highlighting-inventory.json).
The ignored retained include-closure evidence is
`tmp/orchestration/markdown-renderer-embeds/include-closure-manifest.json`.

## Verification

Focused `MarkdownHTMLRendererTests` cover the five languages, approved aliases,
unsupported-language fallback, inert HTML, exact code text, limit fallback, and
cancellation fallback. Implementation commit
`a40156d790eb5f686ad536f8b897e34f8bb22983` contains the bounded Phase 1
candidate. Delivery remains stopped while the exact-head audit findings close.

The H1 operator exception has a clean arm64 release comparison at base
`14f07d60093daf25596522924a77b6fa0742a23d` and implementation commit
`a40156d790eb5f686ad536f8b897e34f8bb22983`. The ignored record is
`tmp/orchestration/markdown-renderer-embeds/phase1-release-size-measurement-a40156d.json`.
Its SHA-256 is
`fd494056f59b8d99cb4f35a13e0c4ed53ba8a9825849ff0e81720863d26866df`.
It records an 8,251,456-byte linked app delta and no shipped test, benchmark,
or fixture file. The C contribution contains only the approved runtime, five
grammars, query wrapper, and reader implementation. The remaining audit gate
work will bind normal-gate evidence to the exact remediation head. Delivery
readiness, push, and pull request actions remain stopped.
