---
timestamp: 2026-08-02T162100Z
title: Issue 1047 URL source duplicate warning
branch: lethal-chipmunk
status: complete
---

# Issue 1047 URL source duplicate warning

## Progress

The URL source flow now checks stored URL provenance before it fetches data.

The check lowercases the scheme and host. It ignores URL fragments. It keeps query parameters and trailing slashes.

The Add from URL sheet shows the matched source name. The user can open that source, cancel, or add another source explicitly.

`wikictl source add --url URL` now reports the matched source and does not fetch it. Use `--allow-duplicate` to add another source.

Content-hash duplicate detection remains separate from this URL check.

## Verification

`make build` passed.

`swift test --filter 'URLFetchServiceTests|WikiStoreModelAddURLTests'` passed. The tests cover URL identity and verify that a duplicate URL does not call the fetcher.
