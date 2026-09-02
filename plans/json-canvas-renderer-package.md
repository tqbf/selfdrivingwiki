# JSON Canvas Renderer Package Migration

Status: Current design of record. Supersedes the prior native JSON Canvas built-in renderer.

## Summary

JSON Canvas is a reviewed, machine-scoped Web renderer package at `RendererPackages/JSONCanvas`. The prior native Swift renderer is removed. There is no JSON Canvas-specific policy in production Swift.

Users import the package through Settings → Renderers → Advanced Local Renderer Package Import. SwiftPM does not bundle or auto-install it. When the package is absent, invalid, removed, incompatible, safe-mode suppressed, or fails at runtime, the Source tab and raw-code fence fallback stay readable.

## Package identity

- Package ID: `org.selfdrivingwiki.json-canvas-readonly`
- Version: `1.1.0`
- Registration ID: `json-canvas`
- Manifest revision: 5
- Compatibility range: protocol revision 1 to 1
- Priority: 110
- Limits: 48,000 bytes input and decoded (the current base64 bridge ceiling), not the former native 256 KiB limit

The viewer is read-only, package-local, and accessible. It supports text, file, link, and group nodes; node and edge colors; edge labels with arrowheads; deterministic order and z-order; pan, zoom, fit, selection, and keyboard traversal; light and dark appearance; and Reduce Motion. Version 1.1.0 repairs the rendering model: correct side-aware Bézier edge geometry, full JSON Canvas 1.0 field parsing with defaults, bounded Markdown text layout, image file nodes and group background images through the host-pinned `asset.read` allowlist, and initial fit-to-window.

## Manifest revision 5

Renderer manifest revision 5 adds a second renderer-neutral authority: asset read.

- `RendererCapability` gains `assetRead`.
- The descriptor gains an explicit `assetRead` declaration with a closed role set (`imageNode`, `groupBackground`), approved image MIME types (`image/png`, `image/jpeg`, `image/gif`, `image/webp`; `image/svg+xml` is deliberately NOT declared until the hostile-SVG image-surface isolation gate passes), bounded extractor limits (input/output bytes, execution seconds, maximum extracted reference count), per-asset and aggregate session byte caps, and one hash-approved package-local reference-extractor asset + identifier-safe entry function.
- The capability requires the declaration; the declaration requires the capability; built-in/native declarations are rejected; the extractor asset must be approved by the descriptor and covered by package digests.
- Revisions 1 to 4 that carry asset-read authority fail closed. Host protocol revision stays 1. Reviewed revision-1/2/3 packages keep their canonical bytes and package hashes. The prior 1.0.1 (revision 4) package hash is preserved byte-for-byte in repository history as a stability contract.
- The reference-extractor contract is renderer-neutral host preflight: the descriptor-hash-approved extractor is reviewed package authority, and the generic host does not and cannot independently prove format semantics.

## Asset-read isolation

Image file nodes and group backgrounds request only the relative reference the host admitted into that renderer session. Before a WebKit session exists, the host:

1. Runs the hash-approved reference-extractor (`extractor.js`, entry `__sdw_extract_canvas_assets`) against the pinned primary canvas bytes in a single-invocation helper with an isolated JavaScriptCore context (no DOM, filesystem, store, bridge, or network; bounded stdin/stdout frames; enforced deadline and output caps; process-group terminate/reap on timeout). It returns only `file` node values (role `imageNode`) and group `background` values (role `groupBackground`).
2. Resolves each record against the page/source's exact sibling/File Provider projection (never broadened to all wiki sources), requiring a UNIQUE match.
3. Pins each admitted reference to the typed `SourceID`, the EXACT active `SourceVersionID`, the approved MIME type, byte count, and SHA-256 digest.

The session `RendererAuthorizedAssetReader` reads only through `sourceContent(versionID:)` and verifies exact version, MIME, size, and digest before returning bounded bytes. A missing, changed, unadmitted, oversized, or closed asset produces a uniform redacted denial; the canvas keeps its readable fallback (filename label or tinted group fill) and never fails as a whole. Package code cannot enumerate wiki content, request arbitrary SourceID values, read the primary canvas through `asset.read`, or fetch network/file URLs.

## Manifest revision 4 (host navigation)

Revision 4 remains in force: `hostNavigation` is a separate capability-gated authority (page/source/namedContent, host-observed single-use activation, uniform acknowledgement). Revision 5 does not alter it.

## Generic host-navigation bridge

The bridge runs in the existing isolated, session-bound content world. It shares the request-ID replay ledger with input reads; a request ID consumed by either method is unavailable to the other.

Package code may request only typed targets:

- `.page(PageID)` with a canonical ULID
- `.source(SourceID)` with a canonical ULID
- `.namedContent(rawRelativeReference)` with a validated relative path and optional `#subpath`

The host rejects control characters, absolute paths, traversal, schemes, credentials, queries, percent escapes, oversized values, and empty paths. The trusted host normalizes the relative file reference (basename, extension removal, leading-`#` anchor) before routing. Package code cannot open arbitrary filesystem paths or URLs.

Every internal navigation request requires a fresh, host-observed, purpose-bound user activation. The activation nonce is single-use, session/session/navigation bound, and lives in its own namespace. An external-link activation cannot authorize host navigation and vice versa.

Host navigation returns only a uniform acknowledgement. It never varies with page/source/title existence or routing success and never returns wiki data, filesystem paths, or resolved titles. Denied requests never invoke the route handler and use redacted diagnostics.

External HTTP(S) links continue through the existing nonce-bound, host-observed `externalLink` flow.

## Parsing and rendering boundaries

The package parser is bounded before large allocations: input bytes, node and edge counts, identifier, key, and text lengths, nesting depth, finite coordinates and sizes, duplicate IDs, known edge endpoints, known node types, closed-field values (sides, ends, `backgroundStyle`), colors, URLs, and link targets. Unknown bounded properties are ignored (forward-compatible extensions do not suppress rendering).

Unsafe or unsupported inputs fail closed and preserve the host Source/raw-fence fallback. A parse failure never mutates source or page data and never grants bridge authority.

The viewer performs no network fetch, worker, storage, clipboard, content editing, forms, frames, or undeclared assets. The DOM is built with `createElement`/`createElementNS` + `textContent` only — never `innerHTML`. Markdown is a bounded safe subset (paragraphs, newlines, emphasis, strong, inline code, links); headings/lists/quotes/fenced-code/images/raw-HTML/tables/footnotes/transclusion are escaped plain text.

## Fallback and compatibility

- Package absent, invalid, removed, incompatible, or safe-mode suppressed: readable source/raw-code fallback.
- Input above the declared cap: readable source/raw-code fallback. This is an accepted user-visible migration limit; global bridge limits are not widened for JSON Canvas.
- A file-node or group-background image that is missing, denied, unadmitted, changed, unsupported, malformed, oversized, or over-budget: readable node fallback (filename label / tinted group fill) — the canvas keeps rendering.
- No reference-extractor helper, or a helper timeout/output-limit/launch failure: fail closed to zero admitted assets; normal non-image rendering and source/raw fallback are preserved.
- External links: existing trusted activation path.
- Internal navigation: generic host-navigation bridge to the same destinations the native renderer used.

## Accepted behavior parity

The repaired scene model supersedes the 1.0.1 center-to-center, single-line rendering claims:

- Ascending node z-order (first lowest, last highest); edges beneath nodes with deterministic side-aware Bézier geometry that never enters connected node interiors.
- JSON Canvas defaults applied: `fromEnd = none`, `toEnd = arrow`; explicit sides honored; automatic sides chosen deterministically.
- Multiline Markdown text wrapped to node width, clipped to node height with an overflow cue, exposed to VoiceOver and keyboard users.
- Image file nodes and group backgrounds render host-pinned images with `preserveAspectRatio`/`cover`/`ratio`/`repeat` behavior; unavailable images keep readable fallbacks.
- Initial fit-to-window, pointer-anchored wheel zoom, pointer pan, keyboard pan/zoom/reset, focus indicators, light/dark, and Reduce Motion.
- Canonical `[[page:<ULID>]]`, `[[source:<ULID>]]`, and validated relative file/subpath references route to the same destinations.

## Verification

Focused suites: manifest/canonicalization/capability (revision 5 + locked revision-4 hash); asset-read extractor helper + location; authorized asset reader + exact-version pinning; bridge contracts (asset.read context/replay/limits); JSON Canvas parser/scene/geometry/text/image via the JavaScriptCore harness; hosted WebKit geometry/markers/text/fallback/fit; fallback and neutrality scans; affected Markdown/embed/built-in registry suites.

Repository gates on macOS: `make build`, `make test`, bare `swift build`, bare `swift test`, `scripts/validate-skills`, implementation review, and built-bundle absence inspection.

## Historical notes

- Version 1.0.1 (manifest revision 4) is preserved in repository history with its package hash as a stability contract; its rendering claims are superseded by 1.1.0.
- The former native JSON Canvas implementation is preserved as historical evidence in `plans/dynamic-renderers-phase6-json-canvas-test-inventory.json` and its progress record. They describe a superseded design; this document is the current design of record.
