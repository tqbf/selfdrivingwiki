#if os(macOS)
import Foundation
import Testing
@testable import WikiFS
@testable import WikiFSCore

/// #1179: an import auto-extraction (or any derived-markdown write) never
/// touches the `sources` row, so the rebuilt `WikiStoreModel.sources` array can
/// be `==` to the previous one. A value-based `.onChange(of: store.sources)`
/// therefore never fires, and the reader keeps its stale `headVersion` (the raw
/// source) until the user re-extracts manually. The model bumps
/// `sourcesVersion` on every `reloadSources()` so views can observe
/// markdown-only changes. These tests pin that contract at the model seam.
@MainActor
struct SourceExtractionRefreshTests {

    /// A derived-markdown write must advance `sourcesVersion` even when the
    /// `sources` array is value-equal before and after the reload — the exact
    /// condition under which the old `onChange(of: store.sources)` stayed
    /// silent.
    @Test func derivedMarkdownWriteAdvancesSourcesVersionWithEqualSourcesArray() async throws {
        let store = try TestStoreFactory.inMemory()
        store.eventBus = WikiEventBus(wikiID: WikiID(rawValue: "extraction-refresh"))
        let model = WikiStoreModel(store: store)
        model.reloadFromStore()

        let source = try store.addSource(filename: "report.docx", data: Data("docx-bytes".utf8))
        try await waitUntil("source import reloads the model") {
            model.sources.contains { $0.id == source.id }
        }
        let baselineVersion = model.sourcesVersion
        let baselineSources = model.sources

        // The markdown-only write: extraction output persisted for the source,
        // exactly what `runImportExtraction` does after an import.
        let body = "# Report\n\nextracted markdown body"
        _ = try store.appendProcessedMarkdown(
            sourceID: source.id, content: body, origin: .extraction,
            note: "extract via docx-to-markdown")

        // The bus-driven reload must advance the counter...
        try await waitUntil("derived markdown write advances sourcesVersion") {
            model.sourcesVersion > baselineVersion
        }
        // ...while the `sources` array stays value-equal (no `sources` row
        // changed). A value-based onChange on the array itself could not have
        // fired under this condition — the regression from #1179.
        #expect(model.sources == baselineSources)

        // The reader's reload path resolves the new HEAD, so the view that
        // observes `sourcesVersion` shows the markdown, not the raw source.
        let summary = try #require(model.sources.first { $0.id == source.id })
        #expect(model.processedMarkdownHead(for: summary)?.content == body)
    }

    private func waitUntil(
        _ description: String, condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition() {
            guard Date() < deadline else {
                throw RefreshWaitError.timedOut(description)
            }
            await Task.yield()
        }
    }

    private enum RefreshWaitError: Error, LocalizedError {
        case timedOut(String)

        var errorDescription: String? {
            switch self {
            case .timedOut(let description): "Timed out waiting for \(description)."
            }
        }
    }
}
#endif
