#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import WikiCtlCore
import WikiDaemonContract
import WikiFSCore
import WikiFSEngine
@testable import WikiFS
@testable import wikid

/// The staged-proposal review section's PRODUCTION wiring (W5b + the
/// daemon→app read seam): a tier-2 run stages over the REAL scoped socket,
/// the daemon's exported state surface serves the records, and the
/// production `QueueStagedProposalSource` resolves them — the section
/// populates from real daemon run state, not only an injected fixture.
///
/// Suite discipline per AGENTS.md #1051: `.serialized` + `.timeLimit`; the
/// socket round trips carry short timeouts; no sleeps, no blocking waits.
@Suite("Daemon lint staged proposal transport", .serialized, .timeLimit(.minutes(5)))
struct LintStagedProposalTransportTests {

    /// One wiki with one selected page, a PROPOSAL-policy run, and the
    /// scoped server serving it (the same shape the staging tests use).
    private final class Fixture {
        let container: URL
        let store: GRDBWikiStore
        let descriptor: WikiDescriptor
        let page: WikiPage
        let head: PageVersionID
        let lintRunState = DaemonLintRunState()
        let runID: DaemonRunID
        let daemon: WikiDaemon
        let client: DaemonDomainSocketClient
        let authorization: DaemonDomainAuthorization
        private let server: DaemonSearchSocketServer

        static let body = "# Target\n\nold text\n"
        static let breakerKey = LintRepairBreakerKey(
            pipelineDigest: "transport-digest", provider: "anthropic",
            model: "claude-opus", effort: "high")

        init() async throws {
            container = FileManager.default.temporaryDirectory
                .appendingPathComponent("dwtransport-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
            var mutable = WikiDescriptor.make(displayName: "Transport Wiki")
            mutable.lastUsedAt = Date()
            descriptor = mutable
            var diskRegistry = WikiRegistry.load(from: container)
            diskRegistry.add(descriptor)
            try diskRegistry.save(to: container)
            store = try GRDBWikiStore(
                databaseURL: container.appendingPathComponent(descriptor.dbFileName, isDirectory: false))
            page = try store.createPage(title: "Transport Target", body: Self.body)
            head = try #require(try store.readPageCoherent(id: page.id).headVersionID)

            daemon = WikiDaemon(containerDirectory: container)
            let runRegistry = DaemonRunRegistry()
            daemon.queueHostLintRunState = lintRunState
            let registration = try await runRegistry.prepareRun(
                scope: DaemonRunScope(wikiID: descriptor.id),
                operationClasses: [.wikiRead],
                operationPolicy: .lintSelectedPageProposal(pageID: page.id))
            try await runRegistry.activate(runID: registration.runID)
            runID = registration.runID
            let dispatcher = DaemonDomainSocketDispatcher(
                daemon: daemon, runRegistry: runRegistry, lintRunState: lintRunState)
            let listenerRunID = registration.runID
            server = try DaemonSearchSocketServer(containerDirectory: container) { request in
                await dispatcher.handle(request, context: .scopedRun(listenerRunID))
            }
            try server.start()
            client = try DaemonDomainSocketClient(containerDirectory: container, timeout: 10)
            authorization = DaemonDomainAuthorization(capability: registration.capability.printable)
        }

        func stop() {
            server.stop()
            do {
                try FileManager.default.removeItem(at: container)
            } catch {
                // Temp cleanup only; each fixture owns a unique directory.
            }
        }

        func mintReceipt() async throws -> String {
            let reply = try await client.send(
                family: .page,
                operation: DaemonDomainOperation.Page.get,
                payload: try JSONEncoder().encode(DaemonPageGetRequest(
                    wikiID: descriptor.id.rawValue,
                    selector: DaemonCommandSelector(id: page.id.rawValue),
                    json: true,
                    workspace: nil)),
                authorization: authorization)
            let outcome = try DaemonCommandOutcome.decode(reply.payload)
            let pageJSON = try #require(
                JSONSerialization.jsonObject(with: Data((outcome.text ?? "").utf8)) as? [String: Any])
            return try #require(pageJSON["lint_receipt"] as? String)
        }

        func propose(receipt: String) async throws -> DaemonDomainReply {
            try await client.send(
                family: .page,
                operation: DaemonDomainOperation.Page.proposePatch,
                payload: try JSONEncoder().encode(DaemonPageProposePatchRequest(
                    wikiID: descriptor.id.rawValue,
                    id: page.id.rawValue,
                    expectHead: head.rawValue,
                    hunks: [DaemonPagePatchRequest.WireHunk(
                        defect: "D25", startByte: 10, endByte: 18,
                        oldText: "old text", newText: "new text",
                        reason: "repair the defect")],
                    author: "agent:lint",
                    lintReceipt: receipt)),
                authorization: authorization)
        }
    }

    /// A queue-engine client whose staged-proposal read serves scripted
    /// records — the stand-in for the XPC proxy's transport leg.
    private final class ScriptedTransportEngine: QueueEngineClient, @unchecked Sendable {
        let id: String = "scripted-transport"
        private let stream = AsyncStream<QueueEvent>.makeStream()
        private let records = Mutex<[LintStagedProposalRecord]>([])

        var events: AsyncStream<QueueEvent> { stream.stream }

        func script(_ records: [LintStagedProposalRecord]) {
            self.records.withLock { $0 = records }
        }

        func loadLintStagedProposals(for pageID: PageID) async -> [LintStagedProposalRecord] {
            records.withLock { $0 }
        }

        func enqueue(_ request: QueueItemRequest) async throws -> QueueItem.ID { QueueItem.ID(rawValue: id) }
        func cancelItem(_ id: QueueItem.ID) async throws {}
        func cancelAllInFlight() async throws -> Int { 0 }
        func retryItem(_ id: QueueItem.ID) async throws {}
        func pause(_ queue: QueueKind) async throws {}
        func resume(_ queue: QueueKind) async throws {}
        func halt(_ queue: QueueKind) async throws {}
        func reorderItem(id: QueueItem.ID, beforeItemID: QueueItem.ID?) async throws {}
        func snapshot() async throws -> QueueSnapshot { QueueSnapshot() }
        func hasActiveWork(for wikiID: WikiID) async throws -> Bool { false }
        func waitForCompletion(of id: QueueItem.ID) async throws -> Result<Void, Error> { .success(()) }
        func waitForCompletion(
            of id: QueueItem.ID, deadline: Duration
        ) async throws -> Result<Void, Error> { .success(()) }
        func loadTranscript(for itemID: QueueItem.ID) async throws -> [ChatTranscriptItem] { [] }
        func loadAllActivitySnapshots() async throws -> [QueueItem.ID: QueueEngine.ActivitySnapshot] { [:] }
        func loadQueueReport(for itemID: QueueItem.ID) async -> QueueReportLoadResult { .notReported }
        func loadQueueReportSummaries(for itemIDs: [QueueItem.ID]) async -> QueueReportSummariesResult { .loaded([:]) }
    }

    @Test("the production source resolves staged records from real daemon state")
    func productionSourceResolvesRealDaemonState() async throws {
        let fixture = try await Fixture()
        defer { fixture.stop() }

        // The trusted host records the run configuration identity BEFORE
        // the child can stage; the staging stamps it onto the record.
        await fixture.lintRunState.recordRunBreakerKey(
            runID: fixture.runID, key: Fixture.breakerKey)
        let receipt = try await fixture.mintReceipt()
        let reply = try await fixture.propose(receipt: receipt)
        #expect(reply.error == nil, "the proposal must stage: \(reply.error?.message ?? "")")

        // The daemon's exported state surface serves the record.
        let records = await WikiDaemonExporter.stagedProposalRecords(
            pageID: fixture.page.id, daemon: fixture.daemon)
        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record.pageID == fixture.page.id.rawValue)
        #expect(record.inspectedHead == fixture.head.rawValue)
        #expect(record.hunks.count == 1)
        #expect(record.hunks[0].startByte == 10 && record.hunks[0].endByte == 18)
        #expect(record.hunks[0].oldText == "old text" && record.hunks[0].newText == "new text")
        #expect(record.perHunkClasses == ["D25"])
        #expect(record.breakerKey?.pipelineDigest == Fixture.breakerKey.pipelineDigest)
        #expect(record.breakerKey?.model == "claude-opus")

        // The PRODUCTION source — the exact wiring the Activity window
        // builds — resolves the section's values through an engine client.
        let engine = ScriptedTransportEngine()
        engine.script(records)
        let source = QueueStagedProposalSource.production(engine: engine)
        let resolved = await source.proposals(fixture.page.id)
        #expect(resolved.count == 1)
        let proposal = try #require(resolved.first)
        #expect(proposal.id == record.id)
        #expect(proposal.pageID == fixture.page.id)
        #expect(proposal.hunkCount == 1)
        #expect(proposal.classLabels == "D25")
        #expect(proposal.breakerKey == Fixture.breakerKey)
        let key = await source.breakerKey()
        #expect(key == Fixture.breakerKey, "the run's configuration identity rides the records")
    }

    @Test("a run whose breaker key was never recorded resolves an unnamed configuration")
    func unrecordedKeyStaysUnnamed() async throws {
        let fixture = try await Fixture()
        defer { fixture.stop() }

        // No key was recorded for this run — the honest state until the
        // live gate wiring names one.
        let receipt = try await fixture.mintReceipt()
        let reply = try await fixture.propose(receipt: receipt)
        #expect(reply.error == nil)

        let records = await WikiDaemonExporter.stagedProposalRecords(
            pageID: fixture.page.id, daemon: fixture.daemon)
        #expect(records.count == 1)
        #expect(records.first?.breakerKey == nil)

        let engine = ScriptedTransportEngine()
        engine.script(records)
        let source = QueueStagedProposalSource.production(engine: engine)
        let resolved = await source.proposals(fixture.page.id)
        #expect(resolved.count == 1, "the section still populates — display never depends on the key")
        let key = await source.breakerKey()
        #expect(key == nil, "no recorded key resolves unnamed, never a guessed one")
    }

    @Test("a wire record with an unknown defect class does not map")
    func unknownDefectClassRecordDoesNotMap() {
        func record(perHunkClasses: [String]) -> LintStagedProposalRecord {
            LintStagedProposalRecord(
                id: "p1", runID: "run", pageID: "01HZPAGE00000000000000000T",
                stagedAt: Date(), inspectedHead: "01HZHEAD0000000000000000009",
                bodyFingerprint: "fp",
                hunks: [LintStagedProposalRecord.Hunk(
                    startByte: 0, endByte: 1, oldText: "a", newText: "b", reason: "r")],
                perHunkClasses: perHunkClasses, breakerKey: nil)
        }
        #expect(QueueLintStagedProposal(record: record(perHunkClasses: ["D99-unknown"])) == nil)
        #expect(QueueLintStagedProposal(record: record(perHunkClasses: ["D25"])) != nil)
    }
}
#endif
