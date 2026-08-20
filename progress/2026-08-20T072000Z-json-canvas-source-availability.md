---
timestamp: 2026-08-20T072000Z
title: Make JSON Canvas source content available
branch: feature/json-canvas-source-renderer
status: complete
---

# Make JSON Canvas source content available

## Progress

The existing native JSON Canvas renderer now receives source content from
`SourceDetailView`. The `.canvas` extension resolves to `application/json`.
The Source pane shows the raw JSON in a code block. The existing renderer host
provides the Reader, Rendered, and Split presentations.

The decoder now accepts standard group nodes and HTTP(S) link nodes. It still
rejects unsafe file references, malformed wiki links, invalid geometry, and
oversized input.

## Verification

`WIKIFS_APP_TESTS=1 swift test --filter 'WikiFSAppTests.JSONCanvasRendererTests|WikiFSAppTests.BuiltInRendererRegistryTests|WikiFSAppTests.SourcesTests'` passed.

The focused run covered 89 tests with zero failures.
