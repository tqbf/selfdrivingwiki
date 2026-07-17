## Design: ACP session efficiency (issue #525)

Design document for optimizing the ACP session lifecycle in the multi-phase
ingest pipeline. **This is a research/design PR — no code changes.**

### Problem

`runACPIngestPlannerExecutors` spawns a new subprocess per phase (planner,
each executor, finalizer) — 7 complete lifecycles for a 5-source ingest, each
with ~2–4s of launch/initialize/authenticate/newSession/setModel overhead =
**12–24s wasted** on process plumbing.

The swift-acp SDK already exposes a rich session lifecycle we don't use:
`closeSession` (free context without killing subprocess), `resumeSession`
(crash recovery — our `resume()` returns `nil`), `forkSession` (branch
conversation), `listSessions`.

### Design: four incremental phases

1. **Warm subprocess** — one `launch`+`initialize` at ingest start, per-phase
   `session/new`+`session/close` (without `terminate`), one `terminate` at the
   end. New `ACPBackend.closeSession()` method. Eliminates 6 subprocess
   spawn/teardown cycles. Uses only existing SDK methods.

2. **`session/resume` crash recovery** — detect subprocess death, spawn a new
   one, `resumeSession` to restore context without history replay. Fall back
   to `session/load` (O(history)) or fresh `session/new`. Requires persisting
   the ACP `sessionId` in the QueueItem payload.

3. **`session/fork` for executors** — fork the planner session so executors
   inherit source-layout understanding without reasoning noise. Falls back to
   fresh sessions if fork unsupported.

4. **Parallel executors** — `withTaskGroup` for concurrent sessions on one
   subprocess (or a pool fallback), plus context monitoring via `usage_update`
   notifications (proactive artifact write at ~64%, close+fresh at ~80%).

### Also covers

- Context-benefit matrix (warm subprocess always; warm sessions only within
  context-beneficial boundaries — e.g., a single source extraction)
- Budget/cost tracking integration (`UsageUpdate.cost` and
  `SessionPromptResponse.usage` — currently discarded, ties to #528)
- Interaction analysis with the generation gate, `stopAgent`, and the watchdog
- Risk table with mitigations (silent subprocess death, concurrent sessions,
  context window exhaustion)
- Implementation sequencing with dependency graph

### Verified against

Confirmed all SDK method signatures and types against
`wsargent/swift-acp` v0.2.0+ source (`Client.swift`, `Capabilities.swift`,
`Updates.swift`, `Responses.swift`, `Session.swift`):
`closeSession`, `resumeSession`, `forkSession`, `listSessions`, `loadSession`,
`terminate`, `processIdentifier`, `stderrLines`;
`SessionCapabilities` sub-capabilities; `UsageUpdate` with
`used`/`size`/`cost`; `SessionPromptResponse` with `usage: Usage?`.

### Files

- `plans/acp-session-efficiency.md` — the design document (new)
- `PLAN.md` — documentation index entry (updated)
- `PROGRESS.md` — progress log entry (updated)

Closes #525 (design).
