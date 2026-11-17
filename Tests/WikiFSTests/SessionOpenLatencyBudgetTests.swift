#if os(macOS)
import Cordis
import CordisLoader
import Foundation
import Testing
import WikiFSCore
import WikiFSSearch
@testable import WikiFSEngine

/// Opt-in performance baseline (plans/daemon-only-access.md Phase 0 → Phase 7
/// budget gate). SKIPPED unless `SESSION_OPEN_BENCHMARK=1` is set; run
/// manually on a quiet machine:
///
///     SESSION_OPEN_BENCHMARK=1 swift test --filter SessionOpenLatencyBudgetTests
///
/// Records cold session open (the app's real `bootWikiSession` path against
/// a fresh container), page open (sidebar navigation read), sidebar search
/// (the model's search path), and the local queue enqueue→terminal round
/// trip. The P0 numbers are the BASELINE recorded in the plan document; the
/// Phase 7 budget gate requires the daemon-only build to stay within
/// 1.25× of these numbers for session open and page open, and within 1.25×
/// for search and ingestion completion.
@Suite("Session open latency budget", .serialized, .timeLimit(.minutes(5)))
struct SessionOpenLatencyBudgetTests {
    private static let benchmarkEnabled =
        ProcessInfo.processInfo.environment["SESSION_OPEN_BENCHMARK"] == "1"
    /// Fixed dataset: the fixture script's content sizes (plan: "a fixed
    /// dataset"). Pages are small and deterministic; the point is a stable
    /// comparative baseline, not absolute numbers.
    private static let pageCount = 20
    private static let iterations = 5

    @Test("cold session open, page open, search, queue round trip (opt-in)")
    @MainActor
    func recordBaselines() async throws {
        guard Self.benchmarkEnabled else {
            return  // skipped by default
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-latency-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Fixed dataset: one wiki with N deterministic pages.
        let wikiID = WikiID(rawValue: "open-latency")
        let databaseURL = root.appendingPathComponent("\(wikiID.rawValue).sqlite")
        let datasetStore = try GRDBWikiStore(databaseURL: databaseURL)
        for index in 1...Self.pageCount {
            _ = try datasetStore.createPage(
                title: "Page \(index)",
                body: "Body for page \(index).\n\nSome deterministic content for search.",
                createdBy: "user", provenance: [])
        }
        datasetStore.close()

        // -- Cold session open: the production app session loader, fresh.
        var coldOpens: [Duration] = []
        var sessions: [ProfileWikiSession] = []
        let processDisposals = ProfileProcessDisposalRecorder()
        let owner = AppProcessProfileOwner {
            try await CordisBoot.boot(.init(
                catalog: try ProfileBootFixture.processCatalog(
                    includeAppServices: true, recorder: processDisposals),
                layers: [PatchFile(
                    entries: ProfileBootFixture.processEntries(includeAppServices: true))]))
        }
        owner.start()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let descriptor = WikiDescriptor(
            id: wikiID, displayName: "Latency", createdAt: timestamp, lastUsedAt: timestamp)
        for _ in 0..<Self.iterations {
            let clock = ContinuousClock()
            let start = clock.now
            let session = try await owner.bootWikiSession(
                wikiID: wikiID,
                descriptor: descriptor,
                containerDirectory: root,
                catalog: try AppPluginCatalog.build(factories: AppPluginCatalogFactories(
                    base: BasePluginCatalogFactories(
                        agentProviderServices: UnavailableAgentProviderServices()),
                    makeDaemonTransport: { ProfileBootFixture.fixtureTransportServices() })),
    
                searchServices: UnavailableSearchServices())
            coldOpens.append(clock.now - start)
            sessions.append(session)
        }

        // -- Page open: navigation read on the LAST booted session.
        let session = try #require(sessions.last)
        var pageOpens: [Duration] = []
        let clock = ContinuousClock()
        for index in 1...Self.pageCount {
            let start = clock.now
            let selected = session.store.selectPage(byTitle: "Page \(index)")
            pageOpens.append(clock.now - start)
            #expect(selected)
        }

        // -- Sidebar search (model search path; daemon-fused — in tests the
        //    store answers locally without the BM25 leg, so this is the
        //    lower bound).
        var searches: [Duration] = []
        for _ in 0..<Self.iterations {
            let start = clock.now
            _ = await session.store.searchSimilar(query: "deterministic content")
            searches.append(clock.now - start)
        }

        // -- Queue round trip: enqueue → running → completed on a file DB.
        let queueURL = root.appendingPathComponent("queue.sqlite")
        let queue = try QueueStore(databaseURL: queueURL)
        var roundTrips: [Duration] = []
        let sourceIDs = try datasetStore.listSources().map(\.id)
        let payload = QueueItemPayload(sourceIDs: [])
        for index in 0..<Self.iterations {
            _ = index
            let start = clock.now
            let item = try queue.enqueue(QueueItemRequest(
                queue: .extraction, wikiID: wikiID, payload: payload))
            try queue.markRunning(id: item.id, providerID: ProviderID(rawValue: "benchmark"))
            try queue.markCompleted(id: item.id)
            roundTrips.append(clock.now - start)
        }
        queue.close()
        _ = sourceIDs

        func percentile(_ samples: [Duration], _ fraction: Double) -> String {
            let ordered = samples.map { $0.components.attoseconds }.sorted()
            let index = min(ordered.count - 1, Int((Double(ordered.count) * fraction).rounded(.up)) - 1)
            let ms = Double(ordered[max(0, index)]) / 1_000_000_000_000_000
            return String(format: "%.1fms", ms)
        }

        func median(_ samples: [Duration]) -> String {
            let sorted = samples.map { $0.components.attoseconds }.sorted()
            let middle = sorted[sorted.count / 2]
            return String(format: "%.1fms", Double(middle) / 1_000_000_000_000_000)
        }

        let report = """
        session-open (cold, \(Self.iterations) runs): \
        min=\(percentile(coldOpens, 0.0)) median=\(median(coldOpens)) p90=\(percentile(coldOpens, 0.9))
        page-open (\(Self.pageCount) pages): \
        median=\(median(pageOpens)) p90=\(percentile(pageOpens, 0.9))
        sidebar-search (\(Self.iterations) runs): \
        median=\(median(searches)) p90=\(percentile(searches, 0.9))
        queue-round-trip (\(Self.iterations) runs): \
        median=\(median(roundTrips)) p90=\(percentile(roundTrips, 0.9))
        """
        print("SESSION_OPEN_BENCHMARK\n\(report)")

        for waiting in sessions {
            await waiting.shutdown()
        }
        await owner.shutdown()
    }
}
#endif
