import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiCtlCore

/// Tests for MermaidValidator — block extraction (pure) + live mermaid v11
/// validation via JavaScriptCore. The validator loads the committed vendored
/// mermaid bundle (`Resources/mermaid.min.js`) — the SAME library the reader
/// uses to render — which is the proof the feature runs with NO Node installed:
/// these tests execute in the `swift test` process, which has no app bundle and
/// no Node — only the macOS JavaScriptCore system framework.
struct MermaidValidatorTests {

    /// Resolve the committed bundle relative to this test file
    /// (Tests/WikiFSTests → ../../Resources/mermaid.min.js).
    private func bundleSource() -> String? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../Resources/mermaid.min.js")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func validator() throws -> MermaidValidator {
        guard let src = bundleSource(), !src.isEmpty else {
            throw ValidationFailure("Resources/mermaid.min.js not found or empty")
        }
        guard let v = MermaidValidator(jsSource: src) else {
            throw ValidationFailure("MermaidValidator failed to load mermaid / install validateMermaid wrapper")
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
        let md = "```mermaid\r\nflowchart LR\r\n  A[unclosed\r\n```"
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
        #expect(results[0].diagramType == "sequenceDiagram")
    }

    @Test func missingArrowIsInvalid() throws {
        // Note (post-#669): mermaid is more lenient than the old merval was.
        // `flowchart LR\n  A B` is now VALID. Use a genuinely-invalid case
        // (unclosed `[`) instead — mermaid.parse() rejects it with PARSE_ERROR.
        let v = try validator()
        let md = "```mermaid\nflowchart LR\n  A[unclosed\n```"
        let bad = v.invalidBlocks(markdown: md)
        #expect(bad.count == 1)
        #expect(bad[0].isValid == false)
        #expect(!bad[0].errors.isEmpty)
        #expect(bad[0].errors.contains { $0.code == "PARSE_ERROR" })
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
            A[unclosed
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

    // MARK: - Mermaid v11 syntax (the #669 regression)

    @Test func validV11ShapeSyntaxPasses() throws {
        // The CORRECT v11 form: A@{ shape: delay } — NO square brackets.
        // This is what merval rejected and what mermaid v11.16.0 must accept.
        let v = try validator()
        let md = "```mermaid\nflowchart LR\n  A@{ shape: delay }\n```"
        let results = v.validate(markdown: md)
        #expect(results.count == 1)
        #expect(results[0].isValid)
        #expect(results[0].errors.isEmpty)
    }

    @Test func validV11ShapeRectPasses() throws {
        let v = try validator()
        let md = "```mermaid\nflowchart LR\n  A@{ shape: rect } --> B\n```"
        let results = v.validate(markdown: md)
        #expect(results.count == 1)
        #expect(results[0].isValid)
        #expect(results[0].errors.isEmpty)
    }

    @Test func invalidBracketAtSyntaxIsCaught() throws {
        // The BRACKETED form A[@{ shape: delay }] is NOT valid mermaid syntax
        // (the @{ … } attaches directly to the node id, no brackets). Documents
        // the bug-report example that was actually invalid.
        let v = try validator()
        let md = "```mermaid\nflowchart LR\n  A[@{ shape: delay }]\n```"
        let bad = v.invalidBlocks(markdown: md)
        #expect(bad.count == 1)
        #expect(bad[0].isValid == false)
        #expect(!bad[0].errors.isEmpty)
    }

    // MARK: - wikictl page add integration (abort on invalid)

    @Test func upsertAbortsOnInvalidMermaidBlock() throws {
        let v = try validator()
        let bad = "```mermaid\nflowchart LR\n  A[unclosed\n```"
        do {
            try PageCommand.abortOnInvalidMermaid(bad, validator: v)
            Issue.record("expected abortOnInvalidMermaid to throw on an invalid block")
        } catch let PageCommand.Failure.message(text) {
            #expect(text.contains("mermaid:"))
            #expect(text.contains("PARSE_ERROR"))
        }
    }

    @Test func upsertAllowsValidMermaid() throws {
        let v = try validator()
        let good = "```mermaid\nflowchart LR\n  A[\"X\"] --> B[\"Y\"]\n```"
        try PageCommand.abortOnInvalidMermaid(good, validator: v)   // no throw
    }

    @Test func upsertSkipsValidationWhenValidatorUnavailable() throws {
        // The unbundled path: nil validator → no-op (never blocks a save).
        let bad = "```mermaid\nflowchart LR\n  A[unclosed\n```"
        try PageCommand.abortOnInvalidMermaid(bad, validator: nil)   // no throw
    }

    @Test func upsertIgnoresBodiesWithoutMermaid() throws {
        let v = try validator()
        try PageCommand.abortOnInvalidMermaid("just prose, no diagrams", validator: v)
    }

    // MARK: - wikictl page add end-to-end (injected validator, real store)

    private func tempDB() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-mermaid-\(UUID().uuidString).sqlite")
    }

    @Test func upsertAbortsBeforeWritingAnInvalidBlock() throws {
        let v = try validator()
        let store = try StoreBackend.current.makeStore(databaseURL: tempDB())
        let bad = "```mermaid\nflowchart LR\n  A[unclosed\n```"
        do {
            _ = try PageCommand.run(.add(id: nil, title: "Diagrams", body: .inline(bad)),
                                    in: store, validator: v)
            Issue.record("expected upsert to abort before writing")
        } catch let PageCommand.Failure.message(text) {
            #expect(text.contains("PARSE_ERROR"))
        }
        // The hard guarantee: a rejected body left NO page behind.
        #expect(try store.listPages(sortBy: .lastUpdated).isEmpty)
    }

    @Test func upsertEndToEndWritesAValidDiagram() throws {
        let v = try validator()
        let store = try StoreBackend.current.makeStore(databaseURL: tempDB())
        let good = "# Diagrams\n\n```mermaid\nflowchart LR\n  A[\"X\"] --> B[\"Y\"]\n```"
        let result = try PageCommand.run(.add(id: nil, title: "Diagrams", body: .inline(good)),
                                         in: store, validator: v)
        #expect(result.didCommit)
        #expect(try store.listPages(sortBy: .lastUpdated).count == 1)
    }

    @Test func validV11ShapeSavesEndToEnd() throws {
        // The #669 fix's end-to-end proof: a body with the v11 shape syntax
        // (which merval rejected) upserts cleanly and the page is stored.
        let v = try validator()
        let store = try StoreBackend.current.makeStore(databaseURL: tempDB())
        let good = "# Diagrams\n\n```mermaid\nflowchart LR\n  A@{ shape: delay }\n```"
        let result = try PageCommand.run(.add(id: nil, title: "V11", body: .inline(good)),
                                         in: store, validator: v)
        #expect(result.didCommit)
        #expect(try store.listPages(sortBy: .lastUpdated).count == 1)
    }
}
