---
timestamp: 2026-09-13T220000Z
title: Raw Source Extract affordance (#1252)
branch: feature/show-extract-button-raw-source
status: implemented; placement moved to Raw Source reader panel per operator review
---

# Raw Source Extract affordance (#1252)

## Progress

SourceDetailView now loads active extractor registration snapshots from the
extraction runtime. A pure route-table matcher selects one deterministic
package when a raw source matches a declared MIME type or file extension.

The Raw Source reader panel (the `binaryFallback` ContentUnavailableView that
says "This file is stored verbatim in the wiki") shows one primary action when
a matching extractor is registered. The action names the package, such as
`Extract with pdf2md`, and dispatches through the same managed path as the
header's Extract button (`runExtractForCurrentSource`). Operator review moved
the affordance here from the source header: the header starts collapsed, so a
header-only button was undiscoverable exactly where the user needs a next step.
The header keeps its pre-#1252 behavior (generic Extract for un-extracted
PDF/HTML/DOCX sources only).

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
