---
timestamp: 2026-08-06T180425Z
title: Dynamic renderers Phase 5 trusted activation contracts
branch: feature/dynamic-renderers-05-webview-security
status: complete
---

# Dynamic renderers Phase 5 trusted activation contracts

## Progress

- Finalized the isolated trusted-activation capability contract.
- Bound each nonce to normalized HTTP(S) destination and host context.
- Made deadline expiry strict and retained one-use invalidation.
- Kept external opening behind successful redemption.
- Did not wire the session host in this slice.

## Verification

- Ran the focused trusted-activation contract tests with the SwiftPM cache workaround.
- Ran the trusted-activation lint, inventory resolution, and diff checks.
- The contract tests do not execute a live WebKit page. A hosted suite still owns synthetic-event and WebKit-provenance proof.
