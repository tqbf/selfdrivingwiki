---
timestamp: 2026-09-23T120000Z
title: wikictl job visibility and stable enqueue IDs (#1316)
branch: feature/1316-wikictl-job-status
status: complete
---

# wikictl job visibility and stable enqueue IDs (#1316)

Built on `feature/package-declared-sync` (PR #1310) — the `extractor sync`
command is not on `main`, so this PR stays based on that branch until it
merges.

## Progress

- **`wikictl job list` / `wikictl job get --id <job-id>`** — read-only
  durable-queue inspection for the selected wiki, with `--json` output
  carrying stable field names (`id`, `queue`, `state`, `sourceIDs`,
  `attempt`, `failureReason`, `extractionCompleted`). `loadItems(wikiID:)`
  on `QueueStore` is the read surface: every item for one wiki including
  terminal history, newest first, skipping unknown queue kinds so older
  persisted rows still render.
- **Read-only queue open** — `QueueStore.init(readOnlyDatabaseURL:)` opens
  with `SQLITE_OPEN_READONLY` + `PRAGMA query_only=ON`, runs no migrations,
  and skips the close/deinit WAL checkpoint. A missing queue database is an
  empty list, not an invitation to create the file. The command dispatch
  bypasses the writable wiki-store profile entirely.
- **Extraction-completed is a fact about the source, not the queue** — the
  job commands cross-reference the wiki DB through `WikiReadService` (the
  sanctioned read-only projection seam; the Cordis boundary script rejects
  bare `GRDBWikiStore` construction in `wikictl`): a source counts as
  extraction-completed when it has any processed Markdown head. A
  completed job implies it; a source can be complete with no job (extracted
  in the app) or a placeholder with none.
- **Sync output tells the truth** — `extractor sync` prints the stable job
  ID from the queue store on create and re-enqueue, and always says
  "request accepted; extraction is not complete" instead of implying
  readiness. The skip line now distinguishes `source exists` from
  `extraction completed/not completed` — the old "already synced" wording
  hid the zero-byte-placeholder case that motivated this issue. An enqueue
  that fails before the queue accepts it throws a typed failure naming the
  source, the underlying cause, and the `--force` retry; the source row
  stays durable either way. `ExtractorSyncOutcome.jobID` (and the
  `enqueueJob` closure returning `QueueItem.ID?`) carries the ID; the
  void-`enqueue` overloads remain for existing callers and tests.

## Verification

- `make build` passes.
- `make test`: 4109 tests across 421 suites with no new failures. The
  remaining local failures are pre-existing environment issues in this
  worktree, reproduced identically on the unmodified base branch:
  "Race-free process group runner" needs `ExtractorProcessFixture` at the
  native-SwiftPM `.build/<config>/debug` path, which the make-driven
  Xcode-build-system layout here does not produce (PR #1310 CI is green);
  "IdentifierBoundaryTypecheckTests" and
  `ExtractorPackageStoreTests.concurrentReadersSeeOnlyCompleteGenerations`
  flake under `--parallel` locally and pass in isolation.
  `./scripts/check-cordis-boundaries --strict` passes (it caught and
  rejected the first draft's direct `GRDBWikiStore` construction).
- New tests: read-only open reads stably without migrating or changing a
  byte of the queue database; read-only list filters by wiki and includes
  terminal items; parser recognizes `job list`/`job get`; empty-queue JSON
  is a stable `[]`; a failed job renders every stable JSON field; sync
  output carries the job ID and the skip/completed distinction; an
  enqueue failure names the source and the retry.
