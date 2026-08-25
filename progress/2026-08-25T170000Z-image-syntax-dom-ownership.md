---
timestamp: 2026-08-25T170000Z
title: Image syntax DOM ownership
branch: feature/typed-markdown-embeds
status: complete
---

# Image syntax DOM ownership

## Progress

## Completed implementation

All image syntax now remains in the reader DOM.

Ordinary Markdown images and wiki source images use DOM `<img>` elements. Mermaid uses inline DOM output. Exact bundled Excalidraw input uses a bounded typed vector projection and inert SVG.

A renderer-backed image without a trusted typed projector keeps its DOM image fallback. It can show **Open interactive renderer** only when exact activation admission succeeds.

Image syntax does not emit an admitted inline placeholder. It cannot auto-mount an AppKit sibling attachment. Rich fences keep their disclosure-row behavior.

## Authorization

The interactive action keeps the exact renderer reference, typed source-version namespace, immutable bytes, recomputed digest, MIME type, `inlineContent` role, capability, generation, and outer document identity checks.

The HTML and action URL remain output boundaries. They do not authorize renderer input.

## Verification

The focused resolver and HTML tests cover Markdown images and wiki source images. They verify DOM fallback content and the absence of attachment metadata.

A hosted WebKit test loads trusted Excalidraw SVG and a generic renderer-backed image in one document. Both nodes remain in document flow. No native attachment mounts.

Final validation passed:

- strict lint
- 3,669 tests in 376 suites
- signed macOS application build
- whitespace checks

An independent GLM 5.3 review found no critical, high, or medium issues.
