---
timestamp: 2026-10-22T05:26:14Z
title: CLI domain commands Phase 3 — the daemon executes the read-only command layer
branch: feature/cli-domain-commands
status: complete
---

# CLI domain commands Phase 3: every read-only wikictl command is store-free

## Progress

Commits `0bf3478e` (read families + job + routing seam) and `15b67245`
(server-side search resolution):

- **The daemon EXECUTES the CLI's command layer.** `wikid` now links
  `WikiCtlCore` (macOS), and the new `DaemonDomainCommands` executor runs
  `PageCommand.run` / `SourceCommand.run` / `ChatCommand.run` /
  `BookmarkCommand.run` / `WorkspaceCommand.run` against the daemon's
  prepared store — admitted through `WikiDaemon.domainCommandStore`, the
  `prepareAndResolveWikiServices` path (fixture seam in tests). Every family
  replies with the uniform `DaemonCommandOutcome {text | bytesBase64,
  didCommit, stderr}`, so byte-stable stdout is guaranteed by construction:
  the same code renders the bytes in both worlds. The CLI does zero catalog
  work — it sends the parsed action and prints.
- **Wire** (`WikiDaemonContract/DaemonCommandWire.swift`): families
  `page`/`source`/`chat`/`bookmark`/`workspace` with per-operation payload
  structs (each carrying `wikiID`, resolved FIRST — unknown wiki is typed
  `notFound` with the byte-stable `no wiki matching <id>` text);
  `Queue.queueWikiItems` behind `job list/get` — the durable FULL terminal
  history read (`QueueStore.loadItems(wikiID:)` through a read-only WAL
  connection beside the engine's writer) plus the extraction-completed wiki
  leg read through the prepared store.
- **Routing seam**: `WikiCtlRunner` gained `daemonCommandRouter`;
  `DaemonCommandRoute.call(for:)` maps ONLY the migrated reads (registry
  selection only) onto daemon calls — anything unmigrated (Phase 4 writes)
  and every `--database-path` fixture keeps the in-process path. The okf
  status/freshness/verify verbs are sanctioned Phase 3 scope: the daemon
  executes their writes and `didCommit` drives the Darwin post exactly as
  before. `job list/get` rerouted through `DaemonCommandRouter.runJob`; the
  CLI's direct `queue.sqlite` + `WikiReadService` reads are gone from
  `main.swift`.
- **Search store-freedom**: `page`/`source`/`chat` × `search` operations run
  the ENTIRE command server-side — BM25 leg via the daemon's own
  `ensureSearchRuntime`, hits mapped against the store catalog (absent ids
  dropped; an all-empty resolution is NO leg, never an error, mirroring
  `CLITantivyLegResolver`), fused with the semantic cosine leg through the
  store's `searchSimilar`, rendered through the same `*Command.run` code. The
  zero-results stderr note and TSV bytes are identical to the in-process
  path.
- **Frame cap**: the dispatcher's shared reply encoder replaces any encoded
  reply over `SearchSocketWire.maxFrameSize` (4 MiB) with a typed
  `operationFailed` naming the cap and the narrower read to use — never a
  truncation. Worst cases audited: `source cat` (base64 bytes, ~3 MiB decoded
  ceiling) and `page get` (page body). `source export` is immune — the daemon
  writes the exported file into the CALLER's cwd (which rides the request)
  and replies with just the path.
- Error contract: unknown wiki → `notFound` ("no wiki matching <selector>",
  dropping the local path's " in the registry" suffix per the Phase 2 daemon
  text); malformed payload → `invalidRequest`; command failures (no page
  titled X, file not found, multiple sources named Y) → `operationFailed`
  carrying the command's own message, printed by the CLI's existing catch
  paths (`wikictl: <message>`, exit 1). Exit codes 0/1/2/3 preserved.

Phase 3 deviations and the exact payload shapes are documented in
`plans/cli-domain-commands.md` §"The landed envelope (v1)" and
§"Deviations from the plan (Phase 3)".

## Verification

- `make build` green; `make test` (default graph) green; the full opt-in
  tier's daemon suites green.
- New `DaemonCommandSocketTests` (17 tests, Swift Testing, real AF_UNIX
  against the real `DaemonDomainSocketDispatcher` over a fixture daemon,
  `.serialized` + `.timeLimit`, short injected timeouts, no blocking waits):
  one round trip per operation (page list/get/--json, history, info, okf
  inspect→status→freshness→verify including the write's `didCommit` and a
  re-inspect proving visibility; source list/cat-bytes/export-into-caller-
  cwd/info; chat list empty + get-missing failure; bookmark list TSV+JSON;
  workspace status/conflicts; job list/get through the real router with a
  durable queue row), typed `notFound`/`invalidRequest`/`operationFailed`
  shapes with exact messages, absent-daemon `daemonNotRunning` through the
  router, and three seam tests pinning that migrated reads (including
  `page search`) never reach the in-process store executor while a Phase 4
  write still does.
- Neighboring suites stay green: `DaemonDomainSocketTests`,
  `DaemonWikiSocketTests`, `DaemonSearchSocketTests`,
  `DaemonWorkloadClientTimeoutTests` — 33 tests.
- Live check on the real wiki `01M41BV9H7N34EAW18R7G9SQEP` with the
  installed app running (bundled `Contents/Helpers/wikictl`): page list,
  source list, chat list, workspace status, job list, and
  `page search --query Ironworkers` (exit 0, 10 hits) all succeed through
  the daemon; with the app quit, a read command fails fast with
  "the wikid daemon is not running — launch the app" (exit 1). The app was
  restarted once (make install) and left RUNNING.
- swiftlint clean on all touched files.
