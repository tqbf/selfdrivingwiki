import Foundation
import Testing
@testable import WikiFSTypes

struct MarkdownFenceInfoTests {
    private func alias(_ rawValue: String) throws -> RendererFenceAlias {
        try #require(RendererFenceAlias(rawValue: rawValue))
    }

    @Test func acceptsUntitledShapeValidAlias() throws {
        #expect(MarkdownFenceInfo.parse("mermaid") == .rich(.init(alias: try alias("mermaid"))))
        #expect(MarkdownFenceInfo.parse(" JSONCANVAS ") == .rich(.init(alias: try alias("jsoncanvas"))))
        // Recognition is registry data now: an alias nobody claims still parses.
        #expect(MarkdownFenceInfo.parse("d2") == .rich(.init(alias: try alias("d2"))))
    }

    @Test func parsesQuotedTitleAndEscapes() throws {
        let parsed = MarkdownFenceInfo.parse(#"excalidraw "System \"architecture\" \\ diagram""#)
        #expect(parsed == .rich(.init(
            alias: try alias("excalidraw"),
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

    // MARK: - Alias token validation

    @Test(arguments: ["mermaid", "jsoncanvas", "excalidraw", "d2", "a", "ab2", String(repeating: "a", count: 32)])
    func acceptsValidAliasTokens(String: __shared String) {
        #expect(RendererFenceAlias(rawValue: String) != nil)
    }

    @Test(arguments: [
        "",                                 // empty
        String(repeating: "a", count: 33),  // too long
        "D2",                               // uppercase
        "text-diagram",                     // hyphen
        "c++",                              // punctuation
        "plántuml",                        // non-ASCII
        "graph.zh",                         // dot
    ])
    func rejectsInvalidAliasTokens(String: __shared String) {
        #expect(RendererFenceAlias(rawValue: String) == nil)
    }

    @Test func validatingInvalidAliasThrowsTypedError() {
        #expect(throws: RendererValidationError.invalidFenceAlias("D2")) {
            try RendererFenceAlias(validating: "D2")
        }
    }

    // MARK: - Shape-only parse semantics

    @Test func reservedOrdinaryLanguageTokensStayUnrecognized() {
        // These labels keep their ordinary code-fence meaning; they can never
        // become rich fences no matter what a package claims.
        for token in ["html", "scala", "java", "swift", "json"] {
            #expect(MarkdownFenceInfo.parse(token) == .unrecognizedAlias(token))
            #expect(
                MarkdownFencedBlock.presentationPolicy(for: token) == .ordinaryCode)
        }
    }

    @Test func shapeInvalidTokensStayUnrecognized() {
        #expect(MarkdownFenceInfo.parse("c++") == .unrecognizedAlias("c++"))
        #expect(
            MarkdownFencedBlock.presentationPolicy(for: "c++")
                == .typedRawCodeFallback(.unsupportedAlias))
    }

    @Test func shapeValidUnclaimedAliasIsARichRequest() throws {
        // Whether a claimant exists is a registry lookup, not a parse result.
        let d2 = try alias("d2")
        let parsed = MarkdownFenceInfo.parse("d2")
        guard case .rich(let info) = parsed else {
            Issue.record("expected rich parse for shape-valid alias")
            return
        }
        #expect(info.alias == d2)
        let policy = MarkdownFencedBlock.presentationPolicy(for: "d2")
        #expect(policy == .hostApprovedRichRequest(d2))
    }
}

/// Alias token round-trip through Codable containers, pinning the wire shape
/// (`alias`, `inlineMIMEType`) that renderer package manifests declare.
struct RendererFenceClaimCodableTests {
    @Test func claimRoundTripsThroughJSON() throws {
        let claim = RendererFenceClaim(
            alias: try #require(RendererFenceAlias(rawValue: "d2")),
            inlineMIMEType: try #require(RendererMIMEType(rawValue: "text/plain")))
        let data = try JSONEncoder().encode(claim)
        let decoded = try JSONDecoder().decode(RendererFenceClaim.self, from: data)
        #expect(decoded == claim)

        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(object["alias"] == "d2")
        #expect(object["inlineMIMEType"] == "text/plain")
    }

    @Test func malformedAliasFailsClaimDecode() {
        let json = #"{"alias": "Not Valid", "inlineMIMEType": "text/plain"}"#
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(
                RendererFenceClaim.self,
                from: Data(json.utf8))
        }
    }
}
