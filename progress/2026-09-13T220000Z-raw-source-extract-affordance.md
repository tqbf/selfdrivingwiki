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
says "This file is stored verbatim in the wiki") shows the affordance. One
matching extractor gets a button; several (a PDF matches both pdf2md and
docling-serve) get a dropdown menu, and the chosen package is force-run via
the same `StageRoutingKey.backend` override channel re-extraction uses —
`ExtractorRouteTableBuilder.executionBackend` maps the reviewed packages to
their execution backends, and unmapped packages run with the configured route
default. The panel text now states what each action does: extract adds a
Markdown version beside the untouched original; ingest asks the agent to read
it and update the wiki. Operator review moved the affordance here from the
source header: the header starts collapsed, so a header-only button was
undiscoverable exactly where the user needs a next step. The header keeps its
pre-#1252 behavior (generic Extract for un-extracted PDF/HTML/DOCX sources
only).

Standalone extraction runs in the wikid daemon and can outlive the view's
30-second XPC `waitForCompletion` (pdf2md and docling runs take minutes) —
after that timeout the view used to keep showing Raw Source until a
close/reopen. The tracker's `extractingSourceIDs` membership ends on the
daemon's terminal queue event, so the view now refreshes the derived head and
renderer presentation on that extracting→idle edge.

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
