---
timestamp: 2026-09-13T220000Z
title: Raw Source Extract affordance (#1252)
branch: feature/show-extract-button-raw-source
status: implemented; verification limited by stale SwiftPM process
---

# Raw Source Extract affordance (#1252)

## Progress

SourceDetailView now loads active extractor registration snapshots from the
extraction runtime. A pure route-table matcher selects one deterministic
package when a raw source matches a declared MIME type or file extension.

The source header shows one primary action only for Raw Source without a
derived Markdown head. The action names the package, such as `Extract with
pdf2md`, and uses the existing managed extraction queue.

The existing sourcesVersion observer remains the refresh path. The store event
bus reloads the source state after extraction writes, and the observer reloads
the derived Markdown head.

## Verification

The macOS app-target build compiled the changed engine and SwiftUI files without
diagnostics. The focused app-test target and normal `make build` gate could not
finish because interrupted SwiftPM processes retained the shared `.build` lock;
the waiting attempts were stopped after they produced no further progress.
