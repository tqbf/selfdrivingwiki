import Foundation
import Testing
@testable import WikiFSCore

/// Phase 6 — version pinning (`@vN`): store-layer tests.
/// AC.3 (replaceLinks writes pin), AC.4 (ordinal chronological),
/// AC.6 (processedMarkdownVersion reader).
struct Phase6PinningStoreTests {

    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wiki-phase6-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WikiFS.sqlite")
    }

    // MARK: - AC.3 — replaceLinks writes pinned_version_id

    @Test func replaceLinksWritesResolvedPin() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let page = try store.createPage(title: "P")
        let source = try store.addSource(filename: "doc.pdf", data: Data("pdf".utf8))

        _ = try store.appendProcessedMarkdown(sourceID: source.id, content: "v1", origin: .extraction, note: nil)
        _ = try store.appendProcessedMarkdown(sourceID: source.id, content: "v2", origin: .extraction, note: nil)
        let v3 = try store.appendProcessedMarkdown(sourceID: source.id, content: "v3", origin: .extraction, note: nil)

        try store.replaceLinks(from: page.id, parsedLinks: [
            .init(linkType: .source, target: source.id.rawValue, linkText: "doc",
                  versionPin: "3")
        ])

        #expect(try store.sourceLinkPin(from: page.id, to: source.id) == v3.id)
    }

    @Test func replaceLinksOutOfRangePinWritesNULL() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let page = try store.createPage(title: "P")
        let source = try store.addSource(filename: "doc.pdf", data: Data("pdf".utf8))

        _ = try store.appendProcessedMarkdown(sourceID: source.id, content: "v1", origin: .extraction, note: nil)

        // Only 1 version exists; @v9 is out of range → NULL (follows active ref).
        try store.replaceLinks(from: page.id, parsedLinks: [
            .init(linkType: .source, target: source.id.rawValue, linkText: "doc",
                  versionPin: "9")
        ])

        #expect(try store.sourceLinkPin(from: page.id, to: source.id) == nil)
    }

    @Test func replaceLinksUnpinnedWritesNULL() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let page = try store.createPage(title: "P")
        let source = try store.addSource(filename: "doc.pdf", data: Data("pdf".utf8))

        try store.appendProcessedMarkdown(sourceID: source.id, content: "v1", origin: .extraction, note: nil)

        try store.replaceLinks(from: page.id, parsedLinks: [
            .init(linkType: .source, target: source.id.rawValue, linkText: "doc")
        ])

        #expect(try store.sourceLinkPin(from: page.id, to: source.id) == nil)
    }

    @Test func citeEmbedAndDistinctPinsCoexist() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let page = try store.createPage(title: "P")
        let source = try store.addSource(filename: "doc.pdf", data: Data("pdf".utf8))

        let v1 = try store.appendProcessedMarkdown(sourceID: source.id, content: "v1", origin: .extraction, note: nil)
        try store.appendProcessedMarkdown(sourceID: source.id, content: "v2", origin: .extraction, note: nil)

        // A cite @v1, a cite @v2, and an embed @v1 — three distinct edges under
        // source_links_edge (from, to, role, COALESCE(pin, '')).
        try store.replaceLinks(from: page.id, parsedLinks: [
            .init(linkType: .source, target: source.id.rawValue, linkText: "cite-v1",
                  versionPin: "1"),
            .init(linkType: .source, target: source.id.rawValue, linkText: "cite-v2",
                  versionPin: "2"),
            .init(linkType: .source, target: source.id.rawValue, linkText: "embed-v1",
                  isEmbed: true, versionPin: "1"),
        ])

        // All three rows coexist as distinct source_links rows.
        #expect(try store.listAllSourceLinks().count == 3)
        // The embed @v1 pins to v1 (readable by role).
        #expect(try store.sourceLinkPin(from: page.id, to: source.id, role: .embed) == v1.id)
    }

    // MARK: - AC.4 — ordinal is chronological (ULID-asc)

    @Test func ordinalResolvesChronologically() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let source = try store.addSource(filename: "doc.pdf", data: Data("pdf".utf8))

        let v1 = try store.appendProcessedMarkdown(sourceID: source.id, content: "oldest", origin: .extraction, note: nil)
        _ = try store.appendProcessedMarkdown(sourceID: source.id, content: "mid", origin: .extraction, note: nil)
        let v3 = try store.appendProcessedMarkdown(sourceID: source.id, content: "newest", origin: .extraction, note: nil)

        // The chain is ULID-asc (chronological); v1 = oldest, v3 = newest.
        let chain = try store.sourceDerivedChains()[source.id]!
        #expect(chain.first == v1.id)
        #expect(chain.last == v3.id)
        #expect(chain.count == 3)

        // @v1 (cite) pins to v1 (oldest); @v3 (embed) pins to v3 (newest) —
        // distinguishable by role so we can read each back individually.
        let page = try store.createPage(title: "P")
        try store.replaceLinks(from: page.id, parsedLinks: [
            .init(linkType: .source, target: source.id.rawValue, linkText: "oldest",
                  versionPin: "1"),
            .init(linkType: .source, target: source.id.rawValue, linkText: "newest",
                  isEmbed: true, versionPin: "3"),
        ])
        #expect(try store.sourceLinkPin(from: page.id, to: source.id, role: .cite) == v1.id)
        #expect(try store.sourceLinkPin(from: page.id, to: source.id, role: .embed) == v3.id)
    }

    @Test func ordinalStableUnderAppend() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let source = try store.addSource(filename: "doc.pdf", data: Data("pdf".utf8))

        let v1 = try store.appendProcessedMarkdown(sourceID: source.id, content: "v1", origin: .extraction, note: nil)
        let v2 = try store.appendProcessedMarkdown(sourceID: source.id, content: "v2", origin: .extraction, note: nil)
        let v3 = try store.appendProcessedMarkdown(sourceID: source.id, content: "v3", origin: .extraction, note: nil)

        // Append a 4th version — v1–v3 ids must be unchanged.
        _ = try store.appendProcessedMarkdown(sourceID: source.id, content: "v4", origin: .extraction, note: nil)
        let chain = try store.sourceDerivedChains()[source.id]!
        #expect(chain.count == 4)
        #expect(chain[0] == v1.id)
        #expect(chain[1] == v2.id)
        #expect(chain[2] == v3.id)
    }

    // MARK: - AC.6 — processedMarkdownVersion(id:)

    @Test func processedMarkdownVersionReturnsCorrectRow() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let source = try store.addSource(filename: "doc.pdf", data: Data("pdf".utf8))

        _ = try store.appendProcessedMarkdown(sourceID: source.id, content: "first", origin: .extraction, note: nil)
        let v2 = try store.appendProcessedMarkdown(sourceID: source.id, content: "second", origin: .extraction, note: nil)

        let resolved = try store.processedMarkdownVersion(id: v2.id)
        #expect(resolved?.id == v2.id)
        #expect(resolved?.content == "second")
        #expect(resolved?.sourceID == source.id)
    }

    @Test func processedMarkdownVersionNilForUnknownID() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let resolved = try store.processedMarkdownVersion(id: PageID(rawValue: "01JZZZZZZZZZZZZZZZZZZZZZZZ"))
        #expect(resolved == nil)
    }
}
