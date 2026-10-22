---
timestamp: 2026-10-22T08:28:05Z
title: CLI domain commands Phase 5 — completion wait over the daemon, the CLI's last direct access stripped, boundary enforcement
branch: feature/cli-domain-commands
status: complete
---

# CLI domain commands Phase 5: one pathway, machine-enforced

## Progress

Phase 5 of `plans/cli-domain-commands.md` is implemented — the final phase.
Commits `f46b609f`, `23d92155`, `a2e62aea`, `17cb52af`, `24b7e7db`,
`9ee9cc48`, `06a6c44e`:

- **Transcribe completion over the daemon.** New queue-family operation
  `queueItemState` (`DaemonDomainWire`/`DaemonCommandWire`): a one-item
  state snapshot (raw `QueueItemState` string + recorded failure text) read
  through a read-only `QueueStore` beside the engine's writer — the same WAL
  pattern `queueWikiItems` uses — served by
  `DaemonDomainCommands.queueItemStateReply` behind the dispatcher, with a
  socket leg on `DaemonWorkloadClient.queueItemState(of:)` (the XPC
  `waitForCompletion` continuation stays app-only). `wikictl transcribe
  --wait` loops on it: one short round trip per poll, sleep between calls,
  `Task.checkCancellation()` each iteration, per-call deadline bounds every
  trip, the 165-minute ceiling stays the caller's wait policy. No socket
  connection (and no CLI-owned queue connection) outlives a poll. A failed
  snapshot with no recorded text now terminates the wait as "failed"
  instead of polling to the ceiling.
- **The transcribe enqueue preflight rides the daemon too.** New
  `transcribePreflight` queue-family op evaluates the same YouTube-scope
  rule through `domainCommandStore`; `inScope=false` covers missing and
  non-YouTube sources alike (the CLI's typed failure is byte-identical), an
  unknown wiki is typed `notFound`, and a wrong-source mistake still fails
  BEFORE anything is enqueued. `GRDBWikiStore.youtubeSpeechPreflight` is no
  longer called from the CLI; `ResolvedWikiTarget`/`databaseURL(for:)`
  dropped out of the transcribe flow.
- **No local store or registry path for registry-selected commands.**
  `WikiCtlRunner.runOrdinary`'s registry branch REQUIRES a
  `DaemonCommandRoute` mapping — an unmapped command fails with "no daemon
  route … no local fallback" instead of booting `CLIStoreProfile` (every
  such command dispatches before the runner in `run()`, so the guard fires
  only on a wiring bug; pinned by a seam test). `WikiResolver` lost
  `descriptor(forSelector:)` (the `WikiRegistry.load` read),
  `databaseURL(for:)`, and `resolve(selection:)`'s registry case — `--wiki`
  resolution happens through the daemon's `resolveWiki`, and the resolver
  serves only explicit `--database-path` fixtures.
- **Extractor sync/fetch fixture leg isolated.** The Phase 4 leftover
  direct queue write moved from main.swift to
  `Sources/wikictl/ExtractorFixtureLeg.swift` and runs ONLY inside explicit
  `--database-path` fixture runs; behavior inside the leg is unchanged.
- **Boundary enforcement.** `scripts/check-cordis-boundaries` gains a
  scope-limited matcher (`reject_matches_in`, with a fixture-layout
  fallback) and rejects `QueueStore(` and `WikiRegistry.load(` in
  `Sources/WikiCtlCore` and `Sources/wikictl` — the single allowlist entry
  is `Sources/wikictl/ExtractorFixtureLeg.swift`, the sanctioned
  `--database-path` fixture carve-out. `CordisBoundaryScriptTests` pins the
  rejections (four new violating fixtures), the carve-out acceptance, and
  the real tree in default and `--strict` modes.
- **`wiki list`/`wiki create` print raw ULIDs again** (`06a6c44e`): the
  daemon descriptors' `WikiID` interpolated in Debug form; `.rawValue`
  restores the TSV scripting contract. Surfaced by the live check;
  pre-existing on the Phase 2 print path.

The plan documents Phase 5 as implemented, the two new queue operations in
the envelope inventory, and §"Deviations from the plan (Phase 5)".

## Verification

- `make build` green after each work item; full `make test` green
  (one-off `WikiFSCoreTests` flake on the first run, two clean reruns —
  5588 test passes).
- Daemon opt-in suites green in one run:
  `DaemonCommandWriteSocketTests`, `DaemonCommandSocketTests` (18 tests —
  including the new no-route guard seam test),
  `DaemonDomainSocketTests` (14 tests — 5 new for the Phase 5 ops),
  `DaemonWikiSocketTests`, `DaemonSearchSocketTests`,
  `DaemonWorkloadClientTimeoutTests`, `DaemonSearchTests` — 82 tests.
- New socket coverage: `queueItemState` lifecycle snapshots (queued →
  running → completed; failed carries the error text), unknown-item and
  no-database typed `notFound`, malformed payload → `invalidRequest`, and
  `transcribePreflight`'s true leg (YouTube-provenance seed), both false
  legs, and the unknown-wiki `notFound`.
- Boundary violation proof (live experiment): reintroducing
  `WikiRegistry.load(` in `WikiResolver.swift` and `QueueStore(` in
  wikictl main.swift made `scripts/check-cordis-boundaries` exit 1 naming
  exactly those two files; removing the probes restored green.
- Live check (bundled `Contents/Helpers/wikictl`, app running):
  - Real wiki `01M41BV9H7N34EAW18R7G9SQEP`: `page list` exit 0; `page
    search --query Ironworkers` exit 0 with exactly 10 hits; `queue status`
    exit 0; `job list` exit 0.
  - Throwaway wiki (created and deleted through the daemon):
    `page add --create-only` exit 0; `page add --id --expect-head <current>`
    exit 0 (CAS success); the same write against the stale head exited 3
    with the byte-stable conflict text ("expected head … but actual head
    is … Re-read the page, reapply your edit, and retry once."). Both
    throwaway wikis deleted (full eviction).
  - App quit: `page list` failed fast — exit 1, "the wikid daemon is not
    running — launch the app".
  - App relaunched; reads exit 0 again. The app was restarted twice (the
    Phase 5 install, plus a second install to pick up the raw-ULID fix) and
    is left RUNNING.
- swiftlint clean on all touched files (pre-commit hook: 0 violations, no
  new bare `try?`).
- **Rebase onto `origin/main`**: the two already-merged search-fix commits
  (`9f7e94b1` + `d6659ff9`, squashed upstream as `a1d892f9`) are gone —
  `d6659ff9` auto-dropped as already upstream, `9f7e94b1` skipped (its
  squash twin is the base). `6362dd32` (sandbox cold-index grant) was
  skipped deliberately: main's #1460 superseded it — search rides the
  daemon, so the sandboxed child no longer needs an index-write grant
  (main's `SandboxProfile` comment and tests state exactly this), and no
  later branch commit depends on the grant. No conflicts remained in the
  phase commits; the plan's cited SHAs were updated to the rebased ones.
