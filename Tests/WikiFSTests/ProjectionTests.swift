import FileProvider
import Foundation
import Testing
import WikiFSCore
@testable import WikiFSFileProvider

/// Tests for `Projection.Identity` identifier construction and ULID extraction,
/// and `Projection.sourceMarkdownNode` construction — all of which are pure
/// functions testable without the File Provider runtime.
struct ProjectionTests {

    // MARK: - sourceMarkdownByID / sourceMarkdownByName round-trip

    @Test func sourceMarkdownByIDRoundTrip() {
        let ulid = "01KV6EAH410NWC9K9ZM44DNMXT"
        let id = Projection.Identity.sourceMarkdownByID(ulid)
        let extracted = Projection.Identity.sourceMarkdownULID(from: id)
        #expect(extracted == ulid)
    }

    @Test func sourceMarkdownByNameRoundTrip() {
        let ulid = "01KV6EAH410NWC9K9ZM44DNMXT"
        let id = Projection.Identity.sourceMarkdownByName(ulid)
        let extracted = Projection.Identity.sourceMarkdownULID(from: id)
        #expect(extracted == ulid)
    }

    // MARK: - sourceMarkdownULID extraction (non-matching identifiers)

    @Test func sourceMarkdownULIDReturnsNilForPageByID() {
        let pageID = Projection.Identity.pageByID("01KV6EAH410NWC9K9ZM44DNMXT")
        #expect(Projection.Identity.sourceMarkdownULID(from: pageID) == nil)
    }

    @Test func sourceMarkdownULIDReturnsNilForPageByTitle() {
        let pageTitle = Projection.Identity.pageByTitle("01KV6EAH410NWC9K9ZM44DNMXT")
        #expect(Projection.Identity.sourceMarkdownULID(from: pageTitle) == nil)
    }

    @Test func sourceMarkdownULIDReturnsNilForSourceByID() {
        let sourceID = Projection.Identity.sourceByID("01KV6EAH410NWC9K9ZM44DNMXT")
        #expect(Projection.Identity.sourceMarkdownULID(from: sourceID) == nil)
    }

    @Test func sourceMarkdownULIDReturnsNilForSourceByName() {
        let sourceName = Projection.Identity.sourceByName("01KV6EAH410NWC9K9ZM44DNMXT")
        #expect(Projection.Identity.sourceMarkdownULID(from: sourceName) == nil)
    }

    @Test func sourceMarkdownULIDReturnsNilForArbitraryIdentifier() {
        let arbitrary = NSFileProviderItemIdentifier("something-else")
        #expect(Projection.Identity.sourceMarkdownULID(from: arbitrary) == nil)
    }

    @Test func sourceMarkdownULIDReturnsNilForRootContainer() {
        #expect(Projection.Identity.sourceMarkdownULID(from: .rootContainer) == nil)
    }

    // MARK: - sourceMarkdownNode construction (by-id)

    @Test func sourceMarkdownNodeByIDFilenameIsULIDDotMD() {
        let sourceID = "01KV6EAH410NWC9K9ZM44DNMXT"
        let headID = "01KV9ABC410NWC9K9ZM44DNMXX"
        let createdAt = Date(timeIntervalSince1970: 1728000000)

        let source = SourceSummary(
            id: PageID(rawValue: sourceID),
            filename: "report.pdf",
            ext: "pdf",
            mimeType: "application/pdf",
            byteSize: 1000,
            createdAt: createdAt,
            updatedAt: createdAt,
            version: 1
        )

        let head = SourceMarkdownVersion(
            id: PageID(rawValue: headID),
            sourceID: PageID(rawValue: sourceID),
            parentID: nil,
            content: "# Processed Report\n\nThis is the extracted markdown.",
            origin: "extraction",
            note: nil,
            createdAt: createdAt
        )

        let identifier = Projection.Identity.sourceMarkdownByID(sourceID)
        let node = Projection.sourceMarkdownNode(for: identifier, source: source, head: head)

        // by-id filename is "<ulid>.md"
        #expect(node.name == "01KV6EAH410NWC9K9ZM44DNMXT.md")
        // parent is sourcesByID
        #expect(node.parent == Projection.Identity.sourcesByID)
        // contentVersion is Data(head.id.rawValue.utf8)
        #expect(node.contentVersion == Data(headID.utf8))
        // metadataVersion is also Data(head.id.rawValue.utf8)
        #expect(node.metadataVersion == Data(headID.utf8))
        // ingestedExt is "md"
        #expect(node.ingestedExt == "md")
        // mimeType is "text/markdown"
        #expect(node.mimeType == "text/markdown")
        // size is the frontmatter-wrapped content
        #expect(node.size == SourceMarkdownFormat.fileContent(for: head).utf8.count)
        // created and modified are head.createdAt
        #expect(node.created == createdAt)
        #expect(node.modified == createdAt)
        // not a folder
        #expect(!node.isFolder)
    }

    // MARK: - sourceMarkdownNode construction (by-name)

    @Test func sourceMarkdownNodeByNameUsesFilenameEscaping() {
        let sourceID = "01JABCDEFGHJKMNPQRSTVWXYZ0"
        let headID = "01JABCDEFGHJKMNPQRSTVWXYZ9"
        let createdAt = Date(timeIntervalSince1970: 1728000000)

        let source = SourceSummary(
            id: PageID(rawValue: sourceID),
            filename: "Trip Report.pdf",
            ext: "pdf",
            mimeType: "application/pdf",
            byteSize: 2000,
            createdAt: createdAt,
            updatedAt: createdAt,
            version: 1
        )

        let head = SourceMarkdownVersion(
            id: PageID(rawValue: headID),
            sourceID: PageID(rawValue: sourceID),
            parentID: nil,
            content: "Extracted content from Trip Report.",
            origin: "extraction",
            note: nil,
            createdAt: createdAt
        )

        let identifier = Projection.Identity.sourceMarkdownByName(sourceID)
        let node = Projection.sourceMarkdownNode(for: identifier, source: source, head: head)

        // by-name uses FilenameEscaping.byNameSourceFilename(filename:ext:sourceID:)
        let expectedName = FilenameEscaping.byNameSourceFilename(
            filename: source.filename, ext: "md", sourceID: sourceID)
        #expect(node.name == expectedName)
        // parent is sourcesByName
        #expect(node.parent == Projection.Identity.sourcesByName)
        // contentVersion is Data(head.id.rawValue.utf8)
        #expect(node.contentVersion == Data(headID.utf8))
        // metadataVersion is also Data(head.id.rawValue.utf8)
        #expect(node.metadataVersion == Data(headID.utf8))
        // ingestedExt is "md"
        #expect(node.ingestedExt == "md")
        // mimeType is "text/markdown"
        #expect(node.mimeType == "text/markdown")
        // size is the frontmatter-wrapped content
        #expect(node.size == SourceMarkdownFormat.fileContent(for: head).utf8.count)
        // created and modified are head.createdAt
        #expect(node.created == createdAt)
        #expect(node.modified == createdAt)
        // not a folder
        #expect(!node.isFolder)
    }

    // MARK: - Cross-module prefix consistency

    /// The `source-by-name:` prefix is the contract between the app
    /// (`WikiFSContainerID`) and the File Provider extension
    /// (`Projection.Identity`). If these ever diverge,
    /// `FileProviderSpike.resolveSourceByNameURL(id:)` wonʼt resolve to real
    /// File Provider items, and the share sheet will see an empty file list.
    @Test func sourceByNamePrefixMatchesAcrossModules() {
        #expect(Projection.Identity.sourceByNamePrefix == WikiFSContainerID.sourceByNamePrefix)
        #expect(WikiFSContainerID.sourceByNamePrefix == "source-by-name:")
    }

    /// Same cross-module check for the `source-by-id:` prefix (already shared
    /// via `WikiFSContainerID.sourceByIDPrefix`).
    @Test func sourceByIDPrefixMatchesAcrossModules() {
        #expect(Projection.Identity.sourceByIDPrefix == WikiFSContainerID.sourceByIDPrefix)
    }
}
