# JSON Canvas Renderer Package Migration

Status: Current design of record. Supersedes the prior native JSON Canvas built-in renderer.

## Summary

JSON Canvas is a reviewed, machine-scoped Web renderer package at `RendererPackages/JSONCanvas`. The prior native Swift renderer is removed. There is no JSON Canvas-specific policy in production Swift.

Users import the package through Settings → Renderers → Advanced Local Renderer Package Import. SwiftPM does not bundle or auto-install it. When the package is absent, invalid, removed, incompatible, safe-mode suppressed, or fails at runtime, the Source tab and raw-code fence fallback stay readable.

## Package identity

- Package ID: `org.selfdrivingwiki.json-canvas-readonly`
- Version: `1.0.1`
- Registration ID: `json-canvas`
- Manifest revision: 4
- Compatibility range: protocol revision 1 to 1
- Priority: 110
- Limits: 48,000 bytes input and decoded (the current base64 bridge ceiling), not the former native 256 KiB limit

The viewer is read-only, package-local, and accessible. It supports text, file, link, and group nodes; node and edge colors; edge labels with arrowheads; deterministic order and z-order; pan, zoom, fit, selection, and keyboard traversal; light and dark appearance; and Reduce Motion.

## Manifest revision 4

Renderer manifest revision 4 adds one renderer-neutral authority: host navigation.

- `RendererCapability` gains `hostNavigation`.
- The descriptor gains an explicit `hostNavigation` declaration with a closed target-kind set (page, source, named content).
- The capability requires the declaration; the declaration requires the capability; built-in/native declarations are rejected.
- Revisions 1 to 3 that carry host navigation fail closed. Older hosts cannot decode the capability and reject the manifest.
- Host protocol revision stays 1. Reviewed revision-1/2/3 packages keep their canonical bytes and package hashes.

This is the runtime feature gate. We do not weaken `RendererCompatibility.supports` and do not edit existing package manifests.

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

The package parser is bounded before large allocations: input bytes, node and edge counts, identifier and text lengths, finite coordinates and sizes, duplicate IDs, known edge endpoints, known node types, colors, URLs, and link targets.

Unsafe or unsupported inputs fail closed and preserve the host Source/raw-fence fallback. A parse failure never mutates source or page data and never grants bridge authority.

The viewer performs no network fetch, worker, storage, clipboard, content editing, forms, frames, or undeclared assets.

## Fallback and compatibility

- Package absent, invalid, removed, incompatible, or safe-mode suppressed: readable source/raw-code fallback.
- Input above the declared cap: readable source/raw-code fallback. This is an accepted user-visible migration limit; global bridge limits are not widened for JSON Canvas.
- External links: existing trusted activation path.
- Internal navigation: generic host-navigation bridge to the same destinations the native renderer used.

## Accepted behavior parity

- Deterministic node order and z-order match the native renderer.
- Supported node types, colors, edge labels/arrowheads, and group backgrounds/styles match the native subset.
- Keyboard traversal, pan/zoom/fit bounds (0.25 to 4.0 scale), accessible labels, light/dark, and Reduce Motion are preserved.
- Canonical `[[page:<ULID>]]`, `[[source:<ULID>]]`, and validated relative file/subpath references route to the same destinations.

## Verification

Focused suites: manifest/canonicalization/capability; bridge contracts; WebView/session/host; JSON Canvas package, parser, hosted, fallback, and neutrality; affected Markdown/embed/built-in registry suites.

Repository gates on macOS: `make build`, `make test`, bare `swift build`, bare `swift test`, `scripts/validate-skills`, implementation review, and built-bundle absence inspection.

## Historical note

The former native JSON Canvas implementation is preserved as historical evidence in `plans/dynamic-renderers-phase6-json-canvas-test-inventory.json` and its progress record. They describe a superseded design; this document is the current design of record.
