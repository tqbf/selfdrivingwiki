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
}
#endif
