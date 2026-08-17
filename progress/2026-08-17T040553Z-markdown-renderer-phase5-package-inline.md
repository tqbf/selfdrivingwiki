---
timestamp: 2026-08-17T040553Z
title: Markdown renderer Phase 5 package-inline seam and evidence
branch: feature/markdown-renderers-05-package-inline
status: complete
---

# Markdown renderer Phase 5 package-inline seam and evidence

## Progress

Added the `RendererAuthorizedInputResolving` composition seam and wired
`SourceDetailView` through it so installed renderers resolve the exact
version-pinned source reader through the main-actor model boundary instead of
calling the concrete store method directly.

The new seam is covered by `RendererAuthorizedInputReaderTests` with a
main-actor test that proves the resolver returns the exact pinned reader for
the requested source. The retained inventory records the implementation head,
the source-detail wiring, and the exact tests that cover the seam and the
store-backed reader path.

The branch kept unrelated signing-file work untouched. No extra renderer
registry, bridge, package store, or security path was added.

## Verification

Passed:

- `swift test --filter RendererAuthorizedInputReaderTests/resolverSeamReturnsTheExactPinnedReader --jobs 4`
- `make build`
- `make test`
- `WIKIFS_APP_TESTS=1 swift test`
- `swift build`
- `swift test`
- `swiftlint lint --strict`
- `git diff --check`

The code commit for the implementation head is `63657e10b8a278e6c476119eddb2964f0bee75c2`.
