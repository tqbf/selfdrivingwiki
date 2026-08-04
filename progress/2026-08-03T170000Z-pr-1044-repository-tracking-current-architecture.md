---
timestamp: 2026-08-03T170000Z
title: "2026-08-03 — PR #1044: repository tracking on the current daemon architecture"
branch: codex/repo-tracking
status: complete
---

# PR #1044: repository tracking on the current daemon architecture

## Progress

Ported repository tracking to GRDB schema v49, the existing XPC queue, and
`wikid` checkout ownership. Repository updates use bounded ACP reader fan-out
(2–19 readers) followed by one write-capable curator. The redesigned sidebar
stores metadata through `WikiStoreModel` and sends clone/fetch/update requests
to the daemon queue.

The port intentionally leaves repositories out of the File Provider projection,
does not restore SQLite/direct-operation boundaries, and keeps the ingestion
watermark agent-owned through `wikictl repo mark-ingested`.

## Verification

- `make build`
- Focused core tests for repository store/migration and reader planning
- `WIKIFS_APP_TESTS=1 swift test --filter WikiFSAppTests.QueueIngestionWorkerTests`
