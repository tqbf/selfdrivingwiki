---
timestamp: 2026-08-06T120000Z
title: Dynamic renderers Phase 5 bridge review blockers
branch: feature/dynamic-renderers-05-webview-security
status: complete
---

# Dynamic renderers Phase 5 bridge review blockers

## Progress

- Added portable behavioral tests for bridge routing, reply encoding, and provenance rejection.
- Added an exact-version byte-count preflight before the bridge reader loads source or Markdown content.
- Kept SourceVersionID and SourceMarkdownVersionID pins for each preflight and payload read.
- Kept package scheme tasks registered until success, failure, stop, or close ends the serve lifecycle.
- Fixed the retained inventory to resolve every named test one time in a listed test path.

## Verification

- Run the focused bridge, reader, and scheme-handler tests.
- Run DocumentationContractTests and the inventory resolution command.
- Run `make lint` and `git diff --check`.
- The portable bridge test does not run a live WebKit page. It does not prove WebKit provenance delivery.
