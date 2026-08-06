---
timestamp: 2026-08-06T103500Z
title: Dynamic renderers Phase 5 bridge remediation evidence
branch: feature/dynamic-renderers-05-webview-security
status: complete
---

# Dynamic renderers Phase 5 bridge remediation evidence

## Progress

- Production remediation head: `fdd303f199d736ea5f7737cb40037288f75a1eb4`.
- The retained Phase 5 inventory uses base `933a0637fa5593c4fdba611edb380058b5838f71` and remediation head `fdd303f199d736ea5f7737cb40037288f75a1eb4`. This correction replaces an abbreviated, incorrect base pin. It does not change the retained gate results.
- The Markdown byte preflight reads the pinned CAS blob size. A missing blob denies the input.
- WebView provenance requires a non-nil expected binding and observed identity.
- A stopped scheme task releases registry state without a WebKit failure callback.
- The inventory checks every listed production and test path. It resolves each named test one time.

## Verification

- `RendererAuthorizedInputReaderTests` passed 2 tests.
- `SourceVersionStoreTests` passed 10 tests.
- `RendererContentWorldBridgeTests` passed 4 opt-in app tests.
- `RendererPackageSchemeHandlerTests` passed 6 opt-in app tests.
- `DocumentationContractTests` passed 10 tests.
- `make lint` passed with 0 violations. `git diff --check` passed.
- The retained shell resolver passed with the `phase5-inventory-bidirectional-resolution-pass` marker.
- The executable Swift inventory contract also passed. It validates the listed paths and named-test resolution.
- The portable bridge and scheme tests do not run a live renderer document.
- The remediation does not claim live WebKit provenance, cancellation delivery, or network isolation.
