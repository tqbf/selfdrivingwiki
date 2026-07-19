import Testing
import Foundation
import WikiFSSearch

/// Integration tests for `TantivyIndexer.autocomplete(...)` /
/// `TantivySearchService.autocomplete(...)` (issues #436 / #638, plan §6b/§6c).
///
/// Mirrors `TantivyShadowIndexTests` (in-memory content source + temp index
/// dir per test). The headline AC is `"Erl"` → `"Erickson"` via distance-2
/// prefix-fuzzy on title (the #638 case the plan-reviewer corrected us on:
/// MUST use the query-string path with `prefix: true`, NOT the structured
/// `.fuzzy` enum which has no `prefix`).
///
/// Marked `.integration` (opens a real Tantivy index) AND added to the
/// fast-tier `--skip` regex in `.github/workflows/ci.yml` per the testing
/// rules. The `swift-integration` job runs them to gate merges.
@Suite(.tags(.integration))
struct TantivyAutocompleteTests {

    // MARK: - In-memory content source (mirror of TantivyShadowIndexTests)

    private actor InMemoryContentSource: TantivyContentSource {
        private var docs: [String: TantivyContentSnapshot] = [:]

        func upsert(_ snapshot: TantivyContentSnapshot) {
            docs["\(snapshot.kind.rawValue):\(snapshot.ulid)"] = snapshot
        }

        func snapshot(ulid: String, kind: TantivyDocumentKind) async throws -> TantivyContentSnapshot? {
            docs["\(kind.rawValue):\(ulid)"]
        }

        func allSnapshots() async throws -> [TantivyContentSnapshot] {
            Array(docs.values)
        }
    }

    private func makeTempDir() -> (URL, FileManager) {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("tantivy-autocomplete-\(UUID().uuidString)")
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        return (url, fm)
    }

    private func makeSnapshot(
        ulid: String,
        kind: TantivyDocumentKind,
        title: String,
        body: String = ""
    ) -> TantivyContentSnapshot {
        TantivyContentSnapshot(
            ulid: ulid, kind: kind, title: title, body: body,
            updatedAt: Date(), versionSum: 1)
    }

    private func makeService(source: InMemoryContentSource, dir: URL) throws -> TantivySearchService {
        try TantivySearchService(
            wikiID: "autocomplete-test",
            containerDirectory: dir,
            contentSource: source)
    }

    // MARK: - AC #1: "Erl" → "Erickson" (the #638 headline case)

    @Test func shortPrefixSurfacesLongerTitleViaPrefixFuzzy() async throws {
        // This is the headline AC of #638. A naive whole-token edit-distance
        // query would score "Erl" as distance-6 from "Erickson" and miss it.
        // The query-string path with `prefix: true` (the reviewer correction)
        // is what makes this work — the fuzzy automaton expands as a prefix.
        let (indexDir, fm) = makeTempDir()
        defer { try? fm.removeItem(at: indexDir) }

        let source = InMemoryContentSource()
        let service = try makeService(source: source, dir: indexDir)

        await source.upsert(makeSnapshot(ulid: "01PAGE00001", kind: .page, title: "Erickson"))
        await source.upsert(makeSnapshot(ulid: "01PAGE00002", kind: .page, title: "Erlang"))
        await source.upsert(makeSnapshot(ulid: "01PAGE00003", kind: .page, title: "Erie"))
        await service.indexer.upsert(ulid: "01PAGE00001", kind: .page)
        await service.indexer.upsert(ulid: "01PAGE00002", kind: .page)
        await service.indexer.upsert(ulid: "01PAGE00003", kind: .page)

        let hits = await service.autocomplete(
            partial: "Erl", kinds: [.page], distance: 2, limit: 8)

        #expect(hits.contains { $0.title == "Erickson" },
                "AC #1: 'Erl' must surface 'Erickson' via prefix-fuzzy — the #638 headline")
        #expect(hits.contains { $0.title == "Erlang" })
        #expect(hits.contains { $0.title == "Erie" })
    }

    // MARK: - AC #2: typo tolerance (distance 1–2)

    @Test func typoDistanceOneSurfacesTarget() async throws {
        // `Erlckson` is edit-distance 1 from `Erickson` (extra `l`).
        let (indexDir, fm) = makeTempDir()
        defer { try? fm.removeItem(at: indexDir) }

        let source = InMemoryContentSource()
        let service = try makeService(source: source, dir: indexDir)

        await source.upsert(makeSnapshot(ulid: "01PAGE00010", kind: .page, title: "Erickson"))
        await service.indexer.upsert(ulid: "01PAGE00010", kind: .page)

        let hits = await service.autocomplete(
            partial: "Erlckson", kinds: [.page], distance: 2, limit: 8)

        #expect(hits.contains { $0.title == "Erickson" },
                "AC #2: a distance-1 typo on a longer title should still resolve")
    }

    // MARK: - AC #3: kind scoping (post-filter in Swift — reviewer correction #1)

    @Test func kindScopingFiltersToOnlyRequestedKind() async throws {
        // Same title across kinds: the page should appear in the `[.page]`
        // query, the source in the `[.source]` query — never crossed.
        let (indexDir, fm) = makeTempDir()
        defer { try? fm.removeItem(at: indexDir) }

        let source = InMemoryContentSource()
        let service = try makeService(source: source, dir: indexDir)

        await source.upsert(makeSnapshot(ulid: "01PAGE00100", kind: .page,   title: "Erlang Guide"))
        await source.upsert(makeSnapshot(ulid: "01SRC00100",  kind: .source, title: "Erlang Spec"))
        await service.indexer.upsert(ulid: "01PAGE00100", kind: .page)
        await service.indexer.upsert(ulid: "01SRC00100",  kind: .source)

        let pageHits = await service.autocomplete(partial: "Erlang", kinds: [.page], limit: 8)
        #expect(pageHits.allSatisfy { $0.kind == .page })
        #expect(pageHits.contains { $0.title == "Erlang Guide" })
        #expect(!pageHits.contains { $0.title == "Erlang Spec" },
               "AC #3: page-scoped query must not return sources")

        let sourceHits = await service.autocomplete(partial: "Erlang", kinds: [.source], limit: 8)
        #expect(sourceHits.allSatisfy { $0.kind == .source })
        #expect(sourceHits.contains { $0.title == "Erlang Spec" })
        #expect(!sourceHits.contains { $0.title == "Erlang Guide" },
               "AC #3: source-scoped query must not return pages")
    }

    @Test func emptyKindsReturnsEmptyResults() async throws {
        // Defensive: callers should always pass at least one kind, but the
        // indexer must not crash on an empty set.
        let (indexDir, fm) = makeTempDir()
        defer { try? fm.removeItem(at: indexDir) }

        let source = InMemoryContentSource()
        let service = try makeService(source: source, dir: indexDir)
        await source.upsert(makeSnapshot(ulid: "01PAGE00200", kind: .page, title: "Anything"))
        await service.indexer.upsert(ulid: "01PAGE00200", kind: .page)

        let hits = await service.autocomplete(partial: "Any", kinds: [], limit: 8)
        #expect(hits.isEmpty)
    }

    // MARK: - Distance-2 actually does work (vs the path's existing distance-1)

    @Test func distanceTwoToleratesTwoEdits() async throws {
        // `Conc` is fine at distance 1. `Canc` (substitute o→a, e→a — depends
        // on tokenizer) is a distance-2 typo of `Conc` — exercise distance 2.
        // Index "Concurrency" and query "Concurrencey" (typo + extra char).
        let (indexDir, fm) = makeTempDir()
        defer { try? fm.removeItem(at: indexDir) }

        let source = InMemoryContentSource()
        let service = try makeService(source: source, dir: indexDir)

        await source.upsert(makeSnapshot(ulid: "01PAGE00300", kind: .page, title: "Concurrency"))
        await service.indexer.upsert(ulid: "01PAGE00300", kind: .page)

        let hits = await service.autocomplete(
            partial: "Concurrecny", kinds: [.page], distance: 2, limit: 8)
        // Distance-2 typo of "Concurrency" — "Concurrecny" has two transposed
        // letters near the end.
        #expect(hits.contains { $0.title == "Concurrency" },
                "distance-2 fuzzy should tolerate a 2-char edit on a long title")
    }

    // MARK: - Empty / edge inputs

    @Test func emptyPartialReturnsEmpty() async throws {
        let (indexDir, fm) = makeTempDir()
        defer { try? fm.removeItem(at: indexDir) }

        let source = InMemoryContentSource()
        let service = try makeService(source: source, dir: indexDir)
        await source.upsert(makeSnapshot(ulid: "01PAGE00400", kind: .page, title: "Anything"))
        await service.indexer.upsert(ulid: "01PAGE00400", kind: .page)

        let hits = await service.autocomplete(partial: "", kinds: [.page], limit: 8)
        #expect(hits.isEmpty, "empty partial must not trigger autocomplete")
    }

    @Test func limitIsRespected() async throws {
        let (indexDir, fm) = makeTempDir()
        defer { try? fm.removeItem(at: indexDir) }

        let source = InMemoryContentSource()
        let service = try makeService(source: source, dir: indexDir)
        // Index 10 pages that all match the "Page" prefix.
        for i in 0..<10 {
            let ulid = String(format: "01PAGE%05d", i + 1)
            await source.upsert(makeSnapshot(ulid: ulid, kind: .page, title: "Page \(i)"))
            await service.indexer.upsert(ulid: ulid, kind: .page)
        }

        let hits = await service.autocomplete(partial: "Page", kinds: [.page], limit: 4)
        #expect(hits.count <= 4, "limit must clamp the result count")
    }
}
