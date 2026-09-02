import Foundation
import Testing
@testable import WikiCtlCore
@testable import WikiFSCore
import WikiFSMarkdown
import WikiFSTypes

/// Tests for FenceSyntaxValidator — the format-neutral runner — driven by
/// the reviewed package's declared assets (engine + wrapper) from
/// `RendererPackages/Mermaid`. This proves the package contract works with
/// no Node installed: these tests execute in the `swift test` process, which
/// has no app bundle and no Node — only the macOS JavaScriptCore system
/// framework.
///
/// The alias under test is data: these fixtures declare what the package
/// claims, the runner has no mermaid knowledge of its own.
struct FenceSyntaxValidatorTests {
    private static let alias = try! RendererFenceAlias(validating: "mermaid")

    /// Resolve the committed package assets relative to this test file
    /// (Tests/WikiFSTests → ../../RendererPackages/Mermaid/…).
    private func packageValidator() throws -> FenceSyntaxValidator {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../RendererPackages/Mermaid")
        guard let engine = try? String(contentsOf: root.appendingPathComponent("mermaid.min.js"), encoding: .utf8),
              let wrapper = try? String(contentsOf: root.appendingPathComponent("validate.js"), encoding: .utf8),
              !engine.isEmpty, !wrapper.isEmpty else {
            throw ValidationFailure("RendererPackages/Mermaid assets unavailable")
        }
        guard let v = FenceSyntaxValidator(jsSources: [wrapper, engine], entryFunction: "__sdw_validate_fence") else {
            throw ValidationFailure("package wrapper failed to install the entry function")
        }
        return v
    }
    private struct ValidationFailure: Error { let msg: String; init(_ s: String) { msg = s } }

    /// A FenceSyntaxValidating stub with a fixed scope: it validates the
    /// mermaid alias (the one the reviewed package claims) through the real
    /// package runner, so the store/CLI seams stay package-shaped without a
    /// machine store in the test process.
    private struct PackageClaimValidator: FenceSyntaxValidating {
        let runner: FenceSyntaxValidator
        let coveredAliases: Set<RendererFenceAlias>

        func fenceSaveWarning(for markdown: String) -> String? {
            guard coveredAliases.contains(Self.alias) else { return nil }
            let invalid = runner.invalidBlocks(markdown: markdown, alias: Self.alias)
            let described = FenceSyntaxValidator.describe(alias: Self.alias, invalid: invalid)
            return described.isEmpty ? nil : described
        }

        func validationSkipNotice(for markdown: String) -> String? {
            let present = FenceSyntaxValidator.richFenceAliases(in: markdown)
            let uncovered = present.filter { coveredAliases.contains($0) == false }
            guard uncovered.isEmpty == false else { return nil }
            let names = uncovered.map(\.rawValue).joined(separator: ", ")
            return "validation skipped for \(names): no installed renderer package declares it"
        }

        static let alias = try! RendererFenceAlias(validating: "mermaid")
    }

    private func packageClaimValidator() throws -> PackageClaimValidator {
        PackageClaimValidator(runner: try packageValidator(), coveredAliases: [Self.alias])
    }

    // MARK: - Block extraction (pure, alias-parameterized)

    @Test func extractsClaimedBlockInnerSource() {
        let md = """
        Some prose.

        ```mermaid
        flowchart LR
            A --> B
        ```

        More prose.
        """
        #expect(FenceSyntaxValidator.blocks(in: md, alias: Self.alias) == ["flowchart LR\n    A --> B"])
    }

    @Test func extractionIsAliasScoped() {
        let md = """
        ```swift
        let x = 1
        ```
        ```mermaid
        graph TD
            A --> B
        ```
        ```d2
        x -> y
        ```
        """
        #expect(FenceSyntaxValidator.blocks(in: md, alias: Self.alias).count == 1)
        #expect(FenceSyntaxValidator.blocks(in: md, alias: Self.alias)[0].hasPrefix("graph TD"))
    }

    @Test func handlesTildeFences() {
        let md = "~~~mermaid\nflowchart LR\n  A --> B\n~~~"
        #expect(FenceSyntaxValidator.blocks(in: md, alias: Self.alias) == ["flowchart LR\n  A --> B"])
    }

    @Test func extractsTitledFencesWithCRLF() {
        let md = "~~~mermaid \"System architecture\"\r\nflowchart LR\r\n  A --> B\r\n~~~"
        #expect(FenceSyntaxValidator.blocks(in: md, alias: Self.alias) == ["flowchart LR\n  A --> B"])
    }

    @Test func multipleBlocksInOrder() {
        let md = "```mermaid\ngraph TD\nA-->B\n```\n\n```mermaid\nflowchart LR\nC-->D\n```"
        let blocks = FenceSyntaxValidator.blocks(in: md, alias: Self.alias)
        #expect(blocks.count == 2)
        #expect(blocks[0].hasPrefix("graph TD"))
        #expect(blocks[1].hasPrefix("flowchart LR"))
    }

    @Test func noClaimedFencesReturnsEmpty() {
        #expect(FenceSyntaxValidator.blocks(in: "# just a heading\n\nplain text", alias: Self.alias).isEmpty)
        #expect(FenceSyntaxValidator.blocks(in: "```swift\nlet x = 1\n```", alias: Self.alias).isEmpty)
    }

    @Test func crlfLineEndingsAreExtracted() {
        // CRLF (e.g. pasted content) must not defeat detection — the info string
        // is "mermaid", not "mermaid\r".
        let md = "```mermaid\r\nflowchart LR\r\n    A --> B\r\n```"
        let blocks = FenceSyntaxValidator.blocks(in: md, alias: Self.alias)
        #expect(blocks.count == 1)
        #expect(blocks[0].contains("A --> B"))
    }

    @Test func richFenceAliasesListsClaimableAliasesInOrder() {
        let md = "```d2\nx -> y\n```\n\n```mermaid\nA\n```\n\n```mermaid\nB\n```\n\n```swift\nlet x\n```"
        let aliases = FenceSyntaxValidator.richFenceAliases(in: md)
        #expect(aliases.count == 2)
        #expect(aliases[0].rawValue == "d2")
        #expect(aliases[1].rawValue == "mermaid")
        #expect(FenceSyntaxValidator.richFenceAliases(in: "```swift\nlet x\n```").isEmpty)
    }

    // MARK: - Runner construction

    @Test func emptySourcesReturnNilRunner() {
        #expect(FenceSyntaxValidator(jsSources: [], entryFunction: "__sdw_validate_fence") == nil)
        #expect(FenceSyntaxValidator(jsSources: [""], entryFunction: "__sdw_validate_fence") == nil)
    }

    @Test func unresolvableEntryFunctionReturnsNilRunner() throws {
        let engine = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("../../RendererPackages/Mermaid/mermaid.min.js"),
            encoding: .utf8)
        #expect(FenceSyntaxValidator(jsSources: [engine], entryFunction: "__absent_function") == nil)
    }

    // MARK: - Live validation (package engine + wrapper in JSC)

    @Test func validFlowchartPasses() throws {
        let v = try packageValidator()
        let md = "```mermaid\nflowchart LR\n  A[\"Start\"] --> B[\"End\"]\n```"
        let results = v.validate(markdown: md, alias: Self.alias)
        #expect(results.count == 1)
        #expect(results[0].isValid)
        #expect(results[0].errors.isEmpty)
        #expect(results[0].diagramType == "flowchart")
    }

    @Test func validSequencePasses() throws {
        let v = try packageValidator()
        let md = "```mermaid\nsequenceDiagram\n  A->>B: hello\n```"
        let results = v.validate(markdown: md, alias: Self.alias)
        #expect(results.count == 1)
        #expect(results[0].isValid)
        #expect(results[0].diagramType == "sequenceDiagram")
    }

    @Test func unclosedBracketIsInvalid() throws {
        let v = try packageValidator()
        let md = "```mermaid\nflowchart LR\n  A[unclosed\n```"
        let bad = v.invalidBlocks(markdown: md, alias: Self.alias)
        #expect(bad.count == 1)
        #expect(bad[0].isValid == false)
        #expect(!bad[0].errors.isEmpty)
        #expect(bad[0].errors.contains { $0.code == "PARSE_ERROR" })
    }

    @Test func invalidBlocksFiltersToOnlyBad() throws {
        let v = try packageValidator()
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
        let bad = v.invalidBlocks(markdown: md, alias: Self.alias)
        #expect(bad.count == 1)
        #expect(bad[0].index == 1)   // the second block
    }

    @Test func noBlocksValidatesNothing() throws {
        let v = try packageValidator()
        #expect(v.validate(markdown: "no diagrams here", alias: Self.alias).isEmpty)
    }

    @Test func crlfInvalidBlockIsCaught() throws {
        let v = try packageValidator()
        let md = "```mermaid\r\nflowchart LR\r\n  A[unclosed\r\n```"
        #expect(v.invalidBlocks(markdown: md, alias: Self.alias).count == 1)
    }

    // MARK: - Mermaid v11 syntax (the #669 regression, via the package engine)

    @Test func validV11ShapeSyntaxPasses() throws {
        // The CORRECT v11 form: A@{ shape: delay } — NO square brackets.
        let v = try packageValidator()
        let md = "```mermaid\nflowchart LR\n  A@{ shape: delay }\n```"
        let results = v.validate(markdown: md, alias: Self.alias)
        #expect(results.count == 1)
        #expect(results[0].isValid)
        #expect(results[0].errors.isEmpty)
    }

    @Test func validV11ShapeRectPasses() throws {
        let v = try packageValidator()
        let md = "```mermaid\nflowchart LR\n  A@{ shape: rect } --> B\n```"
        let results = v.validate(markdown: md, alias: Self.alias)
        #expect(results.count == 1)
        #expect(results[0].isValid)
        #expect(results[0].errors.isEmpty)
    }

    @Test func invalidBracketAtSyntaxIsCaught() throws {
        // The BRACKETED form A[@{ shape: delay }] is NOT valid mermaid syntax.
        let v = try packageValidator()
        let md = "```mermaid\nflowchart LR\n  A[@{ shape: delay }]\n```"
        let bad = v.invalidBlocks(markdown: md, alias: Self.alias)
        #expect(bad.count == 1)
        #expect(bad[0].isValid == false)
        #expect(!bad[0].errors.isEmpty)
    }

    // MARK: - describe(alias:invalid:) is data-driven

    @Test func describeCarriesTheAlias() {
        let issue = FenceSyntaxValidator.BlockResult.Issue(line: 2, code: "PARSE_ERROR", message: "boom")
        let result = FenceSyntaxValidator.BlockResult(index: 0, isValid: false, diagramType: nil, errors: [issue])
        let text = FenceSyntaxValidator.describe(alias: Self.alias, invalid: [result])
        #expect(text.hasPrefix("mermaid: 1 invalid diagram block(s):"))
        #expect(text.contains("block #1 (line 2) [PARSE_ERROR]: boom"))
        #expect(FenceSyntaxValidator.describe(alias: Self.alias, invalid: []).isEmpty)
    }

    // MARK: - wikictl page add integration (abort on invalid)

    @Test func upsertAbortsOnInvalidClaimedFence() throws {
        let v = try packageClaimValidator()
        let bad = "```mermaid\nflowchart LR\n  A[unclosed\n```"
        do {
            _ = try PageCommand.abortOnInvalidFence(bad, validator: v)
            Issue.record("expected abortOnInvalidFence to throw on an invalid block")
        } catch let PageCommand.Failure.message(text) {
            #expect(text.contains("mermaid:"))
            #expect(text.contains("PARSE_ERROR"))
        }
    }

    @Test func upsertAllowsValidClaimedFence() throws {
        let v = try packageClaimValidator()
        let good = "```mermaid\nflowchart LR\n  A[\"X\"] --> B[\"Y\"]\n```"
        _ = try PageCommand.abortOnInvalidFence(good, validator: v)   // no throw
    }

    @Test func upsertSkipsValidationWhenValidatorUnavailable() throws {
        // The no-package path: nil validator → no-op (never blocks a save).
        let bad = "```mermaid\nflowchart LR\n  A[unclosed\n```"
        #expect(try PageCommand.abortOnInvalidFence(bad, validator: nil) == nil)
    }

    @Test func upsertIgnoresBodiesWithoutClaimedFences() throws {
        let v = try packageClaimValidator()
        #expect(try PageCommand.abortOnInvalidFence("just prose, no diagrams", validator: v) == nil)
    }

    @Test func upsertNotifiesWhenNoPackageClaimsTheFence() throws {
        // The operator-accepted package-conditional guarantee: a
        // claimed-looking fence with no installed declaring package proceeds
        // with a one-line notice, not a silent pass and not a block.
        let v = PackageClaimValidator(runner: try packageValidator(), coveredAliases: [])
        let bad = "```mermaid\nflowchart LR\n  A[unclosed\n```"
        let notice = try PageCommand.abortOnInvalidFence(bad, validator: v)
        #expect(notice?.contains("validation skipped for mermaid") == true)
    }

    // MARK: - wikictl page add end-to-end (injected validator, real store)

    private func tempDB() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-fence-\(UUID().uuidString).sqlite")
    }

    @Test func upsertAbortsBeforeWritingAnInvalidBlock() throws {
        let v = try packageClaimValidator()
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
        let v = try packageClaimValidator()
        let store = try StoreBackend.current.makeStore(databaseURL: tempDB())
        let good = "# Diagrams\n\n```mermaid\nflowchart LR\n  A[\"X\"] --> B[\"Y\"]\n```"
        let result = try PageCommand.run(.add(id: nil, title: "Diagrams", body: .inline(good)),
                                         in: store, validator: v)
        #expect(result.didCommit)
        #expect(result.stderrOutput == nil)
        #expect(try store.listPages(sortBy: .lastUpdated).count == 1)
    }

    @Test func validV11ShapeSavesEndToEnd() throws {
        let v = try packageClaimValidator()
        let store = try StoreBackend.current.makeStore(databaseURL: tempDB())
        let good = "# Diagrams\n\n```mermaid\nflowchart LR\n  A@{ shape: delay }\n```"
        let result = try PageCommand.run(.add(id: nil, title: "V11", body: .inline(good)),
                                         in: store, validator: v)
        #expect(result.didCommit)
        #expect(try store.listPages(sortBy: .lastUpdated).count == 1)
    }

    @Test func uncoveredAliasSavesWithNotice() throws {
        let v = PackageClaimValidator(runner: try packageValidator(), coveredAliases: [])
        let store = try StoreBackend.current.makeStore(databaseURL: tempDB())
        let bad = "```mermaid\nflowchart LR\n  A[unclosed\n```"
        let result = try PageCommand.run(.add(id: nil, title: "Uncovered", body: .inline(bad)),
                                         in: store, validator: v)
        #expect(result.didCommit)
        #expect(result.stderrOutput?.contains("validation skipped for mermaid") == true)
        #expect(try store.listPages(sortBy: .lastUpdated).count == 1)
    }
}
