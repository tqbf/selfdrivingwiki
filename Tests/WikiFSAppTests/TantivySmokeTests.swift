#if os(macOS)
import Testing
import TantivySwift
import Foundation

/// Phase 0 build-spike smoke test (plans/tantivy-search-sidecar.md).
///
/// Proves the `botisan-ai/tantivy.swift` XCFramework resolves under bare
/// `swift build` (no Xcode, no xcodebuild) and the UniFFI FFI bridge works
/// end-to-end on macOS: create index → `@TantivyDocument` macro → index one
/// doc → search → verify the hit.
///
/// This is a **spike** — it does NOT wire Tantivy into the search pipeline.
/// Fast (<1 s), no SQLite, no network, so it runs in the fast CI tier.
///
/// Side effect of living in this target: the `@TantivyDocument` macro expansion
/// (Codable + CodingKeys + `TantivySearchableDocument` conformance) is
/// type-checked under `WikiFSTests`' `-warnings-as-errors` setting — so a clean
/// compile here confirms the macro emits no Swift 6 concurrency warnings.
@Suite
struct TantivySmokeTests {

    /// Minimal document exercising `@TantivyDocument` + `@IDField` / `@TextField`.
    @TantivyDocument
    struct SpikeDoc: Sendable {
        @IDField var id: String
        @TextField var title: String
        @TextField var body: String

        init(id: String, title: String, body: String) {
            self.id = id
            self.title = title
            self.body = body
        }
    }

    @Test func indexAndSearchRoundTrip() async throws {
        // Fresh temp dir per run (UUID) so there's nothing to clear.
        let indexPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("tantivy-smoke-\(UUID().uuidString)")
        let fm = FileManager.default
        if fm.fileExists(atPath: indexPath) {
            try fm.removeItem(atPath: indexPath)
        }

        defer { try? fm.removeItem(atPath: indexPath) }

        let index = try TantivySwiftIndex<SpikeDoc>(path: indexPath)

        let doc = SpikeDoc(
            id: "1",
            title: "Swift and Rust",
            body: "Exploring full-text search with Tantivy."
        )
        try await index.index(doc: doc)

        let count = await index.count()
        #expect(count == 1, "indexed document should be countable")

        let query = TantivySwiftSearchQuery<SpikeDoc>(
            queryStr: "tantivy",
            defaultFields: [.title, .body]
        )
        let results = try await index.search(query: query)

        #expect(results.count == 1, "search for 'tantivy' should match 1 doc")
        let hit = try #require(results.docs.first)
        #expect(hit.doc.id == "1")
        #expect(hit.doc.title == "Swift and Rust")
        #expect(hit.score > 0, "matched document should have a positive BM25 score")
    }
}
#endif
