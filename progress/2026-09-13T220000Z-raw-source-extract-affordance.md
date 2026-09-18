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

`make build` and the full `make test` suite pass. The compile failure was not
view complexity: `SourceDetailView` called
`extractionCoordinator.activeRegistrationSnapshots()`, but that method existed
only on the `ExtractionServices` protocol and its conformances — not on
`ExtractionCoordinator`, the facade the view holds. Because the unresolvable
call sat inside the single-expression `body` modifier chain, the compiler
reported it as "unable to type-check this expression in reasonable time" at
the nearby active-tab lookup, which misled the first two fix attempts. The
forwarder now exists on `ExtractionCoordinator`, the registration load lives
in `loadActiveExtractorRegistrations()` outside `body`, and the Extract
button title is hoisted into `extractButtonTitle`. Focused check:
`WIKIFS_APP_TESTS=1 swift test --filter SourceDetailViewContentKindTests`
(21 tests, including the two Raw Source matching tests).
