---
timestamp: 2026-07-16T152023Z
title: "2026-07-16 — macOS notifications for queue operation completion"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-16 — macOS notifications for queue operation completion

## Progress


**Implemented (branch `wizardly-horse`).** When a lint, extraction, or
ingestion operation reaches a terminal state, the app now posts a macOS local
notification (`UNUserNotificationCenter`) summarizing the outcome.

- **New `OperationNotifier`** (`Sources/WikiFS/OperationNotifier.swift`) — a
  `@MainActor` class that subscribes to `QueueEngine.events` (the same
  multicast stream that `QueueActivityTracker` and `MenuBarItemController`
  consume). On `.completed` / `.failed` events it posts a
  `UNNotificationRequest` with a computed title + body. Cancelled items are
  skipped (user-initiated, not actionable).
- **Authorization.** Calls `requestAuthorization(options: [.alert, .sound])`
  at `start()`. When the app is frontmost, notifications land silently in
  Notification Center; when backgrounded they appear as banners (the useful
  case for long-running ingest/extraction).
- **Summary logic** is extracted as `nonisolated static` pure functions:
  `operationKind(for:)` classifies extraction vs. ingestion vs. lint (with
  source/page counts, including whole-wiki lint), and `summary(for:outcome:)`
  produces the title + body. Error messages are truncated to 180 chars.
  Pluralization handled ("1 file" vs. "3 files").
- **Wiring.** Created in `WikiFSApp.startStatusItem()` alongside
  `MenuBarItemController`, held strongly on `AppDelegate.operationNotifier`
  (same retention pattern as the menu-bar controller).

**Drives off the queue engine — no new event sources.** The Queue Engine
already emits `.completed(item)` and `.failed(item, error:)` for every
extraction, ingestion, and lint item. The notifier is a passive third consumer
of the existing `QueueEventBroadcaster` multicast.

**Tests** (`Tests/WikiFSTests/OperationNotifierSummaryTests.swift`, 23 tests):
operation-kind classification, completed/failed/cancelled summaries for all
three operation types, pluralization edge cases, empty-error fallback,
long-error truncation, whole-wiki vs. specific-page lint, outcome identifiers.

**Gates:** `make build` clean; 23 new tests + 2385 existing fast-tier tests all
pass (2408 total).

## Verification

Historical verification remains in the progress record above.
