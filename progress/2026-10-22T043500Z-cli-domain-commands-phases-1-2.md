---
timestamp: 2026-10-22T04:35:00Z
title: CLI domain commands Phases 1–2 — one socket, versioned envelope, daemon-owned wiki lifecycle
branch: feature/cli-domain-commands
status: complete
---

# CLI domain commands, Phases 1–2: the socket becomes THE CLI→daemon transport

## Progress

Phase 1 (commit `2d809bbe`) — transport generalization + queue verbs:

- `DaemonDomainWire` (WikiDaemonContract): the versioned top-level envelope
  `{version, requestID, family, operation, payload}` → typed reply/`error`.
  The version is checked BEFORE dispatch; unknown family/operation is a typed
  `invalidRequest` reply. Operation strings live in `DaemonDomainOperation`.
- `DaemonDomainSocketDispatcher` (wikid): the daemon boot's socket handler now
  routes families instead of calling `searchData` directly. ONE socket file
  (`wikid-search.sock`), same framing/flock/same-user gate/deadlines. The
  queue family reuses `WikiDaemonExporter`'s handlers verbatim, so the queue
  error taxonomy and engine-less stubs are identical to the app's XPC surface.
- `DaemonDomainSocketClient` (WikiCtlCore): envelope client + shared
  `DaemonSocketRoundTrip`; `DaemonSearchSocketClient` wraps the unchanged
  `SearchRPCRequest`/`SearchRPCReply` bytes in the envelope (raw-size cap
  check preserved so oversized searches report their own byte count).
- `DaemonWorkloadClient`: socket backend (`init(socketContainerDirectory:)`)
  with socket legs for snapshot/enqueue/pause/resume/halt — this FIXES the
  pre-existing lookup3 defect (`wikictl queue status` and `transcribe`
  enqueue could never reach the app-embedded XPC service). XPC-only surfaces
  throw a typed failure on the socket backend; the app's XPC path is
  unchanged.
- `SearchSocketError` is `LocalizedError` now; app closed maps to exit 1 with
  "the wikid daemon is not running — launch the app".

Phase 2 (commit `c123797d`) — registry + lifecycle:

- The dispatcher serves the `wiki` family: `listWikis`, `createWiki`,
  `deleteWiki`, `renameWiki`, `resolveWiki` — each routing to the daemon's
  EXISTING registry methods. Unknown ids are resolve-first typed `notFound`
  with the CLI's byte-stable "no wiki matching <id>" text.
- `WikiDaemon.createWikiOverSocket/deleteWikiOverSocket`: production
  coordinator path when a profile owner exists, fixture seam otherwise
  (mirrors `openStore`'s split).
- `DaemonWikiRegistryClient` (WikiCtlCore) is the CLI's typed client.
- wikictl: `wiki list/create/delete/rename` route through the daemon;
  `transcribe --wiki` resolution goes through `resolveWiki`. The CLI's
  direct `wikis.json` writes are gone from those paths, and
  `WikiCtlRunner.runWikiCreate` + its `StoreBootstrap` are DELETED — the
  daemon's creation coordinator owns bootstrap + seed + registry; delete
  inherits the daemon's full eviction (search runtime shutdown, child
  profile removal, registry row, database artifacts), closing the CLI's
  degraded-delete race. Exit codes and stdout formats unchanged.

The envelope's exact wire shape (for Phases 3–4) and the deviations are
documented in `plans/cli-domain-commands.md` §"The landed envelope (v1)" and
§"Deviations from the plan (Phases 1–2)".

## Verification

- `make build` green after each phase; `make test` (default graph) green
  after each phase.
- New suites (Swift Testing, in-process server+client over real AF_UNIX,
  `.serialized` + `.timeLimit`, short injected timeouts, no blocking waits):
  - `DaemonDomainSocketTests` — 9 tests: hello capabilities round trip,
    stale-version → typed `unsupportedVersion`, unknown family string →
    `invalidRequest`, unknown queue operation → `invalidRequest`, malformed
    envelope bytes → typed reply, queue snapshot + lane controls + typed
    enqueue failure over the real socket, absent-daemon `daemonNotRunning`
    with the exact localized message.
  - `DaemonWikiSocketTests` — 6 tests: full lifecycle over the real socket
    (create with trimmed name + Home seeded → list → resolve by ULID and by
    display name → rename → delete with registry row AND `-wal`/`-shm`
    artifacts evicted), blank-name → "Untitled Wiki", unknown-id delete →
    typed `notFound`, unknown/malformed wiki payloads → `invalidRequest`,
    not-running mapping.
- Updated suites: `DaemonSearchSocketTests` 14/14 (fixture handlers wrapped
  in the same envelope routing the daemon applies — all PR #1460 transport
  coverage preserved), `DaemonWorkloadClientTimeoutTests`,
  `DaemonSearchClientTests`, `DaemonSearchTests` green.
- Pre-existing failures verified NOT from this work: `DaemonChatHostTests`
  fails identically on clean HEAD (chat preflight succeeds where the test
  expects a provider-less failure — environmental); the full opt-in app tier
  has documented load flakes (#1397) — `WikiChangeBridgeTests`,
  `PdfExtractionServiceTests`, `PipeDrainingTests`, `DaemonChatHostTests`
  each failed once across four full runs, all pass in isolation.
- Live check (bundled `/Applications/Self Driving Wiki.app/Contents/Helpers/
  wikictl`, app running, daemon socket present):
  - `--wiki 01M41BV9H7N34EAW18R7G9SQEP queue status` → exit 0, TSV intact.
  - `wiki list` → exit 0, 8 wikis.
  - `--wiki 01M41BV9H7N34EAW18R7G9SQEP page search --query Ironworkers` →
    exit 0, 10 hits (search regression guard holds through the envelope).
  - App quit: `queue status` → exit 1
    "wikictl: the wikid daemon is not running — launch the app";
    `wiki list` → same fail-fast.
  - App relaunched; `wiki list` exit 0 again. The app was restarted once
    (make install) and is left RUNNING.
- swiftlint clean on all touched files (pre-commit hook ran the full-tree
  lint: 0 violations).
