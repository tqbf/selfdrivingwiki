#if os(macOS)
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

    private func tempDatabaseURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("page-detail-hosted-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WikiFS.sqlite")
    }

    /// Mount a view in a real `NSWindow`, give SwiftUI + content time to settle,
    /// then return whether a `WKWebView` exists anywhere in the hosting view's
    /// NSView subtree. WKWebView presence ⇒ the reader branch rendered; its
    /// absence ⇒ the editor branch rendered.
    private func hasWebViewAfterMount<V: View>(_ view: V, expectWebView: Bool) async throws -> Bool {
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        _ = Self.app
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        // Condition-based wait: the WKWebView mounts asynchronously after the
        // first SwiftUI render. Poll on wall clock with a bounded sleep so the
        // hosted assertion still exercises the real mount path instead of only
        // burning scheduler yields.
        var found = false
        for _ in 0..<40 {
            found = firstSubview(of: hosting.view, ofType: WKWebView.self) != nil
            if expectWebView && found { break }
            try await Task.sleep(for: .milliseconds(50))
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

    /// Shared host configuration for `PageDetailView` so every hosted mount
    /// gets the same environment model set, including the window-owned
    /// inspector controller the live app injects from `ContentView`.
    private func makeHostedPageDetailView(store model: WikiStoreModel) throws -> some View {
        PageDetailView(
            store: model,
            launcher: AgentLauncher(),
            session: try makeMinimalSession(),
            fileProvider: FileProviderFacade())
            .environment(FindModel())
            .environment(QueueActivityTracker())
            .environment(WindowRightInspectorController())
    }

    // MARK: - New page (Add Page) opens in the editor, NOT the reader

    @Test
    func newPageInNewTab_mountsPageDetailViewInEditingMode() async throws {
        let store = try StoreBackend.current.makeStore(databaseURL: try tempDatabaseURL())
        let model = WikiStoreModel(store: store)
        model.reloadFromStore()

        // The shared "Add Page" entry point (welcome screen button + sidebar +,
        // both routed through `newPageInNewTab`). This sets the new tab's
        // `isEditing = true` and switches selection to it.
        model.newPageInNewTab(title: "Brand New Page")
        #expect(model.activeTab?.isEditing == true)

        let view = try makeHostedPageDetailView(store: model)

        // Editing branch ⇒ ScrollableTextEditor (NSTextView), NO WKWebView.
        let foundWebView = try await hasWebViewAfterMount(view, expectWebView: false)
        #expect(!foundWebView, "New page should render the EDITOR (no WKWebView). A WKWebView in the subtree means the reader/preview branch rendered instead — i.e. the .onAppear seeding did not take effect on first mount.")
    }

    // MARK: - Navigation-opened page stays in rendered (reader) mode

    @Test
    func navigationOpenedPage_mountsPageDetailViewInReaderMode() async throws {
        let store = try StoreBackend.current.makeStore(databaseURL: try tempDatabaseURL())
        let existing = try store.createPage(title: "Existing Page")
        let model = WikiStoreModel(store: store)
        model.reloadFromStore()

        // Opening a page by navigation (sidebar click) goes through `openTab`,
        // which leaves the tab at its default `isEditing == false`.
        model.openTab(.page(existing.id))
        #expect(model.activeTab?.isEditing == false)

        let view = try makeHostedPageDetailView(store: model)

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
        return try WikiSession(
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
    func resolveExtraction(wikiID: WikiID, sourceID: SourceID, backendOverride: ExtractionBackend?) async throws -> ExtractionResolution? { nil }
    func persistExtraction(wikiID: WikiID, sourceID: SourceID, markdown: String, backend: ExtractionBackend, modelVersion: String?, technique: String?) async throws {}
}

private func makeTestQueueEngine() throws -> QueueEngine {
    let store = try QueueStore(databaseURL: URL(fileURLWithPath: ":memory:"))
    let provider = StubExtractionProvider()
    let factory = QueueExtractionWorkerFactory(provider: provider, emitProgress: { _, _ in })
    return QueueEngine(store: store, workerFactory: factory)
}
#endif
