---
timestamp: 2026-08-06T120000Z
title: Dynamic renderers Phase 5 failure accounting and safe mode
branch: feature/dynamic-renderers-05-webview-security
status: complete
---

# Dynamic renderers Phase 5 failure accounting and safe mode

## Progress

- Added a closed four-cause failure taxonomy for installed renderers.
- Persisted a ten-minute rolling window through the package-store coordinator.
- Enabled safe mode after three failures for one installed package version.
- Kept built-in renderers and Source outside the installed descriptor projection.
- Made reset clear safe mode and the rolling history with generation checks.
- Migrated v2 indexes with a savepoint. The migration preserves descriptors, safe mode, and generation.
- Stored only package identity, cause, and timestamp. The history has a fixed bound.

## Verification

- Ran focused failure-window, safe-mode, session-contract, and activation tests.
- Ran the documentation contract and inventory resolution checks.
- The session host does not yet send runtime failure events to the store. A later host-wiring slice owns that boundary.
