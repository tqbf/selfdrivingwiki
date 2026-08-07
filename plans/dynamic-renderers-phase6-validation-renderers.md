# Dynamic renderers Phase 6: validation renderers

## Scope

Phase 6 implements the first renderer validation cases from issue #1026.

- Excalidraw uses the installed static WebView renderer contract.
- JSON Canvas uses the built-in native renderer contract.
- Both renderers keep Source fallback available for invalid, missing, or failed input.
- Renderer selection stays outside `SourceDetailView`.

## Dependency

This phase stacks on PR #1082, `feature/dynamic-renderers-05-webview-security`.
The Phase 5 host, package validation, session isolation, bridge limits, trusted activation, and safe mode must remain unchanged unless a test exposes a contract defect.

## First bounded slice

1. Add typed, bounded Excalidraw and JSON Canvas artifact matchers.
2. Add deterministic valid and malformed fixtures for both formats.
3. Add registry and fallback tests before adding either renderer view.
4. Record the exact implementation head and map each new production symbol to named tests.

## Later slices

1. Add the reviewed Excalidraw viewer package and read-only pan and zoom.
2. Add typed JSON Canvas decoding and the native pan, zoom, selection, and outline surface.
3. Add typed link actions, keyboard traversal, accessibility labels, appearance, and Reduce Motion behavior.
4. Add hosted and golden validation for both renderers.

## Boundaries

Renderer packages cannot write source data, invoke undeclared bridge methods, or bypass the Phase 5 WebView policy. JSON Canvas links use typed host actions. External URLs use the existing trusted activation contract.
