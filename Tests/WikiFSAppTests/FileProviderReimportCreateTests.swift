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
struct FileProviderReimportCreateTests {

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

    private func seed() throws -> (projection: Projection, page: WikiPage) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-reimport-\(UUID().uuidString).sqlite")
        let store = try GRDBWikiStore(databaseURL: url)
        let page = try store.createPage(title: "Alpha")
        let projection = Projection(
            wikiID: WikiID(rawValue: "reimport-\(UUID().uuidString)"), databaseURL: url)
        return (projection, page)
    }

    private func name(of id: NSFileProviderItemIdentifier, in projection: Projection) throws -> String {
        try #require(projection.node(for: id)).name
    }

    @Test func reimportedFoldersMatchTheirProjectedNodes() throws {
        let (projection, _) = try seed()
        let pagesName = try name(of: Projection.Identity.pages, in: projection)
        let byIDName = try name(of: Projection.Identity.pagesByID, in: projection)

        let pages = FileProviderExtension.existingNode(
            forReimportOf: Template(pagesName, in: .rootContainer),
            options: .mayAlreadyExist, in: projection)
        let byID = FileProviderExtension.existingNode(
            forReimportOf: Template(byIDName, in: Projection.Identity.pages),
            options: .mayAlreadyExist, in: projection)

        #expect(pages?.id == Projection.Identity.pages)
        #expect(byID?.id == Projection.Identity.pagesByID)
    }

    @Test func reimportedPageMatchesItsByTitleNode() throws {
        let (projection, page) = try seed()
        let filename = FilenameEscaping.byTitleFilename(title: page.title, pageID: page.id.rawValue)

        let node = FileProviderExtension.existingNode(
            forReimportOf: Template(filename, in: Projection.Identity.pagesByTitle),
            options: .mayAlreadyExist, in: projection)

        #expect(node?.id == Projection.Identity.pageByTitle(page.id.rawValue))
        #expect(node?.isFolder == false)
    }

    @Test func userCreateWithoutMayAlreadyExistStaysRejected() throws {
        let (projection, _) = try seed()
        let pagesName = try name(of: Projection.Identity.pages, in: projection)

        let node = FileProviderExtension.existingNode(
            forReimportOf: Template(pagesName, in: .rootContainer),
            options: [], in: projection)

        #expect(node == nil)
    }

    @Test func reimportOfAnItemTheProjectionLacksStaysRejected() throws {
        let (projection, _) = try seed()

        let node = FileProviderExtension.existingNode(
            forReimportOf: Template("not-a-projected-file.md", in: .rootContainer),
            options: .mayAlreadyExist, in: projection)

        #expect(node == nil)
    }
}
#endif
