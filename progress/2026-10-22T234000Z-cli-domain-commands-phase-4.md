---
timestamp: 2026-10-22T23:40:00Z
title: CLI domain commands Phase 4 — every mutating wikictl command rides the daemon with typed CAS codes
branch: feature/cli-domain-commands
status: complete
---

# CLI domain commands Phase 4: writes over the envelope, CAS across the wire

## Progress

Phase 4 of `plans/cli-domain-commands.md` is implemented on the landed
envelope, following the Phase 3 pattern — the daemon EXECUTES the CLI's
command layer — extended to mutations:

- **Wire** (`WikiDaemonContract`): four typed CAS codes on
  `DaemonDomainErrorCode` — `casConflict` (kind `page` or `sourceMarkdown`),
  `createOnlyConflict`, `expectedTargetMissing`, `strategyRevisionConflict` —
  each carrying a structured `DaemonConflictDetail` (target id, title,
  expected, actual; nil = absent) on `DaemonDomainError`. New families
  `strategy`, `log`, `admin`, `extractor`; write operations on
  page/source/chat/bookmark/workspace; `DaemonDomainBudgets` (per-endpoint
  handler budgets) and the per-operation payload structs.
- **Server** (`DaemonDomainCommands`): every write operation maps its payload
  to the SAME `*Command.run` action the in-process path runs, against the
  daemon's prepared store. `reply(for:)` catches the five typed store errors
  (`PageConflictError`, `PageCreateConflictError`,
  `PageExpectedTargetMissingError`, `SourceMarkdownConflictError`,
  `WikiStrategyConflictError`) and rethrows them as the typed envelope error —
  never a stringified stderr guess. Bodies cross RESOLVED (the CLI resolves
  `BodySource` file/stdin before the wire; the daemon has no caller stdin).
  `page add` runs with the same linter (which AUTO-FIXES the body) and fence
  validator the in-process path uses. `extractor sync/fetch` executes the
  WHOLE command daemon-side — the daemon's own catalog and store, with the
  durable enqueue going through the queue engine's `enqueue` (the exact
  closure the `enqueueItem` queue operation runs).
- **Server budgets** (`DaemonSearchSocketServer.Connection`): the handler
  race now reads its budget from the decoded envelope via
  `DaemonDomainBudgets.handlerTimeout(family:operation:)` — admin family and
  workspace merge/reap get 600 s (client deadline 660 s, above the server so
  the true outcome rides back); everything else keeps the socket's 60 s/30 s
  posture. No async-job pattern — the budget sufficed.
- **CLI** (`DaemonCommandRouting.swift`): every mutating command maps to a
  `DaemonCommandCall` (which now carries its per-endpoint client timeout);
  `DaemonCommandRouter.run` rebuilds the typed store errors from the CAS
  codes (`conflictError(from:)`), so main.swift's existing catch clauses
  print the byte-stable conflict text and exit 3 — successes never throw and
  keep exit 0. `WorkspaceCommand.Action.resolve` became `body: BodySource` (a
  raw bodyFile string would be treated as a PATH server-side). The CLI's old
  direct queue-write path for extractor sync/fetch survives only for
  `--database-path` fixtures (Phase 5 strips it).

Phase 4 deviations (source okf family + `page okfCorrect` + `chat rename` +
`strategy read` riding along; bodies inline; the budget choice; extractor
rerouting) are documented in
`plans/cli-domain-commands.md` §"Deviations from the plan (Phase 4)".

## Verification

- `make build` green; full `make test` (default graph) green.
- New `DaemonCommandWriteSocketTests` (19 tests, Swift Testing, real AF_UNIX
  against the real `DaemonDomainSocketDispatcher` over a fixture daemon,
  `.serialized` + `.timeLimit`, short injected timeouts, no blocking waits):
  page add success (didCommit + visible through the daemon store); stale
  `--expect-head` → typed `casConflict` with expected AND actual heads;
  `--create-only` race → `createOnlyConflict` with the existing head; ghost
  target → `expectedTargetMissing`; delete + revert round trips;
  `page okfCorrect`; source addFile (bytes) → editMarkdown success THEN stale
  head → typed `casConflict` (kind `sourceMarkdown`, expected/actual);
  rename/set-active; addURL invalid-URL and refresh not-refreshable typed
  failures; source okf status write; chat rename failure shape; bookmark
  add-ref/rename/delete; workspace create/abandon/reap; strategy
  save-absent → conflict (expected nil, actual "1") → save on revision →
  reset; log append + index set; admin vacuum round trips within budget plus
  the budget-table pins (600/660 elevated, 60/30 standard); oversized page
  reply → typed frame-cap `operationFailed`; and `extractor sync`/`fetch`
  creating sources and landing durable items in the DAEMON's queue store
  (visible via `queueWikiItems`). Router tests pin the CLI-side CAS
  reconstruction (each code → the exact typed store error main.swift's
  exit-3 catch paths key on) and the success path.
- Neighboring suites stay green: `DaemonCommandSocketTests` (the former
  "unmigrated write stays local" seam test is inverted — a registry-selected
  write now routes over the daemon and the in-process store executor is
  never reached), `DaemonDomainSocketTests`, `DaemonWikiSocketTests`,
  `DaemonSearchSocketTests`, `DaemonWorkloadClientTimeoutTests` — 50 tests.
- swiftlint clean on all touched files.
- Live check: see the transcript summary in the final report — bundled
  `wikictl` against a throwaway wiki: page add success; stale
  `--expect-head` → exit 3 with the conflict text; `source edit-markdown`
  conflict → exit 3; `extractor sync` → item visible in `queue status` /
  `job list`; `strategy save` → exit 0; app quit → write fails fast with the
  not-running error; app relaunched and left RUNNING.
