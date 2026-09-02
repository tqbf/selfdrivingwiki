# Provenance — JSON Canvas Renderer Package

- **Package ID:** `org.selfdrivingwiki.json-canvas-readonly`
- **Version:** `1.0.0`
- **Registration ID:** `json-canvas`
- **Manifest revision:** 4
- **Entry point:** `index.html`
- **Assets:** `index.html`, `viewer.js`, `viewer.css`, `PROVENANCE.md`, `LICENSE.md`, `JSONCanvasSpec.md`

This is a reviewed, machine-scoped, read-only renderer package maintained inside the Self Driving Wiki repository. It renders JSON Canvas documents (the `.canvas` format) as static, accessible SVG inside an isolated WebKit renderer session.

## Implementation

The viewer is self-contained JavaScript. It:

- Reads the host-pinned input through the isolated `input.read` bridge;
- Parses and validates bounded JSON Canvas documents (nodes, edges, identifiers, geometry, colors, and link references);
- Renders text, file, link, and group nodes plus edges with labels and arrowheads;
- Preserves deterministic order and z-order;
- Supports read-only pan, zoom, fit, selection, and keyboard traversal;
- Honors light/dark appearance and Reduce Motion;
- Exposes accessible node semantics and deterministic VoiceOver order;
- Uses typed host navigation for `[[page:<ULID>]]`, `[[source:<ULID>]]`, and validated relative file references with optional subpaths;
- Uses the host's trusted external activation handshake for HTTP(S) links.

No network fetch, worker, storage, clipboard, or content editing is performed. The package does not open arbitrary filesystem paths; the trusted host normalizes relative named-content references before routing.

## Format provenance

The JSON Canvas format is defined by the open specification at <https://jsoncanvas.org/>. This package does not vendor the spec body; `JSONCanvasSpec.md` records the canonical spec reference and license notice for format attribution. The Self Driving Wiki implementation is original and does not copy upstream renderer code.

## Distribution

SwiftPM does not bundle or auto-install this package. Users import the validated folder through **Settings → Renderers → Advanced Local Renderer Package Import**. Removal restores the readable Source/raw-fence fallback.

## Digest discipline

Digests are lowercase SHA-256 over the exact committed asset bytes. Both the descriptor `approvedAssets` and top-level `assets` lists carry identical records. Any asset change requires a version bump because the machine store reserves package version to package hash permanently.

## Validation

```text
swift run RendererPackageTool validate RendererPackages/JSONCanvas
```

## Review status

This is the reviewed JSON Canvas renderer package for the renderer-package migration. It supersedes the previous native JSON Canvas built-in renderer.
