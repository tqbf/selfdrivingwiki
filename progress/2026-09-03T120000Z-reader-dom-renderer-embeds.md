---
timestamp: 2026-09-03T120000Z
title: Reader DOM renderer embeds
branch: feature/reader-dom-renderer-embeds
status: implemented
---

# Reader DOM renderer embeds

## Progress

Implemented on `feature/reader-dom-renderer-embeds`. Not merged.

## What changed

The reader embedded renderer content as native AppKit child views in a sibling
overlay. The overlay needed geometry messages, viewport projection, and zoom
reprojection, and it lagged the page. Reader embeds now live inside the reader
document's DOM:

- Package renderers expand into a sandboxed `renderer-package:` iframe inside
  the row's expansion region.
- Built-in PDF and raw HTML render as pinned iframes served from exact-version
  blob URLs.
- Byte-backed audio and video render as `<audio>` / `<video>` elements.
- Provider-hosted media with no bytes renders a readable fallback with an
  explicit open action. The reader embeds no external iframes.
- The native sibling overlay, its child dictionary, geometry messages, and
  zoom reprojection are removed. `WikiReaderContainerView` hosts only the
  reader webview.

## Why the origin moved

WebKit blocks framed custom-scheme loads from an https parent (custom-scheme
CORS enforcement). Hosted probes proved the block: a `renderer-package:` or
`wiki-blob:` child under an https parent stays at `about:blank`, and the
scheme task never starts. The reader document therefore loads under a
dedicated `wiki-reader:` scheme. Hosted probes also proved that WebKit honors
a custom-scheme `loadHTMLString(baseURL:)` only when the scheme has a
registered `WKURLSchemeHandler`; `WikiReaderDocumentSchemeHandler` satisfies
that. The `wiki-reader:` origin is never stamped into an external URL.

## Security model

- Each admitted package frame gets a 128-bit random origin token. WebKit
  reports the token as the frame's exact `WKSecurityOrigin.host`. Frames are
  cross-origin isolated; the parent cannot read a frame's document.
- `ReaderRendererPackageRouter` maps one token to one package reservation and
  rewrites to the canonical `renderer-package://package/...` form. Unknown,
  replayed, revoked, cross-package, and cross-generation tokens fail closed.
- The canonical `RendererPackageSchemeHandler` stays the single source of CSP,
  MIME, no-sniff, response ordering, and cancellation.
- `ReaderRendererFrameBridgeRegistry` scopes one bridge session per frame:
  broker, input reader, expected origin host, webview identity, generation.
  Wrong token, origin, webview, generation, or closed state rejects the
  message. Two same-package frames cannot read each other's inputs.
- Raw HTML frames omit `allow-scripts`. Package frames get exactly
  `allow-scripts`. Nested frames, popups, forms, and top navigation stay
  denied.

## Budgets and lifecycle

Row budget (4 expanded), inline budget (6), and frame budget (6 concurrent,
30-second load timeout) stay distinct. `ReaderDOMRendererLifecycle` is a
finite state machine per placeholder with an explicit legal-transition table.
Stale-generation callbacks fail closed. Collapse, DOM removal, navigation,
reload, dismantle, and process termination close only the matching session.

## Verification

- `RendererHostedSubframeHarnessTests`: subframe origin proof, two-frame
  isolation, https-parent negative control, harness self-tests (AC.11).
- `ReaderRendererFrameBridgeTests`: provenance rejection axes, budget bounds,
  scoped teardown (AC.4, AC.9).
- `ReaderDOMRendererLifecycleTests`: FSM transitions, budgets, stale
  generation, scoped removal (AC.8).
- `BlobSchemeHandlerTests`: exact-version bytes/MIME, HEAD non-substitution
  (AC.6).
- `BuiltInRendererDOMPlanTests`: PDF/HTML/audio/video plans, inert sandbox,
  byteless fallback with no iframe (AC.6, AC.7).
- `RendererAttachmentCoordinatorTests`: retained FSM/policy tests plus a
  hosted DOM-scroll test asserting the container hosts exactly one subview
  (AC.1, AC.2, AC.10).

## Known issues

Two source-contract suites fail on pristine `main` before this branch:
`SourceDetailRendererArchitectureAuditTests` and
`BuiltInRendererRegistryTests`. Commit `9c1604ce` renamed the Source Detail
wiring to `routedInstalledRendererFactoryInputs` and removed a factory entry
without updating those tests. The failures are pre-existing and unrelated;
fix them in a separate change.

## Follow-ups

- A human visual check should confirm that an expanded diagram stays attached
  to surrounding text during trackpad scrolling.
- The AC.12 representative-document hosted regression scenario is not yet
  written; the behaviors it covers have individual coverage.
