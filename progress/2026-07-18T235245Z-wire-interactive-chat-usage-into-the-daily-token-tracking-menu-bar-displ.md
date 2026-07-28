---
timestamp: 2026-07-18T235245Z
title: "2026-07-18 — Wire interactive chat usage into the daily token tracking + menu bar display (branch `feature/chat-usage-tracking`)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-18 — Wire interactive chat usage into the daily token tracking + menu bar display (branch `feature/chat-usage-tracking`)

## Progress


**Problem:** The "Today: X tokens" menu bar item only counted usage from queue-based runs (ingest/lint). Interactive chat sessions (Ask/Edit tabs) go through `AgentLauncher.startInteractiveQuery` + `sendInteractiveMessage`, which did NOT emit usage via the `onUsage` callback — a long chat burning 50K tokens didn't show up in the daily total. The `ACPBackend` already captures `SessionUsage` for ALL sessions via `SessionUsageState`; the gap was that `AgentLauncher` only called `capturePhaseUsage` + emitted `onUsage` from the queue-based `run()` path, not from the interactive `sendInteractiveMessage` path.

**Key correctness challenge — no double-counting across turns.** The backend's `sessionUsage(for:)` returns **cumulative** per-session totals (tokens across all turns of one session), and `DailyUsage.add` is **additive**. The queue path reads each phase session's usage **once** (no double-count, since each phase is a separate session). Interactive chat reuses ONE session across many turns, so naively emitting the cumulative snapshot after each turn and adding it would re-add the full total on every turn. The fix emits the **per-turn delta** (`current cumulative − last-emitted baseline`) so the daily total only gains the marginal tokens for that turn.

**Approach — Option A (callback).** Matches the existing `onAgentEvent` callback on `AgentLauncher` and the closure-injection threading (`WikiFSApp` → `SessionManager.init` → `WikiSession.init`). Keeps capture in the `@MainActor` `sendInteractiveMessage` turn-end branch (naturally main-actor safe). Avoids adding a new `AgentEvent` case (which would complicate the transcript drain + persistence + the `StoreEmissionExhaustivenessTests` partition).

Changes:

- **`Sources/WikiFSEngine/ACPBackend.swift`** — added `SessionUsage.delta(from:to:)` static helper next to `merging`. Computes the incremental usage between two cumulative snapshots of the same session: token counts are subtracted (`to − from`, clamped to ≥0); cost is a delta (`to.cost − from.cost`, clamped ≥0); context window is point-in-time (takes `to`); provider label/model id/thinking level are latest-non-nil-wins (matching `merging`). `from == nil` returns `to` directly (first turn's delta == full snapshot).
- **`Sources/WikiFSEngine/AgentLauncher.swift`**:
  - New `@ObservationIgnored public var onInteractiveUsage: (@MainActor (SessionUsage) -> Void)?` callback (installed by the app layer; `nil` = no-op so headless/daemon callers are unaffected).
  - New `@ObservationIgnored private var lastInteractiveUsageSnapshot: SessionUsage?` per-session baseline.
  - New `captureInteractiveUsage()` async method: reads `backend.sessionUsage(for: sessionHandle)` (while the session is still alive, before `cancel`/`closeSession`), attaches the configured `runProviderLabel`, computes `delta(from: lastInteractiveUsageSnapshot, to:)`, updates the baseline, and forwards the delta via `onInteractiveUsage`. Silent no-op for non-ACP backends or when the callback is nil. Only forwards when `totalTokens > 0 || cost != nil`.
  - Call site: `sendInteractiveMessage`'s turn-end (`endsGeneration`) branch now calls `await self.captureInteractiveUsage()` after `flushTranscript()`/`generateChatSummary()`.
  - Reset: `lastInteractiveUsageSnapshot = nil` in `resetRunArtifacts()` (per-run fresh start) and `onInteractiveUsage = nil` + `lastInteractiveUsageSnapshot = nil` in `finish()` (session teardown).
- **`Sources/WikiFS/Queue/QueueActivityTracker.swift`** — added `recordInteractiveUsage(_ usage: SessionUsage)` that accumulates the delta into `todayUsage` and persists. Deliberately does NOT create an `itemUsage` entry (interactive chat has no queue item); only the daily total — which the menu bar reads — is updated. The existing `.usage` queue event handler is unchanged.
- **`Sources/WikiFSEngine/WikiSession.swift`** — new `interactiveUsageRecorder: @MainActor (SessionUsage) -> Void` init parameter (default no-op); installed onto BOTH `agentLauncher` and `chatLauncher` so interactive queries AND chats report usage.
- **`Sources/WikiFSEngine/SessionManager.swift`** — new `interactiveUsageRecorder` init param threaded through to `WikiSession`.
- **`Sources/WikiFS/Window/WikiFSApp.swift`** — passes `interactiveUsageRecorder: { [weak activityTracker] usage in activityTracker?.recordInteractiveUsage(usage) }` at `SessionManager` construction (the tracker is created just before the manager).

**No double-count with queued runs.** A single `AgentLauncher` runs EITHER a queue `run()` OR an interactive `startInteractiveQuery` (never both); `resetRunArtifacts()` is called at the start of each and clears `lastInteractiveUsageSnapshot`. The queue path never calls `captureInteractiveUsage` (only `sendInteractiveMessage` does), and the interactive path never emits a queue `.usage` event. So a session that is both queued AND interactive (theoretically possible via takeover) counts once per path.

**Tests:** Added 4 `SessionUsage.delta` tests (`deltaWithNilBaselineReturnsFullSnapshot`, `deltaSubtractsBaselineTokens`, `deltaCarriesMetadataFromBaselineWhenMissing`, `deltaClampsToZero`) in `ACPBackendTests.swift`, and 1 `QueueActivityTracker.recordInteractiveUsage` accumulation test in `QueueIngestionTests.swift`. The tracker test captures + restores the persisted `DailyUsage` so it doesn't pollute the real menu bar count.

**Build/Tests:** `make version prompts && swift build` clean; fast test tier **2578 tests / 219 suites pass**.

## Verification

Historical verification remains in the progress record above.
