#if os(macOS)
import Cordis
import CordisLoader
import Foundation
import Testing
@testable import WikiCtlCore
@testable import WikiFSCore
@testable import WikiFSEngine

/// `CLITantivyLegResolver` tests. The resolver's backend is the daemon's
/// index (`WikiDaemonProtocol.search(request:reply:)` via
/// ``DaemonSearchClient``) — the daemon is the sole index owner and there is
/// no local fallback, so every search scenario here injects a test backend
/// (`withTestSearchBackend`) that replaces the daemon call. No test touches
/// XPC or a Tantivy index; real `GRDBWikiStore`s supply the typed catalogs
/// the resolver maps hits against.
///
/// Mapping contract (#637): hits map best-first to typed summaries
/// (`WikiPageSummary` / `SourceSummary` / `ChatSummary`) via the store's list
/// APIs; hits naming ids absent from the catalog are dropped; a search with
/// no hits — or no hit resolving to the catalog — returns `nil` (no BM25
/// leg); backend failures throw.
@Suite(.serialized, .timeLimit(.minutes(3)))
struct CLITantivyLegResolverTests {
    enum ExpectedBackendFailure: Error {
        case expected
    }

    actor SearchRequestRecorder {
        private var keys: [CLITantivyLegResolver.SearchRequestKey] = []
        private var invocationCount = 0

        func record(_ key: CLITantivyLegResolver.SearchRequestKey) {
            keys.append(key)
            invocationCount += 1
        }

        func recordedKeys() -> [CLITantivyLegResolver.SearchRequestKey] {
            keys
        }

        func recordedInvocationCount() -> Int {
            invocationCount
        }
    }

    // MARK: - Helpers

    /// Fresh temp directory per test (UUID) holding the `<ulid>.sqlite`.
    private func makeTempContainer() throws -> (URL, FileManager) {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("cli-tantivy-leg-\(UUID().uuidString)")
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return (url, fm)
    }

    private func tempStore(in container: URL, wikiID: WikiID) throws -> GRDBWikiStore {
        let dbURL = container.appendingPathComponent("\(wikiID.rawValue).sqlite", isDirectory: false)
        return try GRDBWikiStore(databaseURL: dbURL)
    }

    private func removeTempContainer(_ container: URL, fileManager: FileManager) {
        do {
            try fileManager.removeItem(at: container)
        } catch {
            Issue.record("could not remove CLI test container: \(error)")
        }
    }

    /// A sentinel hit whose document id is `"<kind>:<ulid>"` — the same
    /// composite id the daemon's index produces.
    private func hit(kind: TantivyDocumentKind, ulid: String, score: Float) -> TantivyShadowSearchResult {
        TantivyShadowSearchResult(
            documentID: kind.documentID(for: ulid),
            kind: kind,
            title: "sentinel-\(ulid)",
            score: score)
    }

    // MARK: - Typed summary mapping

    @Test func resolvePageLegMapsHitsToCatalogSummariesInRankOrder() async throws {
        let (container, fm) = try makeTempContainer()
        defer { try? fm.removeItem(at: container) }
        let wikiID = WikiID(rawValue: "01TEST0002")
        let store = try tempStore(in: container, wikiID: wikiID)
        let first = try store.createPage(title: "Rust Ownership")
        try store.updatePage(id: first.id, title: "Rust Ownership", body: "rust")
        let second = try store.createPage(title: "Async Rust")
        try store.updatePage(id: second.id, title: "Async Rust", body: "async")

        // The daemon's rank order — deliberately NOT the catalog order —
        // plus one hit naming an id that does not exist in the catalog.
        let backendHits = [
            hit(kind: .page, ulid: second.id.rawValue, score: 9),
            hit(kind: .page, ulid: "01ABSENT0000000000", score: 5),
            hit(kind: .page, ulid: first.id.rawValue, score: 3),
        ]

        let leg = try await CLITantivyLegResolver.withTestSearchBackend({ key in
            #expect(key.wikiID == wikiID)
            #expect(key.query == "rust")
            #expect(key.kind == .page)
            #expect(key.limit == 10)
            return backendHits
        }, operation: {
            try await CLITantivyLegResolver.resolvePageLeg(
                wikiID: wikiID, store: store, query: "rust", limit: 10)
        })

        // Rank order preserved; the absent id dropped.
        #expect(leg?.map(\.id) == [second.id, first.id])
    }

    @Test func resolvePageLegReturnsNilWhenBackendAnswersNoHits() async throws {
        let (container, fm) = try makeTempContainer()
        defer { try? fm.removeItem(at: container) }
        let wikiID = WikiID(rawValue: "01TEST0001")
        let store = try tempStore(in: container, wikiID: wikiID)

        // The daemon answering an empty success means "no BM25 leg" — nil,
        // not an error and not an empty array.
        let leg = try await CLITantivyLegResolver.withTestSearchBackend({ _ in [] }, operation: {
            try await CLITantivyLegResolver.resolvePageLeg(
                wikiID: wikiID, store: store, query: "anything", limit: 10)
        })
        #expect(leg == nil)
    }

    @Test func resolvePageLegReturnsNilWhenNoHitResolvesToCatalog() async throws {
        let (container, fm) = try makeTempContainer()
        defer { try? fm.removeItem(at: container) }
        let wikiID = WikiID(rawValue: "01TEST0011")
        let store = try tempStore(in: container, wikiID: wikiID)

        let leg = try await CLITantivyLegResolver.withTestSearchBackend({ _ in
            [hit(kind: .page, ulid: "01ABSENT0000000000", score: 1)]
        }, operation: {
            try await CLITantivyLegResolver.resolvePageLeg(
                wikiID: wikiID, store: store, query: "rust", limit: 10)
        })
        #expect(leg == nil)
    }

    @Test func resolveSourceLegMapsHitsToSourceSummaries() async throws {
        let (container, fm) = try makeTempContainer()
        defer { try? fm.removeItem(at: container) }
        let wikiID = WikiID(rawValue: "01TEST0004")
        let store = try tempStore(in: container, wikiID: wikiID)
        _ = try store.addSource(
            filename: "self-driving-cars.pdf", data: Data("%PDF".utf8))
        let sources = try store.listSources()
        let sourceID = try #require(sources.first?.id)

        let leg = try await CLITantivyLegResolver.withTestSearchBackend({ _ in
            [hit(kind: .source, ulid: sourceID.rawValue, score: 4)]
        }, operation: {
            try await CLITantivyLegResolver.resolveSourceLeg(
                wikiID: wikiID, store: store, query: "autonomous", limit: 10)
        })

        #expect(leg?.map(\.id) == [sourceID])
    }

    @Test func resolveChatLegMapsHitsToChatSummaries() async throws {
        let (container, fm) = try makeTempContainer()
        defer { try? fm.removeItem(at: container) }
        let wikiID = WikiID(rawValue: "01TEST0005")
        let store = try tempStore(in: container, wikiID: wikiID)
        let chat = try store.createChat(kind: .edit, title: "Mars Colony")

        let leg = try await CLITantivyLegResolver.withTestSearchBackend({ _ in
            [hit(kind: .chat, ulid: chat.id.rawValue, score: 6)]
        }, operation: {
            try await CLITantivyLegResolver.resolveChatLeg(
                wikiID: wikiID, store: store, query: "terraforming", limit: 10)
        })

        #expect(leg?.map(\.id) == [chat.id])
    }

    // MARK: - Error propagation

    @Test func resolvePageLegRethrowsBackendFailure() async throws {
        let (container, fm) = try makeTempContainer()
        defer { try? fm.removeItem(at: container) }
        let wikiID = WikiID(rawValue: "01TEST0006")
        let store = try tempStore(in: container, wikiID: wikiID)

        do {
            try await CLITantivyLegResolver.withTestSearchBackend({ _ in
                throw ExpectedBackendFailure.expected
            }, operation: {
                _ = try await CLITantivyLegResolver.resolvePageLeg(
                    wikiID: wikiID, store: store, query: "anything", limit: 10)
            })
            Issue.record("expected backend failure to propagate")
        } catch is ExpectedBackendFailure {
            #expect(Bool(true))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: - In-flight dedup

    @Test func sameWikiConcurrentDistinctRequestsDoNotShareWrongTask() async throws {
        struct SearchOutcome: Sendable {
            let label: String
            let ids: [String]?
        }

        let (container, fm) = try makeTempContainer()
        defer { try? fm.removeItem(at: container) }
        let wikiID = WikiID(rawValue: "01TEST0010")
        let store = try tempStore(in: container, wikiID: wikiID)

        let pageRust = try store.createPage(title: "Rust Ownership")
        let pageOwnership = try store.createPage(title: "Ownership Guide")
        let pageAsync = try store.createPage(title: "Async Rust")
        let rustSourceID = try store.addSource(
            filename: "zircon-rust.pdf", data: Data("%PDF-rust".utf8)).id
        let ownershipSourceID = try store.addSource(
            filename: "amber-ownership.pdf", data: Data("%PDF-ownership".utf8)).id
        let terraformChat = try store.createChat(kind: .edit, title: "Terraforming")

        let recorder = SearchRequestRecorder()
        let outcomes = try await CLITantivyLegResolver.withTestSearchBackend({ key in
            guard key.wikiID == wikiID else { return [] }
            await recorder.record(key)
            let kind = key.kind
            let ids: [String]
            switch (key.query, key.kind, key.limit) {
            case ("cobalt borrowingkey", .page, 2):
                ids = [pageRust.id.rawValue, pageAsync.id.rawValue]
            case ("cobalt borrowingkey", .page, 1):
                ids = [pageRust.id.rawValue]
            case ("amber", .page, 1):
                ids = [pageOwnership.id.rawValue]
            case ("zircon", .source, 1):
                ids = [rustSourceID.rawValue]
            case ("amber", .source, 1):
                ids = [ownershipSourceID.rawValue]
            case ("terraformalpha", .chat, 1):
                ids = [terraformChat.id.rawValue]
            default:
                ids = []
            }
            return ids.enumerated().map { offset, id in
                TantivyShadowSearchResult(
                    documentID: kind.documentID(for: id),
                    kind: kind,
                    title: "sentinel-\(offset)",
                    score: Float(ids.count - offset))
            }
        }, operation: {
            try await withThrowingTaskGroup(of: SearchOutcome.self, returning: [SearchOutcome].self) { group in
                group.addTask {
                    _ = try await CLITantivyLegResolver.resolvePageLeg(
                        wikiID: wikiID, store: store,
                        query: "cobalt borrowingkey", limit: 2)
                    let leg = try await CLITantivyLegResolver.resolvePageLeg(
                        wikiID: wikiID, store: store,
                        query: "cobalt borrowingkey", limit: 2)
                    return SearchOutcome(label: "page-rust-2", ids: leg?.map(\.id.rawValue))
                }
                group.addTask {
                    _ = try await CLITantivyLegResolver.resolvePageLeg(
                        wikiID: wikiID, store: store,
                        query: "cobalt borrowingkey", limit: 1)
                    let leg = try await CLITantivyLegResolver.resolvePageLeg(
                        wikiID: wikiID, store: store,
                        query: "cobalt borrowingkey", limit: 1)
                    return SearchOutcome(label: "page-rust-1", ids: leg?.map(\.id.rawValue))
                }
                group.addTask {
                    let leg = try await CLITantivyLegResolver.resolvePageLeg(
                        wikiID: wikiID, store: store,
                        query: "amber", limit: 1)
                    return SearchOutcome(label: "page-ownership-1", ids: leg?.map(\.id.rawValue))
                }
                group.addTask {
                    let leg = try await CLITantivyLegResolver.resolveSourceLeg(
                        wikiID: wikiID, store: store,
                        query: "zircon", limit: 1)
                    return SearchOutcome(label: "source-rust-1", ids: leg?.map(\.id.rawValue))
                }
                group.addTask {
                    let leg = try await CLITantivyLegResolver.resolveSourceLeg(
                        wikiID: wikiID, store: store,
                        query: "amber", limit: 1)
                    return SearchOutcome(label: "source-ownership-1", ids: leg?.map(\.id.rawValue))
                }
                group.addTask {
                    let leg = try await CLITantivyLegResolver.resolveChatLeg(
                        wikiID: wikiID, store: store,
                        query: "terraformalpha", limit: 1)
                    return SearchOutcome(label: "chat-terraforming-1", ids: leg?.map(\.id.rawValue))
                }

                var collected: [SearchOutcome] = []
                for try await outcome in group {
                    collected.append(outcome)
                }
                return collected
            }
        })

        func outcome(named label: String) -> SearchOutcome? {
            outcomes.first { $0.label == label }
        }
        let keys = await recorder.recordedKeys()
        // The two sequential repeats start new requests after completion.
        // Only overlapping identical requests share an in-flight task.
        #expect(keys.count == 8)
        #expect(keys.allSatisfy { $0.wikiID == wikiID })
        #expect(Set(keys).count == 6)
        #expect(outcomes.count == 6)
        #expect(outcome(named: "page-rust-2")?.ids == [pageRust.id.rawValue, pageAsync.id.rawValue])
        #expect(outcome(named: "page-rust-1")?.ids == [pageRust.id.rawValue])
        #expect(outcome(named: "page-ownership-1")?.ids == [pageOwnership.id.rawValue])
        #expect(outcome(named: "source-rust-1")?.ids == [rustSourceID.rawValue])
        #expect(outcome(named: "source-ownership-1")?.ids == [ownershipSourceID.rawValue])
        #expect(outcome(named: "chat-terraforming-1")?.ids == [terraformChat.id.rawValue])
    }

    @Test func concurrentIdenticalRequestsShareOneBackendInvocation() async throws {
        let (container, fm) = try makeTempContainer()
        defer { try? fm.removeItem(at: container) }
        let wikiID = WikiID(rawValue: "01TEST0012")
        let store = try tempStore(in: container, wikiID: wikiID)
        let page = try store.createPage(title: "Rust Ownership")
        try store.updatePage(id: page.id, title: "Rust Ownership", body: "rust")

        let recorder = SearchRequestRecorder()
        let results = try await CLITantivyLegResolver.withTestSearchBackend({ key in
            await recorder.record(key)
            // Small delay so racing callers overlap inside the in-flight
            // window; every overlapping caller must join the same task.
            try? await Task.sleep(for: .milliseconds(50))
            return [hit(kind: .page, ulid: page.id.rawValue, score: 1)]
        }, operation: {
            try await withThrowingTaskGroup(of: [WikiPageSummary]?.self, returning: [[WikiPageSummary]?].self) { group in
                for _ in 0..<5 {
                    group.addTask {
                        try await CLITantivyLegResolver.resolvePageLeg(
                            wikiID: wikiID, store: store,
                            query: "rust", limit: 5)
                    }
                }
                var collected: [[WikiPageSummary]?] = []
                for try await result in group {
                    collected.append(result)
                }
                return collected
            }
        })

        #expect(results.count == 5)
        #expect(results.allSatisfy { $0?.map(\.id) == [page.id] })
        let invocations = await recorder.recordedInvocationCount()
        // All five concurrent callers joined ONE backend round trip.
        #expect(invocations == 1)
    }


    // `wikiCreateSeedsDatabaseThroughBootstrapBoundary` was removed with the
    // CLI's direct create path (Phase 2 of plans/cli-domain-commands.md). Its
    // coverage moved to `DaemonWikiSocketTests`: creation runs on the daemon's
    // creation coordinator over the socket (Home page seeded, registry
    // persisted, full eviction on delete).

    @Test func dumpConfigOutputMatchesCommandFormatting() throws {
        let (container, fm) = try makeTempContainer()
        defer { removeTempContainer(container, fileManager: fm) }
        let runner = WikiCtlRunner(
            resolveContainer: { WikiResolver(containerDirectory: container) })

        let direct = try DumpConfigCommand.run(homeDirectory: container, overlay: nil)
        let output = try runner.runDumpConfig(overlay: nil)
        var expected = direct.note.map { "\($0)\n" } ?? ""
        expected += direct.output
        if !expected.hasSuffix("\n") { expected += "\n" }

        #expect(String(decoding: output.stdout, as: UTF8.self) == expected)
        #expect(output.stderr.isEmpty)
    }
}
#endif
