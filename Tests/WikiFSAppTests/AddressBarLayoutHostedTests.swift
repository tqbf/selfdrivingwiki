#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import WikiFS
@testable import WikiFSEngine
@testable import WikiFSCore

/// Hosted-view checks that the SwiftUI wiring behind the centered omnibox actually
/// renders the width `OmniboxLayout` computes. `OmniboxLayoutTests` only proves the
/// pure math is right; it can't catch the field silently growing past its cap or an
/// implicit spacing eating into the frame. Render the actual `AddressBarView` (which
/// is now *only* the field — the nav cluster is a separate `.navigation` item) and
/// read its rendered width back.
///
/// `NSHostingController.view.fittingSize` is used rather than a real `NSToolbar`
/// (which needs an on-screen window with a toolbar). Since the field carries an
/// explicit `.frame(width:)`, its fitting width is the computed `fieldWidth`.
@MainActor
struct AddressBarLayoutHostedTests {
    /// An `NSHostingController` in a `swift test` CLI has no host app, so give
    /// AppKit one to lay out into (same pattern as `QuoteHighlightWebViewTests`).
    private static let app: NSApplication = {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        return app
    }()

    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("address-bar-layout-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WikiFS.sqlite")
    }

    /// Hosts the real `AddressBarView` at a fixed `detailWidth` and returns its
    /// rendered width — the width NSToolbar would center as the `.principal` item.
    private func renderedWidth(detailWidth: CGFloat, sidebarVisible: Bool = true) async throws -> CGFloat {
        _ = Self.app
        let store = try StoreBackend.current.makeStore(databaseURL: tempDatabaseURL())
        let model = WikiStoreModel(store: store)
        let view = AddressBarView(
            store: model,
            isFocused: .constant(false),
            detailWidth: detailWidth,
            sidebarVisible: sidebarVisible,
            onAddToBookmarks: { _ in })
            .environment(FindModel())
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        // Give SwiftUI a layout pass before reading geometry.
        try await Task.sleep(nanoseconds: 150_000_000)
        return hosting.view.fittingSize.width
    }

    /// Below the cap: the field absorbs region growth 1-for-1, exactly as
    /// `OmniboxLayout.fieldWidth` says it should.
    @Test func renderedWidthTracksDetailWidthOneForOneBelowTheCap() async throws {
        let narrow = try await renderedWidth(detailWidth: 700)
        let wider = try await renderedWidth(detailWidth: 800)
        #expect(abs((wider - narrow) - 100) < 1)
    }

    /// The rendered width matches the pure computation — no implicit padding or
    /// stray spacing has crept into the frame.
    @Test func renderedWidthMatchesTheComputedFieldWidth() async throws {
        let rendered = try await renderedWidth(detailWidth: 700)
        #expect(abs(rendered - OmniboxLayout.fieldWidth(detailWidth: 700, sidebarVisible: true)) < 1)
    }

    /// Past the readability cap the pill freezes: a wider window adds side margin,
    /// not field width, so the rendered width stops moving.
    @Test func renderedWidthFreezesAtTheCap() async throws {
        let m = OmniboxLayout.Metrics.default
        // Both points are past the cap (region - margins exceeds maxWidth).
        #expect(OmniboxLayout.fieldWidth(detailWidth: 1400, sidebarVisible: true) == m.maxWidth)
        #expect(OmniboxLayout.fieldWidth(detailWidth: 1800, sidebarVisible: true) == m.maxWidth)

        let atCap = try await renderedWidth(detailWidth: 1400)
        let pastCap = try await renderedWidth(detailWidth: 1800)
        #expect(abs(pastCap - atCap) < 1)
    }
}
#endif
