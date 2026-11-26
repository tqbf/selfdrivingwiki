#if os(macOS)
import FileProvider
import Foundation
import Testing
import WikiFSCore
@testable import WikiFSFileProvider

/// AC.11: a > 4 MiB source fetch through the REAL daemon socket exercises
/// the projection family's chunked payload-handle download end-to-end —
/// the reply exceeds the inline budget, the daemon stashes the bytes
/// (stashCommitted), the client receives an oversized handle, and its
/// download loop reassembles the payloadRead chunks with byte-count +
/// SHA-256 verification before returning plain bytes.
@Suite(.serialized, .timeLimit(.minutes(3)))
struct ProjectionLargeContentTests {

    @Test func oversizedSourceContentFetchesChunkedThroughTheSocket() throws {
        let fixture = try ProjectionSocketFixture.make(displayName: "Large Content Wiki")

        // 5 MiB of deterministic bytes — over the 4 MiB frame cap, so the
        // reply can never ride inline and must promote to a handle.
        var payload = Data()
        var seed: UInt64 = 0x5A5A_5A5A_5A5A_5A5A
        while payload.count < 5 * 1024 * 1024 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            var word = seed.bigEndian
            withUnsafeBytes(of: &word) { payload.append(contentsOf: $0) }
        }
        let expected = payload

        let source = try fixture.store.addSource(
            filename: "large.bin", data: expected, mimeType: "application/octet-stream")

        let projection = fixture.projection
        let id = Projection.Identity.sourceByName(source.id.rawValue)
        guard let node = projection.node(for: id) else {
            Issue.record("large source node not found")
            return
        }
        #expect(node.name == FilenameEscaping.byNameSourceFilename(
            filename: source.filename, ext: source.ext, sourceID: source.id))

        let fetched: Data? = projection.contents(for: id)
        #expect(fetched == expected, "chunked download must return the exact bytes (count \(fetched?.count ?? 0) vs \(expected.count))")
    }

    /// The per-scope verbatim-byte cache stops caching past its budget
    /// (P7 follow-up 3): a source larger than the budget is never cached,
    /// and once the running total would exceed the budget new fetches are
    /// not retained — they still work, they just repeat — so a pass over
    /// many large sources has a hard memory ceiling. The policy never reads
    /// through the source, so a constructed (never-connected) client serves
    /// as the scope's source.
    @Test func sourceByteCacheStopsCachingPastItsBudget() throws {
        let source = DaemonProjectionClient(
            wikiID: WikiID(rawValue: "01JBUDGETFIXTUREWIKI000000"),
            containerDirectory: { throw CancellationError() })
        let scope = Projection.ReadScope(source: source)
        let budget = Projection.ReadScope.maxCachedSourceBytes
        let overBudgetID = SourceID(rawValue: "01JBUDGETSRC000000000000000A")
        let halfID = SourceID(rawValue: "01JBUDGETSRC000000000000000B")
        let spilloverID = SourceID(rawValue: "01JBUDGETSRC000000000000000C")
        let fittingID = SourceID(rawValue: "01JBUDGETSRC000000000000000D")

        // A single source larger than the whole budget: never cached.
        scope.cacheSourceBytes(Data(count: budget + 1), for: overBudgetID)
        #expect(scope.debugCachedSourceBytesTotal == 0)
        #expect(scope.sourceBytes(for: overBudgetID) == nil)

        // Half the budget caches; an insert that would exceed the budget is
        // skipped, and the skipped source reads as uncached.
        let half = Data(count: budget / 2)
        scope.cacheSourceBytes(half, for: halfID)
        #expect(scope.debugCachedSourceBytesTotal == budget / 2)
        #expect(scope.sourceBytes(for: halfID) == half)
        scope.cacheSourceBytes(Data(count: budget / 2 + 1), for: spilloverID)
        #expect(scope.debugCachedSourceBytesTotal == budget / 2)
        #expect(scope.sourceBytes(for: spilloverID) == nil)

        // A source that fits the remaining budget still caches.
        let fitting = Data(count: budget / 4)
        scope.cacheSourceBytes(fitting, for: fittingID)
        #expect(scope.debugCachedSourceBytesTotal == budget / 2 + budget / 4)
        #expect(scope.sourceBytes(for: fittingID) == fitting)
    }
}
#endif
