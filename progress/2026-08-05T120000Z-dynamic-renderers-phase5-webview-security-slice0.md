---
title: Dynamic renderer Phase 5 WebView-security Slice 0
timestamp: 2026-08-05T12:00:00Z
branch: feature/dynamic-renderers-05-webview-security
status: complete
timestamp_source: operator-request
---

# Dynamic renderer Phase 5 WebView-security Slice 0

## Progress

Added the PR-series audit executable and its SHA-keyed gate schema. The audit requires a clean exact head, valid ancestry, matching GitHub metadata, and current evidence. The executable uses an async `@main` entry point, so a successful command returns with exit status zero.

The audit now applies the PR-series exact-head, check-head, and approval-head policy in verify and build-suite operations. It writes RFC3339 evidence atomically. It reads the GitHub state and local head after the write. It rejects evidence when either value changes.

The gate record has typed finding dispositions. A critical or high finding must have a resolved or rebutted disposition. An unresolved critical or high finding fails the gate.

Activation now preserves caller-owned validated staging when coordinator acquisition fails. It returns the exact coordinator failure without changing its classification. The activation test triggers this path through `RendererMachineIndexStore.activate`.

The retained test inventory defines the future session input contract. A future WebView session will use `SourceVersionID` bytes or `SourceMarkdownVersionID` Markdown. This slice does not add WebView code.

## Verification

Run `swift test --filter RendererPackageActivationTests`, `swift test --filter DynamicRendererPRSeriesAuditTests`, and `swift test --filter DocumentationContractTests`. Run `swift run DynamicRendererPRSeriesAudit verify --series plans/dynamic-renderers-pr-series.json --evidence tmp/dynamic-renderer-gates` only from a clean committed checkout.
