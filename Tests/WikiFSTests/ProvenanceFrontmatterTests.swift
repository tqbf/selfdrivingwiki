import Testing
import Foundation
@testable import WikiFSCore

/// Tests for provenance frontmatter generation (#131):
/// - `PageMarkdownFormat.fileContent` includes `created_by` / `last_edited_by`
///   when present, omits them when nil.
/// - `SourceMarkdownFormat.fileContent` includes `origin`, `date`, `technique`.
@Suite struct ProvenanceFrontmatterTests {

    // MARK: - Page frontmatter

    private func samplePage(
        createdBy: String? = nil,
        lastEditedBy: String? = nil
    ) -> WikiPage {
        WikiPage(
            id: PageID(rawValue: "01PAGE"),
            title: "Mars Terraforming",
            slug: "mars-terraforming",
            bodyMarkdown: "## Phase 1\n\nAtmospheric processing.",
            createdAt: Date(timeIntervalSince1970: 1000000000),
            updatedAt: Date(timeIntervalSince1970: 2000000000),
            version: 3,
            createdBy: createdBy,
            lastEditedBy: lastEditedBy
        )
    }

    @Test func pageFrontmatterWithoutProvenance() {
        let page = samplePage()
        let md = PageMarkdownFormat.fileContent(for: page)
        #expect(md.contains("---"))
        #expect(md.contains("title:"))
        #expect(md.contains("date:"))
        #expect(!md.contains("created_by:"))
        #expect(!md.contains("last_edited_by:"))
    }

    @Test func pageFrontmatterWithCreatedBy() {
        let page = samplePage(createdBy: "user", lastEditedBy: "user")
        let md = PageMarkdownFormat.fileContent(for: page)
        #expect(md.contains("created_by: user"))
        // last_edited_by is omitted when it equals created_by
        #expect(!md.contains("last_edited_by:"))
    }

    @Test func pageFrontmatterWithDifferentEditor() {
        let page = samplePage(createdBy: "user", lastEditedBy: "claude-sonnet-4-5-20250929")
        let md = PageMarkdownFormat.fileContent(for: page)
        #expect(md.contains("created_by: user"))
        #expect(md.contains("last_edited_by: claude-sonnet-4-5-20250929"))
    }

    @Test func pageFrontmatterWithOnlyLastEditedBy() {
        let page = samplePage(createdBy: nil, lastEditedBy: "agent")
        let md = PageMarkdownFormat.fileContent(for: page)
        #expect(!md.contains("created_by:"))
        #expect(md.contains("last_edited_by: agent"))
    }

    @Test func pageFrontmatterBodyPreserved() {
        let page = samplePage()
        let md = PageMarkdownFormat.fileContent(for: page)
        #expect(md.contains("# Mars Terraforming"))
        #expect(md.contains("## Phase 1"))
        #expect(md.contains("Atmospheric processing."))
    }

    // MARK: - Source markdown frontmatter

    private func sampleVersion(
        origin: SourceMarkdownOrigin = .extraction,
        technique: String? = "anthropic",
        note: String? = nil
    ) -> SourceMarkdownVersion {
        SourceMarkdownVersion(
            id: PageID(rawValue: "01SMV"),
            sourceID: PageID(rawValue: "01SRC"),
            parentID: nil,
            content: "# Extracted Content\n\nSome text.",
            origin: origin,
            note: note,
            createdAt: Date(timeIntervalSince1970: 1500000000),
            technique: technique
        )
    }

    @Test func sourceFrontmatterIncludesOriginAndDate() {
        let ver = sampleVersion()
        let md = SourceMarkdownFormat.fileContent(for: ver)
        #expect(md.contains("---"))
        #expect(md.contains("origin: extraction"))
        #expect(md.contains("date:"))
    }

    @Test func sourceFrontmatterIncludesTechnique() {
        let ver = sampleVersion(technique: "gemini")
        let md = SourceMarkdownFormat.fileContent(for: ver)
        #expect(md.contains("technique: gemini"))
    }

    @Test func sourceFrontmatterOmitsTechniqueWhenNil() {
        let ver = sampleVersion(technique: nil)
        let md = SourceMarkdownFormat.fileContent(for: ver)
        #expect(!md.contains("technique:"))
    }

    @Test func sourceFrontmatterIncludesNote() {
        let ver = sampleVersion(note: "Re-extracted with better model")
        let md = SourceMarkdownFormat.fileContent(for: ver)
        #expect(md.contains("note:"))
        #expect(md.contains("Re-extracted with better model"))
    }

    @Test func sourceFrontmatterBodyPreserved() {
        let ver = sampleVersion()
        let md = SourceMarkdownFormat.fileContent(for: ver)
        #expect(md.contains("# Extracted Content"))
        #expect(md.contains("Some text."))
    }

    @Test func sourceFrontmatterUserEdit() {
        let ver = sampleVersion(origin: .user, technique: nil)
        let md = SourceMarkdownFormat.fileContent(for: ver)
        #expect(md.contains("origin: user"))
        #expect(!md.contains("technique:"))
    }
}
