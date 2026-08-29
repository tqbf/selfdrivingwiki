---
timestamp: 2026-08-29T155846Z
title: Fail-closed extractor route recovery
branch: feature/docling-serve-extractor-package
status: complete
---

# Fail-closed extractor route recovery

## Progress

Explicit installed extractor selections now fail closed when they cannot run.

- The selection resolver preserves an unavailable saved package reference.
- PDF and HTML preparation no longer substitute another extractor.
- App and daemon preparation use the same fail-closed process-service seam.
- The route table uses **Ready**, **Needs setup**, **Not installed**, **Starting**, and **Failed**.
- Each non-ready status opens the **Extractor Status** sheet.
- The sheet explains the cause and blocked route.
- The sheet offers only actions that can help the current state.
- Recovery actions support configuration, authorization, connection tests, activation retry, status refresh, picker focus, and diagnostic copy.
- Diagnostics are deterministic, bounded, and redacted.
- Settings route health covers setup and package lifecycle state.
- Per-document extraction failures remain in Activity.
- Issue reporting is not part of this change.

## Privacy boundary

The diagnostic report can show safe package identity and route facts. It can also show bounded host failure text.

The report does not show credentials, headers, source content, parent environment, private paths, Keychain locations, or raw package output. A Docling endpoint contains only the scheme, host, and optional port.

## Verification

Focused resolver, engine, recovery presenter, diagnostic, and hosted Settings suites passed during implementation.

Three independent non-OpenAI reviews (fail-closed routing, SwiftUI design, Swift concurrency) ran against the implementation. Their findings were fixed and pinned by regression tests:

- The process facade now forwards HTML preparation, so valid selections run.
- An unavailable selection fails a queue item with an actionable message instead of staying queued.
- The store-level HTML path runs only the resolved adapter.
- A running connection test no longer wedges the status sheet.
- Fixed packages clear their retained failure state on the next successful activation.

The full repository suite passes. The final repository gates run before the branch commit and push.
