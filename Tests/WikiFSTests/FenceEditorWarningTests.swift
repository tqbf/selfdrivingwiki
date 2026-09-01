import Foundation
import Testing
@testable import WikiFSCore
import WikiFSMarkdown
import WikiFSTypes

/// In-app editor (non-blocking) warning path: `WikiStoreModel.save()` sets
/// `fenceSaveWarning` for a broken claimed fence, clears it once fixed, and
/// clears it on a page switch. The validator is injected from the committed
/// package assets (`RendererPackages/Mermaid`), so these run under
/// `swift test` with no app bundle — the same JavaScriptCore-no-Node story
/// as FenceSyntaxValidatorTests.
@MainActor
struct FenceEditorWarningTests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-fence-warn-\(UUID().uuidString).sqlite")
    }

    /// Read the committed package assets relative to this test file and build
    /// the fence validator the app wiring would inject.
    private func repoValidator() throws -> any FenceSyntaxValidating {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../RendererPackages/Mermaid")
        guard let engine = try? String(contentsOf: root.appendingPathComponent("mermaid.min.js"), encoding: .utf8),
              let wrapper = try? String(contentsOf: root.appendingPathComponent("validate.js"), encoding: .utf8),
              !engine.isEmpty, !wrapper.isEmpty,
              let runner = FenceSyntaxValidator(jsSources: [wrapper, engine], entryFunction: "__sdw_validate_fence") else {
            throw Failure("RendererPackages/Mermaid assets unavailable or failed to load")
        }
        return ScopedFenceValidator(runner: runner, coveredAliases: [ScopedFenceValidator.alias])
    }
    private struct Failure: Error { let msg: String; init(_ s: String) { msg = s } }

    /// The package-shaped seam the store consumes: one runner, the aliases
    /// the installed package claims.
    private struct ScopedFenceValidator: FenceSyntaxValidating {
        static let alias = try! RendererFenceAlias(validating: "mermaid")

        let runner: FenceSyntaxValidator
        let coveredAliases: Set<RendererFenceAlias>

        func fenceSaveWarning(for markdown: String) -> String? {
            guard coveredAliases.contains(Self.alias) else { return nil }
            let invalid = runner.invalidBlocks(markdown: markdown, alias: Self.alias)
            let described = FenceSyntaxValidator.describe(alias: Self.alias, invalid: invalid)
            return described.isEmpty ? nil : described
        }

        func validationSkipNotice(for markdown: String) -> String? { nil }
    }

    @Test func saveSetsWarningForBrokenDiagram() throws {
        let model = WikiStoreModel(store: try StoreBackend.current.makeStore(databaseURL: tempURL()))
        model.fenceSyntaxValidator = try repoValidator()
        model.newPage(title: "Diagrams")
        model.draftBody = "```mermaid\nflowchart LR\n  A[unclosed\n```"
        model.save()
        // Non-blocking: the save still happened, but the warning is surfaced.
        #expect(model.fenceSaveWarning != nil)
        #expect(model.fenceSaveWarning?.contains("PARSE_ERROR") == true)
    }

    @Test func saveClearsWarningOnceFixed() throws {
        let model = WikiStoreModel(store: try StoreBackend.current.makeStore(databaseURL: tempURL()))
        model.fenceSyntaxValidator = try repoValidator()
        model.newPage(title: "Diagrams")
        model.draftBody = "```mermaid\nflowchart LR\n  A[unclosed\n```"
        model.save()
        #expect(model.fenceSaveWarning != nil)
        // Fix the block and re-save → warning clears.
        model.draftBody = "```mermaid\nflowchart LR\n  A[\"X\"] --> B[\"Y\"]\n```"
        model.save()
        #expect(model.fenceSaveWarning == nil)
    }

    @Test func pageSwitchClearsStaleWarning() throws {
        let model = WikiStoreModel(store: try StoreBackend.current.makeStore(databaseURL: tempURL()))
        model.fenceSyntaxValidator = try repoValidator()
        model.newPage(title: "Bad")
        model.draftBody = "```mermaid\nflowchart LR\n  A[unclosed\n```"
        model.save()
        #expect(model.fenceSaveWarning != nil)
        // Selecting another page reloads drafts, which must clear the stale banner.
        model.newPage(title: "Other")
        #expect(model.fenceSaveWarning == nil)
    }

    @Test func noWarningForPageWithoutClaimedFence() throws {
        let model = WikiStoreModel(store: try StoreBackend.current.makeStore(databaseURL: tempURL()))
        model.fenceSyntaxValidator = try repoValidator()
        model.newPage(title: "Prose")
        model.draftBody = "# Just a heading\n\nNo diagrams here."
        model.save()
        #expect(model.fenceSaveWarning == nil)
    }

    @Test func nilValidatorSkipsWarning() throws {
        // The no-package path: no injected validator → the save proceeds and
        // no banner appears, exactly like the old nil-validator contract.
        let model = WikiStoreModel(store: try StoreBackend.current.makeStore(databaseURL: tempURL()))
        model.newPage(title: "Diagrams")
        model.draftBody = "```mermaid\nflowchart LR\n  A[unclosed\n```"
        model.save()
        #expect(model.fenceSaveWarning == nil)
    }
}
