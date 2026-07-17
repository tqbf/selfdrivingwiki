import Foundation
import Testing
@testable import WikiFSCore

/// Tests for the pure generated-index byte producers (INITIAL §5/§8): valid
/// JSON, counts matching a seeded DB, and deterministic bytes for fixed input.
struct IndexGeneratorTests {

    private func tempStore() throws -> SQLiteWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-index-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try SQLiteWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }

    private func page(_ id: String, _ title: String, updatedAt: Double) -> WikiPage {
        WikiPage(id: PageID(rawValue: id), title: title, slug: title.lowercased(),
                 bodyMarkdown: "", createdAt: Date(timeIntervalSince1970: 0),
                 updatedAt: Date(timeIntervalSince1970: updatedAt), version: 1)
    }

    // MARK: - manifest.json

    @Test func manifestIsValidJSONWithCorrectCount() throws {
        let pages = [page("A", "Home", updatedAt: 1), page("B", "Other", updatedAt: 2)]
        let data = IndexGenerators.manifest(pages: pages, sourceCount: 3,
                                            chatCount: 0, generatedAt: Date(timeIntervalSince1970: 0))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["name"] as? String == "Self Driving Wiki")
        #expect(obj?["version"] as? Int == 1)
        #expect(obj?["page_count"] as? Int == 2)
        #expect(obj?["file_count"] as? Int == 3)
        #expect(obj?["chat_count"] as? Int == 0)
        let paths = obj?["paths"] as? [String: Any]
        #expect(paths?["page_index"] as? String == "indexes/pages.jsonl")
        #expect(paths?["link_index"] as? String == "indexes/links.jsonl")
        #expect(paths?["sources_by_id"] as? String == "sources/by-id")
        #expect(paths?["source_index"] as? String == "indexes/sources.jsonl")
        #expect(paths?["chats_by_id"] as? String == "chats/by-id")
        #expect(paths?["chat_index"] as? String == "indexes/chats.jsonl")
    }

    @Test func manifestGeneratedAtIsISO8601UTC() throws {
        let data = IndexGenerators.manifest(pages: [], sourceCount: 0,
                                            chatCount: 0, generatedAt: Date(timeIntervalSince1970: 0))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["generated_at"] as? String == "1970-01-01T00:00:00Z")
    }

    // MARK: - pages.jsonl

    @Test func pagesJSONLEachLineValidWithCorrectCount() throws {
        let pages = [page("A1", "Home", updatedAt: 100), page("B2", "Notes", updatedAt: 200)]
        let data = IndexGenerators.pagesJSONL(pages: pages)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasSuffix("\n"))

        let lines = text.split(separator: "\n")
        #expect(lines.count == pages.count)
        for line in lines {
            let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            #expect(obj?["id"] != nil)
            #expect(obj?["title"] != nil)
            #expect((obj?["path"] as? String)?.hasPrefix("pages/by-id/") == true)
            #expect(obj?["updated_at"] != nil)
        }
        // First line carries the expected shape.
        let first = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        #expect(first?["id"] as? String == "A1")
        #expect(first?["title"] as? String == "Home")
        #expect(first?["path"] as? String == "pages/by-id/A1.md")
        #expect(first?["updated_at"] as? Int == 100)
    }

    // MARK: - links.jsonl

    @Test func linksJSONLEachLineValidWithCorrectCount() throws {
        let links = [
            IndexGenerators.LinkRow(from: "A", to: "B", linkText: "File Provider"),
            IndexGenerators.LinkRow(from: "A", to: "C", linkText: "Notes"),
        ]
        let data = IndexGenerators.linksJSONL(links: links)
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        #expect(lines.count == links.count)
        let first = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        #expect(first?["from"] as? String == "A")
        #expect(first?["to"] as? String == "B")
        #expect(first?["link_text"] as? String == "File Provider")
        #expect(first?["type"] as? String == "page")
    }

    // MARK: - links.jsonl type field (Phase B)

    @Test func linksJSONLIncludesTypeField() {
        let links = [
            IndexGenerators.LinkRow(from: "A", to: "B", linkText: "x", type: "page"),
            IndexGenerators.LinkRow(from: "A", to: "S1", linkText: "src", type: "source"),
        ]
        let data = IndexGenerators.linksJSONL(links: links)
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        #expect(lines.count == 2)

        let first = try! JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        #expect(first?["type"] as? String == "page")

        let second = try! JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any]
        #expect(second?["type"] as? String == "source")
    }

    @Test func linksJSONLIsByteStable() {
        let links = [IndexGenerators.LinkRow(from: "A", to: "B", linkText: "x", type: "page")]
        #expect(IndexGenerators.linksJSONL(links: links) == IndexGenerators.linksJSONL(links: links))
    }

    // MARK: - sources.jsonl (Phase 5)

    @Test func sourcesJSONLEachLineValidWithCorrectCount() throws {
        let files = [
            IndexGenerators.SourceIndexRow(id: "F1", filename: "Report.pdf", ext: "pdf",
                                    mime: "application/pdf", byteSize: 1024,
                                    hasMarkdown: false),
            IndexGenerators.SourceIndexRow(id: "F2", filename: "notes", ext: "",
                                    mime: nil, byteSize: 0,
                                    hasMarkdown: false),
        ]
        let data = IndexGenerators.sourcesJSONL(sources: files)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasSuffix("\n"))

        let lines = text.split(separator: "\n")
        #expect(lines.count == files.count)

        let first = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        #expect(first?["id"] as? String == "F1")
        #expect(first?["name"] as? String == "Report.pdf")
        #expect(first?["path"] as? String == "sources/by-id/F1.pdf")
        #expect(first?["size"] as? Int == 1024)
        #expect(first?["mime"] as? String == "application/pdf")
        #expect(first?["has_markdown"] as? Bool == false)

        // Extension-less + nil mime: path omits the dot; mime is JSON null.
        let second = try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any]
        #expect(second?["path"] as? String == "sources/by-id/F2")
        #expect(second?["size"] as? Int == 0)
        #expect(second?["mime"] is NSNull)
        #expect(second?["has_markdown"] as? Bool == false)
    }

    @Test func sourcesJSONLIncludesHasMarkdown() throws {
        let files = [
            IndexGenerators.SourceIndexRow(id: "F1", filename: "a.pdf", ext: "pdf",
                                    mime: "application/pdf", byteSize: 100,
                                    hasMarkdown: true),
            IndexGenerators.SourceIndexRow(id: "F2", filename: "b.txt", ext: "txt",
                                    mime: "text/plain", byteSize: 50,
                                    hasMarkdown: false),
        ]
        let data = IndexGenerators.sourcesJSONL(sources: files)
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")

        let first = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        #expect(first?["has_markdown"] as? Bool == true)

        let second = try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any]
        #expect(second?["has_markdown"] as? Bool == false)
    }

    @Test func sourcesJSONLIsByteStable() {
        let files = [IndexGenerators.SourceIndexRow(id: "F1", filename: "x.txt", ext: "txt",
                                             mime: "text/plain", byteSize: 5,
                                             hasMarkdown: false)]
        #expect(IndexGenerators.sourcesJSONL(sources: files)
                == IndexGenerators.sourcesJSONL(sources: files))
    }

    // MARK: - sources.jsonl has_markdown with/without chain (integration with the store)

    @Test func sourcesJSONLHasMarkdownTrueWhenChainExists() throws {
        let store = try tempStore()
        // Add a source and append a processed-markdown version to create a chain.
        let ingested = try store.addSource(filename: "doc.md", data: Data("hello".utf8))
        try store.appendProcessedMarkdown(
            sourceID: ingested.id, content: "v1", origin: .extraction, note: nil)
        let sources = try store.listAllSourcesOrderedByID()
        #expect(sources.count == 1)
        #expect(sources[0].hasMarkdown == true)

        let data = IndexGenerators.sourcesJSONL(sources: sources)
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        let obj = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        #expect(obj?["has_markdown"] as? Bool == true)
    }

    @Test func sourcesJSONLHasMarkdownFalseWhenNoChain() throws {
        let store = try tempStore()
        // Add a source without any processed-markdown version.
        _ = try store.addSource(filename: "plain.pdf", data: Data("%PDF".utf8))
        let sources = try store.listAllSourcesOrderedByID()
        #expect(sources.count == 1)
        #expect(sources[0].hasMarkdown == false)

        let data = IndexGenerators.sourcesJSONL(sources: sources)
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        let obj = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        #expect(obj?["has_markdown"] as? Bool == false)
    }

    // MARK: - Determinism

    @Test func bytesAreDeterministicForFixedInput() {
        let pages = [page("A", "Home", updatedAt: 1), page("B", "Other", updatedAt: 2)]
        let date = Date(timeIntervalSince1970: 12345)
        #expect(IndexGenerators.manifest(pages: pages, sourceCount: 1, chatCount: 0, generatedAt: date)
                == IndexGenerators.manifest(pages: pages, sourceCount: 1, chatCount: 0, generatedAt: date))
        #expect(IndexGenerators.pagesJSONL(pages: pages) == IndexGenerators.pagesJSONL(pages: pages))
        let links = [IndexGenerators.LinkRow(from: "A", to: "B", linkText: "x")]
        #expect(IndexGenerators.linksJSONL(links: links) == IndexGenerators.linksJSONL(links: links))
        let sources = [IndexGenerators.SourceIndexRow(id: "S1", filename: "r.pdf", ext: "pdf",
                                               mime: "application/pdf", byteSize: 100,
                                               hasMarkdown: true)]
        #expect(IndexGenerators.sourcesJSONL(sources: sources)
                == IndexGenerators.sourcesJSONL(sources: sources))
    }

    // MARK: - Counts match a seeded DB (integration with the store)

    @Test func countsMatchSeededDB() throws {
        let store = try tempStore()
        let a = try store.createPage(title: "A")
        _ = try store.createPage(title: "B")
        try store.replaceLinks(from: a.id, parsedLinks: [.init(target: "B", linkText: "B")])

        let pages = try store.listAllPagesOrderedByID()
        let links = try store.listAllLinks()

        let manifest = try JSONSerialization.jsonObject(
            with: IndexGenerators.manifest(pages: pages, sourceCount: 0, chatCount: 0, generatedAt: Date())) as? [String: Any]
        #expect(manifest?["page_count"] as? Int == 2)

        let pagesLines = String(decoding: IndexGenerators.pagesJSONL(pages: pages), as: UTF8.self)
            .split(separator: "\n")
        #expect(pagesLines.count == 2)

        let linksLines = String(decoding: IndexGenerators.linksJSONL(links: links), as: UTF8.self)
            .split(separator: "\n")
        #expect(linksLines.count == 1)
    }

    // MARK: - Projected path names (Phase A Bug B fix)

    @Test func sourcesJSONLPathIsCorrect() {
        // The generator's advertised path must match what the File Provider projects.
        #expect(IndexGenerators.sourceIndexPath == "indexes/sources.jsonl")
        #expect(IndexGenerators.sourcesByIDPath == "sources/by-id")
    }

    @Test func manifestAdvertisesSourcePaths() throws {
        let data = IndexGenerators.manifest(pages: [], sourceCount: 0,
                                            chatCount: 0, generatedAt: Date(timeIntervalSince1970: 0))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let paths = obj?["paths"] as? [String: Any]
        #expect(paths?["sources_by_id"] as? String == "sources/by-id")
        #expect(paths?["source_index"] as? String == "indexes/sources.jsonl")
    }
}
