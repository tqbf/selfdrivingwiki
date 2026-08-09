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
cancellation fallback. The complete gate and exact-head evidence are recorded
after the implementation commit.

The pre-delivery normal gate run passed on the preserved candidate at base and
HEAD `14f07d60093daf25596522924a77b6fa0742a23d`. It passed `make build`,
`make test`, app-test-enabled `swift test`, `make prompts`, bare `swift build`,
bare `swift test`, focused renderer tests, and focused sanitizer tests. The
candidate remains uncommitted. Delivery readiness, commit, push, and pull
request actions remain stopped for orchestrator direction.
