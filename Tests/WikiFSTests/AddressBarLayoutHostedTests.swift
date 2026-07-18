import AppKit
import SwiftUI
import Testing
@testable import WikiFS
@testable import WikiFSEngine
@testable import WikiFSCore

/// Hosted-view checks that the SwiftUI wiring behind the omnibox toolbar item
/// actually renders the width `OmniboxLayout` computes. `OmniboxLayoutTests`
/// only proves the pure math is right; it can't catch a `Color.clear` spacer
/// wired into the wrong `HStack`, an extra implicit spacing eating into it, or
/// the field itself silently growing past its cap — all invisible to the pure
/// function but exactly the class of bug issue #114 was about (a real widget
/// stalling short of the true trailing edge). Render the actual view and read
/// its layout back.
///
/// A `NSHostingController.view.fittingSize` is used rather than a real
/// `NSToolbar` (which needs a window on screen with a toolbar attached and adds
/// its own empirically-observed padding — see `OmniboxLayout.Metrics`'s
/// `openLeadingChrome`/`closedLeadingChrome` doc comments). Absolute widths
/// aren't comparable to those constants outside a real toolbar, so these tests
/// assert *deltas*: how much the rendered width moves when `detailWidth` moves.
/// That's exactly what the fix is about — the group's total rendered width must
/// track `detailWidth` 1:1 everywhere, including past the field's cap — and it's
/// invariant to whatever padding a real `NSToolbar` adds on top.
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
    /// natural (unconstrained) width — the same sizing an `NSToolbar` reads to
    /// place the trailing items after it. `homePageID` mirrors the real trigger
    /// for the Home nav button (issue #280): non-`nil` renders a fourth nav
    /// button, exactly like a wiki with a configured home page.
    private func renderedWidth(detailWidth: CGFloat, sidebarVisible: Bool,
                               homePageID: PageID? = nil) async throws -> CGFloat {
        _ = Self.app
        let store = try StoreBackend.current.makeStore(databaseURL: tempDatabaseURL())
        let model = WikiStoreModel(store: store)
        let view = AddressBarView(
            store: model,
            isFocused: .constant(false),
            wikiName: "My Wiki",
            detailWidth: detailWidth,
            sidebarVisible: sidebarVisible,
            homePageID: homePageID,
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

    /// Below the cap: the field alone absorbs window growth, 1-for-1, same as
    /// before the spacer existed — this proves the fix didn't disturb the
    /// unclamped case.
    @Test func renderedWidthTracksDetailWidthOneForOneBelowTheCap() async throws {
        let narrow = try await renderedWidth(detailWidth: 700, sidebarVisible: true)
        let wider = try await renderedWidth(detailWidth: 800, sidebarVisible: true)
        #expect(abs((wider - narrow) - 100) < 1)
    }

    /// The regression this issue is about: past the field's `maxWidth` cap, a
    /// widening window used to produce NO change in the group's rendered width
    /// (the field was stuck at the cap and nothing else absorbed the rest) — that
    /// frozen total is exactly the growing trailing-edge gap the user reported.
    /// With the spacer wired in, the rendered width must keep tracking
    /// `detailWidth` 1-for-1 even past the cap.
    @Test func renderedWidthKeepsTrackingDetailWidthPastTheCap() async throws {
        let m = OmniboxLayout.Metrics.default
        let field2000 = OmniboxLayout.fieldWidth(detailWidth: 2000, sidebarVisible: true, switcherExtra: 0)
        let field2200 = OmniboxLayout.fieldWidth(detailWidth: 2200, sidebarVisible: true, switcherExtra: 0)
        // Sanity: both points really are past the cap (field itself is frozen).
        #expect(field2000 == m.maxWidth)
        #expect(field2200 == m.maxWidth)

        let atCap = try await renderedWidth(detailWidth: 2000, sidebarVisible: true)
        let pastCap = try await renderedWidth(detailWidth: 2200, sidebarVisible: true)
        #expect(abs((pastCap - atCap) - 200) < 1)
    }

    /// Same check with the sidebar hidden (the other `leadingChrome` branch),
    /// since the fix touches both.
    @Test func renderedWidthKeepsTrackingDetailWidthPastTheCapWithSidebarHidden() async throws {
        let atCap = try await renderedWidth(detailWidth: 2200, sidebarVisible: false)
        let pastCap = try await renderedWidth(detailWidth: 2400, sidebarVisible: false)
        #expect(abs((pastCap - atCap) - 200) < 1)
    }

    /// The home-button regression: a wiki with a configured home page (issue
    /// #280) renders a fourth nav button. If `OmniboxLayout` doesn't know about
    /// it (`homeButtonShown`), the field doesn't shrink to compensate, so the
    /// WHOLE group (nav cluster + gap + field) renders WIDER than with no home
    /// button — encroaching into the trailing switcher/toggle's reserved space
    /// by exactly the button's footprint. That's what permanently pushed the
    /// Toggle Transcript button into the toolbar's `»` overflow for any such
    /// wiki, at any window width (a fixed offset, not a threshold — widening the
    /// window never fixed it). With the fix, the field shrinks by exactly the
    /// button's own footprint, so the total rendered width is UNCHANGED whether
    /// or not the home button shows — the trailing items land in the same place
    /// either way.
    @Test func homeButtonDoesNotChangeTotalRenderedWidthBecauseTheFieldCompensates() async throws {
        let withoutHome = try await renderedWidth(detailWidth: 900, sidebarVisible: true, homePageID: nil)
        let withHome = try await renderedWidth(detailWidth: 900, sidebarVisible: true,
                                               homePageID: PageID(rawValue: "test-home-page"))
        #expect(abs(withoutHome - withHome) < 1)
    }
}
