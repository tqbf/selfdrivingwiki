---
timestamp: 2026-08-07T174500Z
title: Dynamic renderers Phase 6 native JSON Canvas
branch: feature/dynamic-renderers-06-excalidraw-json-canvas
status: active
issue: 1026
phase: 6
---

# Dynamic renderers Phase 6 native JSON Canvas

## Progress

Commit `e2315838a3470324195b9fde58c53ccd6283c0bf` adds the native JSON Canvas slice.
It adds `json-canvas` to the closed built-in renderer map.

Commit `b09c82bc37ae4f6575f59df5485e3f828af8aaf7` corrects its capability metadata.
The descriptor sets `supportsVoiceOver` and `supportsKeyboardNavigation` to false.
This record does not claim either behavior.

Commit `7e59888cf706e9b429ac0ca9cfecc1c5b760ee62` adds validation boundary tests.
It does not change production behavior.

Commit `cd12be4588b9529b63bf475f1c01521a12aebb84` adds deterministic keyboard traversal and individual VoiceOver semantics.
The descriptor now sets `supportsVoiceOver` and `supportsKeyboardNavigation` to true.
Up and Down traverse the document outline, selection stops at the first or last node, and Left and Right move between the outline and canvas surfaces.
Each outline entry and each canvas node is a read-only selectable SwiftUI control with a meaningful label, selected value, and Select action.

Commit `66c97c23d286ea86c183cb40ad6215485caac1ea` adds typed internal JSON Canvas links.
File nodes accept only a bounded safe relative path, and link nodes accept only canonical `[[page:<ULID>]]` or `[[source:<ULID>]]` targets.
The decoder rejects absolute, traversal, scheme-bearing, credential-bearing, query, fragment, percent-escaped, external, and ambiguous values.
The view exposes an explicit `Open Internal Link` context-menu action that emits a closed typed host request; it does not navigate, open URLs, read files, or invoke WebView code.

Commit `8b243e22e2fde5ba769ebe625f896591c0abd873` completes the JSON Canvas appearance and Reduce Motion item.
The view uses semantic background, primary, secondary, and accent styles with Dynamic-Type body fonts.
The selected node has a wider border as a non-color cue.
The root transaction disables inherited and local animation for pan, zoom, focus, and selection.
The renderer has no animation or transition modifier, so it has no Reduce Motion alternate transition.

The decoder reads at most 256 KiB before it decodes JSON.
It bounds nodes, edges, identifiers, text, coordinates, zoom, and translation.
It accepts text nodes, safe internal file and wiki link nodes, and node-to-node edges only.
It rejects unknown fields, unsupported nodes, unsafe link data, bad geometry, and missing edge endpoints.

The factory returns no view when input is unavailable or invalid.
The existing renderer host then keeps Source fallback.
The view changes only local pan, zoom, selection, and outline state.
It writes no source data; its typed link request is inert until separately authorized host wiring exists.

The Phase 5 host, session, bridge, navigation, CSP, safe-mode, and trusted-activation code did not change.
The Excalidraw package files and tests did not change.

## Verification

- `WIKIFS_APP_TESTS=1 swift test --filter 'JSONCanvasRendererTests|BuiltInRendererRegistryTests' --jobs 4` passed with 37 tests after the typed-link implementation.
- `WIKIFS_APP_TESTS=1 swift test --filter 'JSONCanvasRendererTests|BuiltInRendererRegistryTests|RendererArtifactMatcherTests|SourceDetailRendererArchitectureAuditTests' --jobs 4` passed with 48 tests after the typed-link implementation.
- `make lint` passed with zero violations and no new bare `try?` use after the typed-link implementation.
- `make build` passed after the typed-link implementation.
- Bare `swift build` passed after the typed-link implementation.
- `make test` passed with 3,254 tests in 291 suites after the typed-link implementation.
- `git diff --check` passed before the implementation commit.
- The registry test asserts both descriptor capability flags are true.
- The validation tests cover excessive edges, duplicate node and edge IDs, invalid and non-finite geometry input, oversized text, translation clamps, and non-finite zoom factors.
- The typed-link tests cover local file and canonical page/source references, unsafe external and ambiguous rejection, closed action dispatch, and factory Source fallback.
- The appearance test pins the semantic SwiftUI styles, Dynamic-Type body font, wider selected border, and disabled no-motion transaction.
- `WIKIFS_APP_TESTS=1 swift test --filter DocumentationContractTests --jobs 4` passed with 11 tests against this refreshed JSON Canvas evidence.
- `make test` passed after the semantic appearance and no-motion implementation.

## Limits

The native renderer does not support group nodes, arbitrary URLs, external URL activation, file reads, host navigation, aliases, fragments, or version pins. The host-action seam is intentionally inert until separately authorized host wiring.
The focused tests do not host a SwiftUI window, toggle system appearance or Reduce Motion, measure contrast, assert AppKit keyboard routing or VoiceOver output, or verify pixels.
The matcher reads only a bounded JSON prefix. A matching document can fail full decoding and then stays in Source fallback.

[`plans/dynamic-renderers-phase6-json-canvas-test-inventory.json`](../plans/dynamic-renderers-phase6-json-canvas-test-inventory.json) maps each native path to its focused tests at the exact implementation commit.
