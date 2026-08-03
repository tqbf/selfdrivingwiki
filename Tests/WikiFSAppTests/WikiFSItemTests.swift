#if os(macOS)
import FileProvider
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import WikiFSFileProvider

/// Tests for `WikiFSItem.contentType` — specifically the MIME-first ingested-file
/// branch from the content-type-over-extension plan.
struct WikiFSItemTests {

    @Test func contentTypePrefersMIMEOverExt() throws {
        // A source node with mimeType="application/pdf" but ingestedExt="txt"
        // should resolve to PDF, not plain text.
        let node = ProjectedNode.file(
            id: .rootContainer, parent: .rootContainer,
            name: "renamed.txt", size: 100,
            version: Data("1".utf8), metadataVersion: Data("m".utf8),
            created: Date(), modified: Date(),
            ingestedExt: "txt",
            mimeType: "application/pdf")
        let item = WikiFSItem(node: node)
        #expect(item.contentType == .pdf)
    }

    @Test func contentTypeFallsBackToExtWhenMIMENil() throws {
        // When mimeType is nil (pre-existing rows, or no magic-byte match),
        // fall back to the extension.
        let node = ProjectedNode.file(
            id: .rootContainer, parent: .rootContainer,
            name: "notes.md", size: 50,
            version: Data("1".utf8), metadataVersion: Data("m".utf8),
            created: Date(), modified: Date(),
            ingestedExt: "md",
            mimeType: nil)
        let item = WikiFSItem(node: node)
        // UTType for "md" → net.daringfireball.markdown (definitely not .data)
        #expect(item.contentType != .data)
    }

    @Test func contentTypeReturnsDataWhenBothUnknown() throws {
        // When both mimeType and ingestedExt are empty/unknown, fall back to .data
        // (generic binary).
        let node = ProjectedNode.file(
            id: .rootContainer, parent: .rootContainer,
            name: "mystery.blob", size: 200,
            version: Data("1".utf8), metadataVersion: Data("m".utf8),
            created: Date(), modified: Date(),
            ingestedExt: "",
            mimeType: nil)
        let item = WikiFSItem(node: node)
        #expect(item.contentType == .data)
    }

    @Test func contentTypeNotAffectedForNonIngestedNodes() throws {
        // Nodes without ingestedExt (pages, generated docs) are unaffected by the
        // MIME-first change — they use the name-suffix branches.
        let node = ProjectedNode.file(
            id: .rootContainer, parent: .rootContainer,
            name: "page.md", size: 80,
            version: Data("1".utf8), metadataVersion: Data("m".utf8),
            created: Date(), modified: Date(),
            ingestedExt: nil,
            mimeType: nil)
        let item = WikiFSItem(node: node)
        // Name-suffix branch: "page.md" → markdown type, not .data.
        #expect(item.contentType != .data)
        #expect(item.contentType != .folder)
    }
}
#endif
