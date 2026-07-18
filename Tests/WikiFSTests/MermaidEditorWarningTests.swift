import Foundation
import Testing
@testable import WikiFSCore

/// In-app editor (non-blocking) warning path: `WikiStoreModel.save()` sets
/// `mermaidSaveWarning` for a broken ```mermaid block, clears it once fixed, and
/// clears it on a page switch. The validator is injected from the committed repo
/// bundle (`Resources/merval.bundle.js`), so these run under `swift test` with no
/// app bundle — the same JavaScriptCore-no-Node story as MermaidValidatorTests.
@MainActor
struct MermaidEditorWarningTests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-mermaid-warn-\(UUID().uuidString).sqlite")
    }

    /// Read the committed bundle relative to this test file and build a validator.
    private func repoValidator() throws -> MermaidValidator {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../Resources/merval.bundle.js")
        guard let src = try? String(contentsOf: url, encoding: .utf8), !src.isEmpty,
              let v = MermaidValidator(jsSource: src) else {
            throw Failure("Resources/merval.bundle.js unavailable or failed to load")
        }
        return v
    }
    private struct Failure: Error { let msg: String; init(_ s: String) { msg = s } }

    @Test func saveSetsWarningForBrokenDiagram() throws {
        let model = WikiStoreModel(store: try StoreBackend.current.makeStore(databaseURL: tempURL()))
        model.mermaidValidator = try repoValidator()
        model.newPage(title: "Diagrams")
        model.draftBody = "```mermaid\nflowchart LR\n  A B\n```"
        model.save()
        // Non-blocking: the save still happened, but the warning is surfaced.
        #expect(model.mermaidSaveWarning?.contains("MISSING_ARROW") == true)
    }

    @Test func saveClearsWarningOnceFixed() throws {
        let model = WikiStoreModel(store: try StoreBackend.current.makeStore(databaseURL: tempURL()))
        model.mermaidValidator = try repoValidator()
        model.newPage(title: "Diagrams")
        model.draftBody = "```mermaid\nflowchart LR\n  A B\n```"
        model.save()
        #expect(model.mermaidSaveWarning != nil)
        // Fix the block and re-save → warning clears.
        model.draftBody = "```mermaid\nflowchart LR\n  A[\"X\"] --> B[\"Y\"]\n```"
        model.save()
        #expect(model.mermaidSaveWarning == nil)
    }

    @Test func pageSwitchClearsStaleWarning() throws {
        let model = WikiStoreModel(store: try StoreBackend.current.makeStore(databaseURL: tempURL()))
        model.mermaidValidator = try repoValidator()
        model.newPage(title: "Bad")
        model.draftBody = "```mermaid\nflowchart LR\n  A B\n```"
        model.save()
        #expect(model.mermaidSaveWarning != nil)
        // Selecting another page reloads drafts, which must clear the stale banner.
        model.newPage(title: "Other")
        #expect(model.mermaidSaveWarning == nil)
    }

    @Test func noWarningForPageWithoutMermaid() throws {
        let model = WikiStoreModel(store: try StoreBackend.current.makeStore(databaseURL: tempURL()))
        model.mermaidValidator = try repoValidator()
        model.newPage(title: "Prose")
        model.draftBody = "# Just a heading\n\nNo diagrams here."
        model.save()
        #expect(model.mermaidSaveWarning == nil)
    }
}
