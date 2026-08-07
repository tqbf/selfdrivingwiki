---
timestamp: 2026-08-07T171000Z
title: Dynamic renderers Phase 6 Excalidraw static package
branch: feature/dynamic-renderers-06-excalidraw-json-canvas
status: active
issue: 1026
phase: 6
---

# Dynamic renderers Phase 6 Excalidraw static package

## Progress

Commit `30ae1e42b1c165bd1dbb7b2cba16d32b44a03b96` adds the reviewed local Excalidraw package.
The package ID is `org.selfdrivingwiki.excalidraw-readonly` at version `1.0.0`.

The manifest declares every static package file with a SHA-256 digest.
It declares only `inputRead` and `externalLink` capabilities.
The existing `userActivatedExternal` contract controls external links.

The viewer requests input only through the existing `input.read` bridge method.
It renders a bounded subset of Excalidraw elements.
Pointer and keyboard input change only pan and zoom view state.
The package has no loader, worker, fetch, network socket, dynamic script evaluation, browser storage, or writable source path.

The Phase 5 host, session, bridge, navigation, CSP, safe-mode, and trusted-activation code did not change.
The existing host keeps Source fallback for unavailable, invalid, failed, or safe-mode-suppressed package input.

## Verification

- `WIKIFS_APP_TESTS=1 swift test --filter ExcalidrawRendererPackageTests --jobs 4` passed with four tests.
- The tests validate registration, capability bounds, asset completeness, package hash equality, static viewer controls, forbidden source patterns, and changed-asset rejection.
- `node --check RendererPackages/Excalidraw/viewer.js` passed.
- `jq empty RendererPackages/Excalidraw/manifest.json` passed.
- The static-source scan found no prohibited network, worker, dynamic-loader, dynamic-evaluation, writable-storage, clipboard, or editable-source pattern.
- The commit hook ran `swiftlint lint --strict` and passed with zero violations.

## Limits

The focused tests do not host WebKit.
They do not prove full Excalidraw compatibility.
The bounded matcher can keep a large valid document in Source when its signature is outside the sniff prefix.

[`plans/dynamic-renderers-phase6-excalidraw-package-test-inventory.json`](../plans/dynamic-renderers-phase6-excalidraw-package-test-inventory.json) maps each package path to its focused test at the exact package commit.
