---
timestamp: 2026-08-07T063000Z
title: Dynamic renderers Phase 5 CI and hosted WSS remediation
branch: chore/phase5-ci-wss-gate
status: complete
---

# Dynamic renderers Phase 5 CI and hosted WSS remediation

## Progress

macOS CI now runs the selected portable WebKit-facing Phase 5 suites.

The CI step runs package-scheme, bridge, external-activation, and host/session lifecycle tests.

The CI step excludes the storage-isolation and hosted HTTP/WSS suites.

Those suites require real AppKit or WebKit state, hosted network receivers, or a login-keychain TLS identity.

The hosted HTTP/WSS positive control now requires `WIKIFS_RENDERER_HOSTED_NETWORK_TESTS=1`.

When the required TLS identity is absent, test discovery reports the suite as disabled with the keychain diagnostic.

When enabled, the test still requires a real HTTP response, WSS upgrade, WebKit `open` callback, and both receiver tokens.

## Verification

The documentation contract test first failed because CI did not select the portable suites and the inventory claimed a WSS pass.

The focused documentation contract and selected app-test suites run after this update.

Ordinary CI proves the selected portable WebKit-facing tests only. It does not prove live WSS or browser-storage isolation.
