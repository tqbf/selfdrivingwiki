import Foundation
import Synchronization
import Testing
import WikiFSMarkdown
@testable import WikiFSCore
@testable import WikiFSEngine

/// Engine-level report behavior (plan §2/§3): commit-before-publish ordering,
/// reporting-unavailable on persistence failure (job outcome untouched),
/// lease-activation resets, engine load APIs, transport envelope round trip,
/// ingestion reporting facts, and extraction worker outcomes.
@Suite("QueueReportEngine")
struct QueueReportEngineTests {

    // MARK: - Helpers

    private func makeStore() throws -> QueueStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-report-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try QueueStore(databaseURL: dir.appendingPathComponent("queue.sqlite"))
    }

    private func makeItem(_ store: QueueStore) throws -> QueueItem {
        try store.enqueue(QueueItemRequest(
            queue: .ingestion,
            wikiID: WikiID(rawValue: "wiki-e"),
            payload: QueueItemPayload(sourceIDs: [SourceID(rawValue: "s1")])))
    }

    private func scope(_ item: QueueItem) -> QueueReportScope {
        .targets(item.payload.sourceIDs.map { QueueReportTargetRecord(target: .source($0), state: .planned) })
    }

    /// Drain an invalidation stream immediately (no in-flight admissions in
    /// these tests, so the stream finishes without waiting).
    private func drain(_ stream: AsyncStream<Void>) async {
        for await _ in stream {}
    }

    // MARK: Commit-before-publish ordering

    @Test("Report update is persisted before it is published")
    func commitBeforePublish() async throws {
        let order = Mutex<[String]>([])
        let committed = QueueAttemptReport(
            attemptID: QueueAttemptID(itemID: QueueItemID(rawValue: "i"), attempt: 0),
            executionID: QueueExecutionID(rawValue: UUID()),
            revision: QueueReportRevision(rawValue: 7),
            operation: .ingest,
            scope: .wholeWiki,
            phase: .staging,
            provider: nil,
            model: nil,
            availability: .available,
            resultSummary: nil,
            targets: [])

        let channel = QueueWorkerOutputChannel(
            appendProgress: { _, _ in },
            persistTranscript: { _ in },
            persistUsage: { _, _ in },
            persistRunPaths: { _, _, _ in },
            observePublication: { _ in
                order.withLock { $0.append("publish") }
            },
            activateReportExecution: { _, _ in },
            beginReport: { _, _, _, _ in
                order.withLock { $0.append("persist") }
                return committed
            },
            commitReport: { _, _, _ in
                order.withLock { $0.append("persist") }
                return committed
            })

        let stream = channel.events(onSubscribed: {})
        let attemptID = QueueAttemptID(itemID: QueueItemID(rawValue: "i"), attempt: 0)
        // makeScope activates the lease so emissions are admitted.
        let scope = channel.makeScope(attemptID: attemptID)
        scope.emitReportBegin(operation: .ingest, scope: .wholeWiki)
        scope.emitReport(QueueReportMutation(phase: .finished))

        var iterator = stream.makeAsyncIterator()
        var events: [QueueEvent] = []
        for _ in 0..<2 {
            if let event = await iterator.next() { events.append(event) }
        }
        #expect(events.count == 2)
        // Both emissions persisted exactly once BEFORE their publication.
        #expect(order.withLock { $0 } == ["persist", "publish", "persist", "publish"])
        guard case .reportUpdated(_, let published) = events.first else {
            Issue.record("Expected reportUpdated as first event")
            return
        }
        #expect(published == committed)
    }

    @Test("Persistence failure publishes reportUnavailable and never a false durable success")
    func persistenceFailurePublishesUnavailable() async throws {
        struct InjectedFailure: Error {}
        let channel = QueueWorkerOutputChannel(
            appendProgress: { _, _ in },
            persistTranscript: { _ in },
            persistUsage: { _, _ in },
            persistRunPaths: { _, _, _ in },
            beginReport: { _, _, _, _ in throw InjectedFailure() },
            commitReport: { _, _, _ in throw InjectedFailure() })

        let stream = channel.events(onSubscribed: {})
        let attemptID = QueueAttemptID(itemID: QueueItemID(rawValue: "j"), attempt: 0)
        let scope = channel.makeScope(attemptID: attemptID)
        scope.emitReport(QueueReportMutation(phase: .finished))

        var iterator = stream.makeAsyncIterator()
        let event = await iterator.next()
        guard case .reportUnavailable(let id, _) = event else {
            Issue.record("Expected reportUnavailable, got \(String(describing: event))")
            return
        }
        #expect(id == attemptID.itemID)
    }

    @Test("A new lease on the same attempt resets stored progress")
    func newLeaseResetsSameAttemptProgress() async throws {
        let store = try makeStore()
        let channel = QueueWorkerOutputChannel(store: store)
        let item = try makeItem(store)
        let attemptID = QueueAttemptID(itemID: item.id, attempt: 0)

        let firstScope = channel.makeScope(attemptID: attemptID)
        firstScope.emitReportBegin(operation: .ingest, scope: scope(item))
        firstScope.emitReport(QueueReportMutation(
            targetUpserts: [QueueReportTargetRecord(
                target: .source(item.payload.sourceIDs[0]),
                state: .submitted)]))
        await drain(channel.invalidate(firstScope))

        guard let before = try store.loadReport(itemID: item.id) else {
            Issue.record("Report missing after first dispatch")
            return
        }
        #expect(before.targets.first?.state == .submitted)

        // Halt-resume style: a NEW lease for the SAME attempt activates,
        // which resets progress; the new dispatch then re-begins the report,
        // recreating the planned inventory.
        let secondScope = channel.makeScope(attemptID: attemptID)
        secondScope.emitReportBegin(operation: .ingest, scope: scope(item))
        guard let after = try store.loadReport(itemID: item.id) else {
            Issue.record("Report missing after new lease")
            return
        }
        #expect(after.revision.rawValue > before.revision.rawValue)
        #expect(after.targets.first?.state == .planned)
        #expect(after.executionID.rawValue != before.executionID.rawValue)

        // The new lease may write; the old one may not.
        secondScope.emitReport(QueueReportMutation(
            targetUpserts: [QueueReportTargetRecord(
                target: .source(item.payload.sourceIDs[0]),
                state: .processing)]))
        firstScope.emitReport(QueueReportMutation(resultSummary: "stale lease write"))
        guard let final = try store.loadReport(itemID: item.id) else {
            Issue.record("Report missing after emissions")
            return
        }
        #expect(final.resultSummary == nil)
        #expect(final.targets.first?.state == .processing)
        await drain(channel.invalidate(secondScope))
    }

    // MARK: Engine load APIs

    @Test("Engine loadQueueReport returns notReported, loaded, then unavailable")
    func engineLoadQueueReportTransitions() async throws {
        let store = try makeStore()
        let engine = QueueEngine(store: store, workerFactory: NoopFactory())
        let item = try makeItem(store)

        // No report yet → notReported (never an error, never zeros).
        guard case .notReported = await engine.loadQueueReport(for: item.id) else {
            Issue.record("Expected .notReported for unreported item")
            return
        }

        _ = try store.beginReport(
            attemptID: QueueAttemptID(itemID: item.id, attempt: 0),
            executionID: QueueExecutionID(rawValue: UUID()),
            operation: .ingest,
            scope: .targets([QueueReportTargetRecord(
                target: .source(item.payload.sourceIDs[0]),
                state: .planned)]))
        guard case .loaded(let report) = await engine.loadQueueReport(for: item.id) else {
            Issue.record("Expected .loaded after beginReport")
            return
        }
        #expect(report.attemptID == QueueAttemptID(itemID: item.id, attempt: 0))

        // Closed store → explicit unavailable result (not a thrown error).
        store.close()
        guard case .unavailable = await engine.loadQueueReport(for: item.id) else {
            Issue.record("Expected .unavailable after store close")
            return
        }
        guard case .unavailable = await engine.loadQueueReportSummaries(for: [item.id]) else {
            Issue.record("Expected .unavailable summaries after store close")
            return
        }
    }

    @Test("Engine summaries load through the batched API")
    func engineSummariesLoad() async throws {
        let store = try makeStore()
        let engine = QueueEngine(store: store, workerFactory: NoopFactory())
        let item = try makeItem(store)
        let execution = QueueExecutionID(rawValue: UUID())
        _ = try store.beginReport(
            attemptID: QueueAttemptID(itemID: item.id, attempt: 0),
            executionID: execution,
            operation: .ingest,
            scope: .targets([QueueReportTargetRecord(
                target: .source(item.payload.sourceIDs[0]),
                displayName: "Reported Source",
                state: .submitted)]))

        guard case .loaded(let summaries) = await engine.loadQueueReportSummaries(for: [item.id]) else {
            Issue.record("Expected loaded summaries")
            return
        }
        #expect(summaries[item.id]?.searchText.contains("Reported Source") == true)
    }

    // MARK: Transport round trip (real envelope serialization)

    @Test("Report events survive QueueEventEnvelope round trip")
    func envelopeReportRoundTrip() throws {
        let itemID = QueueItemID(rawValue: "wire-item")
        let report = QueueAttemptReport(
            attemptID: QueueAttemptID(itemID: itemID, attempt: 2),
            executionID: QueueExecutionID(rawValue: UUID()),
            revision: QueueReportRevision(rawValue: 9),
            operation: .extract,
            scope: .targets([QueueReportTargetRecord(
                target: .source(SourceID(rawValue: "s9")),
                displayName: "Paper",
                state: .succeeded,
                result: .outputReference(QueueExtractionOutputReference(versionID: "v1")))]),
            phase: .finished,
            provider: ProviderID(rawValue: "local-pdf2md"),
            model: QueueReportModelName(rawValue: "pdf2md-1"),
            availability: .available,
            resultSummary: "Extraction persisted",
            targets: [QueueReportTargetRecord(
                target: .source(SourceID(rawValue: "s9")),
                displayName: "Paper",
                state: .succeeded,
                result: .outputReference(QueueExtractionOutputReference(versionID: "v1")))])

        let event = QueueEvent.reportUpdated(itemID, report)
        guard let envelope = QueueEventEnvelope(from: event) else {
            Issue.record("Envelope init failed for reportUpdated")
            return
        }
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(QueueEventEnvelope.self, from: data)
        guard case .reportUpdated(let roundTrippedID, let roundTrippedReport)? = decoded.toQueueEvent() else {
            Issue.record("toQueueEvent failed for reportUpdated envelope")
            return
        }
        #expect(roundTrippedID == itemID)
        #expect(roundTrippedReport == report)

        // Unavailable events carry the reason through unchanged.
        let unavailable = QueueEvent.reportUnavailable(itemID, reason: "store closed")
        guard let unavailableEnvelope = QueueEventEnvelope(from: unavailable),
              let unavailableData = try? JSONEncoder().encode(unavailableEnvelope),
              let unavailableDecoded = try? JSONDecoder().decode(QueueEventEnvelope.self, from: unavailableData),
              case .reportUnavailable(let unavailableID, let reason)? = unavailableDecoded.toQueueEvent()
        else {
            Issue.record("reportUnavailable round trip failed")
            return
        }
        #expect(unavailableID == itemID)
        #expect(reason == "store closed")
    }

    @Test("Report load results survive the JSON wire payload codec")
    func wirePayloadRoundTrip() throws {
        let itemID = QueueItemID(rawValue: "wire-2")
        let report = QueueAttemptReport(
            attemptID: QueueAttemptID(itemID: itemID, attempt: 0),
            executionID: QueueExecutionID(rawValue: UUID()),
            revision: QueueReportRevision(rawValue: 1),
            operation: .lint,
            scope: .wholeWiki,
            phase: .finished,
            provider: nil,
            model: nil,
            availability: .notReported,
            resultSummary: "Agent run completed; page-level results not reported",
            targets: [])

        // Loaded branch.
        let loaded = QueueReportLoadResult.loaded(report)
        let loadedData = try JSONEncoder().encode(loaded)
        let decodedLoaded = try JSONDecoder().decode(QueueReportLoadResult.self, from: loadedData)
        #expect(decodedLoaded == loaded)

        // notReported + unavailable branches (the older-daemon / soft-failure
        // surfaces both client and daemon produce).
        let notReportedData = try JSONEncoder().encode(QueueReportLoadResult.notReported)
        #expect(try JSONDecoder().decode(QueueReportLoadResult.self, from: notReportedData) == .notReported)
        let unavailableData = try JSONEncoder().encode(QueueReportLoadResult.unavailable(reason: "unsupported"))
        guard case .unavailable(let reason) = try JSONDecoder().decode(QueueReportLoadResult.self, from: unavailableData) else {
            Issue.record("unavailable branch failed to decode")
            return
        }
        #expect(reason == "unsupported")

        // Summaries result.
        let summaries = QueueReportSummariesResult.loaded([
            itemID: QueueReportSummary(
                itemID: itemID,
                attempt: 0,
                revision: QueueReportRevision(rawValue: 3),
                phase: .staging,
                availability: .available,
                phaseCounts: [.submitted: 2, .skipped: 1],
                resultSummary: "8 of 12 submitted",
                searchText: "Alpha Source bytes unavailable"),
        ])
        let summariesData = try JSONEncoder().encode(summaries)
        #expect(try JSONDecoder().decode(QueueReportSummariesResult.self, from: summariesData) == summaries)
    }

    // MARK: Ingestion reporting facts

    @Test("Staging mutation reports exact submitted/skipped facts, never invented completion")
    func stagingMutationFacts() {
        let mutation = QueueIngestionReporting.stagingMutation(requested: [
            (id: SourceID(rawValue: "a"), outcome: .staged(name: "Alpha")),
            (id: SourceID(rawValue: "b"), outcome: .bytesUnavailable),
        ])
        #expect(mutation.phase == .staging)
        let byID = Dictionary(uniqueKeysWithValues: mutation.targetUpserts.map { ($0.target.id, $0) })
        #expect(byID["a"]?.state == .submitted)
        #expect(byID["a"]?.displayName == "Alpha")
        #expect(byID["b"]?.state == .skipped(reason: "Source bytes unavailable"))
        // No target is marked succeeded/failed — completion is NOT inferred.
        #expect(mutation.targetUpserts.allSatisfy { !$0.state.isObservedOutcome || $0.state.countKey == .skipped })
    }

    @Test("Agent completion reports notReported availability; lint wording never claims page results")
    func agentCompletionDoesNotInventTargetResults() {
        let lintCompletion = QueueIngestionReporting.agentCompletionMutation(operation: .lint, usage: nil)
        #expect(lintCompletion.availability == .notReported)
        #expect(lintCompletion.phase == .finished)
        #expect(lintCompletion.targetUpserts.isEmpty)  // no invented page outcomes
        #expect(lintCompletion.resultSummary?.contains("page-level results not reported") == true)
        #expect(lintCompletion.usage == nil)  // no usage reported → none committed

        let ingestCompletion = QueueIngestionReporting.agentCompletionMutation(
            operation: .ingest,
            usage: SessionUsage(
                inputTokens: 1, outputTokens: 2, totalTokens: 3,
                cachedReadTokens: nil, cachedWriteTokens: nil,
                thoughtTokens: nil, cost: nil, currency: nil, contextUsed: 0, contextSize: 0,
                providerLabel: nil, modelId: "claude-sonnet-4-5"))
        #expect(ingestCompletion.availability == .notReported)
        #expect(ingestCompletion.model == QueueReportModelName(rawValue: "claude-sonnet-4-5"))
        #expect(ingestCompletion.resultSummary?.contains("not reported") == true)
        // The launcher's run-total usage rides along as the durable
        // report-header usage (design change 11) — the same values the
        // navigator showed live.
        #expect(ingestCompletion.usage == QueueReportUsage(
            inputTokens: 1, outputTokens: 2,
            cachedReadTokens: nil, thoughtTokens: nil,
            cost: nil, currency: nil))

        // Optional counters and cost/currency carry over 1:1.
        let fullUsage = QueueIngestionReporting.agentCompletionMutation(
            operation: .ingest,
            usage: SessionUsage(
                inputTokens: 4_178, outputTokens: 537, totalTokens: 4_715,
                cachedReadTokens: 133_376, cachedWriteTokens: nil,
                thoughtTokens: 395, cost: 0.0421, currency: "USD",
                contextUsed: 0, contextSize: 0))
        #expect(fullUsage.usage == QueueReportUsage(
            inputTokens: 4_178, outputTokens: 537,
            cachedReadTokens: 133_376, thoughtTokens: 395,
            cost: 0.0421, currency: "USD"))
    }

    @Test("Whole-wiki lint scope stays a marker and never enumerates pages")
    func wholeWikiScopeIsNotACompletedClaim() {
        let workerScope = QueueIngestionWorker.reportScope(for: QueueItem(
            id: QueueItemID(rawValue: "w"),
            queue: .ingestion,
            wikiID: WikiID(rawValue: "wiki"),
            payload: QueueItemPayload(sourceIDs: [], lintPageIDs: []),
            state: .queued,
            orderingKey: 1,
            attempt: 0,
            createdAt: 0))
        guard case .wholeWiki = workerScope else {
            Issue.record("Expected wholeWiki scope marker, got \(workerScope)")
            return
        }
        // And the report operation is lint.
        #expect(QueueIngestionWorker.reportOperation(for: QueueItem(
            id: QueueItemID(rawValue: "w"),
            queue: .ingestion,
            wikiID: WikiID(rawValue: "wiki"),
            payload: QueueItemPayload(sourceIDs: [], lintPageIDs: []),
            state: .queued,
            orderingKey: 1,
            attempt: 0,
            createdAt: 0)) == .lint)
    }

    @Test("Lint pages staging records requested IDs; unresolvable pages are skipped")
    func lintPagesStagingFacts() {
        let requested = [PageID(rawValue: "p1"), PageID(rawValue: "p-missing")]
        let mutation = QueueIngestionReporting.lintPagesStagingMutation(
            resolved: [(id: PageID(rawValue: "p1"), title: "Notes")],
            requested: requested)
        let byID = Dictionary(uniqueKeysWithValues: mutation.targetUpserts.map { ($0.target.id, $0) })
        #expect(byID["p1"]?.displayName == "Notes")
        #expect(byID["p1"]?.state == .processing)
        #expect(byID["p-missing"]?.state == .skipped(reason: "Requested page not found"))
        #expect(mutation.targetUpserts.count == requested.count)
    }

    // MARK: Extraction worker outcomes

    @Test("Extraction reports succeeded with output reference only after persistence")
    func extractionOutcomeAfterPersistence() async throws {
        let mutations = Mutex<[QueueReportMutation]>([])
        let beginLock = Mutex<QueueReportScope?>(nil)

        let worker = QueueExtractionWorker(
            provider: FakeExtractionProvider(
                resolution: .bytes(FakeExtractionProvider.fakeBytesResolution()),
                persistReference: QueueExtractionOutputReference(versionID: "version-77")),
            emitProgress: { _, _ in },
            emitReportBegin: { _, reportScope in
                beginLock.withLock { $0 = reportScope }
            },
            emitReport: { mutation in
                mutations.withLock { $0.append(mutation) }
            })

        let item = QueueItem(
            id: QueueItemID(rawValue: "ext-1"),
            queue: .extraction,
            wikiID: WikiID(rawValue: "wiki"),
            payload: QueueItemPayload(sourceIDs: [SourceID(rawValue: "only")]),
            state: .running,
            orderingKey: 1,
            attempt: 0,
            createdAt: 0)
        try await worker.execute(item)

        let recorded = mutations.withLock { $0 }
        // The terminal mutation carries the succeeded state + the persisted
        // version reference — emitted only after the provider persisted.
        let terminal = recorded.last
        #expect(terminal?.phase == .finished)
        #expect(terminal?.availability == .available)
        #expect(terminal?.targetUpserts.first?.state == .succeeded)
        #expect(terminal?.targetUpserts.first?.result == .outputReference(
            QueueExtractionOutputReference(versionID: "version-77")))
        // Phase progression observed: staging → running → persisting → finished.
        let phases = recorded.compactMap(\.phase)
        #expect(phases == [.staging, .running, .persisting, .finished])
        // Begin carried the full payload scope.
        if case .targets(let records)? = beginLock.withLock({ $0 }) {
            #expect(records.first?.target == .source(SourceID(rawValue: "only")))
            #expect(records.first?.state == .planned)
        } else {
            Issue.record("Expected targets scope at begin")
        }
    }

    @Test("No-route extraction records skipped, preserves existing completion semantics")
    func noRouteExtractionIsSkippedNotSuccess() async throws {
        let mutations = Mutex<[QueueReportMutation]>([])
        let worker = QueueExtractionWorker(
            provider: FakeExtractionProvider(resolution: nil, persistReference: nil),
            emitProgress: { _, _ in },
            emitReportBegin: { _, _ in },
            emitReport: { mutation in
                mutations.withLock { $0.append(mutation) }
            })

        let item = QueueItem(
            id: QueueItemID(rawValue: "ext-2"),
            queue: .extraction,
            wikiID: WikiID(rawValue: "wiki"),
            payload: QueueItemPayload(sourceIDs: [SourceID(rawValue: "no-route")]),
            state: .running,
            orderingKey: 1,
            attempt: 0,
            createdAt: 0)
        // The worker returns normally (item → .completed) — unchanged.
        try await worker.execute(item)

        let terminal = mutations.withLock { $0 }.last
        #expect(terminal?.phase == .finished)
        #expect(terminal?.targetUpserts.first?.state == .skipped(reason: "No extraction route for this source"))
        #expect(terminal?.resultSummary?.hasPrefix("Skipped") == true)
    }

    @Test("Multi-source extraction payload keeps unobserved targets planned")
    func multiTargetExtractionKeepsOthersPlanned() throws {
        // Execution still processes only the first source; the report scope
        // records every payload target.
        let scope = QueueIngestionWorker.reportScope(for: QueueItem(
            id: QueueItemID(rawValue: "ext-3"),
            queue: .extraction,
            wikiID: WikiID(rawValue: "wiki"),
            payload: QueueItemPayload(sourceIDs: [SourceID(rawValue: "first"), SourceID(rawValue: "second")]),
            state: .queued,
            orderingKey: 1,
            attempt: 0,
            createdAt: 0))
        guard case .targets(let records) = scope else {
            Issue.record("Expected targets scope")
            return
        }
        #expect(records.count == 2)
        #expect(records[0].target == .source(SourceID(rawValue: "first")))
        #expect(records[1].target == .source(SourceID(rawValue: "second")))
        #expect(records.allSatisfy { $0.state == .planned })
    }

    @Test("Readiness failure records the target failure reason before throwing")
    func readinessFailureRecordsReason() async throws {
        let mutations = Mutex<[QueueReportMutation]>([])
        let worker = QueueExtractionWorker(
            provider: FakeExtractionProvider(
                resolution: .bytes(FakeExtractionProvider.unreadyBytesResolution()),
                persistReference: nil),
            emitProgress: { _, _ in },
            emitReportBegin: { _, _ in },
            emitReport: { mutation in
                mutations.withLock { $0.append(mutation) }
            })

        let item = QueueItem(
            id: QueueItemID(rawValue: "ext-4"),
            queue: .extraction,
            wikiID: WikiID(rawValue: "wiki"),
            payload: QueueItemPayload(sourceIDs: [SourceID(rawValue: "unready")]),
            state: .running,
            orderingKey: 1,
            attempt: 0,
            createdAt: 0)
        await #expect(throws: QueueExtractionError.self) {
            try await worker.execute(item)
        }

        let terminal = mutations.withLock { $0 }.last
        #expect(terminal?.targetUpserts.first?.state == .failed(reason: "no API key"))
        // The report never marks the extraction succeeded on a thrown item.
        #expect(terminal?.targetUpserts.first?.state != .succeeded)
    }

    // MARK: Cancel vs in-flight report commit

    @Test("Cancel drains the dispatch scope so a late commit cannot regress interrupted targets")
    func cancelPreventsLateCommitFromRegressingInterruptedTargets() async throws {
        let store = try makeStore()
        let ready = AsyncStream<Void>.makeStream()
        let done = AsyncStream<Void>.makeStream()
        let lateCommitAllowed = AtomicFlag()
        let factory = LateCommitWorkerFactory(
            ready: ready.continuation,
            done: done.continuation,
            lateCommitAllowed: lateCommitAllowed)
        let engine = QueueEngine(
            store: store,
            config: QueueEngineConfig(ingestionLimits: ["p1": 1]),
            workerFactory: factory)
        let itemID = try await engine.enqueue(QueueItemRequest(
            queue: .ingestion,
            wikiID: WikiID(rawValue: "cancel-report-wiki"),
            payload: QueueItemPayload(sourceIDs: [SourceID(rawValue: "s1")])))
        await engine.start()

        // The worker began the report and committed a live target state.
        for await _ in ready.stream {}

        await engine.cancelItem(itemID)

        // The cancel path projected the interrupted report over the live state.
        let cancelledItem = try #require(try store.getItem(itemID))
        #expect(cancelledItem.state == .cancelled)
        let projected = try #require(try store.loadReport(itemID: itemID))
        #expect(projected.phase == .finished)
        #expect(projected.targets.first?.state == .interrupted)
        let projectedRevision = projected.revision

        // Release the worker. Its "in-flight" commit lands now — admitted
        // before the cancel, landing after the interrupted projection. With
        // the cancel-path drain the lease is already invalidated, so the
        // emission is rejected instead of regressing interrupted targets to
        // live state.
        lateCommitAllowed.value = true
        for await _ in done.stream {}

        let final = try #require(try store.loadReport(itemID: itemID))
        #expect(final.phase == .finished)
        #expect(final.targets.first?.state == .interrupted)
        #expect(final.revision == projectedRevision)
    }

    @Test("An orphaned cancellation requeue still projects interrupted targets (L5)")
    func orphanedCancelRequeueProjectsInterruptedReport() async throws {
        // The defensive branch in `handleWorkerFinished`: a worker ends with
        // CancellationError while the store still says `.running` — neither
        // `cancelItem` nor `halt` ran, so nothing projected the interrupted
        // report. The requeue alone used to leave live target states in the
        // report. L5: the branch now re-projects, so unfinished targets read
        // as interrupted, never as live work.
        let store = try makeStore()
        let ready = AsyncStream<Void>.makeStream()
        let release = AtomicFlag()
        let factory = OrphanedCancelWorkerFactory(
            ready: ready.continuation, release: release)
        let engine = QueueEngine(
            store: store,
            config: QueueEngineConfig(ingestionLimits: ["p1": 1]),
            workerFactory: factory)
        let itemID = try await engine.enqueue(QueueItemRequest(
            queue: .ingestion,
            wikiID: WikiID(rawValue: "orphan-report-wiki"),
            payload: QueueItemPayload(sourceIDs: [SourceID(rawValue: "s1")])))
        await engine.start()

        // The worker began the report and committed a live target state, then
        // parks. Pause BEFORE releasing it: the orphan requeue returns the
        // item to `.queued`, and a running queue would re-dispatch it — the
        // pause keeps this test on the orphan branch only.
        for await _ in ready.stream {}
        await engine.pause(.ingestion)
        release.value = true
        // Bound the wait for handleWorkerFinished + the projection; yields
        // cooperatively so it can never park a cooperative-pool thread.
        for _ in 0..<10_000 {
            if let item = try store.getItem(itemID),
               item.state == .queued,
               let report = try store.loadReport(itemID: itemID),
               report.phase == .finished {
                break
            }
            await Task.yield()
        }

        // The orphan was requeued (existing behavior)…
        let requeued = try #require(try store.getItem(itemID))
        #expect(requeued.state == .queued)
        // …and its report no longer shows live work (L5).
        let report = try #require(try store.loadReport(itemID: itemID))
        #expect(report.phase == .finished)
        #expect(report.targets.first?.state == .interrupted)
    }
}

// MARK: - Fakes

/// No-op factory for engine construction without dispatch.
private struct NoopFactory: QueueWorkerFactory {
    func providerID(for item: QueueItem) async -> ProviderID? { nil }
    func worker(for item: QueueItem) async throws -> any QueueWorker {
        throw QueueIngestionError.noSources
    }
}

/// Configurable extraction provider for worker-level outcome tests.
private final class FakeExtractionProvider: QueueExtractionProvider, @unchecked Sendable {
    let resolution: ExtractionResolution?
    let persistReference: QueueExtractionOutputReference?

    init(resolution: ExtractionResolution?, persistReference: QueueExtractionOutputReference?) {
        self.resolution = resolution
        self.persistReference = persistReference
    }

    static func fakeBytesResolution() -> BytesExtractionResolution {
        BytesExtractionResolution(
            extractor: FakeMarkdownExtractor(ready: true),
            sourceBytes: Data("pdf-bytes".utf8),
            filename: "paper.pdf",
            backend: .localPdf2md)
    }

    static func unreadyBytesResolution() -> BytesExtractionResolution {
        BytesExtractionResolution(
            extractor: FakeMarkdownExtractor(ready: false),
            sourceBytes: Data("pdf-bytes".utf8),
            filename: "paper.pdf",
            backend: .localPdf2md)
    }

    func resolveExtraction(
        wikiID: WikiID,
        sourceID: SourceID,
        backendOverride: ExtractionBackend?
    ) async throws -> ExtractionResolution? {
        resolution
    }

    func persistBytesExtraction(
        wikiID: WikiID,
        sourceID: SourceID,
        resolution: BytesExtractionResolution,
        markdown: String
    ) async throws -> QueueExtractionOutputReference? {
        persistReference
    }

    func persistTranscriptExtraction(
        wikiID: WikiID,
        sourceID: SourceID,
        resolution: TranscriptExtractionResolution,
        outcome: TranscriptFetchOutcome
    ) async throws -> QueueExtractionOutputReference? {
        persistReference
    }
}

/// Minimal Sendable extractor stub.
private struct FakeMarkdownExtractor: MarkdownExtractor {
    let ready: Bool

    var displayName: String { "Fake" }

    func readiness() async -> ExtractionReadiness {
        ready ? .ready : .needsSetup("no API key")
    }

    func convert(
        pdfData: Data,
        filename: String,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> String {
        "extracted markdown"
    }
}

/// A thread-safe boolean gate. `Mutex` itself is non-Copyable, so it cannot
/// sit in a stored property of a Copyable struct; this immutable wrapper can.
private final class AtomicFlag: Sendable {
    private let state = Mutex(false)

    var value: Bool {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

/// A worker that begins the report, commits a live target state, then parks
/// until the test releases it — at which point it attempts one more "in
/// flight" report commit and throws `CancellationError`. This models a commit
/// that was admitted by the lease before the cancel arrived and lands after
/// the cancel path's interrupted projection.
private struct LateCommitWorker: QueueWorker {
    let output: QueueWorkerOutputScope
    let ready: AsyncStream<Void>.Continuation
    let done: AsyncStream<Void>.Continuation
    let lateCommitAllowed: AtomicFlag

    /// Bound so a misbehaving test cannot hang the suite; far longer than
    /// `cancelItem` needs. Yields cooperatively — never blocks a thread.
    private static let maxSpinIterations = 1_000_000

    func execute(_ item: QueueItem) async throws {
        let source = item.payload.sourceIDs.first ?? SourceID(rawValue: "s1")
        output.emitReportBegin(
            operation: .ingest,
            scope: .targets([
                QueueReportTargetRecord(
                    target: .source(source),
                    displayName: "Late.pdf",
                    state: .planned)
            ]))
        output.emitReport(.init(targetUpserts: [
            QueueReportTargetRecord(
                target: .source(source),
                displayName: "Late.pdf",
                state: .processing)
        ]))
        ready.yield()
        ready.finish()

        var spins = 0
        while !lateCommitAllowed.value {
            guard spins < Self.maxSpinIterations else { break }
            spins += 1
            await Task.yield()
        }

        // The late commit: must be rejected by the invalidated lease.
        output.emitReport(.init(targetUpserts: [
            QueueReportTargetRecord(
                target: .source(source),
                displayName: "Late.pdf",
                state: .processing)
        ]))
        done.yield()
        done.finish()
        throw CancellationError()
    }
}

/// Factory for ``LateCommitWorker``; the engine dispatches through the scoped
/// variant, which is the only one given an output capability.
private struct LateCommitWorkerFactory: QueueWorkerFactory {
    let ready: AsyncStream<Void>.Continuation
    let done: AsyncStream<Void>.Continuation
    let lateCommitAllowed: AtomicFlag

    func providerID(for item: QueueItem) async -> ProviderID? {
        ProviderID(rawValue: "p1")
    }

    func worker(for item: QueueItem) async throws -> any QueueWorker {
        Issue.record("Engine must dispatch through the scoped factory variant")
        throw CancellationError()
    }

    func worker(for item: QueueItem, output: QueueWorkerOutputScope) async throws -> any QueueWorker {
        LateCommitWorker(
            output: output,
            ready: ready,
            done: done,
            lateCommitAllowed: lateCommitAllowed)
    }
}

/// A worker that begins the report, commits a live target state, parks until
/// the test releases it, then dies with `CancellationError` WITHOUT any
/// user-driven cancel/halt — driving `handleWorkerFinished`'s orphaned-
/// cancellation branch (store still says `.running`).
private struct OrphanedCancelWorker: QueueWorker {
    let output: QueueWorkerOutputScope
    let ready: AsyncStream<Void>.Continuation
    let release: AtomicFlag

    /// Bound so a misbehaving test cannot hang the suite. Yields
    /// cooperatively — never blocks a thread.
    private static let maxSpinIterations = 1_000_000

    func execute(_ item: QueueItem) async throws {
        let source = item.payload.sourceIDs.first ?? SourceID(rawValue: "s1")
        output.emitReportBegin(
            operation: .ingest,
            scope: .targets([
                QueueReportTargetRecord(
                    target: .source(source),
                    displayName: "Orphan.pdf",
                    state: .planned)
            ]))
        output.emitReport(.init(targetUpserts: [
            QueueReportTargetRecord(
                target: .source(source),
                displayName: "Orphan.pdf",
                state: .processing)
        ]))
        ready.yield()
        ready.finish()

        var spins = 0
        while !release.value {
            guard spins < Self.maxSpinIterations else { break }
            spins += 1
            await Task.yield()
        }
        // No cancelItem/halt ran: the item is still `.running`, so the engine
        // takes the orphaned-cancellation branch.
        throw CancellationError()
    }
}

/// Factory for ``OrphanedCancelWorker``; the engine dispatches through the
/// scoped variant, which is the only one given an output capability.
private struct OrphanedCancelWorkerFactory: QueueWorkerFactory {
    let ready: AsyncStream<Void>.Continuation
    let release: AtomicFlag

    func providerID(for item: QueueItem) async -> ProviderID? {
        ProviderID(rawValue: "p1")
    }

    func worker(for item: QueueItem) async throws -> any QueueWorker {
        Issue.record("Engine must dispatch through the scoped factory variant")
        throw CancellationError()
    }

    func worker(for item: QueueItem, output: QueueWorkerOutputScope) async throws -> any QueueWorker {
        OrphanedCancelWorker(output: output, ready: ready, release: release)
    }
}
