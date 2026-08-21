import Foundation
import Testing
@testable import WikiFSTypes

struct MarkdownFenceInfoTests {
    @Test func acceptsUntitledApprovedAlias() {
        #expect(MarkdownFenceInfo.parse("mermaid") == .rich(.init(alias: .mermaid)))
        #expect(MarkdownFenceInfo.parse(" JSONCANVAS ") == .rich(.init(alias: .jsoncanvas)))
    }

    @Test func parsesQuotedTitleAndEscapes() {
        let parsed = MarkdownFenceInfo.parse(#"excalidraw "System \"architecture\" \\ diagram""#)
        #expect(parsed == .rich(.init(
            alias: .excalidraw,
            displayTitle: #"System "architecture" \ diagram"#)))
    }

    @Test func rejectsMalformedTitleForms() {
        for info in [
            "mermaid System architecture",
            "mermaid \"\"",
            "mermaid \"unclosed",
            "mermaid \"title\" trailing"
        ] {
            #expect(MarkdownFenceInfo.parse(info) == .malformed)
        }
    }

    @Test func titledFencesUseAliasOnlyForCanonicalIdentity() throws {
        let identity = MarkdownDocumentIdentity(
            pageID: PageID(rawValue: "01J00000000000000000000001"),
            pageVersionID: PageVersionID(rawValue: "01J00000000000000000000002"))
        let bytes = Data("flowchart LR\nA --> B".utf8)
        let untitled = try MarkdownFencedBlock(
            documentIdentity: identity,
            parserOrdinal: 0,
            rawInfoString: "mermaid",
            bytes: bytes)
        let titled = try MarkdownFencedBlock(
            documentIdentity: identity,
            parserOrdinal: 0,
            rawInfoString: "mermaid \"System architecture\"",
            bytes: bytes)

        #expect(untitled.digest == titled.digest)
        #expect(untitled.blockID == titled.blockID)
        #expect(titled.fenceInfo?.displayTitle == "System architecture")
    }

    @Test func malformedTitleFallsBackToTypedRawCode() throws {
        let block = try MarkdownFencedBlock(
            documentIdentity: nil,
            parserOrdinal: 0,
            rawInfoString: "mermaid \"title\" trailing",
            bytes: Data("flowchart LR".utf8))

        #expect(block.presentationPolicy == .typedRawCodeFallback(.malformedInfoString))
        #expect(block.fenceInfo == nil)
    }
}
