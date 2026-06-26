import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiCtlCore

/// Tests for MermaidValidator — block extraction (pure) + live merval validation
/// via JavaScriptCore. The validator loads the committed vendored bundle
/// (`Resources/merval.bundle.js`), which is the proof the feature runs with NO
/// Node installed: these tests execute in the `swift test` process, which has no
/// app bundle and no Node — only the macOS JavaScriptCore system framework.
struct MermaidValidatorTests {

    /// Resolve the committed bundle relative to this test file
    /// (Tests/WikiFSTests → ../../Resources/merval.bundle.js).
    private func bundleSource() -> String? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../Resources/merval.bundle.js")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func validator() throws -> MermaidValidator {
        guard let src = bundleSource(), !src.isEmpty else {
            throw ValidationFailure("Resources/merval.bundle.js not found or empty")
        }
        guard let v = MermaidValidator(jsSource: src) else {
            throw ValidationFailure("MermaidValidator failed to load __merval.validateMermaid")
        }
        return v
    }
    private struct ValidationFailure: Error { let msg: String; init(_ s: String) { msg = s } }

    // MARK: - Block extraction (pure)

    @Test func extractsMermaidBlockInnerSource() {
        let md = """
        Some prose.

        ```mermaid
        flowchart LR
            A --> B
        ```

        More prose.
        """
        #expect(MermaidValidator.mermaidBlocks(in: md) == ["flowchart LR\n    A --> B"])
    }

    @Test func ignoresNonMermaidFences() {
        let md = """
        ```swift
        let x = 1
        ```
        ```mermaid
        graph TD
            A --> B
        ```
        """
        #expect(MermaidValidator.mermaidBlocks(in: md).count == 1)
        #expect(MermaidValidator.mermaidBlocks(in: md)[0].hasPrefix("graph TD"))
    }

    @Test func handlesTildeFences() {
        let md = "~~~mermaid\nflowchart LR\n  A --> B\n~~~"
        #expect(MermaidValidator.mermaidBlocks(in: md) == ["flowchart LR\n  A --> B"])
    }

    @Test func multipleBlocksInOrder() {
        let md = "```mermaid\ngraph TD\nA-->B\n```\n\n```mermaid\nflowchart LR\nC-->D\n```"
        let blocks = MermaidValidator.mermaidBlocks(in: md)
        #expect(blocks.count == 2)
        #expect(blocks[0].hasPrefix("graph TD"))
        #expect(blocks[1].hasPrefix("flowchart LR"))
    }

    @Test func noMermaidReturnsEmpty() {
        #expect(MermaidValidator.mermaidBlocks(in: "# just a heading\n\nplain text").isEmpty)
    }

    @Test func crlfLineEndingsAreExtracted() {
        // CRLF (e.g. pasted content) must not defeat detection — the info string
        // is "mermaid", not "mermaid\r".
        let md = "```mermaid\r\nflowchart LR\r\n    A --> B\r\n```"
        let blocks = MermaidValidator.mermaidBlocks(in: md)
        #expect(blocks.count == 1)
        #expect(blocks[0].contains("A --> B"))
    }

    @Test func crlfInvalidBlockIsCaught() throws {
        let v = try validator()
        let md = "```mermaid\r\nflowchart LR\r\n  A B\r\n```"
        #expect(v.invalidBlocks(markdown: md).count == 1)
    }

    @Test func emptySourceReturnsNilValidator() {
        #expect(MermaidValidator(jsSource: "") == nil)
    }

    // MARK: - Live validation (JavaScriptCore)

    @Test func validFlowchartPasses() throws {
        let v = try validator()
        let md = "```mermaid\nflowchart LR\n  A[\"Start\"] --> B[\"End\"]\n```"
        let results = v.validate(markdown: md)
        #expect(results.count == 1)
        #expect(results[0].isValid)
        #expect(results[0].errors.isEmpty)
        #expect(results[0].diagramType == "flowchart")
    }

    @Test func validSequencePasses() throws {
        let v = try validator()
        let md = "```mermaid\nsequenceDiagram\n  A->>B: hello\n```"
        let results = v.validate(markdown: md)
        #expect(results.count == 1)
        #expect(results[0].isValid)
        #expect(results[0].diagramType == "sequence")
    }

    @Test func missingArrowIsInvalid() throws {
        let v = try validator()
        let md = "```mermaid\nflowchart LR\n  A B\n```"
        let bad = v.invalidBlocks(markdown: md)
        #expect(bad.count == 1)
        #expect(bad[0].isValid == false)
        #expect(!bad[0].errors.isEmpty)
        // merval reports a structural error code for the missing arrow.
        #expect(bad[0].errors.contains { $0.code == "MISSING_ARROW" })
    }

    @Test func invalidBlocksFiltersToOnlyBad() throws {
        let v = try validator()
        let md = """
        ```mermaid
        flowchart LR
            A["OK"] --> B["Good"]
        ```

        ```mermaid
        flowchart LR
            A B
        ```
        """
        let bad = v.invalidBlocks(markdown: md)
        #expect(bad.count == 1)
        #expect(bad[0].index == 1)   // the second block
    }

    @Test func noBlocksValidatesNothing() throws {
        let v = try validator()
        #expect(v.validate(markdown: "no diagrams here").isEmpty)
    }

    // MARK: - wikictl page upsert integration (abort on invalid)

    @Test func upsertAbortsOnInvalidMermaidBlock() throws {
        let v = try validator()
        let bad = "```mermaid\nflowchart LR\n  A B\n```"
        do {
            try PageCommand.abortOnInvalidMermaid(bad, validator: v)
            Issue.record("expected abortOnInvalidMermaid to throw on an invalid block")
        } catch let PageCommand.Failure.message(text) {
            #expect(text.contains("mermaid:"))
            #expect(text.contains("MISSING_ARROW"))
        }
    }

    @Test func upsertAllowsValidMermaid() throws {
        let v = try validator()
        let good = "```mermaid\nflowchart LR\n  A[\"X\"] --> B[\"Y\"]\n```"
        try PageCommand.abortOnInvalidMermaid(good, validator: v)   // no throw
    }

    @Test func upsertSkipsValidationWhenValidatorUnavailable() throws {
        // The unbundled path: nil validator → no-op (never blocks a save).
        let bad = "```mermaid\nflowchart LR\n  A B\n```"
        try PageCommand.abortOnInvalidMermaid(bad, validator: nil)   // no throw
    }

    @Test func upsertIgnoresBodiesWithoutMermaid() throws {
        let v = try validator()
        try PageCommand.abortOnInvalidMermaid("just prose, no diagrams", validator: v)
    }
}
