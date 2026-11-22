#if os(macOS)
import FileProvider
import Foundation
import Testing
import WikiFSCore
@testable import WikiFSFileProvider

/// `FileProviderExtension.existingNode(forReimportOf:options:in:)`: during
/// `reimportItems(below:)` the daemon re-offers every file on disk through
/// `createItem` with `.mayAlreadyExist`. Each one must match the projected
/// node it came from. A read-only rejection throttles the subtree and the
/// reimport never repairs the mount.
@Suite(.serialized, .timeLimit(.minutes(3)))
struct FileProviderReimportCreateTests {

    /// A seeded projection whose socket fixture stays alive for the test's
    /// lifetime (the fixture's deinit stops the server and removes the
    /// container) — callers bind the whole value, never discard it.
    private struct Seed {
        let fixture: ProjectionSocketFixture
        var projection: Projection { fixture.projection }
        let page: WikiPage
    }

    /// The fields `existingNode` reads from a daemon-supplied template.
    private final class Template: NSObject, NSFileProviderItem {
        let itemIdentifier = NSFileProviderItemIdentifier("daemon-assigned-\(UUID().uuidString)")
        let parentItemIdentifier: NSFileProviderItemIdentifier
        let filename: String

        init(_ filename: String, in parent: NSFileProviderItemIdentifier) {
            self.filename = filename
            self.parentItemIdentifier = parent
        }
    }

    private func seed() throws -> Seed {
        let fixture = try ProjectionSocketFixture.make()
        return Seed(fixture: fixture, page: try fixture.store.createPage(title: "Alpha"))
    }

    private func name(of id: NSFileProviderItemIdentifier, in projection: Projection) throws -> String {
        try #require(projection.node(for: id)).name
    }

    @Test func reimportedFoldersMatchTheirProjectedNodes() throws {
        let s = try seed(); let projection = s.projection; defer { _ = s }
        let pagesName = try name(of: Projection.Identity.pages, in: projection)
        let byIDName = try name(of: Projection.Identity.pagesByID, in: projection)

        let pages = try FileProviderExtension.existingNode(
            forReimportOf: Template(pagesName, in: .rootContainer),
            options: .mayAlreadyExist, in: projection)
        let byID = try FileProviderExtension.existingNode(
            forReimportOf: Template(byIDName, in: Projection.Identity.pages),
            options: .mayAlreadyExist, in: projection)

        #expect(pages?.id == Projection.Identity.pages)
        #expect(byID?.id == Projection.Identity.pagesByID)
    }

    @Test func reimportedPageMatchesItsByTitleNode() throws {
        let s = try seed(); let projection = s.projection; let page = s.page; defer { _ = s }
        let filename = FilenameEscaping.byTitleFilename(title: page.title, pageID: page.id.rawValue)

        let node = try FileProviderExtension.existingNode(
            forReimportOf: Template(filename, in: Projection.Identity.pagesByTitle),
            options: .mayAlreadyExist, in: projection)

        #expect(node?.id == Projection.Identity.pageByTitle(page.id.rawValue))
        #expect(node?.isFolder == false)
    }

    /// By-id names carry the full ULID, so the match resolves the identifier
    /// directly instead of building the whole folder per create.
    @Test func reimportedByIDPageMatchesDirectly() throws {
        let s = try seed(); let projection = s.projection; let page = s.page; defer { _ = s }
        let filename = FilenameEscaping.byIDFilename(pageID: page.id.rawValue)

        let node = try FileProviderExtension.existingNode(
            forReimportOf: Template(filename, in: Projection.Identity.pagesByID),
            options: .mayAlreadyExist, in: projection)

        #expect(node?.id == Projection.Identity.pageByID(page.id.rawValue))
        #expect(Projection.byIDCandidates(named: filename, in: Projection.Identity.pagesByID)
                == [Projection.Identity.pageByID(page.id.rawValue)])
    }

    @Test func reimportedByIDSourceMatchesDirectly() throws {
        let fixture = try ProjectionSocketFixture.make()
        let projection = fixture.projection
        let source = try fixture.store.addSource(filename: "notes.txt", data: Data("abc".utf8), mimeType: "text/plain")
        let filename = FilenameEscaping.byIDSourceFilename(sourceID: source.id, ext: source.ext)

        let node = try FileProviderExtension.existingNode(
            forReimportOf: Template(filename, in: Projection.Identity.sourcesByID),
            options: .mayAlreadyExist, in: projection)

        #expect(node?.id == Projection.Identity.sourceByID(source.id.rawValue))
    }

    /// A by-id name whose ULID names no row, or whose suffix does not match
    /// the row's projected name, is not a child: no fallback scan.
    @Test func byIDNameThatResolvesToNoNodeStaysRejected() throws {
        let s = try seed(); let projection = s.projection; let page = s.page; defer { _ = s }

        let unknown = try FileProviderExtension.existingNode(
            forReimportOf: Template("01ZZZZZZZZZZZZZZZZZZZZZZZZ.md", in: Projection.Identity.pagesByID),
            options: .mayAlreadyExist, in: projection)
        let wrongSuffix = try FileProviderExtension.existingNode(
            forReimportOf: Template("\(page.id.rawValue).txt", in: Projection.Identity.pagesByID),
            options: .mayAlreadyExist, in: projection)
        let tooShort = try FileProviderExtension.existingNode(
            forReimportOf: Template("x.md", in: Projection.Identity.pagesByID),
            options: .mayAlreadyExist, in: projection)

        #expect(unknown == nil)
        #expect(wrongSuffix == nil)
        #expect(tooShort == nil)
    }

    @Test func userCreateWithoutMayAlreadyExistStaysRejected() throws {
        let s = try seed(); let projection = s.projection; defer { _ = s }
        let pagesName = try name(of: Projection.Identity.pages, in: projection)

        let node = try FileProviderExtension.existingNode(
            forReimportOf: Template(pagesName, in: .rootContainer),
            options: [], in: projection)

        #expect(node == nil)
    }

    @Test func reimportOfAnItemTheProjectionLacksStaysRejected() throws {
        let s = try seed(); let projection = s.projection; defer { _ = s }

        let node = try FileProviderExtension.existingNode(
            forReimportOf: Template("not-a-projected-file.md", in: .rootContainer),
            options: .mayAlreadyExist, in: projection)

        #expect(node == nil)
    }
}
#endif
