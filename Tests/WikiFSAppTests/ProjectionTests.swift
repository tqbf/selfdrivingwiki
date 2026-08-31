#if os(macOS)
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
        #expect(id.rawValue == "source-markdown-by-id:\(ulid)")
        #expect(extracted == ulid)
    }

    @Test func sourceMarkdownByNameRoundTrip() {
        let ulid = "01KV6EAH410NWC9K9ZM44DNMXT"
        let id = Projection.Identity.sourceMarkdownByName(ulid)
        let extracted = Projection.Identity.sourceMarkdownULID(from: id)
        #expect(id.rawValue == "source-markdown-by-name:\(ulid)")
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
            id: SourceID(rawValue: sourceID),
            filename: "report.pdf",
            ext: "pdf",
            mimeType: "application/pdf",
            byteSize: 1000,
            createdAt: createdAt,
            updatedAt: createdAt,
            version: 1
        )

        let head = SourceMarkdownVersion(
            id: SourceMarkdownVersionID(rawValue: headID),
            sourceID: SourceID(rawValue: sourceID),
            parentID: nil,
            content: "# Processed Report\n\nThis is the extracted markdown.",
            origin: .extraction,
            note: nil,
            createdAt: createdAt
        )

        let identifier = Projection.Identity.sourceMarkdownByID(sourceID)
        let node = Projection.sourceMarkdownNode(for: identifier, source: source, head: head)

        // by-id filename is "<ulid>.md"
        #expect(node.name == "01KV6EAH410NWC9K9ZM44DNMXT.md")
        // parent is sourcesByID
        #expect(node.parent == Projection.Identity.sourcesByID)
        let item = WikiFSItem(node: node)
        #expect(item.itemIdentifier == identifier)
        #expect(item.parentItemIdentifier == Projection.Identity.sourcesByID)
        // contentVersion is Data(head.id.rawValue.utf8)
        #expect(node.contentVersion == Data(headID.utf8))
        // metadataVersion is also Data(head.id.rawValue.utf8)
        #expect(node.metadataVersion == Data(headID.utf8))
        // ingestedExt is "md"
        #expect(node.ingestedExt == "md")
        // mimeType is "text/markdown"
        #expect(node.mimeType == "text/markdown")
        // size matches the provided rendered bytes
        let rendered = SourceMarkdownFormat.fileContent(
            for: head,
            metadata: SourceOKFMetadata(
                title: source.effectiveName,
                generated: .init(by: OKFActor(rawValue: "process:extraction"), at: createdAt),
                sources: [.init(
                    resource: .bundlePath("/sources/by-id/\(sourceID).pdf"),
                    title: source.effectiveName
                )]
            )
        )
        let renderedData = Data(rendered.utf8)
        let sizedNode = Projection.sourceMarkdownNode(for: identifier, source: source, head: head, contentData: renderedData)
        #expect(sizedNode.size == renderedData.count)
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
            id: SourceID(rawValue: sourceID),
            filename: "Trip Report.pdf",
            ext: "pdf",
            mimeType: "application/pdf",
            byteSize: 2000,
            createdAt: createdAt,
            updatedAt: createdAt,
            version: 1
        )

        let head = SourceMarkdownVersion(
            id: SourceMarkdownVersionID(rawValue: headID),
            sourceID: SourceID(rawValue: sourceID),
            parentID: nil,
            content: "Extracted content from Trip Report.",
            origin: .extraction,
            note: nil,
            createdAt: createdAt
        )

        let identifier = Projection.Identity.sourceMarkdownByName(sourceID)
        let node = Projection.sourceMarkdownNode(for: identifier, source: source, head: head)

        // by-name uses FilenameEscaping.byNameSourceFilename(filename:ext:sourceID:)
        let expectedName = FilenameEscaping.byNameSourceFilename(
            filename: source.filename, ext: "md", sourceID: SourceID(rawValue: sourceID))
        #expect(node.name == expectedName)
        // parent is sourcesByName
        #expect(node.parent == Projection.Identity.sourcesByName)
        let item = WikiFSItem(node: node)
        #expect(item.itemIdentifier == identifier)
        #expect(item.parentItemIdentifier == Projection.Identity.sourcesByName)
        // contentVersion is Data(head.id.rawValue.utf8)
        #expect(node.contentVersion == Data(headID.utf8))
        // metadataVersion is also Data(head.id.rawValue.utf8)
        #expect(node.metadataVersion == Data(headID.utf8))
        // ingestedExt is "md"
        #expect(node.ingestedExt == "md")
        // mimeType is "text/markdown"
        #expect(node.mimeType == "text/markdown")
        let rendered = SourceMarkdownFormat.fileContent(
            for: head,
            metadata: SourceOKFMetadata(
                title: source.effectiveName,
                generated: .init(by: OKFActor(rawValue: "process:extraction"), at: createdAt),
                sources: [.init(
                    resource: .bundlePath("/sources/by-id/\(sourceID).pdf"),
                    title: source.effectiveName
                )]
            )
        )
        let renderedData = Data(rendered.utf8)
        let sizedNode = Projection.sourceMarkdownNode(for: identifier, source: source, head: head, contentData: renderedData)
        #expect(sizedNode.size == renderedData.count)
        // created and modified are head.createdAt
        #expect(node.created == createdAt)
        #expect(node.modified == createdAt)
        // not a folder
        #expect(!node.isFolder)
    }

    @Test func sourceMarkdownRevisionChangesContentVersionButNotMetadataVersion() {
        let source = SourceSummary(
            id: .init(rawValue: "source"), filename: "source.pdf", ext: "pdf",
            mimeType: "application/pdf", byteSize: 10,
            createdAt: .distantPast, updatedAt: .distantPast, version: 1)
        let head = SourceMarkdownVersion(
            id: .init(rawValue: "markdown"), sourceID: source.id, parentID: nil,
            content: "body", origin: .extraction, note: nil, createdAt: .distantPast)
        let byID = Projection.sourceMarkdownNode(
            for: Projection.Identity.sourceMarkdownByID(source.id.rawValue),
            source: source, head: head, projectionRevision: 3)
        let byName = Projection.sourceMarkdownNode(
            for: Projection.Identity.sourceMarkdownByName(source.id.rawValue),
            source: source, head: head, projectionRevision: 3)
        #expect(byID.contentVersion == Data("markdown:okf:3".utf8))
        #expect(byName.contentVersion == byID.contentVersion)
        #expect(byID.metadataVersion == Data("markdown".utf8))
        #expect(byName.metadataVersion == byID.metadataVersion)
    }

    @Test func pageRevisionChangesBothAliasContentVersionsAndZeroIsNeutral() {
        let page = WikiPage(
            id: .init(rawValue: "page"), title: "Page", slug: "page",
            bodyMarkdown: "body", createdAt: .distantPast,
            updatedAt: .distantPast, version: 7)
        let byID = Projection.pageFileNode(
            for: Projection.Identity.pageByID(page.id.rawValue), page: page,
            projectionRevision: 2)
        let byTitle = Projection.pageFileNode(
            for: Projection.Identity.pageByTitle(page.id.rawValue), page: page,
            projectionRevision: 2)
        let legacy = Projection.pageFileNode(
            for: Projection.Identity.pageByID(page.id.rawValue), page: page)
        #expect(byID.contentVersion == Data("7:okf:2".utf8))
        #expect(byTitle.contentVersion == byID.contentVersion)
        #expect(legacy.contentVersion == Data("7".utf8))
    }

    // MARK: - Cross-module prefix consistency

    /// The `source-by-name:` prefix is the contract between the app
    /// (`WikiFSContainerID`) and the File Provider extension
    /// (`Projection.Identity`). If these ever diverge,
    /// `FileProviderFacade.resolveSourceByNameURL(id:)` wonʼt resolve to real
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

    // MARK: - Provenance digest + `:prov:` contentVersion formulas (#927)

    @Test func provenanceDigestIsDeterministicAndSensitiveToEverySignal() {
        let base = OKFSourceReference(
            resource: .bundlePath("/sources/by-id/01SRC.md"),
            title: "Report",
            id: "01SRC",
            author: OKFActor(rawValue: "pdf-extractor/1.2.0"),
            usageCount: 3,
            lastModified: Date(timeIntervalSince1970: 1750000900),
            usageWindow: OKFUsageWindow(
                from: Date(timeIntervalSince1970: 1750000000),
                to: Date(timeIntervalSince1970: 2000000000)))
        let digest = Projection.provenanceDigest([base])
        // Deterministic: identical input → identical digest.
        #expect(Projection.provenanceDigest([base]) == digest)
        // Every signal family participates — mutating any one changes it.
        #expect(Projection.provenanceDigest([OKFSourceReference(
            resource: base.resource, title: base.title, id: "01OTHER",
            author: base.author, usageCount: base.usageCount,
            lastModified: base.lastModified, usageWindow: base.usageWindow)]) != digest)
        #expect(Projection.provenanceDigest([OKFSourceReference(
            resource: base.resource, title: base.title, id: base.id,
            author: base.author, usageCount: 4,
            lastModified: base.lastModified, usageWindow: base.usageWindow)]) != digest)
        // last_modified participates: a same-producer re-ingest advances the
        // digest by construction (AC.6) even when nothing else changes.
        #expect(Projection.provenanceDigest([OKFSourceReference(
            resource: base.resource, title: base.title, id: base.id,
            author: base.author, usageCount: base.usageCount,
            lastModified: base.lastModified!.addingTimeInterval(1),
            usageWindow: base.usageWindow)]) != digest)
        #expect(Projection.provenanceDigest([OKFSourceReference(
            resource: base.resource, title: base.title, id: base.id,
            author: base.author, usageCount: base.usageCount,
            lastModified: base.lastModified,
            usageWindow: OKFUsageWindow(from: base.usageWindow!.from,
                                        to: base.usageWindow!.to.addingTimeInterval(1)))]) != digest)
        #expect(Projection.provenanceDigest([OKFSourceReference(
            resource: base.resource, title: base.title, id: base.id,
            author: OKFActor(rawValue: "other-tool/2.0"),
            usageCount: base.usageCount,
            lastModified: base.lastModified, usageWindow: base.usageWindow)]) != digest)
        // Entry ORDER participates (the fold is sequence-sensitive).
        let second = OKFSourceReference(resource: .bundlePath("/sources/by-id/01SRC2.md"), title: "2")
        #expect(Projection.provenanceDigest([base, second])
                == Projection.provenanceDigest([base, second]))
        #expect(Projection.provenanceDigest([second, base])
                != Projection.provenanceDigest([base, second]))
    }

    @Test func pageProvDigestAppendsToBothRevisionShapes() {
        let page = WikiPage(
            id: .init(rawValue: "page"), title: "Page", slug: "page",
            bodyMarkdown: "body", createdAt: .distantPast,
            updatedAt: .distantPast, version: 7)
        let digest = "abc123"
        let byID = Projection.pageFileNode(
            for: Projection.Identity.pageByID(page.id.rawValue), page: page,
            provenanceDigest: digest)
        let withRevision = Projection.pageFileNode(
            for: Projection.Identity.pageByID(page.id.rawValue), page: page,
            projectionRevision: 2, provenanceDigest: digest)
        let byTitle = Projection.pageFileNode(
            for: Projection.Identity.pageByTitle(page.id.rawValue), page: page,
            projectionRevision: 2, provenanceDigest: digest)
        let legacy = Projection.pageFileNode(
            for: Projection.Identity.pageByID(page.id.rawValue), page: page)
        #expect(byID.contentVersion == Data("7:prov:abc123".utf8))
        #expect(withRevision.contentVersion == Data("7:okf:2:prov:abc123".utf8))
        // Both aliases share the same version (same content path, same digest).
        #expect(byTitle.contentVersion == withRevision.contentVersion)
        #expect(legacy.contentVersion == Data("7".utf8))
        // A different digest yields a different version — the coordination
        // contract the staleness regression tests rely on.
        let other = Projection.pageFileNode(
            for: Projection.Identity.pageByID(page.id.rawValue), page: page,
            provenanceDigest: "zzz999")
        #expect(other.contentVersion != byID.contentVersion)
    }

    @Test func sourceMarkdownProvDigestAppendsToBothRevisionShapes() {
        let source = SourceSummary(
            id: .init(rawValue: "source"), filename: "source.pdf", ext: "pdf",
            mimeType: "application/pdf", byteSize: 10,
            createdAt: .distantPast, updatedAt: .distantPast, version: 1)
        let head = SourceMarkdownVersion(
            id: .init(rawValue: "markdown"), sourceID: source.id, parentID: nil,
            content: "body", origin: .extraction, note: nil, createdAt: .distantPast)
        let bare = Projection.sourceMarkdownNode(
            for: Projection.Identity.sourceMarkdownByID(source.id.rawValue),
            source: source, head: head, provenanceDigest: "d1")
        let withRevision = Projection.sourceMarkdownNode(
            for: Projection.Identity.sourceMarkdownByID(source.id.rawValue),
            source: source, head: head, projectionRevision: 3, provenanceDigest: "d1")
        let byName = Projection.sourceMarkdownNode(
            for: Projection.Identity.sourceMarkdownByName(source.id.rawValue),
            source: source, head: head, projectionRevision: 3, provenanceDigest: "d1")
        let legacy = Projection.sourceMarkdownNode(
            for: Projection.Identity.sourceMarkdownByID(source.id.rawValue),
            source: source, head: head)
        #expect(bare.contentVersion == Data("markdown:prov:d1".utf8))
        #expect(withRevision.contentVersion == Data("markdown:okf:3:prov:d1".utf8))
        #expect(byName.contentVersion == withRevision.contentVersion)
        #expect(legacy.contentVersion == Data("markdown".utf8))
        // metadataVersion stays pinned to the head id — the digest advances
        // ONLY the content version (same convention as the :okf: revision).
        #expect(bare.metadataVersion == Data("markdown".utf8))
    }
}
#endif
