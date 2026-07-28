---
timestamp: 2026-07-27T044546Z
title: "2026-07-27 — LOW audit: AutocompleteHostedTestGate"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-27 — LOW audit: AutocompleteHostedTestGate

## Progress


Audited `Tests/WikiFSAppTests/AutocompleteHostedTestGate.swift` and its two
users, `EditorAutocompleteHostedTests.swift` and
`ComposerAutocompleteHostedTests.swift`. No `WKWebView` is used. Both suites
are `@MainActor` and `.serialized` internally, while Swift Testing can still
overlap the suites; each creates a live AppKit `NSWindow`/`NSTextView` hierarchy
and retains a suite-static window through deferred teardown. The gate therefore
protects a test-only hosted AppKit lifecycle, not production autocomplete
contention. Based on the prior full-matrix idle-helper failure, narrowing it to
construction or teardown alone is not technically safe: the entire hosted
interaction must remain within the lease.

Conclusion: retain the explicit lifecycle gate as a technically defensible
rebuttal to the LOW concern. A narrower design would first need per-test window
ownership plus a targeted concurrent hosted regression; that is a separate
harness redesign, not a safe bounded edit. No test code was changed.

## Verification

Historical verification remains in the progress record above.
