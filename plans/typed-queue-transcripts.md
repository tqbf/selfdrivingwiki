# Typed Queue Transcripts

## Goal

Replace the Activity window's legacy queue-agent transcript path with the typed
chat transcript vocabulary. Preserve all non-transcript queue and chat data.
Discard the approved legacy queue transcript history during the final cutover.

## Implementation Summary

The Activity window still renders queue-agent history from legacy `AgentEvent`
arrays. The chat detail view uses typed `ChatTranscriptItem` values,
`ChatDisplayProjection`, and `ChatTranscriptView`. This split makes queue
transcripts less structured and keeps two renderer contracts alive.

This change replaces queue-agent transcript storage and presentation with the
chat transcript vocabulary. It discards existing queue-agent transcript
history. It does not migrate or backfill legacy events. The change preserves
queue items, queue activity, extraction progress, usage, logs, debug folders,
and all chat data.

`AgentQueueView` already uses the typed renderer. This plan changes the selected
item transcript in `ActivityWindowView` and the durable queue transcript path.

## Decisions

1. Drop `queue_item_events` during the final typed cutover.
2. Add a queue-specific typed transcript table.
3. Keep `QueueItem.ID` and `ChatID` in separate namespaces.
4. End `AgentEvent` at the provider-to-translator boundary.
5. Carry `QueueAttemptID` in every typed queue transcript update.
6. Use one ordered typed update stream for persistence and live presentation.
7. Extract one shared translator from `LauncherChatAgentRuntime`.
8. Use `ChatTranscriptView` directly in the Activity window.
9. Keep `ChatTranscriptPaneView` specific to chat detail.
10. Keep extraction and transcription progress outside the transcript model.
11. Scope generated transcript identities to a queue item attempt.

## Non-goals

- Do not migrate legacy queue transcript history.
- Do not change chat transcript storage or chat history.
- Do not remove `AgentEvent` from provider and launcher integrations that emit it.
- Do not move queue controls, usage, or progress into transcript rows.
- Do not change extraction or transcription progress persistence.
- Do not add an Xcode-only build dependency.

## Current Architecture

The legacy durable path is:

```text
AgentEvent
  -> QueueEngine.makeEmitTranscript
  -> queue_item_events
  -> QueueEngineClient.loadTranscript
  -> XPC and daemon adapters
  -> ActivityWindowView
  -> ChatWebView(events:)
```

The typed live chat path is:

```text
ChatTranscriptItem
  -> ChatDisplayProjection
  -> ChatDisplayTranscript
  -> ChatTranscriptRenderingInput
  -> ChatTranscriptView
  -> ChatWebView(chatRows:)
```

`AgentQueueView` already uses the second path. The Activity window is the last
app presentation surface that uses `ChatWebView(events:)`.

## Target Architecture

The queue path becomes:

```text
Provider or AgentLauncher
  -> AgentEvent
  -> AgentEventTranscriptTranslator
  -> ChatTranscriptDelta
  -> ChatTranscriptReducer with accumulated state
  -> QueueTranscriptUpdate(QueueAttemptID, batchNumber, changedItems)
  -> ordered persistence in queue_item_transcript_items
  -> QueueEvent.transcript(QueueTranscriptUpdate)
  -> QueueEventEnvelope.typedTranscriptData
  -> QueueActivityTracker
  -> canonical persisted/live item selection
  -> ChatDisplayProjection
  -> ChatTranscriptView
```

`AgentEvent` does not cross the queue event or XPC boundary. Persistence and live
presentation consume the same immutable typed update after one translation and
one ordered reduction.

## Identity Model

### Queue attempt identity

Add `QueueAttemptID` as a typed `Hashable`, `Codable`, and `Sendable` value. It
contains a `QueueItem.ID` and the immutable attempt number from the claimed
`QueueItem`.

The worker captures `QueueAttemptID` when it starts. It passes the value through
the transcript callback, engine persistence seam, `QueueEvent`, and
`QueueEventEnvelope`. Do not look up the current attempt when an event arrives.
That lookup would mislabel a late callback from an old worker.

`QueueAttemptID` owns the construction of one stable `ChatTurnID`. The encoded
raw value can use this compatibility form:

```text
queue:<queue-item-id>:attempt:<attempt-number>
```

No call site interpolates this string. A retry gets a new turn identity. The
engine and tracker reject an event when its captured attempt is not current.

### Transcript item identity

Each `ChatTranscriptItem` case has a separate identity namespace:

- message: `ChatMessageID`
- tool call: `ToolCallID`
- notice: `ChatTranscriptNoticeID`
- failure: `ChatTranscriptFailureID`

The queue table stores a normalized tagged identity. The database does not scan
or decode JSON to find an item during an upsert.

## Storage Schema

Add two append-only `QueueStore` migrations. The first migration creates typed
storage. The final cutover migration drops the legacy table after all callers
use the typed APIs. GRDB runs each migration in its own transaction.

```sql
-- Additive typed-storage migration.
CREATE TABLE queue_item_transcript_items (
    item_id        TEXT NOT NULL
                   REFERENCES queue_items(id) ON DELETE CASCADE,
    attempt        INTEGER NOT NULL,
    seq            INTEGER NOT NULL,
    item_kind      TEXT NOT NULL,
    identity       TEXT NOT NULL,
    item_json      TEXT NOT NULL,
    projected_text TEXT NOT NULL DEFAULT '',
    created_at     INTEGER NOT NULL,
    updated_at     INTEGER NOT NULL,
    PRIMARY KEY (item_id, attempt, seq),
    UNIQUE (item_id, attempt, item_kind, identity)
) WITHOUT ROWID;

-- Register this migration only in the atomic cutover slice.
DROP TABLE IF EXISTS queue_item_events;
```

Do not create an index that duplicates the primary key. Add an index only when a
query needs a different key order.

The migration must not modify these tables:

- `queue_items`
- `queue_state`
- `queue_item_activity`

The main wiki database and all chat tables are outside `QueueStore`. This
migration must not open or modify them.

## Store Semantics

Add typed APIs in `Sources/WikiFSCore/Core/QueueStore.swift`.

### Upsert

Use one store transaction for current-attempt validation, sequence allocation,
and write. Prefer one `INSERT ... ON CONFLICT(item_id, attempt, item_kind,
identity) DO UPDATE` statement. Reject the batch when `QueueAttemptID.attempt`
does not equal the current `queue_items.attempt` value.

For a new identity:

1. Allocate `max(seq) + 1` for the queue item attempt.
2. Insert the item and its normalized identity.
3. Set `created_at` and `updated_at`.

For an existing identity:

1. Preserve the original `seq` and `created_at`.
2. Replace `item_json` and `projected_text`.
3. Update `updated_at`.

The store must extract an identity for all four `ChatTranscriptItem` cases. The
write must fail if the item cannot produce a normalized identity.

### Read

Load items by `item_id` and `ORDER BY seq`. Decode each row to a
`ChatTranscriptItem`. Log decode failures through `DebugLog`. Do not use a bare
`try?`.

### Clear and prune

A retry clears typed transcript rows before the new attempt emits events. Queue
history pruning uses the foreign-key cascade. It must not leave orphan rows.

## Shared Translator

Move the complete translator from
`Sources/wikid/LauncherChatAgentRuntime.swift` to
`Sources/WikiFSEngine/AgentEventTranscriptTranslator.swift`.

Move these parts together:

- translator state
- open content block state
- content block ordinals
- running tool-call state
- event-to-delta mapping
- tool-use and tool-result pairing
- active content block projection
- failure mapping
- ignored-event rules

`LauncherChatAgentRuntime` must call the extracted translator. Delete its private
copy and its private translation test hook. Move pure translator tests to a
dedicated test file. Keep a small runtime integration test.

The translator is a pure state-in and state-out value. It must not own locks,
actors, persistence, or UI state.

## Reduction Semantics

Never call `ChatTranscriptReducer.reducing(items: [], with: deltas)` for each
event. Replacement and tool upsert deltas require accumulated items.

For each queue item attempt, keep:

- `AgentEventTranscriptTranslatorState`
- accumulated `[ChatTranscriptItem]`

For one incoming event:

1. Read the attempt state.
2. Translate the event to deltas.
3. Reduce the deltas against the accumulated items.
4. Compare old and new items by normalized identity.
5. Persist only changed items.
6. Store the new translator and reducer state.

The operation that reads and updates in-memory state must be atomic. Do not hold
the state lock during SQLite writes or event broadcasts.

## Concurrency

`QueueEngine.makeEmitTranscript()` returns a synchronous `@Sendable` closure.
Use a queue transcript state store with one ordered drain per `QueueAttemptID`.

While it holds the attempt lock, the state store must:

1. Reject an attempt that is no longer current.
2. Translate and reduce one event against accumulated state.
3. Assign a monotonically increasing batch number.
4. Enqueue an immutable `QueueTranscriptUpdate` with changed typed items.
5. Elect one drainer when no drainer is active.

After it releases the attempt lock, the elected drainer must:

1. Remove batches in batch-number order.
2. Persist changed typed items in one store transaction.
3. Broadcast the same typed update only after persistence succeeds.
4. Log persistence failure and do not broadcast a state the store rejected.
5. Continue until the attempt queue is empty.
6. Mark the drainer inactive while it holds the attempt lock.

The drainer never holds the translation lock during SQLite or broadcast work.
Another callback can enqueue its batch while the drainer persists an earlier
batch. Only one drainer commits batches for an attempt. Different attempts can
drain independently.

Use the project lock abstraction when one exists for this target. Otherwise use
the same lock type and discipline as `QueueEventBroadcaster`. Do not add an
unprotected `@unchecked Sendable` dictionary.

Clear attempt state only after terminal processing has drained all accepted
batches. Reject late callbacks from old attempts before translation, persistence,
and broadcast.

## Canonical App Transcript State

`QueueActivityTracker` applies ordered `QueueTranscriptUpdate` values on the main
actor. It does not import `AgentEvent` or own translator state. It rejects stale
attempts and duplicate or out-of-order batch numbers.

The Activity window can also load durable typed items after selection. Add one
pure helper that computes the canonical item list from:

- persisted typed items
- live typed items

Use the helper for rendering and copy.

The merge rules are:

1. Preserve persisted sequence order.
2. Replace a persisted item when a live item has the same tagged identity.
3. Append new live identities in live order.
4. Use live content for conflicts.
5. Never compare raw IDs from different item kinds.

A completed in-memory transcript can be complete from run start, but the view
must not depend on that unstated invariant. The canonical helper makes restored
and partially live transcripts work the same way.

## App Presentation

Change `Sources/WikiFS/Queue/ActivityWindowView.swift`.

- Replace `loadedEvents` with typed loaded items.
- Load typed items through the queue client.
- Merge persisted and live items with the canonical helper.
- Project the merged items through `ChatDisplayProjection`.
- Pass the result to `ChatTranscriptView`.
- Keep `TranscriptID.queueItem(item.id)`.
- Keep the existing wiki-link handler.
- Keep the render-context provider and blob store.
- Keep the extraction progress fallback.
- Use the same canonical items for copy.

Use `ChatTranscriptView`, not `ChatTranscriptPaneView`. The pane contains
chat-only composition such as the chat preflight banner, thinking indicator,
permission approval, outline scrolling, and chat zoom. The Activity window keeps
its existing queue header and permission status.

## Protocol and XPC Cutover

Change persisted transcript loading from `[AgentEvent]` to
`[ChatTranscriptItem]`. Update all implementations in one buildable cutover.

The cutover includes:

- `QueueEngineClient`
- `QueueEngine`
- `QueueEngineHotSwap`
- `XPCQueueEngineProxy`
- `UnavailableQueueEngine`
- `DaemonWorkloadClient`
- `WikiDaemonProtocol`
- the real daemon implementation in `Sources/wikid/main.swift`
- the unavailable daemon implementation
- all fakes and protocol conformance tests

Add `QueueTranscriptUpdate` as a `Codable` and `Sendable` queue-engine value. It
contains `QueueAttemptID`, a monotonic batch number, and the changed typed items.
Change the queue transcript event and envelope to carry this value. Update all
event producers, codecs, sinks, trackers, and tests in the atomic cutover.
`AgentEvent` remains only before translation in provider and launcher code.

## Implementation Plan

### Phase 1: Extract the translator

Make a pure move from `LauncherChatAgentRuntime` to `WikiFSEngine`. Delete the
old implementation after all launcher tests pass.

**Gate:** The existing translation behavior and identities do not change.

### Phase 2: Add typed storage APIs

Add the typed table and store APIs in code. Do not register the migration that
drops the old table yet. Test the table through a test-only schema setup or a
migration that only creates the new table.

This phase can merge independently because old callers still use the old table.

**Gate:** Typed identity upserts preserve sequence and survive database reopen.

### Phase 3: Atomic typed cutover

In one integration slice:

1. Change engine persistence to typed items.
2. Change retry clearing to typed rows.
3. Capture `QueueAttemptID` at worker creation.
4. Add the attempt token to the callback, event case, and envelope.
5. Change the load protocol to typed items.
6. Update all daemon, XPC, client, wrapper, and fake implementations.
7. Change `QueueActivityTracker` to typed accumulated state.
8. Change `ActivityWindowView` to the canonical typed projection.
9. Register the final migration that drops `queue_item_events`.
10. Remove all runtime calls to legacy event-store APIs.

Do not ship or merge a state where the table is absent and old callers remain.

**Gate:** A v4 queue database opens, discards only legacy transcript rows, and
then stores and loads a new typed transcript through the daemon client.

**Implementation record (2026-08-01):** The cutover uses an immutable
`QueueAttemptID` captured by `QueueIngestionWorker`, a lock-backed per-attempt
translator/reducer/drainer, and `QueueTranscriptUpdate` batches across the
engine event and XPC boundary. v6 drops only `queue_item_events`; typed retry
clearing preserves queue metadata and activity rows. The Activity window merges
durable and live typed rows through one value-only presentation seam.

### Phase 4: Remove the legacy renderer

After the typed Activity view passes live verification, remove:

- `ChatWebView.init(events:)`
- event-based coordinator reload and apply methods
- event-based pending and rendered state
- legacy visibility helpers that have no remaining callers
- stale comments about the Activity event adapter

Keep the old migration registrations. Do not edit past migration bodies.

**Gate:** No app presentation file constructs `ChatWebView` from `AgentEvent`.

### Phase 5: Full verification and documentation

Run focused tests after each phase. Run the full suite before the PR. Verify one
live agent run and one restored transcript in the signed or development app.

Update this plan with implementation evidence. Add a progress entry after the
feature passes all gates.

## Acceptance Criteria

### TQT.AC1: Data reset safety

- The migration drops `queue_item_events`.
- Existing legacy transcript history disappears.
- `queue_items`, `queue_state`, and `queue_item_activity` remain unchanged.
- Chat databases and chat tables remain unchanged.

### TQT.AC2: Typed persistence

- Future queue-agent transcripts persist as `ChatTranscriptItem` values.
- Every item stores a tagged normalized identity.
- Replacements keep their original sequence.
- Reads preserve transcript order after database reopen.
- Queue pruning cascades to typed transcript rows.

### TQT.AC3: Translation correctness

- Queue and chat runtime paths use one translator implementation.
- Streamed assistant and reasoning text updates one stable row.
- Tool results update the matching tool-call row.
- Failures map to typed failure rows.
- Ignored events stay absent.
- Retries use a new attempt-scoped identity.

### TQT.AC4: Concurrency correctness

- Translation for one queue attempt is atomic and ordered.
- Different queue attempts cannot share translator state.
- SQLite work occurs after the state lock releases.
- Numbered batches persist and broadcast in accepted event order.
- A late event from an old attempt is not persisted or rendered.

### TQT.AC5: Typed client contract

- Persisted transcript load APIs return typed items end to end.
- The daemon and XPC client round-trip typed items.
- The queue event and envelope carry `QueueTranscriptUpdate` end to end.
- Each update carries immutable `QueueAttemptID` and batch number.
- `AgentEvent` does not cross the queue event or XPC boundary.

### TQT.AC6: Shared presentation

- `ActivityWindowView` renders through `ChatDisplayProjection` and
  `ChatTranscriptView`.
- Restored transcripts appear when no live tracker state exists.
- Partial live state merges with restored state by tagged identity.
- Copy uses the same canonical transcript as display.
- Wiki links, blob rendering, and queue-item transcript identity still work.
- Extraction progress still appears when no typed transcript exists.

### TQT.AC7: Legacy removal

- No Activity presentation path calls `ChatWebView(events:)`.
- The event-based `ChatWebView` initializer and coordinator path are deleted.
- Legacy queue event store methods have no callers and are deleted.

## Test Strategy

### TQT.AC1: Data preservation

Add these migration tests:

- `migrationDropsOnlyLegacyTranscriptTable`
- `migrationPreservesEveryQueueItemColumn`
- `migrationPreservesRunningAndPausedQueueStateRows`
- `migrationPreservesUsageLogDebugAndProgressActivityFields`
- `queueInitializationAndTypedLoadDoNotChangeChatRows`

The v4 fixture must use distinct, non-default values and nullable variants. Take
raw SQL row snapshots before and after migration. Do not rely only on public value
types, because they do not expose every persisted column.

Compare every `queue_items` column:

- `id`
- `queue`
- `wiki_id`
- `payload`
- `state`
- `ordering_key`
- `provider_id`
- `attempt`
- `error`
- `created_at`
- `started_at`
- `finished_at`

Compare both `queue_state` columns, `queue` and `state`. Seed extraction and
ingestion rows with different state values.

Compare every `queue_item_activity` column:

- `item_id`
- `usage_json`
- `log_url`
- `debug_url`
- `progress_log`
- `updated_at`

Use non-empty usage JSON, log URL, debug URL, multiline progress text, and a fixed
non-default timestamp. The chat test must seed representative chat and message
rows, run queue initialization and a typed daemon load, then compare chat counts
and encoded content.

### TQT.AC2: Typed persistence

Add `QueueStoreTypedTranscriptTests` with these tests:

- `upsertPreservesSequenceForEachTaggedIdentityKind`
- `identicalRawIDsInDifferentKindsDoNotCollide`
- `typedTranscriptOrderSurvivesDatabaseReopen`
- `retryClearRemovesOnlyTheSelectedItemTranscript`
- `historyPruneCascadesTypedTranscriptRows`
- `staleAttemptBatchIsRejectedAtomically`

### TQT.AC3: Shared translation

Add `AgentEventTranscriptTranslatorTests` with these tests:

- `assistantStreamUpdatesOneStableMessage`
- `reasoningStreamUpdatesOneStableMessage`
- `fullReplacementPreservesMessageIdentity`
- `toolResultUpdatesTheMatchingFIFOCall`
- `turnFailureProducesTypedFailure`
- `ignoredEventsProduceNoDelta`
- `queueAttemptCreatesDeterministicDistinctIdentities`
- `launcherRuntimeUsesSharedTranslator`

### TQT.AC4: Ordering and stale callbacks

Add `QueueTranscriptConcurrencyTests` with these tests:

- `sameAttemptCallbacksCommitInAcceptedOrder`
- `differentAttemptsDoNotShareTranslatorState`
- `delayedFirstBatchCannotBeOvertakenBySecondBatch`
- `sqliteRunsAfterTranslationLockIsReleased`
- `oldWorkerCallbackAfterRetryIsRejected`
- `oldWorkerCallbackAfterNewOutputIsRejected`
- `oldWorkerCallbackAfterStateCleanupIsRejected`
- `reopenedTranscriptPreservesAcceptedEventOrder`

Use barriers to delay batch A after translation while batch B reaches the drain.
Assert durable sequence, live delivery, and reopened order remain A then B.

### TQT.AC5: Protocol and wire

Update or add these tests:

- `QueueEngineClientConformanceTests.loadTypedTranscriptIsCallable`
- `WikiDaemonWorkloadHostTests.typedQueueTranscriptRoundTripsThroughXPC`
- `QueueEventEnvelopeTests.typedTranscriptUpdateRoundTripsWithAttemptAndBatch`
- `QueueEventEnvelopeTests.transcriptRejectsMissingAttemptIdentity`
- `QueueEventEnvelopeTests.transcriptRejectsMissingBatchNumber`
- `QueueEventEnvelopeTests.transcriptEnvelopeContainsNoAgentEventPayload`

Update all fake clients in the same cutover.

### TQT.AC6: Presentation

Add `QueueTranscriptCanonicalMergeTests` with these tests:

- `persistedOrderIsStable`
- `liveItemReplacesMatchingTaggedIdentity`
- `sameRawIDInDifferentKindsDoesNotCollide`
- `newLiveIdentityAppendsInLiveOrder`

Add `QueueActivityTrackerTypedTranscriptTests` with these tests:

- `liveEventsReduceAgainstAccumulatedItems`
- `retryChangesAttemptAndClearsLiveState`
- `staleAttemptEventIsNotRendered`

Add hosted `ActivityWindowTypedTranscriptTests` with these tests:

- `persistedOnlyTranscriptProducesVisibleTypedRows`
- `partialLiveTranscriptReplacesPersistedRow`
- `copyTextEqualsCanonicalVisibleTranscript`
- `wikiLinkIntentUsesSelectedItemsWikiHandler`
- `rendererReceivesBlobStoreAndRenderContext`
- `rendererUsesQueueItemTranscriptIdentity`
- `progressOnlyItemUsesProgressFallback`

Extract a value-only presentation input or injectable transcript-render seam when
the hosted test cannot inspect the WebKit rows directly. Host the real Activity
view in an `NSWindow`, wait for its async load, and inspect that seam. Manual
verification does not replace these tests.

### TQT.AC7: Legacy removal

Update `ChatPresentationAPIManifestTests` with these tests:

- `activityPresentationDoesNotImportAgentEvent`
- `activityPresentationUsesTypedTranscriptView`
- `chatWebViewHasNoLegacyEventInitializer`
- `legacyQueueEventStoreMethodsAreAbsent`

## Verification Commands

Run these commands from the repository root:

```bash
make build
swift test --filter AgentEventTranscriptTranslatorTests
swift test --filter QueueStoreTypedTranscriptTests
swift test --filter QueueStoreTypedTranscriptMigrationTests
swift test --filter QueueTranscriptConcurrencyTests
swift test --filter QueueEngineClientConformanceTests
swift test --filter QueueEventEnvelopeTests
WIKIFS_APP_TESTS=1 swift test --filter WikiDaemonWorkloadHostTests
WIKIFS_APP_TESTS=1 swift test --filter ChatPresentationAPIManifestTests
make test
```

Run the project prompt synchronization prerequisites before a bare Swift build if
a prompt file changes. This feature does not plan prompt changes.

For live verification:

1. Start an ingestion or lint queue item.
2. Confirm streaming text updates one row.
3. Confirm tool use and result share one row.
4. Close and reopen the Activity window.
5. Restart the app and daemon.
6. Confirm the completed transcript loads from typed storage.
7. Confirm copy matches the visible transcript.
8. Confirm extraction progress still appears for a progress-only item.
9. Confirm existing chat history remains available.

## Review Strategy

Before implementation, the implementer must read these project skills:

- `swift-concurrency-pro` for the `Sendable` callback, ordered drain, locks, and
  main-actor tracker boundary
- `swiftui-pro` for `ActivityWindowView` data flow and hosted presentation seam
- `macos-design` for Activity window hierarchy and native queue behavior
- `swift-testing-pro` for all new Swift Testing suites

After implementation and automated tests, run the same Swift concurrency and
SwiftUI reviews against the changed code. Fix or explicitly rebut every finding.
Run a new review after any critical or high correction.

When the PR head is available, run a checked-out exact-head Paseo audit while CI
runs. Require green repository checks and no unresolved critical, high, medium,
or low audit findings at the same head SHA. A changed head invalidates the prior
audit and requires a new audit.

The implementation worker must not merge the PR. The operator merges after the
CI and audit gates pass.

## Documentation Strategy

- Keep this plan current when implementation changes a contract.
- Update the `QueueStore` migration history comment.
- Replace the legacy transcript section in `plans/queue-engine.md`.
- Add a `progress/` entry only after implementation and verification complete.
- Record exact build, test, live verification, CI, and audit evidence.

## Risks, Blockers, and Required Decisions

### Legacy data loss

The migration permanently removes old queue-agent transcript history. The user
approved this loss. The migration test must prove that unrelated queue data
survives.

### Mixed-version app and daemon

The typed load protocol is not compatible with an old daemon. Ship the app,
daemon, XPC contract, and proxy changes together. Do not support mixed versions
for this pre-production cutover.

### Streaming identity drift

A copied translator can drift from chat behavior. Move the complete translator
and delete the old implementation.

### Duplicate transcript rows

JSON scans and non-atomic cursor allocation can create duplicates. Store a
normalized tagged identity and use a database uniqueness constraint.

### Retry contamination

A queue item ID alone cannot distinguish retries. Include `attempt` in the turn
and derived transcript identities. Clear the old typed rows before the new
attempt starts.

### UI history gaps

A live-only projection hides restored history. Use one canonical persisted/live
merge for display and copy.

### Required decisions

No product decisions remain. The operator approved permanent deletion of legacy
queue-agent transcript history. Implementation must stop and ask only when a
required correction changes product scope or this resolved data-loss decision.

## Definition of Done

The feature is complete when the Activity window uses the typed chat transcript
vocabulary for live and restored queue-agent runs. The legacy table and renderer
path no longer exist. Queue metadata, progress, usage, logs, and chat history
remain intact. All focused tests, app tests, the full SwiftPM suite, and the live
verification steps pass.
