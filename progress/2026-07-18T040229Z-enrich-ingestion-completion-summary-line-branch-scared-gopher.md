---
timestamp: 2026-07-18T040229Z
title: "2026-07-17 — Enrich ingestion completion summary line (branch `scared-gopher`)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-17 — Enrich ingestion completion summary line (branch `scared-gopher`)

## Progress


**Problem:** When an ingestion finished, the Activity window showed "797 in · 203 out" — no unit, no model, no harness, no thinking signal, no start time, no duration. The user couldn't tell what the numbers meant or what ran.

**Fix:** Threaded run metadata (provider label + model id) from the launcher into `SessionUsage` and enriched `UsageFormatter` to produce a full summary line.

Changes across 4 source files + 1 test file:

- **`Sources/WikiFSEngine/ACPBackend.swift`** — `SessionUsage` gained `providerLabel: String?` and `modelId: String?` (point-in-time, latest non-nil wins on merge, like cost/currency). `sessionUsage(for:)` now enriches the snapshot with `session.modelsInfo?.currentModelId` (the actual model the session used).
- **`Sources/WikiFSEngine/AgentLauncher.swift`** — `capturePhaseUsage` gained a `providerLabel` parameter; every call site (7 total — planner, executor ×3, finalizer, single-session, runPhase) passes `routing.provider.label`. The provider label is attached before merging into `runTotalUsage`.
- **`Sources/WikiFS/Queue/QueueActivityTracker.swift`** — `UsageFormatter` gained `tokenSummary(usage:)` (token segment with explicit "tokens" unit + thought tokens), `duration(ms:)`, `startTime(ms:)`, and `fullSummary(usage:startedAt:finishedAt:)` which composes the full line.
- **`Sources/WikiFS/Queue/ActivityWindowView.swift`** — both display sites (list row + detail header) call `fullSummary` with `item.startedAt`/`item.finishedAt` (already on `QueueItem`).

The completion line now renders like:
```
2:32 PM · 1m 3s · Claude · sonnet-4 · 797 tokens in · 203 tokens out · 412 thought · $0.34
```
Each segment is omitted when its data is unavailable. There is no "thinking effort" level setting; thought tokens (the cumulative reasoning-token count) surface as "412 thought" when present.

**Tests:** `Tests/WikiFSTests/UsageFormatterTests.swift` (27 tests covering `tokens`, `cost`, `duration`, `startTime`, `tokenSummary`, `summary`, `fullSummary` edge cases). Extended `ACPBackendTests.swift` with 3 `SessionUsage.merging` tests for the new fields.

**Build/Tests:** `swift build` clean; `swift test --filter UsageFormatterTests` 27/27 pass; full fast test tier 2462 tests pass.

## Verification

Historical verification remains in the progress record above.
