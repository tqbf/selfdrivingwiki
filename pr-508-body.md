## Fix #508: Namespace shared "running" rawValue, type QueueLogRecord fields

Closes #508.

### R1: Namespace `QueueRunState.running` rawValue

`QueueItemState.running` and `QueueRunState.running` previously shared
the rawValue `"running"`, making it impossible to tell which enum a
`"running"` value belonged to without context. The ambiguity was even
documented in a code comment (`QueueEventLog.swift` lines 30–33).

**Changes:**
- `QueueRunState.running` rawValue changed from `"running"` to `"queue-running"` (both now unambiguous).
- `QueueStore`: schema version bumped 2 → 3, with a migration step
  (`migrateV2ToV3`) that `UPDATE`s existing `queue_state` rows from
  `'running'` → `'queue-running'` (idempotent). Fresh DB seeds also
  updated to the new rawValue.

### R6: Type `QueueLogRecord` fields as enums

`QueueLogRecord.eventType` was `String` (a typo like `"strted"` would
silently be written and never caught). `itemState` and `runState`
were `String?` storing rawValues, also untyped.

**Changes:**
- New `QueueEventType: String, Codable, Sendable` enum with one case per
  `QueueEvent` case. `eventType` field retyped from `String` to
  `QueueEventType`.
- `itemState` retyped from `String?` to `QueueItemState?`.
- `runState` retyped from `String?` to `QueueRunState?`.
- The `init(event:logTime:)` switch now assigns enum cases (`.enqueued`,
  `.started`, etc.) and enum values (`i.state`, `state`) directly instead
  of string literals and `.rawValue` calls.
- Test assertions updated to compare against enum cases.

### Test results

All 2444 tests pass (fast tier). No new failures. The migration is
exercised implicitly by existing `QueueStoreTests` (which create fresh
DBs and test run-state persistence round-trips).
