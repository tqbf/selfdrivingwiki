# Provenance — JSON Canvas Renderer Package

- **Package ID:** `org.selfdrivingwiki.json-canvas-readonly`
- **Version:** `1.1.2`
- **Registration ID:** `json-canvas`
- **Manifest revision:** 5
- **Entry point:** `index.html`
- **Assets:** `index.html`, `viewer.js`, `viewer.css`, `extractor.js`, `PROVENANCE.md`, `LICENSE.md`, `JSONCanvasSpec.md`

This is a reviewed, machine-scoped, read-only renderer package maintained inside the Self Driving Wiki repository. It renders JSON Canvas 1.0 documents (the `.canvas` format) as static, accessible SVG inside an isolated WebKit renderer session.

## Implementation

The viewer is self-contained JavaScript with a staged architecture (parse → scene → geometry/layout → asset resolution → semantic SVG/HTML render). It:

- Reads the host-pinned input through the isolated `input.read` bridge;
- Parses and validates bounded JSON Canvas 1.0 documents: node types (`text`/`file`/`link`/`group`), geometry, colors (presets + hex), edge sides (`top`/`right`/`bottom`/`left`), edge ends (`none`/`arrow`, with JSON Canvas defaults `fromEnd=none`, `toEnd=arrow`), edge labels, group labels/backgrounds, and `backgroundStyle` (`cover`/`ratio`/`repeat`);
- Applies JSON Canvas defaults and rejects unknown values for the closed fields (`type`, sides, ends, `backgroundStyle`); bounded unknown top-level/node/edge properties are ignored so forward-compatible extensions do not suppress rendering;
- Renders nodes with rounded frames, native-like tinted fills, independent strokes, visible focused state, and ascending z-order (first node lowest, last node highest);
- Renders edges as cubic Bézier curves with deterministic automatic side selection, boundary anchors (paths never enter node interiors), `marker-start`/`marker-end` only when requested, and edge labels on a readable background;
- Renders text nodes with a bounded Markdown tokenizer (paragraphs, explicit newlines, emphasis, strong emphasis, inline code, links) as semantic HTML inside a node-bounded `foreignObject`, with width-aware wrapping, height clipping, an explicit overflow cue, and SVG `<title>`/`<desc>` plus an offscreen semantic fallback for WebKit accessibility;
- Renders image file nodes and group background images through the isolated `asset.read` bridge: only host-admitted references are requested; a denied/unavailable image keeps a readable node fallback (filename label / tinted group fill) without failing the canvas;
- Supports initial fit-to-window, pointer-anchored wheel zoom, pointer pan with drag threshold + capture/cancel, keyboard pan/zoom/reset, focus indicators, light/dark appearance, and Reduce Motion;
- Uses typed host navigation for `[[page:<ULID>]]`, `[[source:<ULID>]]`, and validated relative file references with optional subpaths;
- Uses the host's trusted external activation handshake for HTTP(S) links;
- Requests image assets only through the `asset.read` method using the exact host-admitted reference key; it cannot enumerate, fetch, or probe wiki content.

The DOM is built exclusively with `createElement`/`createElementNS` + `textContent` — never `innerHTML`. No network fetch, worker, storage, clipboard, content editing, arbitrary HTML, audio/video playback, or Markdown transclusion is performed. SVG content is never inserted into the document DOM; image MIME types are restricted to the host-approved declaration, and SVG (`image/svg+xml`) is deliberately NOT declared until the hostile-SVG image-surface isolation gate proves in hosted tests that untrusted SVG cannot escape the image surface.

The `extractor.js` reference-extractor (manifest revision 5 `assetRead` authority) runs inside a single-invocation host helper in an isolated JavaScriptCore context. It returns ONLY `file` node values (role `imageNode`) and group `background` values (role `groupBackground`) from the pinned primary canvas, with no lookups, no enumeration, no network, and no store access.

## Format provenance

The JSON Canvas format is defined by the open specification at <https://jsoncanvas.org/> (version 1.0, 2024-03-11). This package does not vendor the spec body; `JSONCanvasSpec.md` records the canonical spec reference and license notice for format attribution.

### MIT-licensed upstream algorithms (adapted, not vendored)

The edge geometry (side-aware rectangle-boundary anchors, cubic Bézier control points, parallel stroke/marker offset) is adapted from **JSON-Canvas-Viewer** by Hesprs (<https://github.com/Hesprs/JSON-Canvas-Viewer>, MIT License, pinned reference: `main` branch). The adaptation is rewritten to this package's local data model and bounded parser; the upstream dependency graph (React/Vite/TypeScript) is not used. The `cover`/`ratio`/`repeat` group-background composition is adapted from **rehype-jsoncanvas** (<https://github.com/>, MIT License) image-fit patterns. Neither upstream viewer is vendored wholesale, and no runtime dependency is introduced.

MIT License (as included in `LICENSE.md`):

```
Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

This package's own original code is original work and does not claim upstream provenance for independently reimplemented concepts (bounded parser, Markdown tokenizer, fit/pan/zoom, accessibility layer).

## Distribution

SwiftPM does not bundle or auto-install this package. Users import the validated folder through **Settings → Renderers → Advanced Local Renderer Package Import**. Removal restores the readable Source/raw-fence fallback. Image file nodes and group backgrounds read only through the host-pinned `asset.read` allowlist; a missing or denied image falls back without failing the canvas.

## Digest discipline

Digests are lowercase SHA-256 over the exact committed asset bytes. Both the descriptor `approvedAssets` and top-level `assets` lists carry identical records. Any asset change requires a version bump because the machine store reserves package version to package hash permanently.

## Validation

```text
swift run RendererPackageTool validate RendererPackages/JSONCanvas
```

## Review status

This is the reviewed JSON Canvas renderer package for the renderer-package migration. It supersedes versions 1.0.0/1.0.1 (manifest revisions 3/4), whose rendering claims are superseded by this version's repaired scene model. The 1.0.1 package hash remains a stability contract and is preserved byte-for-byte in repository history.
