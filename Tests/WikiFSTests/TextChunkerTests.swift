import Testing
@testable import WikiFSCore

/// `TextChunker` (recursive character splitter) — pure, deterministic behavior.
/// The chunker exists to keep every `NLEmbedding.vector(for:)` call small: whole
/// documents crash NLEmbedding with an uncatchable `std::bad_alloc` above ~250k
/// chars, and are slow long before that.
@Suite struct TextChunkerTests {

    @Test func emptyReturnsEmpty() {
        #expect(TextChunker.chunk("").isEmpty)
    }

    @Test func shortTextReturnsSingleChunk() {
        let chunks = TextChunker.chunk("hello world", chunkSize: 100, overlap: 0)
        #expect(chunks == ["hello world"])
    }

    @Test func splitsOnParagraphBoundariesFirst() {
        let text = "para one\n\npara two\n\npara three"
        // chunkSize=12 keeps each paragraph whole (8/8/11 chars) yet small enough
        // that the merger emits one chunk per paragraph.
        let chunks = TextChunker.chunk(text, chunkSize: 12, overlap: 0)
        #expect(chunks == ["para one", "para two", "para three"])
    }

    @Test func mergesSmallPiecesIntoChunkSizedBuckets() {
        // Many short lines should be packed into chunks no larger than chunkSize.
        let lines = (0..<50).map { "line\($0)" }.joined(separator: "\n")
        let chunks = TextChunker.chunk(lines, chunkSize: 40, overlap: 0)
        #expect(chunks.count > 1)
        for c in chunks { #expect(c.count <= 40) }
        // Re-joining all chunks preserves every line token.
        #expect(chunks.joined(separator: " ").contains("line0"))
        #expect(chunks.joined(separator: " ").contains("line49"))
    }

    @Test func overlapCarriesTailIntoNextChunk() {
        // With overlap, consecutive chunks share a suffix/prefix window so a
        // passage straddling a boundary is represented in both.
        let words = (0..<200).map { "word\($0)" }.joined(separator: " ")
        let chunks = TextChunker.chunk(words, chunkSize: 100, overlap: 30)
        #expect(chunks.count > 1)
        // No chunk exceeds the size bound.
        for c in chunks { #expect(c.count <= 100) }
    }

    @Test func giantStringWithNoSeparatorsDoesNotCrash() {
        // A single 300k run with NO whitespace would have crashed NLEmbedding.
        // The chunker hard-splits it into bounded runs.
        let giant = String(repeating: "a", count: 300_000)
        let chunks = TextChunker.chunk(giant, chunkSize: 4000, overlap: 0)
        #expect(chunks.count >= 75)            // 300000 / 4000
        for c in chunks { #expect(c.count <= 4000) }
        #expect(chunks.joined().count == 300_000)
    }

    @Test func defaultsAreSane() {
        // Default chunkSize/overlap from the public entry point.
        let text = String(repeating: "the quick brown fox\n\n", count: 400)  // ~9k
        let chunks = TextChunker.chunk(text)
        #expect(chunks.count >= 2)
        for c in chunks { #expect(c.count <= 4000) }
    }
}
