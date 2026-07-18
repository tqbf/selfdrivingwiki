import Foundation
import Testing
@testable import WikiFSCore

/// In-app editor (non-blocking) markdown warning path: `WikiStoreModel.save()`
/// sets `markdownSaveWarning` for cosmetic issues, clears it once fixed, and the
/// save succeeds with the ORIGINAL text (the editor is the human escape hatch).
/// The linter is injected from the committed repo bundle
/// (`Resources/markdownlint.bundle.js`), so these run under `swift test` with no
/// app bundle — the same JavaScriptCore-no-Node story as MarkdownLinterTests.
///
/// Unlike the mermaid warning (computed synchronously), the markdown warning is
/// computed on a background `Task` (markdownlint is heavier than the fence
/// line-scan), so tests poll briefly for the async result.
@MainActor
struct MarkdownEditorWarningTests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-md-warn-\(UUID().uuidString).sqlite")
    }

    /// Read the committed bundle relative to this test file and build a linter.
    private func repoLinter() throws -> MarkdownLinter {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../Resources/markdownlint.bundle.js")
        guard let src = try? String(contentsOf: url, encoding: .utf8), !src.isEmpty,
              let l = MarkdownLinter(jsSource: src) else {
            throw Failure("Resources/markdownlint.bundle.js unavailable or failed to load")
        }
        return l
    }
    private struct Failure: Error { let msg: String; init(_ s: String) { msg = s } }

    @Test func saveSetsWarningForCosmeticIssues() async throws {
        let store = try StoreBackend.current.makeStore(databaseURL: tempURL())
        let model = WikiStoreModel(store: store)
        model.markdownLinter = try repoLinter()
        model.newPage(title: "Messy")
        model.draftBody = "#No space after hash"
        model.save()
        // The markdown warning is computed on a background Task — poll briefly.
        try await pollFor { model.markdownSaveWarning != nil }
        #expect(model.markdownSaveWarning?.contains("MD018") == true)
    }

    @Test func saveClearsWarningOnceFixed() async throws {
        let store = try StoreBackend.current.makeStore(databaseURL: tempURL())
        let model = WikiStoreModel(store: store)
        model.markdownLinter = try repoLinter()
        model.newPage(title: "FixMe")
        model.draftBody = "#No space"
        model.save()
        try await pollFor { model.markdownSaveWarning != nil }
        // Fix the issue and re-save → warning clears.
        model.draftBody = "# Fixed heading\n"
        model.save()
        try await pollFor { model.markdownSaveWarning == nil }
        #expect(model.markdownSaveWarning == nil)
    }

    @Test func saveSucceedsWithOriginalBody() async throws {
        let store = try StoreBackend.current.makeStore(databaseURL: tempURL())
        let model = WikiStoreModel(store: store)
        model.markdownLinter = try repoLinter()
        model.newPage(title: "Original")
        let messy = "#No space\ntrailing   \n"
        model.draftBody = messy
        model.save()
        // The in-app path saves the ORIGINAL text (no auto-fix). Re-read it
        // directly from the store (the model's draftBody IS the original).
        let id = try store.resolveTitleToID("Original")!
        let stored = try store.getPage(id: id).bodyMarkdown
        #expect(stored == messy)
    }

    @Test func fixMarkdownInDraftCleansAndSaves() async throws {
        let store = try StoreBackend.current.makeStore(databaseURL: tempURL())
        let model = WikiStoreModel(store: store)
        model.markdownLinter = try repoLinter()
        model.newPage(title: "FixMe")
        // Trailing whitespace on heading + body — fixes cleanly in one pass.
        model.draftBody = "# Title   \n\nText with trailing   \n"
        model.save()
        try await pollFor { model.markdownSaveWarning != nil }
        // Apply the fix button.
        model.fixMarkdownInDraft()
        // The draft body is now normalized (trailing whitespace stripped).
        #expect(!model.draftBody.contains("   "))
        #expect(model.draftBody.hasSuffix("\n"))
        // The stored body matches the fixed draft (save() was called).
        let id = try store.resolveTitleToID("FixMe")!
        let stored = try store.getPage(id: id).bodyMarkdown
        #expect(stored == model.draftBody)
        // The warning clears after the fix (fixed body has no findings).
        try await pollFor { model.markdownSaveWarning == nil }
        #expect(model.markdownSaveWarning == nil)
    }

    @Test func fixMarkdownInDraftIsNoOpForCleanBody() async throws {
        let store = try StoreBackend.current.makeStore(databaseURL: tempURL())
        let model = WikiStoreModel(store: store)
        model.markdownLinter = try repoLinter()
        model.newPage(title: "AlreadyClean")
        let clean = "# Title\n\nClean text.\n"
        model.draftBody = clean
        model.save()
        model.fixMarkdownInDraft()
        #expect(model.draftBody == clean)
    }

    @Test func noWarningForCleanPage() async throws {
        let store = try StoreBackend.current.makeStore(databaseURL: tempURL())
        let model = WikiStoreModel(store: store)
        model.markdownLinter = try repoLinter()
        model.newPage(title: "Clean")
        model.draftBody = "# Title\n\nSome paragraph text here.\n"
        model.save()
        try await pollFor { model.markdownSaveWarning == nil }
        #expect(model.markdownSaveWarning == nil)
    }

    @Test func noCrashWhenLinterUnavailable() throws {
        // The unbundled path: nil linter → no warning, no crash.
        let store = try StoreBackend.current.makeStore(databaseURL: tempURL())
        let model = WikiStoreModel(store: store)
        model.markdownLinter = nil
        model.newPage(title: "Unbundled")
        model.draftBody = "#No space"
        model.save()
        #expect(model.markdownSaveWarning == nil)
    }

    // MARK: - helpers

    /// Poll a condition on the main actor until it's true or a timeout elapses.
    /// The markdown warning is set asynchronously via a background `Task` +
    /// `@MainActor` hop, so we yield to let it complete.
    private func pollFor(
        _ condition: @MainActor () -> Bool,
        attempts: Int = 20,
        intervalMS: UInt64 = 25
    ) async throws {
        for _ in 0..<attempts {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(intervalMS))
        }
    }
}
