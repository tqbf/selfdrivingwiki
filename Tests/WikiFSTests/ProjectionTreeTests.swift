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
@Suite(.tags(.integration))
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

    @Test func byTitlePageRewritesLinksAndSizeMatchesBytes() throws {
        // A page body linking to another page (canonical ULID) and a source
        // (canonical ULID). The by-title view must rewrite both AND report a
        // size equal to the rewritten bytes — a mismatch truncates `cat` (#216).
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-proj-links-\(UUID().uuidString).sqlite")
        let store = try SQLiteWikiStore(databaseURL: url)
        let target = try store.createPage(title: "Target Page")
        let pdf = try store.addSource(
            filename: "paper.pdf", data: Data("%PDF fake".utf8), mimeType: "application/pdf")
        _ = try store.appendProcessedMarkdown(
            sourceID: pdf.id, content: "# Paper", origin: "test", note: nil)
        let src = try store.createPage(title: "Home")
        try store.updatePage(
            id: src.id, title: "Home",
            body: "See [[page:\(target.id.rawValue)|the target]] and "
                + "[[source:\(pdf.id.rawValue)|the paper]].")
        let projection = Projection(wikiID: "links-\(UUID().uuidString)", databaseURL: url)

        let id = Projection.Identity.pageByTitle(src.id.rawValue)
        guard let node = projection.node(for: id),
              let bytes = projection.contents(for: id) else {
            Issue.record("by-title node/content not found"); return
        }
        // Invariant: reported size == served bytes.
        #expect(node.size == bytes.count)

        let text = String(decoding: bytes, as: UTF8.self)
        // Page link → sibling; source link → climbs to sources/by-name.
        let targetFile = FilenameEscaping.byTitleFilename(
            title: "Target Page", pageID: target.id.rawValue)
        #expect(text.contains("[the target](\(targetFile.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!))"))
        #expect(text.contains("[the paper](../../sources/by-name/"))
        // No raw wikilinks remain.
        #expect(!text.contains("[[page:"))
        #expect(!text.contains("[[source:"))
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
        #expect(s.projection.contents(for: id) == Data(SourceMarkdownFormat.fileContent(for: head).utf8))
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

    // MARK: - Source image rewriting (snapshot siblings)

    @Test func snapshotImageSiblingResolvesAndRewritesPath() throws {
        // Create a markdown-native source with an image that has a sibling.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-image-snapshot-\(UUID().uuidString).sqlite")
        let store = try SQLiteWikiStore(databaseURL: url)

        // Create a fetch activity for the snapshot.
        let provenance = SourceProvenance(agentName: "test", activityKind: "website-snapshot")
        let activityID = try store.ensureFetchActivity(provenance: provenance)

        // Create the main markdown source WITH the activity (same pattern as storeSnapshot).
        let mdSource = try store.addSource(
            filename: "article.md", data: Data("![alt](assets/pic.png)".utf8),
            mimeType: "text/markdown", provenance: provenance, role: .primary,
            originalPath: nil, activityID: activityID)

        // Add the snapshot image as a sibling (same activity).
        _ = try store.addSnapshotImage(
            filename: "pic.png", data: Data("png-data".utf8), mimeType: "image/png",
            originalPath: "assets/pic.png", sourceURL: URL(string: "https://example.com/pic.png")!,
            activityID: activityID, role: .media)

        let projection = Projection(wikiID: "snapshot-\(UUID().uuidString)", databaseURL: url)

        // Verify by-name view: node size must match served content.
        let id = Projection.Identity.sourceByName(mdSource.id.rawValue)
        guard let node = projection.node(for: id) else {
            Issue.record("source node not found"); return
        }
        guard let bytes = projection.contents(for: id) else {
            Issue.record("source content not found"); return
        }

        // Invariant: reported size == served bytes.
        #expect(node.size == bytes.count)

        // The served content should have rewritten the image path.
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(!text.contains("assets/pic.png"))
        // Should contain the by-name filename of the sibling (without "assets/" prefix).
        #expect(text.contains("![alt](pic"))
    }

    @Test func sourceWithoutImageSiblingsIsUnaffected() throws {
        // A text source with NO image siblings should serve unmodified bytes,
        // and size should match byteSize, same as today (regression guard).
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-no-image-\(UUID().uuidString).sqlite")
        let store = try SQLiteWikiStore(databaseURL: url)

        let originalData = Data("This markdown has ![alt](missing.png) but no siblings.".utf8)
        let textSource = try store.addSource(
            filename: "lonely.md", data: originalData, mimeType: "text/markdown")

        let projection = Projection(wikiID: "no-image-\(UUID().uuidString)", databaseURL: url)

        // By-name view.
        let id = Projection.Identity.sourceByName(textSource.id.rawValue)
        guard let node = projection.node(for: id) else {
            Issue.record("source node not found"); return
        }
        guard let bytes = projection.contents(for: id) else {
            Issue.record("source content not found"); return
        }

        // Both size and content must be unchanged.
        #expect(node.size == originalData.count)
        #expect(bytes == originalData)
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
            "pages", "sources", "chats", "bookmarks", "indexes"
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
        #expect(names == ["pages.jsonl", "links.jsonl", "sources.jsonl", "chats.jsonl"])
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

    // MARK: - Bookmarks projection (Phase D)

    /// Seed a wiki with a bookmark tree: a root folder "Research" holding a
    /// nested "Papers" folder, plus a page ref and a source ref at the root.
    private struct Bookmarked {
        let projection: Projection
        let store: SQLiteWikiStore
        let pages: [WikiPage]
        let pdfSource: SourceSummary
        let folderNode: BookmarkNode
        let nestedNode: BookmarkNode
        let pageRefNode: BookmarkNode
        let sourceRefNode: BookmarkNode
    }

    private func seedBookmarks() throws -> Bookmarked {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-bm-\(UUID().uuidString).sqlite")
        let store = try SQLiteWikiStore(databaseURL: url)
        let alpha = try store.createPage(title: "Alpha")
        try store.updatePage(id: alpha.id, title: "Alpha", body: "Alpha body")
        let pdfSource = try store.addSource(
            filename: "doc.pdf", data: Data("%PDF-1.4 fake".utf8),
            mimeType: "application/pdf")
        let pages = try store.listAllPagesOrderedByID()
        let folderNode = try store.createBookmarkNode(
            parentID: nil, position: 0, kind: .folder, label: "Research", targetID: nil)
        let pageRefNode = try store.createBookmarkNode(
            parentID: nil, position: 1, kind: .pageRef, label: nil, targetID: pages[0].id)
        let sourceRefNode = try store.createBookmarkNode(
            parentID: nil, position: 2, kind: .sourceRef, label: nil, targetID: pdfSource.id)
        let nestedNode = try store.createBookmarkNode(
            parentID: folderNode.id, position: 0, kind: .folder, label: "Papers", targetID: nil)
        let projection = Projection(wikiID: "proj-bm-\(UUID().uuidString)", databaseURL: url)
        return Bookmarked(projection: projection, store: store, pages: pages,
                          pdfSource: pdfSource, folderNode: folderNode, nestedNode: nestedNode,
                          pageRefNode: pageRefNode, sourceRefNode: sourceRefNode)
    }

    @Test func bookmarksFolderEnumeratesRootChildren() throws {
        let b = try seedBookmarks()
        let children = b.projection.children(of: Projection.Identity.bookmarks)
        // position order: folder, page ref, source ref.
        #expect(children.count == 3)
        #expect(children[0].name == "Research")
        #expect(children[0].isFolder)
        #expect(children[1].name == "Alpha.md")
        #expect(!children[1].isFolder)
        #expect(children[2].name == "doc.pdf")
        #expect(!children[2].isFolder)
    }

    @Test func nestedBookmarkFolderEnumeratesChildren() throws {
        let b = try seedBookmarks()
        let folderID = Projection.Identity.bookmarkFolder(b.nestedNode.id)
        let children = b.projection.children(of: folderID)
        // "Papers" folder has no children yet.
        #expect(children.isEmpty)
    }

    @Test func bookmarkFolderNodeResolves() throws {
        let b = try seedBookmarks()
        let id = Projection.Identity.bookmarkFolder(b.folderNode.id)
        guard let node = b.projection.node(for: id) else {
            Issue.record("folder node not found"); return
        }
        #expect(node.isFolder)
        #expect(node.name == "Research")
        #expect(node.parent == Projection.Identity.bookmarks)
    }

    @Test func bookmarkPageRefServesTargetContent() throws {
        let b = try seedBookmarks()
        let id = Projection.Identity.bookmarkPageRef(b.pageRefNode.id)
        guard let node = b.projection.node(for: id) else {
            Issue.record("page ref node not found"); return
        }
        #expect(!node.isFolder)
        #expect(node.name == "Alpha.md")
        let expected = Data(PageMarkdownFormat.fileContent(for: b.pages[0]).utf8)
        #expect(b.projection.contents(for: id) == expected)
    }

    @Test func bookmarkSourceRefServesTargetContent() throws {
        let b = try seedBookmarks()
        let id = Projection.Identity.bookmarkSourceRef(b.sourceRefNode.id)
        guard let node = b.projection.node(for: id) else {
            Issue.record("source ref node not found"); return
        }
        #expect(!node.isFolder)
        #expect(node.name == "doc.pdf")
        let expected = try b.store.sourceContent(id: b.pdfSource.id)
        #expect(b.projection.contents(for: id) == expected)
    }

    @Test func staleBookmarkRefRendersPlaceholder() throws {
        let b = try seedBookmarks()
        // A ref to a page that doesn't exist.
        let stale = try b.store.createBookmarkNode(
            parentID: nil, position: 99, kind: .pageRef, label: nil,
            targetID: PageID(rawValue: "does-not-exist"))
        let id = Projection.Identity.bookmarkPageRef(stale.id)
        guard let node = b.projection.node(for: id) else {
            Issue.record("stale node not found"); return
        }
        #expect(node.name == "Stale Reference.md")
        let content = b.projection.contents(for: id)
        #expect(content != nil)
        #expect(String(data: content!, encoding: .utf8)?.contains("deleted") == true)
    }

    @Test func workingSetIncludesAllBookmarkNodes() throws {
        let b = try seedBookmarks()
        let ids = Set(b.projection.children(of: .workingSet).map(\.id))
        #expect(ids.contains(Projection.Identity.bookmarkFolder(b.folderNode.id)))
        #expect(ids.contains(Projection.Identity.bookmarkFolder(b.nestedNode.id)))
        #expect(ids.contains(Projection.Identity.bookmarkPageRef(b.pageRefNode.id)))
        #expect(ids.contains(Projection.Identity.bookmarkSourceRef(b.sourceRefNode.id)))
    }

    @Test func emptyBookmarksFolderIsStillListedAtRoot() throws {
        let b = try seedBookmarks()
        // The bookmarks folder always appears at root even when empty — delete
        // all nodes and verify root children still lists it.
        for node in try b.store.listBookmarkNodes() {
            try b.store.deleteBookmarkNode(id: node.id)
        }
        let names = b.projection.children(of: .rootContainer).map(\.name)
        #expect(names.contains("bookmarks"))
        // The folder is now empty.
        #expect(b.projection.children(of: Projection.Identity.bookmarks).isEmpty)
    }

    @Test func bookmarkPageRefRewritesLinksAndSizeMatchesBytes() throws {
        // A page body linking to another page (canonical ULID). The bookmark
        // pageRef must rewrite [[page:...]] → relative links and report a size
        // equal to the rewritten bytes — a mismatch truncates `cat` (#216).
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-bm-links-\(UUID().uuidString).sqlite")
        let store = try SQLiteWikiStore(databaseURL: url)
        let target = try store.createPage(title: "Target Page")
        let home = try store.createPage(title: "Home")
        try store.updatePage(
            id: home.id, title: "Home",
            body: "See [[page:\(target.id.rawValue)|t]].")
        let pageRefNode = try store.createBookmarkNode(
            parentID: nil, position: 0, kind: .pageRef, label: nil, targetID: home.id)
        let projection = Projection(wikiID: "bm-links-\(UUID().uuidString)", databaseURL: url)

        let id = Projection.Identity.bookmarkPageRef(pageRefNode.id)
        guard let node = projection.node(for: id),
              let bytes = projection.contents(for: id) else {
            Issue.record("bookmark page ref node/content not found"); return
        }
        // Invariant: reported size == served bytes.
        #expect(node.size == bytes.count)

        let text = String(decoding: bytes, as: UTF8.self)
        // Page link → sibling (one ../ to climb from bookmarks/ to root).
        let targetFile = FilenameEscaping.byTitleFilename(
            title: "Target Page", pageID: target.id.rawValue)
        let encoded = targetFile.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
        #expect(text.contains("[t](../pages/by-title/\(encoded))"))
        // No raw wikilinks remain.
        #expect(!text.contains("[[page:"))
    }

    @Test func nestedBookmarkPageRefClimbsCorrectDepth() throws {
        // A page ref nested one level deep (inside a folder) must climb with
        // two `../` to reach the root.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-bm-nested-\(UUID().uuidString).sqlite")
        let store = try SQLiteWikiStore(databaseURL: url)
        let target = try store.createPage(title: "Target")
        let home = try store.createPage(title: "Home")
        try store.updatePage(
            id: home.id, title: "Home",
            body: "Link: [[page:\(target.id.rawValue)]].")
        let folder = try store.createBookmarkNode(
            parentID: nil, position: 0, kind: .folder, label: "Research", targetID: nil)
        let pageRefNode = try store.createBookmarkNode(
            parentID: folder.id, position: 0, kind: .pageRef, label: nil, targetID: home.id)
        let projection = Projection(wikiID: "bm-nested-\(UUID().uuidString)", databaseURL: url)

        let id = Projection.Identity.bookmarkPageRef(pageRefNode.id)
        guard let node = projection.node(for: id),
              let bytes = projection.contents(for: id) else {
            Issue.record("nested bookmark content not found"); return
        }
        // Byte-identity must hold at nested depth too (size path builds baseDir
        // from the same ancestor walk as the content path).
        #expect(node.size == bytes.count)
        let text = String(decoding: bytes, as: UTF8.self)
        // Two levels: bookmarks/Research/ → root → pages/by-title/ = ../../pages/by-title/
        #expect(text.contains("../../pages/by-title/"))
    }

    @Test func bookmarkChatRefRewritesLinksAndSizeMatchesBytes() throws {
        // A chat transcript containing a [[page:...]] link, bookmarked as a
        // chatRef, must rewrite the link AND keep size == served bytes (#216).
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-bm-chat-\(UUID().uuidString).sqlite")
        let store = try SQLiteWikiStore(databaseURL: url)
        let target = try store.createPage(title: "Referenced Page")
        let chat = try store.createChat(kind: .edit, title: "Chat With Link")
        _ = try store.appendChatMessages(
            chatID: chat.id,
            events: [.userText("See [[page:\(target.id.rawValue)|that page]]."),
                     .assistantText("Sure.")])
        let chatRefNode = try store.createBookmarkNode(
            parentID: nil, position: 0, kind: .chatRef, label: nil, targetID: chat.id)
        let projection = Projection(wikiID: "bm-chat-\(UUID().uuidString)", databaseURL: url)

        let id = Projection.Identity.bookmarkChatRef(chatRefNode.id)
        guard let node = projection.node(for: id),
              let bytes = projection.contents(for: id) else {
            Issue.record("bookmark chat ref node/content not found"); return
        }
        // Invariant: reported size == served bytes.
        #expect(node.size == bytes.count)
        let text = String(decoding: bytes, as: UTF8.self)
        // Root-level chatRef: one ../ to reach the pages view.
        #expect(text.contains("[that page](../pages/by-title/"))
        #expect(!text.contains("[[page:"))
    }

    @Test func bookmarkSourceRefIsLeftVerbatimWithSizeMatch() throws {
        // A bookmark sourceRef must serve verbatim sourceContent bytes unchanged,
        // and node.size must equal the byte count (#216).
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-bm-source-\(UUID().uuidString).sqlite")
        let store = try SQLiteWikiStore(databaseURL: url)
        let pdfBytes = Data("%PDF-1.4 test content".utf8)
        let pdf = try store.addSource(
            filename: "doc.pdf", data: pdfBytes, mimeType: "application/pdf")
        let sourceRefNode = try store.createBookmarkNode(
            parentID: nil, position: 0, kind: .sourceRef, label: nil, targetID: pdf.id)
        let projection = Projection(wikiID: "bm-source-\(UUID().uuidString)", databaseURL: url)

        let id = Projection.Identity.bookmarkSourceRef(sourceRefNode.id)
        guard let node = projection.node(for: id),
              let bytes = projection.contents(for: id) else {
            Issue.record("bookmark source ref node/content not found"); return
        }
        // Invariant: reported size == served bytes.
        #expect(node.size == bytes.count)
        // Verbatim bytes from sourceContent.
        let expected = try store.sourceContent(id: pdf.id)
        #expect(bytes == expected)
    }

    // MARK: - Chats projection (#119)

    /// A seeded projection with chats: two chats, the first carrying a short
    /// transcript. Mirrors `seed()` / `seedBookmarks()` (own temp DB + store).
    private struct Chatted {
        let projection: Projection
        let store: SQLiteWikiStore
        let chats: [ChatSummary]
    }

    /// Seed a wiki with two chats — the first with a two-message
    /// transcript, the second empty — so tree-shape and content tests have
    /// realistic rows.
    private func seedChats() throws -> Chatted {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-chat-\(UUID().uuidString).sqlite")
        let store = try SQLiteWikiStore(databaseURL: url)
        let first = try store.createChat(kind: .edit, title: "Test Chat")
        _ = try store.appendChatMessages(
            chatID: first.id, events: [.userText("Hello"), .assistantText("Hi there")])
        _ = try store.createChat(kind: .edit, title: "Second Chat")
        let chats = try store.listAllChatsOrderedByID()   // ULID (creation) order
        let projection = Projection(wikiID: "proj-chat-\(UUID().uuidString)", databaseURL: url)
        return Chatted(projection: projection, store: store, chats: chats)
    }

    @Test func chatsFolderResolvesAtRoot() throws {
        let c = try seedChats()
        guard let node = c.projection.node(for: Projection.Identity.chats) else {
            Issue.record("chats folder node not found"); return
        }
        #expect(node.parent == .rootContainer)
        #expect(node.name == "chats")
        #expect(node.isFolder)
    }

    @Test func chatsFolderHasByIDAndByName() throws {
        let c = try seedChats()
        let ids = c.projection.children(of: Projection.Identity.chats).map(\.id)
        #expect(ids == [Projection.Identity.chatsByID, Projection.Identity.chatsByName])
    }

    @Test func chatsByIDChildrenMatchChatCount() throws {
        let c = try seedChats()
        let nodes = c.projection.children(of: Projection.Identity.chatsByID)
        #expect(nodes.count == c.chats.count)
    }

    @Test func chatNodeResolvesWithContent() throws {
        let c = try seedChats()
        let chat = c.chats[0]
        let id = Projection.Identity.chatByID(chat.id.rawValue)
        guard let node = c.projection.node(for: id) else {
            Issue.record("chat-by-id node not found"); return
        }
        #expect(node.size > 0)
        guard let data = c.projection.contents(for: id),
              let markdown = String(data: data, encoding: .utf8) else {
            Issue.record("chat content not served"); return
        }
        #expect(markdown.contains(chat.title) == true)
    }

    @Test func chatByNameNodeResolves() throws {
        let c = try seedChats()
        let chat = c.chats[0]
        let id = Projection.Identity.chatByName(chat.id.rawValue)
        guard let node = c.projection.node(for: id) else {
            Issue.record("chat-by-name node not found"); return
        }
        #expect(node.size > 0)
        guard let data = c.projection.contents(for: id),
              let markdown = String(data: data, encoding: .utf8) else {
            Issue.record("chat-by-name content not served"); return
        }
        #expect(markdown.contains(chat.title) == true)
    }

    @Test func workingSetIncludesChatNodes() throws {
        let c = try seedChats()
        let ids = Set(c.projection.children(of: .workingSet).map(\.id))
        // Every chat appears in the working set under its by-id view.
        for chat in c.chats {
            #expect(ids.contains(Projection.Identity.chatByID(chat.id.rawValue)))
        }
    }

    @Test func emptyChatsFolderStillListedAtRoot() throws {
        // No chats at all, but the `chats` folder still appears at root.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-chat-empty-\(UUID().uuidString).sqlite")
        let store = try SQLiteWikiStore(databaseURL: url)
        let projection = Projection(wikiID: "proj-chat-empty-\(UUID().uuidString)", databaseURL: url)
        _ = store  // seed nothing
        let names = projection.children(of: .rootContainer).map(\.name)
        #expect(names.contains("chats"))
        #expect(projection.children(of: Projection.Identity.chatsByID).isEmpty)
    }

    @Test func chatsJsonlCountMatchesChatCount() throws {
        let c = try seedChats()
        // `chats.jsonl` is listed under `indexes/`.
        let indexIds = Set(c.projection.children(of: Projection.Identity.indexes).map(\.id))
        #expect(indexIds.contains(Projection.Identity.indexChatsJSONL))
        guard let data = c.projection.contents(for: Projection.Identity.indexChatsJSONL) else {
            Issue.record("chats.jsonl not served"); return
        }
        let lines = String(data: data, encoding: .utf8)?
            .split(separator: "\n").filter { !$0.isEmpty }
        #expect(lines?.count == c.chats.count)
    }
}
