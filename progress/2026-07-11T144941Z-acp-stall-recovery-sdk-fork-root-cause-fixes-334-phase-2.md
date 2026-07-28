---
timestamp: 2026-07-11T144941Z
title: "2026-07-11 — ACP stall recovery: SDK fork + root-cause fixes (#334 Phase 2)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-11 — ACP stall recovery: SDK fork + root-cause fixes (#334 Phase 2)

## Progress


**Problem:** Phase 1 (#335) fixed the *symptom* (permanent stall → failed turn
with retry). Phase 2 fixes the four *root causes* inside the swift-acp SDK.

**SDK fork:** Forked `wiedymi/swift-acp` v0.1.0 → `wsargent/swift-acp` v0.2.0.
Upstream confirmed dead since v0.1.0 (no fixes available). `Package.swift`
swapped to the fork pinned to `v0.2.0`. Upstream PRs offered when the upstream
resumes.

**Four root-cause fixes (all in the fork):**

1. **Ordered transport reads** (the likely loss in the observed incident).
   `ACPProcessManager.startReading()` and `StdioTransport.startReading()` spawned
   an unstructured `Task { processIncomingData }` per pipe chunk — tasks raced
   across actor hops and could swap chunk order, corrupting JSON-RPC framing and
   silently dropping messages. Replaced with an ordered `AsyncStream<Data>` pipe:
   the readabilityHandler yields into the stream; ONE long-lived consumer calls
   `processIncomingData` in arrival order. Same fix in both transports.

2. **Non-blocking incoming requests.** `Client.handleMessage` dispatched
   `.request` handling inline — `handleIncomingRequest` awaited
   `requestRouter.routeRequest` on the actor. Under `.alwaysAsk`, a
   `session/request_permission` that suspends on a user decision froze the whole
   actor (no responses, no notifications). Now wrapped in `Task { }` — responses
   and notification yields stay inline (they're fast).

3. **Stderr forwarding.** `startReadingStderr` discarded stderr entirely.
   Now yields lines to a new `stderrLines()` stream on `Client`. Default consumer
   is none (preserving behavior). The app wires it to `DebugLog.agent`.

4. **PID exposure.** `ProcessRegistry` recorded pid/pgid but had no read API.
   `Client` gains `processIdentifier()` and `processGroupIdentifier()` methods.
   The app threads the PID to `AgentLauncher.currentProcessID` via
   `ACPBackend.processIdentifier(for:)` → `captureProcessID(session:)`.

**App-side wiring:**
- `ACPBackend.start`: starts a stderr drain task → `DebugLog.agent`.
- `ACPBackend.processIdentifier(for:)`: delegates to `session.client.processIdentifier()`.
- `AgentLauncher.captureProcessID(session:)`: called alongside
  `captureAndCacheModels` at all 4 spawn sites → assigns `currentProcessID`.

**Gate:** `swift build` clean (fork + app); fast tier **2140 tests in 180 suites
pass**. No new tests (SDK changes are in the fork; the app-side wiring is thin
delegation). Phase 2 ship gate: live-agent smoke (multi-turn session incl.
always-ask permission mid-turn) — needs manual verification with credentials.

**Files changed (selfdrivingwiki):**
- `Package.swift` — swapped to `wsargent/swift-acp` from `0.2.0`.
- `Package.resolved` — resolved fork.
- `Sources/WikiFS/ACPBackend.swift` — `processIdentifier(for:)` + stderr drain.
- `Sources/WikiFS/AgentLauncher.swift` — `captureProcessID(session:)` + 4 call sites.

**Files changed (fork: wsargent/swift-acp):**
- `Sources/ACP/Internal/ProcessManager.swift` — ordered reads + stderr + PID.
- `Sources/ACP/Transport/StdioTransport.swift` — ordered reads.
- `Sources/ACP/Client.swift` — non-blocking requests + PID/stderr accessors.

## Verification

Historical verification remains in the progress record above.
