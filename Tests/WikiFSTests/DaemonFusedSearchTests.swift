#if os(macOS)
import Foundation
import Testing
import WikiDaemonContract
import WikiFSCore
import WikiFSSearch
@testable import WikiCtlCore
@testable import wikid

/// AC.7 (plans/daemon-only-access.md Phase 5): the daemon-side FUSED search.
/// The app consumes ONE store-family round trip; the DAEMON's executor
/// resolves the Tantivy BM25 leg from its own index runtime and its store
/// computes the semantic cosine leg, fused via `RankFusion.rrf`.
///
/// **Deterministic embedder fixture:** `EmbeddingService.installTestEmbedder`
/// (the `#if DEBUG` hook) installs a fixed-vector embedder in THIS process —
/// the fixture daemon runs in-process, so its store's query embedding uses
/// the same deterministic vectors. Standard suites never need the MLX model.
/// An optional real-MLX smoke run against the bundled wikid.xpc is documented
/// in plans/daemon-only-access.md and is NOT a gate.
///
/// Proven: fused ORDERING (a doc hit by both legs outranks either
/// single-leg doc; the lexical-only doc appears only through the daemon's
/// leg — the pure-cosine path cannot see it), rebuild-before-query
/// FRESHNESS (a page committed after a query appears in the next query),
/// and FAILURE PROPAGATION (embedder unavailable → the daemon degrades to
/// the BM25 leg alone, typed results, never an error surface).
@Suite("Daemon fused search", .serialized, .timeLimit(.minutes(6)))
struct DaemonFusedSearchTests {

    // MARK: - Deterministic embedder

    /// Fixed 4-dim unit vectors keyed by keyword; multi-word text averages
    /// the keyword vectors (so "harbor market" leans toward both). Unknown
    /// text maps to a vector orthogonal to every keyword. Deterministic:
    /// no model, no Metal, no nondeterminism.
    private struct KeywordEmbedder: Embedder {
        static let identifier = "keyword-fixture-4"
        let dimension = 4

        private let keywords: [String: [Float]] = [
            "harbor":   [1, 0, 0, 0],
            "mountain": [0, 1, 0, 0],
            "desert":   [0, 0, 1, 0],
        ]
        private let unrelated: [Float] = [0, 0, 0, 1]

        func vector(for text: String) -> [Float]? {
            let words = text.lowercased().split(separator: " ").map(String.init)
            guard !words.isEmpty else { return nil }
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

    /// In-process fixture daemon + the store transport the app uses, wired
    /// through `WikiDaemonExporter.storeOperation` (the same invoker seam an
    /// XPC connection vends). The daemon embeds through the installed test
    /// embedder; its Tantivy runtime lives under the fixture container.
    private final class Fixture {
        let container: URL
        let daemon: WikiDaemon
        let exporter: WikiDaemonExporter
        let wikiID: WikiID
        let store: RemoteWikiStore

        init(wikiName: String) throws {
            container = FileManager.default.temporaryDirectory
                .appendingPathComponent("daemon-fused-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
            daemon = WikiDaemon(
                containerDirectory: container,
                testFixtureMakeStore: { try GRDBWikiStore(databaseURL: $0) })
            let data = try #require(daemon.testFixtureCreateWiki(name: wikiName))
            wikiID = try JSONDecoder().decode(WikiDescriptor.self, from: data).id
            exporter = WikiDaemonExporter(daemon: daemon)
            store = RemoteWikiStore(
                transport: XPCStoreTransport(
                    invoker: { [exporter] wikiID, request, reply in
                        exporter.storeOperation(wikiID, request: request, reply: reply)
                    },
                    timeout: 20),
                wikiID: wikiID)
        }

        func shutdown() {
            try? FileManager.default.removeItem(at: container)
        }
    }

    /// Chunk text + vector for a page, seeded DAEMON-side through the store
    /// family (the same writes the app's deleted local backfill used to do).
    private func seedPage(
        _ fixture: Fixture, title: String, body: String, vector: [Float]
    ) async throws -> WikiPageSummary {
        let page = try await fixture.store.createPage(title: title)
        try await fixture.store.updatePage(
            id: page.id, title: title, body: body, lastEditedBy: nil,
            provenance: [])
        try await fixture.store.storePageChunks(id: page.id, chunks: [blob(vector)])
        return WikiPageSummary(
            id: page.id, title: title,
            updatedAt: page.updatedAt, createdAt: page.createdAt)
    }

    @Test("fused ordering: the both-legs doc outranks either single-leg doc; the daemon leg lifts the lexical-only doc")
    func fusedOrderingPutsBothLegsFirst() async throws {
        // Claim the cross-suite embedder seam BEFORE installing — the
        // embedder is a process global shared with other suites.
        let seam = await EmbedderSeamGate.shared.acquire()
        EmbeddingService.installTestEmbedder(KeywordEmbedder())
        defer {
            EmbeddingService.resetTestEmbedder()
            Task { await EmbedderSeamGate.shared.release(seam) }
        }
        let fixture = try Fixture(wikiName: "Fused Ordering")
        defer { fixture.shutdown() }

        // Hand-seeded chunk vectors (distinct sims, no ties):
        // - "both": lexical hit for "harbor" AND cosine 0.93 (both legs vote).
        // - "lexicalOnly": lexical hit, cosine 0 (BM25 vote only).
        // - "semanticOnly": no lexical overlap, cosine 0.71 (cosine vote only).
        let both = try await seedPage(
            fixture, title: "Harbor Market", body: "harbor market notes",
            vector: [0.9285, 0.3714, 0, 0])
        let lexicalOnly = try await seedPage(
            fixture, title: "Harbor Log", body: "harbor master log",
            vector: [0, 0, 1, 0])
        let semanticOnly = try await seedPage(
            fixture, title: "Seaside Notes", body: "seaside dock inventory",
            vector: [0.7071, 0.7071, 0, 0])

        // The fused daemon reply (bm25Leg: nil — the daemon resolves the leg).
        let fused = try await fixture.store.searchSimilar(
            query: "harbor", limit: 10, bm25Leg: nil)
        let fusedIDs = fused.map(\.id)
        #expect(fusedIDs.contains(both.id))
        #expect(fusedIDs.contains(lexicalOnly.id))
        #expect(fusedIDs.contains(semanticOnly.id))
        // Both legs vote → the fused winner is deterministic.
        #expect(fused.first?.id == both.id)
        // The daemon's BM25 leg is LOAD-BEARING: the lexical-only doc (cosine
        // 0) outranks the semantic-only doc (cosine 0.71) ONLY because the
        // executor's Tantivy vote joins the fusion.
        let fusedLexical = try #require(fusedIDs.firstIndex(of: lexicalOnly.id))
        let fusedSemantic = try #require(fusedIDs.firstIndex(of: semanticOnly.id))
        #expect(fusedLexical < fusedSemantic)

        // The pure-cosine contrast (the daemon's OWN store, no leg): the
        // order there is strictly by cosine — lexical-only ranks LAST.
        let daemonStore = try await fixture.daemon.testStore(wikiID: fixture.wikiID)
        let cosineOnly = try await daemonStore.searchSimilar(
            query: "harbor", limit: 10, bm25Leg: nil)
        #expect(cosineOnly.map(\.id) == [both.id, semanticOnly.id, lexicalOnly.id])
    }

    @Test("freshness: a page committed after a query appears in the next query (rebuild-before-query)")
    func committedPageAppearsInNextQuery() async throws {
        // Claim the cross-suite embedder seam BEFORE installing — the
        // embedder is a process global shared with other suites.
        let seam = await EmbedderSeamGate.shared.acquire()
        EmbeddingService.installTestEmbedder(KeywordEmbedder())
        defer {
            EmbeddingService.resetTestEmbedder()
            Task { await EmbedderSeamGate.shared.release(seam) }
        }
        let fixture = try Fixture(wikiName: "Fused Freshness")
        defer { fixture.shutdown() }

        let before = try await seedPage(
            fixture, title: "Mountain Guide", body: "mountain trail guide",
            vector: KeywordEmbedder().vector(for: "mountain")!)
        let first = try await fixture.store.searchSimilar(
            query: "mountain", limit: 10, bm25Leg: nil)
        #expect(first.map(\.id) == [before.id])

        // Commit AFTER the query: the daemon's change-token baseline moves,
        // so the next query rebuilds before answering.
        let after = try await seedPage(
            fixture, title: "Mountain Journal", body: "mountain summit journal",
            vector: KeywordEmbedder().vector(for: "mountain")!)
        let second = try await fixture.store.searchSimilar(
            query: "mountain", limit: 10, bm25Leg: nil)
        #expect(second.map(\.id).contains(before.id))
        #expect(second.map(\.id).contains(after.id))
    }

    @Test("failure propagation: embedder unavailable degrades to the BM25 leg alone, never an error")
    func embedderFailureDegradesToLexicalOnly() async throws {
        // Claim the cross-suite embedder seam for the WHOLE test — including
        // the mid-test reset below. This test deliberately flips the
        // process-global embedder (installed → removed); ungated, that flip
        // nils (or stomps) whatever embedder a parallel gated suite has
        // installed, silently emptying its cosine leg. Holding the claim
        // keeps the flip private to this test.
        let seam = await EmbedderSeamGate.shared.acquire()
        EmbeddingService.installTestEmbedder(KeywordEmbedder())
        let fixture = try Fixture(wikiName: "Fused Degradation")
        defer {
            EmbeddingService.resetTestEmbedder()
            Task { await EmbedderSeamGate.shared.release(seam) }
            fixture.shutdown()
        }

        let lexical = try await seedPage(
            fixture, title: "Desert Survey", body: "desert survey notes",
            vector: KeywordEmbedder().vector(for: "harbor")!)

        // Embedder STILL INSTALLED: fused reply contains the doc (lexical
        // leg matched; the orthogonal vector ranks it last or filters it).
        let fused = try await fixture.store.searchSimilar(
            query: "desert", limit: 10, bm25Leg: nil)
        #expect(fused.contains { $0.id == lexical.id })

        // Embedder REMOVED (the daemon has no model): the semantic leg is
        // empty, the BM25 leg still answers — typed results, no throw.
        EmbeddingService.resetTestEmbedder()
        let degraded = try await fixture.store.searchSimilar(
            query: "desert", limit: 10, bm25Leg: nil)
        #expect(degraded.map(\.id) == [lexical.id])
    }

    @Test("chat and source searches fuse through the same daemon executor")
    func chatsAndSourcesFuseDaemonSide() async throws {
        // Claim the cross-suite embedder seam BEFORE installing — the
        // embedder is a process global shared with other suites.
        let seam = await EmbedderSeamGate.shared.acquire()
        EmbeddingService.installTestEmbedder(KeywordEmbedder())
        defer {
            EmbeddingService.resetTestEmbedder()
            Task { await EmbedderSeamGate.shared.release(seam) }
        }
        let fixture = try Fixture(wikiName: "Fused Chats Sources")
        defer { fixture.shutdown() }

        let chat = try await fixture.store.createChat(kind: .edit, title: "Harbor planning")
        try await fixture.store.storeChatChunks(
            id: chat.id, chunks: [blob(KeywordEmbedder().vector(for: "harbor")!)])
        let chatFused = try await fixture.store.searchSimilarChats(
            query: "harbor", limit: 10, bm25Leg: nil)
        #expect(chatFused.map(\.id) == [chat.id])

        let source = try await fixture.store.addSource(
            filename: "mountain-notes.txt", data: Data("mountain trail guide".utf8))
        try await fixture.store.storeSourceChunks(
            id: source.id, chunks: [blob(KeywordEmbedder().vector(for: "mountain")!)])
        let sourceFused = try await fixture.store.searchSimilarSources(
            query: "mountain", limit: 10, bm25Leg: nil)
        #expect(sourceFused.map(\.id) == [source.id])
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
