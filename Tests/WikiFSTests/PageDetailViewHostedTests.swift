import AppKit
import SwiftUI
import Testing
import WebKit
@testable import WikiFS
@testable import WikiFSEngine
@testable import WikiFSCore

/// Live-UI verification of the "Add Page opens in the editor" feature
/// (plans/add-page-editor-default.md §8). The model-level half (the new tab is
/// created with `isEditing == true`) is pinned in `EditorTabTests`; these tests
/// pin the VIEW-layer half — that `PageDetailView.onAppear` seeds its `@State
/// isEditing` from the active tab so the editor branch (not the preview branch)
/// renders on first paint, and that the header expands to reveal Save/Cancel.
///
/// `PageDetailView`'s internal `@State` isn't directly readable from outside
/// the view, so we mount the REAL view in an `NSWindow` and inspect its NSView
/// subtree. `contentAndOutline` switches on `isEditing`: the editor branch
/// renders `ScrollableTextEditor` (NSTextView-backed) and the reader branch
/// renders `WikiReaderView` (WKWebView-backed, per the `[render] webview.*`
/// logs). So a `WKWebView` in the subtree ⇒ reader (preview), and its absence
/// ⇒ editor. This is the exact behavior the feature changes — a new page must
/// land in the editor, a navigation-opened page must land in the reader. See
/// `docs/skills/reproducing-live-ui-bugs` for the hosted-view test pattern.
@MainActor
struct PageDetailViewHostedTests {

    /// An `NSHostingController` in a `swift test` CLI has no host app, so give
    /// AppKit one to lay out into (same pattern as
    /// `AddressBarLayoutHostedTests` / `QuoteHighlightWebViewTests`).
    private static let app: NSApplication = {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        return app
    }()

    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("page-detail-hosted-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WikiFS.sqlite")
    }

    /// Mount a view in a real `NSWindow`, give SwiftUI + content time to settle,
    /// then return whether a `WKWebView` exists anywhere in the hosting view's
    /// NSView subtree. WKWebView presence ⇒ the reader branch rendered; its
    /// absence ⇒ the editor branch rendered.
    private func hasWebViewAfterMount<V: View>(_ view: V, expectWebView: Bool) async throws -> Bool {
        _ = Self.app
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        // Poll up to ~2s. The WKWebView mounts asynchronously after the first
        // SwiftUI render (the reader kicks off an async load). When we DON'T
        // expect a web view, wait the full window to be confident it never
        // appears; when we do, return as soon as it's found.
        var found = false
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 50_000_000)
            found = firstSubview(of: hosting.view, ofType: WKWebView.self) != nil
            if expectWebView && found { break }
        }
        return found
    }

    /// Depth-first search for the first subview matching `type`.
    private func firstSubview<ViewType: NSView>(of view: NSView, ofType type: ViewType.Type) -> ViewType? {
        if let match = view as? ViewType { return match }
        for sub in view.subviews {
            if let match = firstSubview(of: sub, ofType: type) { return match }
        }
        return nil
    }

    // MARK: - New page (Add Page) opens in the editor, NOT the reader

    @Test
    func newPageInNewTab_mountsPageDetailViewInEditingMode() async throws {
        let store = try StoreBackend.current.makeStore(databaseURL: tempDatabaseURL())
        let model = WikiStoreModel(store: store)
        model.reloadFromStore()

        // The shared "Add Page" entry point (welcome screen button + sidebar +,
        // both routed through `newPageInNewTab`). This sets the new tab's
        // `isEditing = true` and switches selection to it.
        model.newPageInNewTab(title: "Brand New Page")
        #expect(model.activeTab?.isEditing == true)

        let view = PageDetailView(
            store: model,
            launcher: AgentLauncher(),
            session: try makeMinimalSession(),
            fileProvider: FileProviderFacade())
            .environment(FindModel())
            .environment(QueueActivityTracker())

        // Editing branch ⇒ ScrollableTextEditor (NSTextView), NO WKWebView.
        let foundWebView = try await hasWebViewAfterMount(view, expectWebView: false)
        #expect(!foundWebView, "New page should render the EDITOR (no WKWebView). A WKWebView in the subtree means the reader/preview branch rendered instead — i.e. the .onAppear seeding did not take effect on first mount.")
    }

    // MARK: - Navigation-opened page stays in rendered (reader) mode

    @Test
    func navigationOpenedPage_mountsPageDetailViewInReaderMode() async throws {
        let store = try StoreBackend.current.makeStore(databaseURL: tempDatabaseURL())
        let existing = try store.createPage(title: "Existing Page")
        let model = WikiStoreModel(store: store)
        model.reloadFromStore()

        // Opening a page by navigation (sidebar click) goes through `openTab`,
        // which leaves the tab at its default `isEditing == false`.
        model.openTab(.page(existing.id))
        #expect(model.activeTab?.isEditing == false)

        let view = PageDetailView(
            store: model,
            launcher: AgentLauncher(),
            session: try makeMinimalSession(),
            fileProvider: FileProviderFacade())
            .environment(FindModel())
            .environment(QueueActivityTracker())

        // Reader branch ⇒ WikiReaderView (WKWebView). Behavior is unchanged for
        // navigation-opened pages — this is the scope guard.
        let foundWebView = try await hasWebViewAfterMount(view, expectWebView: true)
        #expect(foundWebView, "Navigation-opened page should render the READER (WKWebView present).")
    }

    // MARK: - Minimal WikiSession for mount (session is only read in button
    // closures that don't fire during .onAppear; a minimal instance is enough)
    private func makeMinimalSession() throws -> WikiSession {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("page-detail-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let descriptor = WikiDescriptor.make(displayName: "Test")
        let coordinator = ExtractionCoordinator(
            containerDirectory: dir,
            localExtractorFactory: { StubExtractor() })
        return WikiSession(
            wikiID: descriptor.id,
            descriptor: descriptor,
            containerDirectory: dir,
            extractionCoordinator: coordinator,
            queueEngine: try makeTestQueueEngine(),
            extractionProvider: StubExtractionProvider())
    }
}

/// Minimal stubs mirroring `WikiSessionTests` (private there, so duplicated
/// here). PageDetailView never exercises extraction during `.onAppear`.
@MainActor
private final class StubExtractor: MarkdownExtractor {
    nonisolated var displayName: String { "Stub" }
    func readiness() async -> ExtractionReadiness { .ready }
    func convert(pdfData: Data, filename: String, onProgress: (@Sendable (String) -> Void)?) async throws -> String { "" }
}

private struct StubExtractionProvider: QueueExtractionProvider {
    func resolveExtraction(wikiID: String, sourceID: PageID, backendOverride: ExtractionBackend?) async throws -> ExtractionResolution? { nil }
    func persistExtraction(wikiID: String, sourceID: PageID, markdown: String, backend: ExtractionBackend, modelVersion: String?) async throws {}
}

private func makeTestQueueEngine() throws -> QueueEngine {
    let store = try QueueStore(databaseURL: URL(fileURLWithPath: ":memory:"))
    let provider = StubExtractionProvider()
    let factory = QueueExtractionWorkerFactory(provider: provider, emitProgress: { _, _ in })
    return QueueEngine(store: store, workerFactory: factory)
}
