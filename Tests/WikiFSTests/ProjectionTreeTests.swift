import FileProvider
import Foundation
import Testing
import WikiFSCore
@testable import WikiFSFileProvider

/// Characterization tests for the projection **tree** — `node(for:)` /
/// `children(of:)` / `contents(for:)` / the working set — the dispatch paths
/// `ProjectionTests` does NOT cover (those test only the pure `Identity` /
/// `sourceMarkdownNode` functions). Added in slice 2b Phase B as the
/// byte-identical contract for the descriptor refactor (Phase B.2): they
/// capture the CURRENT behavior; the refactor must keep them green, unchanged.
///
/// They rely on the `databaseURL` injection seam (Phase B.0) so the projection
/// is exercisable without the App Group sandbox (`ProjectionTests` could only
/// test pure functions before it).
struct ProjectionTreeTests {

    /// A seeded projection: two pages, a text source (no `.md` sibling), and a
    /// pdf source WITH a processed-markdown head (emits a `.md` sibling).
    private struct Seeded {
        let projection: Projection
        let store: SQLiteWikiStore
        let pages: [WikiPage]
        let textSource: SourceSummary
        let pdfSource: SourceSummary
    }

    private func seed() throws -> Seeded {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-proj-\(UUID().uuidString).sqlite")
        let store = try SQLiteWikiStore(databaseURL: url)
        let alpha = try store.createPage(title: "Alpha")
        try store.updatePage(id: alpha.id, title: "Alpha", body: "Alpha body")
        _ = try store.createPage(title: "Beta")
        let textSource = try store.addSource(
            filename: "notes.txt", data: Data("plain text".utf8), mimeType: "text/plain")
        let pdfSource = try store.addSource(
            filename: "doc.pdf", data: Data("%PDF-1.4 fake".utf8), mimeType: "application/pdf")
        _ = try store.appendProcessedMarkdown(
            sourceID: pdfSource.id, content: "# Extracted", origin: "test", note: nil)
        let pages = try store.listAllPagesOrderedByID()   // ULID order
        let projection = Projection(wikiID: "proj-tree-\(UUID().uuidString)", databaseURL: url)
        return Seeded(projection: projection, store: store, pages: pages,
                      textSource: textSource, pdfSource: pdfSource)
    }

    @Test func rootChildrenIncludePagesAndSourcesFolders() throws {
        let s = try seed()
        let ids = Set(s.projection.children(of: .rootContainer).map(\.id))
        #expect(ids.contains(Projection.Identity.pages))
        #expect(ids.contains(Projection.Identity.sources))
    }

    @Test func pagesFolderHasByIDAndByTitle() throws {
        let s = try seed()
        let ids = s.projection.children(of: Projection.Identity.pages).map(\.id)
        #expect(ids == [Projection.Identity.pagesByID, Projection.Identity.pagesByTitle])
    }

    @Test func sourcesFolderHasByIDAndByName() throws {
        let s = try seed()
        let ids = s.projection.children(of: Projection.Identity.sources).map(\.id)
        #expect(ids == [Projection.Identity.sourcesByID, Projection.Identity.sourcesByName])
    }

    @Test func pagesByIDChildrenMatchPageCountAndULIDOrder() throws {
        let s = try seed()
        let nodes = s.projection.children(of: Projection.Identity.pagesByID)
        #expect(nodes.count == s.pages.count)
        let expected = s.pages.map { Projection.Identity.pageByID($0.id.rawValue) }
        #expect(nodes.map(\.id) == expected)
    }

    @Test func pageNodeResolvesWithContent() throws {
        let s = try seed()
        let page = s.pages[0]
        let id = Projection.Identity.pageByID(page.id.rawValue)
        guard let node = s.projection.node(for: id) else {
            Issue.record("page node not found"); return
        }
        #expect(node.parent == Projection.Identity.pagesByID)
        #expect(node.name == FilenameEscaping.byIDFilename(pageID: page.id.rawValue))
        let expected = Data(PageMarkdownFormat.fileContent(for: page).utf8)
        #expect(node.size == expected.count)
        #expect(s.projection.contents(for: id) == expected)
    }

    @Test func sourceNodeResolvesWithVerbatimContent() throws {
        let s = try seed()
        let id = Projection.Identity.sourceByID(s.pdfSource.id.rawValue)
        guard let node = s.projection.node(for: id) else {
            Issue.record("source node not found"); return
        }
        #expect(node.parent == Projection.Identity.sourcesByID)
        #expect(node.name == FilenameEscaping.byIDSourceFilename(
            sourceID: s.pdfSource.id.rawValue, ext: s.pdfSource.ext))
        let expected = try s.store.sourceContent(id: s.pdfSource.id)
        #expect(s.projection.contents(for: id) == expected)
    }

    @Test func markdownSiblingResolvesAndIsServed() throws {
        let s = try seed()
        let id = Projection.Identity.sourceMarkdownByID(s.pdfSource.id.rawValue)
        guard let node = s.projection.node(for: id) else {
            Issue.record("markdown node not found"); return
        }
        #expect(node.parent == Projection.Identity.sourcesByID)
        #expect(node.ingestedExt == "md")
        #expect(node.mimeType == "text/markdown")
        guard let head = try s.store.processedMarkdownHead(sourceID: s.pdfSource.id) else {
            Issue.record("markdown head not found"); return
        }
        #expect(s.projection.contents(for: id) == Data(head.content.utf8))
    }

    @Test func markdownSiblingAppearsForNonTextSource() throws {
        let s = try seed()
        let ids = Set(s.projection.children(of: Projection.Identity.sourcesByID).map(\.id))
        // pdf source (non-text) WITH a markdown head → verbatim + .md nodes.
        #expect(ids.contains(Projection.Identity.sourceByID(s.pdfSource.id.rawValue)))
        #expect(ids.contains(Projection.Identity.sourceMarkdownByID(s.pdfSource.id.rawValue)))
    }

    @Test func markdownSiblingAbsentForTextSource() throws {
        let s = try seed()
        let ids = Set(s.projection.children(of: Projection.Identity.sourcesByID).map(\.id))
        // text source → NO .md sibling (text/ is markdown-native).
        #expect(ids.contains(Projection.Identity.sourceByID(s.textSource.id.rawValue)))
        #expect(!ids.contains(Projection.Identity.sourceMarkdownByID(s.textSource.id.rawValue)))
    }

    @Test func workingSetIncludesFlatLeaves() throws {
        let s = try seed()
        let ids = Set(s.projection.children(of: .workingSet).map(\.id))
        #expect(ids.contains(Projection.Identity.pageByID(s.pages[0].id.rawValue)))
        #expect(ids.contains(Projection.Identity.sourceByID(s.pdfSource.id.rawValue)))
        #expect(ids.contains(Projection.Identity.sourceMarkdownByID(s.pdfSource.id.rawValue)))
    }

    // MARK: - Singleton docs + generated indexes (Phase C)

    @Test func rootChildrenOrderMatchesHistoricalLayout() throws {
        let s = try seed()
        let names = s.projection.children(of: .rootContainer).map(\.name)
        #expect(names == [
            "README.md", "CLAUDE.md", "AGENTS.md",
            "index.md", "log.md", "WIKI-STRUCTURE.md", "TREE.md",
            "manifest.json",
            "pages", "sources", "indexes"
        ])
    }

    @Test func readmeNodeIsStatic() throws {
        let s = try seed()
        guard let node = s.projection.node(for: Projection.Identity.readme) else {
            Issue.record("readme node not found"); return
        }
        #expect(node.name == "README.md")
        #expect(node.size == Projection.readmeBytes.count)
        #expect(s.projection.contents(for: Projection.Identity.readme) == Projection.readmeBytes)
    }

    @Test func systemPromptServesIdenticalBytesForBothAliases() throws {
        let s = try seed()
        let claude = s.projection.contents(for: Projection.Identity.claudeMD)
        let agents = s.projection.contents(for: Projection.Identity.agentsMD)
        #expect(claude != nil)
        #expect(claude == agents)
        #expect(s.projection.node(for: Projection.Identity.claudeMD)?.name == "CLAUDE.md")
        #expect(s.projection.node(for: Projection.Identity.agentsMD)?.name == "AGENTS.md")
    }

    @Test func wikiIndexNodeServesContent() throws {
        let s = try seed()
        let data = s.projection.contents(for: Projection.Identity.indexMD)
        #expect(data != nil)
        #expect(s.projection.node(for: Projection.Identity.indexMD)?.name == "index.md")
    }

    @Test func logNodeServesContent() throws {
        let s = try seed()
        let data = s.projection.contents(for: Projection.Identity.logMD)
        #expect(data != nil)
        #expect(s.projection.node(for: Projection.Identity.logMD)?.name == "log.md")
    }

    @Test func wikiStructureServesIdenticalBytesForBothAliases() throws {
        let s = try seed()
        let structure = s.projection.contents(for: Projection.Identity.wikiStructureMD)
        let tree = s.projection.contents(for: Projection.Identity.treeMD)
        #expect(structure != nil)
        #expect(structure == tree)
        #expect(s.projection.node(for: Projection.Identity.wikiStructureMD)?.name == "WIKI-STRUCTURE.md")
        #expect(s.projection.node(for: Projection.Identity.treeMD)?.name == "TREE.md")
    }

    @Test func indexesChildrenAreTheThreeJsonlFiles() throws {
        let s = try seed()
        let names = s.projection.children(of: Projection.Identity.indexes).map(\.name)
        #expect(names == ["pages.jsonl", "links.jsonl", "sources.jsonl"])
    }

    @Test func manifestNodeSizeMatchesContent() throws {
        let s = try seed()
        guard let node = s.projection.node(for: Projection.Identity.manifest) else {
            Issue.record("manifest node not found"); return
        }
        let data = s.projection.contents(for: Projection.Identity.manifest)
        #expect(data != nil)
        #expect(node.size == data?.count)
    }

    @Test func pagesJsonlCountMatchesPageCount() throws {
        let s = try seed()
        guard let data = s.projection.contents(for: Projection.Identity.indexPagesJSONL) else {
            Issue.record("pages.jsonl not found"); return
        }
        let lines = String(data: data, encoding: .utf8)?
            .split(separator: "\n").filter { !$0.isEmpty }
        #expect(lines?.count == s.pages.count)
    }

    @Test func sourcesJsonlCountMatchesSourceCount() throws {
        let s = try seed()
        guard let data = s.projection.contents(for: Projection.Identity.indexSourcesJSONL) else {
            Issue.record("sources.jsonl not found"); return
        }
        let lines = String(data: data, encoding: .utf8)?
            .split(separator: "\n").filter { !$0.isEmpty }
        // text source + pdf source = 2.
        #expect(lines?.count == 2)
    }

    @Test func workingSetExcludesReadmeAndIncludesDocsAndIndexes() throws {
        let s = try seed()
        let ids = Set(s.projection.children(of: .workingSet).map(\.id))
        // README is static — excluded from the working set.
        #expect(!ids.contains(Projection.Identity.readme))
        // Non-static singleton docs + generated indexes included.
        #expect(ids.contains(Projection.Identity.claudeMD))
        #expect(ids.contains(Projection.Identity.agentsMD))
        #expect(ids.contains(Projection.Identity.indexMD))
        #expect(ids.contains(Projection.Identity.logMD))
        #expect(ids.contains(Projection.Identity.wikiStructureMD))
        #expect(ids.contains(Projection.Identity.treeMD))
        #expect(ids.contains(Projection.Identity.manifest))
        #expect(ids.contains(Projection.Identity.indexPagesJSONL))
        #expect(ids.contains(Projection.Identity.indexLinksJSONL))
        #expect(ids.contains(Projection.Identity.indexSourcesJSONL))
    }
}
