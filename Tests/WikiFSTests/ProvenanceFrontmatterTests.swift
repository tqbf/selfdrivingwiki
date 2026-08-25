import Testing
import Foundation
@testable import WikiFSCore

/// Tests for OKF v0.2 frontmatter generation (#927).
@Suite struct ProvenanceFrontmatterTests {

    @Test func emitsOrderedPersistedTrustFields() throws {
        let page = samplePage()
        let earlier = OKFVerificationEvent(
            id: OKFVerificationID(rawValue: "01A"),
            by: try OKFVerifierIdentity("human:alice"),
            verifiedAt: Date(timeIntervalSince1970: 2_000_000_000),
            basis: .init(kind: .humanReview))
        let later = OKFVerificationEvent(
            id: OKFVerificationID(rawValue: "01B"),
            by: try OKFVerifierIdentity("checker/1.2"),
            verifiedAt: Date(timeIntervalSince1970: 2_000_000_100),
            basis: .init(kind: .sourceChecked))
        let trust = OKFConceptMetadata(
            status: .deprecated,
            staleAfter: Date(timeIntervalSince1970: 2_000_003_600),
            freshnessPolicy: .fixed(Date(timeIntervalSince1970: 2_000_003_600)),
            verifications: [later, earlier], projectionRevision: 4)
        let metadata = PageOKFMetadata(
            generated: .init(by: .init(rawValue: "human:user"), at: page.updatedAt),
            trust: trust)

        let markdown = PageMarkdownFormat.fileContent(for: page, metadata: metadata)
        let verified = try #require(markdown.range(of: "verified:"))
        let status = try #require(markdown.range(of: "status: deprecated"))
        let stale = try #require(markdown.range(of: "stale_after: 2033-05-18T04:33:20Z"))
        #expect(verified.lowerBound < status.lowerBound)
        #expect(status.lowerBound < stale.lowerBound)
        #expect(markdown.contains("  - by: \"human:alice\"\n    at: 2033-05-18T03:33:20Z"))
        #expect(markdown.contains("  - by: \"checker/1.2\"\n    at: 2033-05-18T03:35:00Z"))
    }

    @Test func correctedVerificationIsNotProjected() throws {
        let page = samplePage()
        let corrected = OKFVerificationEvent(
            id: OKFVerificationID(rawValue: "01A"),
            by: try OKFVerifierIdentity("human:alice"),
            verifiedAt: Date(timeIntervalSince1970: 2_000_000_000),
            basis: .init(kind: .humanReview),
            removedAt: Date(timeIntervalSince1970: 2_000_001_000))
        let metadata = PageOKFMetadata(
            generated: .init(by: .init(rawValue: "human:user"), at: page.updatedAt),
            trust: .init(verifications: [corrected]))
        #expect(!PageMarkdownFormat.fileContent(for: page, metadata: metadata).contains("verified:"))
    }

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
        #expect(md == """
        ---
        type: "Page"
        title: "Mars Terraforming"
        generated:
          by: "process:legacy-import"
          at: 2033-05-18T03:33:20Z
        ---

        # Mars Terraforming

        ## Phase 1

        Atmospheric processing.
        """)
    }

    @Test func pageFrontmatterWithCreatedBy() {
        let page = samplePage(createdBy: "user", lastEditedBy: "user")
        let md = PageMarkdownFormat.fileContent(for: page)
        #expect(md.contains("by: \"human:user\""))
        #expect(!md.contains("created_by:"))
        #expect(!md.contains("last_edited_by:"))
    }

    @Test func pageFrontmatterWithDifferentEditor() {
        let page = samplePage(createdBy: "user", lastEditedBy: "agent:ingest")
        let md = PageMarkdownFormat.fileContent(for: page)
        #expect(md.contains("by: \"process:agent:ingest\""))
        #expect(!md.contains("created_by:"))
        #expect(!md.contains("last_edited_by:"))
    }

    @Test func pageFrontmatterWithOnlyLastEditedBy() {
        let page = samplePage(createdBy: nil, lastEditedBy: "agent")
        let md = PageMarkdownFormat.fileContent(for: page)
        #expect(md.contains("by: \"process:agent\""))
    }

    @Test func pageFrontmatterBodyPreserved() {
        let page = samplePage()
        let md = PageMarkdownFormat.fileContent(for: page)
        #expect(md.contains("# Mars Terraforming"))
        #expect(md.contains("## Phase 1"))
        #expect(md.contains("Atmospheric processing."))
    }

    @Test func pageFrontmatterIncludesSourceConceptReferences() {
        let page = samplePage(createdBy: "chat:01CHAT")
        let md = PageMarkdownFormat.fileContent(
            for: page,
            metadata: PageOKFMetadata(
                generated: .init(by: OKFActor(rawValue: "process:chat:01CHAT"),
                                 at: Date(timeIntervalSince1970: 2000000000)),
                sources: [
                    .init(resource: .bundlePath("/sources/by-id/01SRC.md"),
                          title: "Flight Plan"),
                    .init(resource: .bundlePath("/sources/by-id/01SRC2.md"),
                          title: "Launch Checklist")
                ]
            )
        )

        #expect(md.contains("""
        sources:
          - resource: "/sources/by-id/01SRC.md"
            title: "Flight Plan"
          - resource: "/sources/by-id/01SRC2.md"
            title: "Launch Checklist"
        """))
        #expect(!md.contains("verified:"))
        #expect(!md.contains("status:"))
        #expect(!md.contains("stale_after:"))
    }

    // MARK: - Source markdown frontmatter

    private func sampleVersion(
        origin: SourceMarkdownOrigin = .extraction,
        technique: String? = "anthropic",
        note: String? = nil
    ) -> SourceMarkdownVersion {
        SourceMarkdownVersion(
            id: SourceMarkdownVersionID(rawValue: "01SMV"),
            sourceID: SourceID(rawValue: "01SRC"),
            parentID: nil,
            content: "# Extracted Content\n\nSome text.",
            origin: origin,
            note: note,
            createdAt: Date(timeIntervalSince1970: 1500000000),
            technique: technique
        )
    }

    @Test func sourceFrontmatterUsesOKFShape() {
        let ver = sampleVersion()
        let md = SourceMarkdownFormat.fileContent(
            for: ver,
            metadata: SourceOKFMetadata(
                title: "Saturn V.pdf",
                generated: .init(by: OKFActor(rawValue: "process:extraction"),
                                 at: Date(timeIntervalSince1970: 1500000000)),
                sources: [
                    .init(resource: .bundlePath("/sources/by-id/01SRC.pdf"),
                          title: "Saturn V.pdf")
                ]
            )
        )
        #expect(md == """
        ---
        type: "Source"
        title: "Saturn V.pdf"
        generated:
          by: "process:extraction"
          at: 2017-07-14T02:40:00Z
        sources:
          - resource: "/sources/by-id/01SRC.pdf"
            title: "Saturn V.pdf"
        ---

        # Extracted Content

        Some text.
        """)
    }

    @Test func sourceFrontmatterBodyPreserved() {
        let ver = sampleVersion()
        let md = SourceMarkdownFormat.fileContent(
            for: ver,
            metadata: SourceOKFMetadata(
                title: "Paper",
                generated: .init(by: OKFActor(rawValue: "process:extraction"),
                                 at: Date(timeIntervalSince1970: 1500000000)),
                sources: [.init(resource: .bundlePath("/sources/by-id/01SRC.pdf"),
                                title: "Paper.pdf")]
            )
        )
        #expect(md.contains("# Extracted Content"))
        #expect(md.contains("Some text."))
    }

    @Test func sourceFrontmatterOmitsFabricatedClaimsAndLegacyKeys() {
        let ver = sampleVersion(origin: .user, technique: nil, note: "kept local")
        let md = SourceMarkdownFormat.fileContent(
            for: ver,
            metadata: SourceOKFMetadata(
                title: "Edited notes",
                generated: .init(by: OKFActor(rawValue: "human:user"),
                                 at: Date(timeIntervalSince1970: 1500000000)),
                sources: [.init(resource: .bundlePath("/sources/by-id/01SRC.md"),
                                title: "Edited notes.md")]
            )
        )
        #expect(!md.contains("origin:"))
        #expect(!md.contains("date:"))
        #expect(!md.contains("technique:"))
        #expect(!md.contains("note:"))
        #expect(!md.contains("verified:"))
        #expect(!md.contains("status:"))
        #expect(!md.contains("stale_after:"))
    }

    @Test func sourceActorUsesProducerVersionWhenAvailable() {
        let actor = OKFActor.sourceActor(
            producerName: "anthropic",
            producerVersion: "claude-sonnet-4-5-20250929",
            fallbackOrigin: .extraction
        )
        #expect(actor.rawValue == "anthropic/claude-sonnet-4-5-20250929")
    }
}
