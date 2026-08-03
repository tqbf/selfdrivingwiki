import AppKit
import WebKit
import WikiFSCore

/// Prints the document a reader `WKWebView` is currently showing (issue #933).
///
/// There is exactly one print mechanism in the app and this is it: WebKit's own
/// `WKWebView.printOperation(with:)`, which renders the *live* DOM — the same
/// markdown, transclusions, diagrams, and reader CSS the user is looking at.
/// Re-rendering the markdown to a separate print-only document would be a second
/// mechanism that could silently disagree with the screen.
///
/// The operation is run **sheet-modal** on the web view's window, so the print
/// panel does not block the main actor and each window prints its own reader.
/// `NSPrintOperation.runModal(for:delegate:didRun:contextInfo:)` returns
/// immediately; the panel drives itself from the run loop.
@MainActor
enum ReaderPrinting {

    /// Page margins for the printed document, in points (72pt = 1 inch). A
    /// half-inch keeps the reader's own body padding from stacking with a wide
    /// paper margin and reflowing code blocks.
    static let pageMargin: CGFloat = 36

    /// Present the print panel for `webView`'s current document.
    ///
    /// `NSPrintInfo.shared` is copied rather than mutated: it is process-wide
    /// state, and scribbling margins onto it would leak this reader's page setup
    /// into every other print operation in the app.
    static func run(for webView: WKWebView) {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.topMargin = pageMargin
        info.bottomMargin = pageMargin
        info.leftMargin = pageMargin
        info.rightMargin = pageMargin

        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        // WebKit paginates from the operation view's width; without this the
        // view can carry a zero frame and the job renders blank pages.
        operation.view?.frame = webView.bounds

        if let window = webView.window {
            DebugLog.reader("print: running sheet-modal for window \(window.windowNumber)")
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            // No window (detached view — e.g. a hosted test harness or a reader
            // torn down mid-click). App-modal is the only remaining option, and
            // it is still the user's own explicit Print action.
            DebugLog.reader("print: web view has no window, running app-modal")
            operation.run()
        }
    }
}
