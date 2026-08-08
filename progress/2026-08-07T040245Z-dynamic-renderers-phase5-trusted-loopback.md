---
timestamp: 2026-08-07T040245Z
title: Dynamic renderers Phase 5 trusted loopback WebKit harness
branch: feature/dynamic-renderers-05-webview-security
status: complete
---

# Dynamic renderers Phase 5 trusted loopback WebKit harness

## Progress

The hosted positive control keeps its live HTTP receiver and its live WebSocket receiver.

The WebSocket receiver now uses Network.framework TLS. It resolves the login-keychain identity with SHA-1 `7C0B00954A876487620BE7B2E2D0FDEC54B8EF08`.

The receiver compares the selected certificate digest before it starts. It uses the identity as its TLS server identity.

The WebSocket URL now uses `wss://127.0.0.1`. This uses the certificate IP SAN and matches the IPv4 loopback listener.

The test still requires the HTTP response, the WebSocket `open` callback, the WebSocket upgrade response, and both receiver tokens. It does not replace the receiver with a mock or skip the assertion.

## Verification

`WIKIFS_APP_TESTS=1 SWIFTPM_MODULECACHE_OVERRIDE=$PWD/tmp/orchestration/dynamic-renderers-phase5-webview-security/module-cache swift test --filter RendererHostedWebKitHarnessTests --jobs 1` passed one hosted test in 0.421 seconds.

The test observed the HTTP response, the WebKit `open` callback, the WebSocket upgrade response, and both receiver tokens.

The identity lookup selected the required SHA-1 certificate. A Security API inspection showed SANs for `localhost`, `127.0.0.1`, and `::1`.

## Diagnosis and fix

The first failing run reached the TLS listener but rejected the valid upgrade.
The receiver split headers on LF, but WebSocket requests use CRLF line endings.

The receiver now parses request lines and headers with explicit CRLF boundaries.
The browser then completed the WebSocket handshake and the test passed.

The harness also records browser state, trust challenges, listener state, and
the last server event when a timeout occurs. No production ATS exception,
private WebKit flag, fake receiver, or weakened assertion was added.
