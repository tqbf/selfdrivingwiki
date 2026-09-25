# Queue Engine Hardening — Tier 0 Correctness + Tier 1 Durable Truth

Status: implemented. Six phases, one branch + PR each, merged in order.
Committee consensus (Codex gpt-6-astra + Gemini 3.1 Pro, 2026-09-24) is the
basis; this note records what changed, the claims the committee corrected,
and the decisions that are deliberately deferred.

## The problem

The durable queue engine could strand work invisibly:

- A lane `pause()` landing during provider resolution could be raced by a
  claim (`dispatchScan` re-checked only the engine lifecycle after its one
  `await`).
- Two post-claim read-back failures (`getItem` throwing, or the row
  vanishing) left an item `.running` with no worker until restart.
- Store transitions were read-validate-then-unconditional-UPDATE. Two
  connections (or a reentrant scan) could double-claim a row.
- `cancelItem` and `halt` removed the `runningTasks` entry before the worker
  settled. `handleWorkerFinished`'s lease guard then early-returned, so
  `waitForCompletion` waiters on cancelled items were NEVER resumed.
- `waitForCompletion` parked on a bare checked continuation; the daemon's
  admission drain parked on a bare `for await`. A never-settling worker or a
  hung RPC pinned them forever.
- The daemon constructed the engine with default `QueueEngineConfig()` —
  configured `AgentProvidersConfig.maxConcurrent` never reached it.
- Follow-on format routes were enqueued with a bare `queueStore.enqueue` —
  no engine event, so the job waited for an unrelated trigger.
- A `providerID(for:)` returning `nil` left an item queued forever with no
  durable record and no surface — the original Zotero symptom.

## Committee claim corrections (verified; do not "fix" these again)

- XPC RPCs are NOT unbounded. `DaemonWorkloadClient.withTimeout` bounds every
  RPC at 30 s. The unbounded waits were engine `waitForCompletion` and the
  daemon-side admission drain (both now bounded — Phase 3).
- Engine shutdown settlement IS deadline-bounded (10 s → `.shutdownBlocked`).
  Do not rework it.
- `decrementProviderCount` clamps at 0, so double-decrement corrupts nothing
  numerically. The real defect was bookkeeping managed on the cancel path
  instead of at settlement.

## What changed

Tier 0 (correctness):

1. **Claim discipline** — `dispatchScan` re-checks the lane run state after
   the provider await; a lifecycle stop aborts the whole scan, a lane pause
   stops only that lane. Post-claim read-back failures requeue the item
   (`repairStrandedClaim`).
2. **CAS store transitions** — `markRunning`, `markCompleted`, `markFailed`,
   `markCancelled`, `requeue`, `retryItem`, and `recordAdmissionWait` are
   single-statement compare-and-sets (`WHERE ... AND state = ...`,
   `changesCount == 1`), throwing the same typed errors (`.notFound`,
   `.invalidStateTransition`) the read-validate path used to give.
3. **Settlement-owned bookkeeping** — `cancelItem`/`halt` keep the
   `runningTasks` entry; the lease is the settle-once key.
   `handleWorkerFinished` is the single settlement point: entry removal,
   slot release (`releaseDispatchSlots`), and waiter resume happen exactly
   once on every path. A halt's `rebuildInMemoryState` records rebuilt-away
   leases in `releaseDeferredByRebuild` so a late stale settlement skips the
   release instead of releasing a sibling dispatch's capacity.
4. **Bounded waits** — `waitForCompletion` races its waiter against
   `QueueEngineWaitPolicy.completionWaitDeadline` (35 min — strictly above
   the 30-minute `ExtractorHostLimits.maximumDurationMilliseconds` ceiling
   that Pdf2md/DoclingServe legitimately declare; a test pins the ordering).
   Timeout resumes `.failure(QueueEngineCompletionWaitError.timeout(itemID:))`
   with remove-then-resume exactly-once semantics. The item is untouched —
   the WAIT is bounded, not the work. The daemon admission drain races an
   injected 60 s deadline; expiry force-finishes with deficit accounting so
   the stuck RPC's late `finishAdmission` cannot trip the admissions-pair
   invariant.

Tier 1 (durable truth):

5. **Daemon config** — `QueueEngineConfig.daemonConfig(agents:)` maps
   `maxConcurrent` into ingestion limits (same provider-id key space) with
   extraction at the named defaults. The mapping is the unit-tested seam;
   the daemon now actually enforces configured limits.
6. **Wakeup** — `DaemonQueueExtractionProvider.engineEnqueue` routes
   follow-on items through the engine, so the dispatch scan runs
   immediately. The store-only fallback remains for engine-less sites.
7. **Admission status** — migration v10 adds nullable `admission_reason` +
   `admission_checked_at`. Nil-route scans record
   `QueueAdmissionReason.noExtractorRoute` (deduplicated per scan) and emit
   a progress line. Lane resume clears then re-records; retry clears.
   Surfaces: the Activity "Waiting for route — …" warning chip, a
   `wikictl job` admission column, and `wikictl queue status`
   waiting_for_route counts.
8. **`wikictl queue`** — `status [--json]`, `pause|resume|halt --lane
   extraction|ingestion` against the live daemon workload XPC surface.
9. **Per-lane menu-bar truth** — membership is per-lane (`QueueKind`-keyed);
   the tooltip renders per-lane lines ("Extraction: paused (2 waiting) ·
   Ingestion: running (1 active)"). Icon precedence is unchanged
   (daemon-down > attention > paused > working > idle); a lane resume
   re-derives the icon synchronously.

## Decisions made during implementation

- **Cancellation contract (Phase 2 item 4).** `Task.cancel` is cooperative;
  settlement-owned bookkeeping means a worker that ignored cancellation
  would hold its slot until shutdown. Accepted and documented rather than
  deadline-raced: extraction workers are manifest-deadline-bounded and
  handle cancellation explicitly; ingestion settles through the ACP
  launcher's cancellation handling — the same contract the shutdown
  settlement already relies on.
- **Admission status is a field, not a new item state.** The committee
  rejected a `.blocked` item state: blocked is queued-plus-reason, the
  transition graph already covers it, and a new state would touch every
  CAS transition and every consumer. Two nullable columns keep the state
  machine untouched.
- **Waiter truth on lost store races.** When a worker's terminal transition
  loses a CAS race to a cancel/requeue, waiters receive
  `.failure(CancellationError())` — the item's terminal state wins over the
  worker's raw outcome. For a requeued item this reads as "this wait is
  over", not "the work failed"; it may succeed on re-dispatch.
- **Queued-item cancels resume waiters directly.** A queued item has no
  dispatch, so no settlement will ever run for it; `cancelItem` resumes its
  waiters itself, guarded on `dispatch == nil`.
- **Test seams.** `QueueStore` is a `final class`; the read-back failure
  seam is a one-shot internal `injectGetItemOutcome` (never public). Engine
  test suites share `FakeWorkerFactory`/`FakeWorkerRecorder` (internal in
  `QueueEngineTests.swift`) — never duplicate them.

## Known follow-ups (deferred on purpose)

- Catalog/credential changes do not yet re-trigger admission re-checks
  (resume and retry do). Documented as follow-up.
- A `markCompleted`/`markFailed` store I/O failure (non-race) leaves the
  item `.running` with no dispatch until restart/halt; waiters get a
  cancellation result. The old shape had the same orphan; settlement-owned
  bookkeeping makes it worth its own fix later.
- Replay log / revision-stamped snapshot synchronization, cross-wiki
  fairness + per-wiki history pruning quotas, and automatic
  retry/backoff/dead-letter (blocked on an idempotent-effect design) remain
  deferred tiers. Momentary halt was rejected: halt stays a durable pause.

## Evidence

- Gates per phase: `make build`, `make test`, `swiftlint lint --strict`,
  and the app-graph suites (`WIKIFS_APP_TESTS=1`) for touched suites.
- Reviews: read-only review subagents per phase (Phase 1: 1 MEDIUM fixed
  with the phase; Phase 2: 2 HIGH + 1 MEDIUM fixed in the follow-up
  commit).
- Engine suites: `QueueEngineTests`, `QueueEngineClaimTests`,
  `QueueEngineSettlementTests`, `QueueEngineBoundedWaitTests`,
  `QueueEngineDaemonConfigTests`, `QueueStoreTests`, `JobCommandTests`,
  `WikiCtlCommandTests`, `MenuBarItemLintBlinkerTests`,
  `QueueWorkspacePresentationTests`, `WikiDaemonWorkloadHostTests`.
