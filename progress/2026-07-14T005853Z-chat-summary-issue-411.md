---
timestamp: 2026-07-14T005853Z
title: "2026-07-13 — Chat Summary (issue #411)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-13 — Chat Summary (issue #411)

## Progress


**Implemented.** The sidebar's `RecentChatRow` now shows a one-line summary of
the model's first response under the chat title. The summary is generated once
on chat completion (`AgentLauncher.finish()`) and persisted to SQLite
(`chats.summary` + `chats.summary_at`, schema v36), so it's available
immediately when the history list loads — no recomputation on app launch.

**v0 strategy: deterministic first-sentence extract** (no LLM call). The
schema and rendering are designed so an LLM-based summarizer can be layered on
later without further migrations.

**What changed:**
- `Sources/WikiFSCore/SQLiteWikiStore.swift` — schema migration v35→v36
  (`migrateV35ToV36`), `createChatTablesV23` columns, `createFreshSchemaV20`
  version stamp, `listChats` / `listAllChatsOrderedByID` SELECT update (NULL-
  safe reads), new `updateChatSummary` mutator (routes through `mutate()`).
- `Sources/WikiFSCore/WikiStore.swift` — `updateChatSummary` on the protocol.
- `Sources/WikiFSCore/ChatModels.swift` — `summary`/`summaryAt` fields on
  `ChatSummary`, `summaryExtract(from:maxLength:)` pure function.
- `Sources/WikiFSCore/WikiStoreModel.swift` — `updateChatSummary` wrapper.
- `Sources/WikiFSEngine/AgentLauncher.swift` — `summarySink` property,
  `onSummary` parameter on `startInteractiveQuery`, `firstSummaryText(from:)`
  static function, `generateChatSummary()` method called in `finish()`.
- `Sources/WikiFSEngine/AgentOperationRunner.swift` — wired `onSummary` at both
  `startInteractiveQuery` call sites.
- `Sources/WikiFS/AgentToolsView.swift` — `RecentChatRow` shows summary caption
  when `!isLive`.
- Tests: `ChatSummaryTests.swift` (13 tests: pure extract, static event
  selection, store round-trip, NULL handling, updatedAt bump).

## Verification

Historical verification remains in the progress record above.
