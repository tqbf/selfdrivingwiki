---
timestamp: 2026-07-17T234922Z
title: "2026-07-17 — Issue #525: Design — ACP session efficiency (branch `design/acp-session-efficiency`)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-17 — Issue #525: Design — ACP session efficiency (branch `design/acp-session-efficiency`)

## Progress


**Design doc written.** Produced `plans/acp-session-efficiency.md` covering the
full ACP session-lifecycle optimization for the multi-phase ingest pipeline.

The problem: `runACPIngestPlannerExecutors` spawns a new subprocess per phase
(planner, each executor, finalizer) — 7 complete lifecycles for a 5-source
ingest, each with ~2–4s of launch/initialize/authenticate/newSession/setModel
overhead = 12–24s wasted on process plumbing.

The design documents four incremental phases:
1. **Warm subprocess** — one `launch`+`initialize` at ingest start, per-phase
   `session/new`+`session/close` (without `terminate`), one `terminate` at the
   end. New `ACPBackend.closeSession()` method. Uses only existing SDK methods.
2. **`session/resume` crash recovery** — detect subprocess death, spawn a new
   one, `resumeSession` to restore context without history replay. Falls back
   to `session/load` (O(history)) or fresh `session/new`. Requires persisting
   the ACP `sessionId` in the QueueItem payload.
3. **`session/fork` for executors** — fork the planner session so executors
   inherit source-layout understanding without reasoning noise. Falls back to
   fresh sessions if fork unsupported.
4. **Parallel executors** — `withTaskGroup` for concurrent sessions on one
   subprocess (or a pool fallback), plus context monitoring via `usage_update`
   notifications (proactive artifact write at ~64%, close+fresh at ~80%).

Includes a context-benefit matrix (warm subprocess always; warm sessions only
within context-beneficial boundaries like a single source extraction), budget/
cost tracking integration (`UsageUpdate.cost` and `SessionPromptResponse.usage`
— currently discarded, ties to #528), interaction analysis with the generation
gate, `stopAgent`, and the watchdog, and a risk table with mitigations.

Verified against the swift-acp SDK (`wsargent/swift-acp` v0.2.0+) source:
confirmed `closeSession`, `resumeSession`, `forkSession`, `listSessions`,
`loadSession`, `terminate`, `processIdentifier`, `stderrLines` method
signatures; confirmed `SessionCapabilities` sub-capabilities
(`close`/`resume`/`fork`/`list`/`delete`); confirmed `UsageUpdate` carries
`used`/`size`/`cost: Cost(amount:currency:)`; confirmed `SessionPromptResponse`
carries `usage: Usage?` with `inputTokens`/`outputTokens`/`totalTokens`.

Key files read: `Sources/WikiFSEngine/AgentLauncher.swift` (the
`runACPIngestPlannerExecutors`, `runPhase`, `startInteractiveQuery`,
`stopAgent`, `finish`, `startCompletionWatchdog` methods),
`Sources/WikiFSEngine/ACPBackend.swift` (the `ACPSession` struct, `start`,
`send`, `cancel`, `resume`, `resolveSpawnConfig`),
`Sources/WikiFSEngine/AgentBackend.swift` (the protocol, `SessionHandle`,
`BackendProfile`), `Sources/WikiFSEngine/ACPPermissions.swift` (the
`ACPEventTranslator` — discards `.usageUpdate`),
`Sources/WikiFSEngine/GenerationGate.swift`, `Sources/WikiFSEngine/QueueIngestionProvider.swift`.

## Verification

Historical verification remains in the progress record above.
