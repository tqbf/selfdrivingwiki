import AppKit
import SwiftUI

/// A programmatic scroll request for `ScrollableTextEditor`. When `version`
/// changes, the editor scrolls so the character at `charOffset` is visible and
/// places the caret there.
///
/// `charOffset` is an `NSString` (UTF-16 code-unit) index into the editor's
/// text — the same coordinate space `NSTextView` uses for ranges. This matches
/// the `charOffset` computed by `PageOutlineView.parseHeadings`.
struct EditorScrollRequest: Equatable {
    let charOffset: Int
    /// Monotonic counter. The editor only acts when this value changes, so
    /// re-clicking the same heading re-fires the scroll + caret move.
    let version: Int
}

/// `NSTextView`-backed plain-text editor that supports programmatic
/// scroll-to-heading and caret reporting. Replaces SwiftUI's `TextEditor` in
/// page/source edit mode so that outline clicks can scroll the cursor to a
/// heading (issue #268).
///
/// SwiftUI's built-in `TextEditor` has no public API for scrolling to an
/// arbitrary character offset or reading the caret position — both needed for
/// outline-click navigation and live "which heading is the caret in?"
/// highlighting. This `NSViewRepresentable` wraps an `NSScrollView` +
/// `NSTextView` (the same backing `TextEditor` uses internally) and exposes
/// those capabilities.
///
/// Mirrors `ComposerTextView` — this repo's existing `NSViewRepresentable`
/// text-input precedent: a `Coordinator` owns delegate state and forwards
/// through to SwiftUI bindings; `updateNSView` only touches AppKit state that
/// has actually changed, so it doesn't fight the user's in-flight edit /
/// selection / IME state on every SwiftUI update.
struct ScrollableTextEditor: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    /// When `version` changes, the editor scrolls to `charOffset` and sets the
    /// caret there. Pass `nil` when no scroll is pending.
    var scrollRequest: EditorScrollRequest?
    /// Fires with the caret's character index whenever it changes — used by the
    /// caller to highlight the heading the caret is currently inside.
    var onCaretChange: ((Int) -> Void)?

    // MARK: - NSViewRepresentable

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = Self.makeConfiguredTextView(font: font)
        textView.delegate = context.coordinator
        textView.string = text

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }

        // Sync text only when it changed externally (avoids clobbering the
        // user's in-flight edit). Setting `.string` resets undo + selection,
        // so we must skip it when the text view is already in sync.
        if textView.string != text {
            textView.string = text
        }
        if textView.font?.fontName != font.fontName
            || textView.font?.pointSize != font.pointSize {
            textView.font = font
        }

        // Consume a pending scroll request.
        if let request = scrollRequest,
           context.coordinator.appliedScrollVersion != request.version {
            context.coordinator.appliedScrollVersion = request.version
            let length = (textView.string as NSString).length
            let clamped = min(max(0, request.charOffset), length)
            let range = NSRange(location: clamped, length: 0)
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            textView.window?.makeFirstResponder(textView)
        }
    }

    // MARK: - Text view factory (shared with tests)

    static func makeConfiguredTextView(font: NSFont) -> NSTextView {
        let textView = NSTextView()
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.font = font
        // Disable automatic substitutions so pasted/typed markdown is not
        // silently rewritten (smart quotes, dashes, etc.).
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isSelectable = true
        textView.isEditable = true

        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: 0)

        if let container = textView.textContainer {
            container.widthTracksTextView = true
            container.containerSize = NSSize(width: 0,
                                              height: CGFloat.greatestFiniteMagnitude)
        }

        return textView
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ScrollableTextEditor
        /// The last `EditorScrollRequest.version` this coordinator applied.
        var appliedScrollVersion: Int?
        /// Avoids redundant SwiftUI updates: only reports the caret when its
        /// index actually changed.
        private var lastReportedCaret: Int?

        init(_ parent: ScrollableTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if parent.text != textView.string {
                parent.text = textView.string
            }
            reportCaret(in: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            reportCaret(in: textView)
        }

        private func reportCaret(in textView: NSTextView) {
            let caret = textView.selectedRange().location
            guard caret != lastReportedCaret else { return }
            lastReportedCaret = caret
            parent.onCaretChange?(caret)
        }
    }
}
