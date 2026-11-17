#if os(macOS)
import Foundation
import Testing
import WikiDaemonContract
import WikiFSCore
import WikiFSSearch
@testable import WikiCtlCore
@testable import wikid

/// P5.2 (plans/daemon-only-access.md; AC.7): `upgradeSearchIndex` is a
/// DAEMON operation. The embedding backfill runs in the fixture daemon
/// (deterministic fixed-vector embedder — no MLX model), and its progress
/// flows as `wikid.search-upgrade-event.v1` envelopes on the event firehose.
///
/// Proven: the start reply's typed outcome; the per-item progress event
/// stream (phase order pages → sources → chats, monotone `done`, fixed
/// `total`); exactly one terminal `complete`; the chunk rows landing
/// DAEMON-side (the daemon's own store reports no missing work after the
/// run); the embedder-unavailable typed no-op; and the app model's sheet
/// state machine driven by the events (`SearchUpgradeState` is a direct
/// projection — the non-dismissible sheet resolves on the terminal event).
@Suite("Search upgrade progress events", .serialized, .timeLimit(.minutes(6)))
struct SearchUpgradeProgressEventTests {

    // MARK: - Deterministic embedder (same fixture family as DaemonFusedSearchTests)

    private struct KeywordEmbedder: Embedder {
        static let identifier = "keyword-upgrade-4"
        let dimension = 4
        private let keywords: [String: [Float]] = [
            "harbor":   [1, 0, 0, 0],
            "mountain": [0, 1, 0, 0],
        ]
        private let unrelated: [Float] = [0, 0, 0, 1]

        func vector(for text: String) -> [Float]? {
            let words = text.lowercased().split(separator: " ").map(String.init)
            var sum = [Float](repeating: 0, count: dimension)
            var matched = 0
            for word in words {
                guard let v = keywords[word] ?? keywords.first(where: { word.contains($0.key) })?.value else {
                    continue
                }
                for i in 0..<dimension { sum[i] += v[i] }
                matched += 1
            }
            guard matched > 0 else { return unrelated }
            let norm = sqrt(sum.reduce(0) { $0 + $1 * $1 })
            guard norm > 0 else { return unrelated }
            return sum.map { $0 / norm }
        }
    }

    private func blob(_ floats: [Float]) -> Data {
        floats.withUnsafeBytes { Data($0) }
    }

    // MARK: - Fixture

    private final class Fixture {
        let container: URL
        let daemon: WikiDaemon
        let exporter: WikiDaemonExporter
        let wikiID: WikiID
        let store: RemoteWikiStore
        let sink: RecordingSink
        let sinkID: UUID

        init() throws {
            container = FileManager.default.temporaryDirectory
                .appendingPathComponent("upgrade-events-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
            daemon = WikiDaemon(
                containerDirectory: container,
                testFixtureMakeStore: { try GRDBWikiStore(databaseURL: $0) })
            let data = try #require(daemon.testFixtureCreateWiki(name: "Upgrade Events"))
            wikiID = try JSONDecoder().decode(WikiDescriptor.self, from: data).id
            exporter = WikiDaemonExporter(daemon: daemon)
            store = RemoteWikiStore(
                transport: XPCStoreTransport(
                    invoker: { [exporter] wikiID, request, reply in
                        exporter.storeOperation(wikiID, request: request, reply: reply)
                    },
                    timeout: 20),
                wikiID: wikiID)
            // Register the sink BEFORE the store's first operation, then
            // flip it live through the coordinator's acknowledged handshake
            // (the same readiness barrier the XPC path applies).
            sink = RecordingSink()
            sinkID = daemon.registerEventSink(sink)
            _ = daemon.storeEvents.completeHandshake(
                sinkID: sinkID,
                preparedWikiIDs: [wikiID.rawValue],
                proxies: daemon.eventSinkProxies())
        }

        func shutdown() {
            daemon.unregisterEventSink(id: sinkID)
            try? FileManager.default.removeItem(at: container)
        }
    }

    /// A `WikiDaemonEventSink` that decodes ONLY the search-upgrade
    /// envelopes (the firehose's other grammars fail the decode and are
    /// dropped — the two-way discrimination contract).
    private final class RecordingSink: NSObject, WikiDaemonEventSink, @unchecked Sendable {
        private let lock = NSLock()
        private var events: [DaemonSearchUpgradeEvent] = []

        func deliverEvent(_ payload: Data) {
            // swiftlint:disable:next silent_try_optional
            guard let envelope = try? JSONDecoder().decode(
                DaemonSearchUpgradeEventEnvelope.self, from: payload),
                envelope.wire == DaemonSearchUpgradeEventWire.marker
            else { return }
            lock.lock()
            events.append(envelope.event)
            lock.unlock()
        }

        func recordedEvents() -> [DaemonSearchUpgradeEvent] {
            lock.lock(); defer { lock.unlock() }
            return events
        }
    }

    /// Seed `pageCount` pages with content but NO chunk embeddings — the
    /// daemon's missing-work scan must find exactly those.
    private func seedPagesWithoutEmbeddings(
        _ fixture: Fixture, titles: [String]
    ) async throws {
        for title in titles {
            let page = try await fixture.store.createPage(title: title)
            try await fixture.store.updatePage(
                id: page.id, title: title, body: "harbor content for \(title)",
                lastEditedBy: nil, provenance: [])
        }
    }

    /// Timeout-bounded, non-blocking wait for the run's terminal event
    /// (never parks a cooperative-pool thread; `swift test`-safe).
    private func awaitTerminalEvent(
        _ fixture: Fixture, timeout: TimeInterval = 30
    ) async -> [DaemonSearchUpgradeEvent] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let events = fixture.sink.recordedEvents()
            if events.contains(where: { $0.state != .running }) {
                return events
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return fixture.sink.recordedEvents()
    }

    // MARK: - The event stream

    @Test("a started run reports progress events and one terminal complete; the chunks land daemon-side")
    func startedRunEmitsProgressAndCompletes() async throws {
        // Claim the cross-suite embedder seam BEFORE installing — the
        // embedder is a process global shared with other suites.
        await EmbedderSeamGate.shared.acquire()
        defer { Task { await EmbedderSeamGate.shared.release() } }
        EmbeddingService.installTestEmbedder(KeywordEmbedder())
        defer { EmbeddingService.resetTestEmbedder() }
        let fixture = try Fixture()
        defer { fixture.shutdown() }

        try await seedPagesWithoutEmbeddings(
            fixture, titles: ["Alpha Harbor", "Beta Harbor", "Gamma Harbor"])

        // The daemon's missing-work scan BEFORE the run: the fixture wiki
        // seeds a Home page too, so the scan is OUR pages + whatever the
        // fixture seeded (>= 3) — the run's total must equal it exactly.
        let daemonStore = try await fixture.daemon.testStore(wikiID: fixture.wikiID)
        let missingBefore = try await daemonStore.missingPageEmbeddingWork()
        #expect(missingBefore.count >= 3)

        // Start through the store family op (the app's trigger path).
        let outcome = try await fixture.store.startSearchUpgrade()
        #expect(outcome == .started)

        let events = await awaitTerminalEvent(fixture)
        guard let terminal = events.last, terminal.state == .complete else {
            Issue.record("expected a terminal complete event, got: \(events)")
            return
        }

        // Stream shape: one terminal; every earlier event is `running`;
        // phase order pages → sources → chats; `done` monotone; `total`
        // fixed at the scanned count.
        #expect(events.filter { $0.state == .complete }.count == 1)
        #expect(events.filter { $0.state == .failed }.isEmpty)
        let running = events.filter { $0.state == .running }
        #expect(running.count >= 3)
        #expect(events.allSatisfy { $0.wikiID == fixture.wikiID.rawValue })
        let scanned = missingBefore.count
        #expect(events.allSatisfy { $0.total == scanned })
        let phaseOrder = events.map(\.phase)
        let firstChat = phaseOrder.firstIndex(of: .chats)
        let lastSource = phaseOrder.lastIndex(of: .sources)
        let firstSource = phaseOrder.firstIndex(of: .sources)
        let lastPage = phaseOrder.lastIndex(of: .pages)
        #expect(firstSource != nil)
        #expect(firstChat != nil)
        if let lastPage, let firstSource {
            #expect(lastPage <= firstSource, "pages must finish before sources begin")
        }
        if let lastSource, let firstChat {
            #expect(lastSource <= firstChat, "sources must finish before chats begin")
        }
        #expect(running.map(\.done) == running.map(\.done).sorted())
        if let lastRunning = running.last {
            #expect(lastRunning.done == scanned)
        }

        // The chunks landed DAEMON-side: the daemon's own store reports no
        // missing page work, and the terminal event closed the run.
        let missingAfter = try await daemonStore.missingPageEmbeddingWork()
        #expect(missingAfter.isEmpty)
    }

    @Test("re-triggering a running run reports started again and does not double-run")
    func reTriggerIsSingleFlight() async throws {
        // Claim the cross-suite embedder seam BEFORE installing — the
        // embedder is a process global shared with other suites.
        await EmbedderSeamGate.shared.acquire()
        defer { Task { await EmbedderSeamGate.shared.release() } }
        EmbeddingService.installTestEmbedder(KeywordEmbedder())
        defer { EmbeddingService.resetTestEmbedder() }
        let fixture = try Fixture()
        defer { fixture.shutdown() }

        try await seedPagesWithoutEmbeddings(
            fixture, titles: ["Alpha Harbor", "Beta Harbor"])

        let first = try await fixture.store.startSearchUpgrade()
        #expect(first == .started)
        let second = try await fixture.store.startSearchUpgrade()
        #expect(second == .started)

        let events = await awaitTerminalEvent(fixture)
        #expect(events.contains { $0.state == .complete })
        // Exactly ONE run's worth of completes.
        #expect(events.filter { $0.state == .complete }.count == 1)
    }

    @Test("no embedder: the start answers embedderUnavailable and emits no events")
    func missingEmbedderIsTypedNoOp() async throws {
        // DELIBERATELY no test embedder installed — the fixture daemon has
        // no model (standard suites run model-less). CLAIM the seam while
        // asserting the absence: a parallel suite installing its own
        // embedder mid-test would otherwise flip this run's outcome.
        await EmbedderSeamGate.shared.acquire()
        defer { Task { await EmbedderSeamGate.shared.release() } }
        EmbeddingService.resetTestEmbedder()
        let fixture = try Fixture()
        defer { fixture.shutdown() }

        try await seedPagesWithoutEmbeddings(fixture, titles: ["Alpha Harbor"])

        let outcome = try await fixture.store.startSearchUpgrade()
        #expect(outcome == .embedderUnavailable)
        // Give the daemon a beat, then assert the silence.
        try await Task.sleep(for: .milliseconds(200))
        #expect(fixture.sink.recordedEvents().isEmpty)
    }

    @Test("nothing missing: the start answers notNeeded and emits no events")
    func nothingMissingIsTypedNoOp() async throws {
        // Claim the cross-suite embedder seam BEFORE installing — the
        // embedder is a process global shared with other suites.
        await EmbedderSeamGate.shared.acquire()
        defer { Task { await EmbedderSeamGate.shared.release() } }
        EmbeddingService.installTestEmbedder(KeywordEmbedder())
        defer { EmbeddingService.resetTestEmbedder() }
        let fixture = try Fixture()
        defer { fixture.shutdown() }

        // Cover EVERY missing item (the fixture wiki seeds a Home page too),
        // so the daemon's scan finds nothing — the typed no-op path.
        let daemonStore = try await fixture.daemon.testStore(wikiID: fixture.wikiID)
        for (id, text) in try await daemonStore.missingPageEmbeddingWork() {
            try await daemonStore.storePageChunks(
                id: id, chunks: [blob(KeywordEmbedder().vector(for: text) ?? [])])
        }
        for (id, text) in try await daemonStore.missingSourceEmbeddingWork() {
            try await daemonStore.storeSourceChunks(
                id: id, chunks: [blob(KeywordEmbedder().vector(for: text) ?? [])])
        }
        for (id, text) in try await daemonStore.missingChatEmbeddingWork() {
            try await daemonStore.storeChatChunks(
                id: id, chunks: [blob(KeywordEmbedder().vector(for: text) ?? [])])
        }

        let outcome = try await fixture.store.startSearchUpgrade()
        #expect(outcome == .notNeeded)
        try await Task.sleep(for: .milliseconds(200))
        #expect(fixture.sink.recordedEvents().isEmpty)
    }

    // MARK: - The app model's sheet state machine (event-driven)

    @MainActor
    @Test("the model's SearchUpgradeState is a direct projection of the events")
    func modelSheetFollowsEvents() async {
        let store = try! TestStoreFactory.inMemory()
        let model = WikiStoreModel(store: store)
        #expect(model.searchUpgrade == nil)

        // First running event CREATES the non-dismissible sheet state.
        model.applySearchUpgradeProgress(.init(phase: .pages, done: 0, total: 5, terminal: .none))
        #expect(model.searchUpgrade?.total == 5)
        #expect(model.searchUpgrade?.done == 0)
        #expect(model.searchUpgrade?.phase == .pages)

        // Progress updates keep the sheet up and move the counters.
        model.applySearchUpgradeProgress(.init(phase: .pages, done: 3, total: 5, terminal: .none))
        #expect(model.searchUpgrade?.done == 3)
        model.applySearchUpgradeProgress(.init(phase: .sources, done: 4, total: 5, terminal: .none))
        #expect(model.searchUpgrade?.phase == .sources)
        #expect(model.searchUpgrade?.done == 4)

        // The terminal complete DISMISSES the sheet.
        model.applySearchUpgradeProgress(.init(phase: .chats, done: 5, total: 5, terminal: .complete))
        #expect(model.searchUpgrade == nil)

        // A failed run ALSO dismisses (the sheet must never hang waiting
        // for a complete that never comes).
        model.applySearchUpgradeProgress(.init(phase: .pages, done: 1, total: 9, terminal: .none))
        #expect(model.searchUpgrade != nil)
        model.applySearchUpgradeProgress(.init(phase: .pages, done: 1, total: 9, terminal: .failed))
        #expect(model.searchUpgrade == nil)
    }
}
extension WikiDaemon {
    /// Test accessor: the daemon's admitted store for `wikiID` (the fixture
    /// prepares it lazily through the domain-command seam).
    fileprivate func testStore(wikiID: WikiID) async throws -> any WikiStore {
        try await domainCommandStore(wikiID: wikiID)
    }
}
#endif
