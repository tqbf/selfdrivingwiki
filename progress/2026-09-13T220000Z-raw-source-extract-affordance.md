---
timestamp: 2026-09-13T220000Z
title: Raw Source Extract affordance (#1252)
branch: feature/show-extract-button-raw-source
status: implemented; CI compiler fix pending verification
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

CI reported that the added view complexity caused SwiftUI type checking to fail
at the existing active-tab lookup. The lookup now uses a local tab array and a
separate closure expression. A local scratch build passed the modified
`SourceDetailView` compilation point without that diagnostic; the full target
was stopped during unrelated remaining compilation after no further output.
