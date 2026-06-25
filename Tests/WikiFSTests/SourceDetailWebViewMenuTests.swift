import AppKit
import Testing
@testable import WikiFS

/// Tests for the WKWebView subclass's pure helpers that back the right-click
/// "Add as Source" item: the AppKit→CSS coordinate flip (`cssHitTestPoint`) and
/// the DOM hit-test JavaScript (`linkHrefAtJS`). (The menu wiring + the JS
/// execution run inside WKWebView on macOS and are covered manually.)
struct WikiReaderWebViewMenuTests {

    // MARK: - cssHitTestPoint (AppKit bottom-left → CSS top-left)

    @Test func hitTestFlipsYAxis() {
        // AppKit origin is bottom-left; `document.elementFromPoint` is top-left,
        // so y is mirrored. A point 10pt below the top is at AppKit y=90.
        let r = WikiReaderWebView.cssHitTestPoint(
            NSPoint(x: 10, y: 90), in: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(r.x == 10)
        #expect(r.y == 10)
    }

    @Test func hitTestMidPointUnchanged() {
        let r = WikiReaderWebView.cssHitTestPoint(
            NSPoint(x: 50, y: 50), in: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(r.x == 50)
        #expect(r.y == 50)
    }

    @Test func hitTestClampsOutOfRange() {
        // x below 0 → 0; y beyond height → height - over → negative → clamped to 0.
        let r = WikiReaderWebView.cssHitTestPoint(
            NSPoint(x: -5, y: 999), in: CGRect(x: 0, y: 0, width: 200, height: 100))
        #expect(r.x == 0)
        #expect(r.y == 0)
    }

    @Test func hitTestClampsTopEdge() {
        // AppKit y=0 (very bottom) → CSS height (very bottom of viewport too);
        // height-0 = 100, within bounds, unclamped.
        let r = WikiReaderWebView.cssHitTestPoint(
            NSPoint(x: 1, y: 0), in: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(r.y == 100)
    }

    // MARK: - linkHrefAtJS

    @Test func hrefJSHitTestsAndEmbedsCoordinates() {
        let js = WikiReaderWebView.linkHrefAtJS(x: 12.5, y: 33)
        #expect(js.contains("elementFromPoint"))
        // Numbers are POSIX-formatted and passed at the call site.
        #expect(js.contains("12.50,33.00"))
    }

    @Test func hrefJSKeepsOnlyHttpOrHttps() {
        let js = WikiReaderWebView.linkHrefAtJS(x: 1, y: 2)
        #expect(js.contains("\"http:\""))
        #expect(js.contains("\"https:\""))
        // Only resolves anchors.
        #expect(js.contains("tagName!==\"A\""))
    }

    @Test func hrefJSUsesPOSIXDecimalPoint() {
        // A locale-dependent ',' would break the JS — must always be '.'.
        let js = WikiReaderWebView.linkHrefAtJS(x: 7.25, y: 0)
        #expect(js.contains("7.25"))
        #expect(!js.contains("7,25"))
    }
}
