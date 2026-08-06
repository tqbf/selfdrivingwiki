---
timestamp: 2026-08-06T100000Z
title: Dynamic renderers Phase 5 bridge security remediation
branch: feature/dynamic-renderers-05-webview-security
status: complete
---

# Dynamic renderers Phase 5 bridge security remediation

## Progress

- Closed the bridge review's navigation, provenance, reply-delivery, and replay-retention findings.
- Added a package-only navigation policy and applied it to navigation actions, responses, and window creation.
- Bound isolated-world messages to the session's actual WebView, package security origin, and main frame.
- Switched the adapter to `WKScriptMessageHandlerWithReply` and relayed bounded responses back through the isolated world.
- Limited relay injection to the main frame, removed the inert `navigate-to` CSP directive, and bounded request identifiers and retained replay state.
- This remediation does not add trusted activation, general subresource interception, network or storage harnesses, safe mode, a SwiftUI host, Excalidraw, JSON Canvas, or settings UI.

## Verification

- Exact production head: `f13da5ebbb0e90cf9a6714e1b8854cb63a7a1c54`.
- Evidence head: `b8395f244f2b7876de9b28f5acb7582f5de18414` (docs/test contract only after the production head).
- Focused bridge, navigation-policy, package-resource, scheme-handler, and opt-in session tests passed.
- `make build` passed, `make lint` passed with 0 violations, `swift build` passed, and `make test` passed with 3,218 tests in 285 suites.
- JSON validation, bidirectional inventory resolution, documentation contract tests (9 tests), and `git diff --check` passed.
- The portable and opt-in tests do not prove a live page's WebKit provenance or network isolation; hosted WebKit positive controls and hostile matrices remain required later slices.
