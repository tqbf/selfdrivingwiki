---
timestamp: 2026-08-07T181500Z
title: Dynamic renderers Phase 6 hosted validation
branch: feature/dynamic-renderers-06-excalidraw-json-canvas
status: active
issue: 1026
phase: 6
---

# Dynamic renderers Phase 6 hosted validation

## Progress

Commit `783bb56f699d80192529132157ace287af3403e9` adds the final Phase 6 hosted-validation suite.
It adds test evidence only. It does not change production renderer code, package assets, or Phase 5 policy.

The JSON Canvas test decodes a fixed two-node document, mounts `JSONCanvasRendererView` in a real AppKit `NSWindow` through `NSHostingController`, and captures a nonempty PNG. Its exact outline order remains `First note`, then `Second note`.

The Excalidraw test changes no package asset or package policy. It validates the reviewed package into an isolated temporary staging root, constructs the production version-pinned package URL and resource provider, then mounts the real restrictive `WikiAppWebViewSession`. After the session reaches ready state, the test replays the viewer's existing `input.read` envelope through the content-world bridge, observes `svg.scene`, sends synthetic `+` and Right Arrow keyboard events, and verifies two distinct bounded view transforms. Replacing the SwiftUI root then observes the existing session close lifecycle.

No permissive HTTP or WebSocket test harness is used for this package-session test. No external activation is sent. No URL is opened, file is resolved, network request is made, or source data is written.

## Verification

- Observed: `WIKIFS_APP_TESTS=1 swift test --filter Phase6RendererHostedValidationTests --jobs 4` passed with two tests.
- Observed: `WIKIFS_APP_TESTS=1 swift test --filter 'Phase6RendererHostedValidationTests|ExcalidrawRendererPackageTests|JSONCanvasRendererTests|BuiltInRendererRegistryTests|RendererArtifactMatcherTests|SourceDetailRendererArchitectureAuditTests' --jobs 4` passed with 55 tests in seven suites.
- Observed, environment-bound: `WIKIFS_APP_TESTS=1 WIKIFS_RENDERER_HOSTED_NETWORK_TESTS=1 swift test --filter RendererHostedWebKitHarnessTests --jobs 4` passed one permissive HTTP/WebSocket positive-control test with the local trusted loopback identity provisioned. This does not alter the restrictive package-session test or production policy.
- Observed: `WIKIFS_APP_TESTS=1 swift test --filter DocumentationContractTests --jobs 4` passed with 11 tests.
- Observed: `make lint`, `make build`, bare `swift build`, and `make test` passed. The lint run reported zero violations and no new bare `try?` use.
- Observed: the exact inventory resolver command and `git diff --check` passed.
- The suite uses `HostedAppKitTestGate`, is serialized, polls without blocking cooperative threads, checks cancellation, and times out after 15 seconds.

## Limits

The JSON Canvas check is a real-window mount plus deterministic outline and nonempty-bitmap evidence, not a pixel-baseline golden test. It does not toggle appearance or Reduce Motion, measure contrast, assert AppKit focus routing, or observe VoiceOver output.

The Excalidraw check covers package validation, restrictive local package navigation, authorized input, synthetic keyboard pan/zoom, and teardown. It does not prove pointer or wheel delivery, full Excalidraw compatibility, or an external-link redemption. The optional live HTTP/WebSocket positive control remains unavailable where the trusted loopback identity is not provisioned; it must be recorded as skipped there, not passed.

[`plans/dynamic-renderers-phase6-hosted-validation-test-inventory.json`](../plans/dynamic-renderers-phase6-hosted-validation-test-inventory.json) maps this final hosted evidence to the exact test implementation commit.
