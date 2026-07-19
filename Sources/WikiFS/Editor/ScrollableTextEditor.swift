import AppKit
import SwiftUI
import WikiFSCore

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
    /// Builds the insertion text for a sidebar drag-drop onto the editor. Receives
    /// the flattened `[SidebarDragPayload]` across every dragged pasteboard item
    /// (handles both a single leaf drop and a multi-row selection / bookmark
    /// folder). Returns `nil` to reject the drop (e.g. when an agent is
    /// mid-generation, or every payload resolved stale). `nil` (the default)
    /// disables sidebar drops entirely — the editor behaves exactly as before
    /// (#616 is opt-in per call site).
    ///
    /// The closure is stored on the representable and re-applied in `updateNSView`
    /// so a new SwiftUI evaluation (e.g. `store` changing) re-wires it
    /// on the live `DropLinkTextView`. Captured `WikiStoreModel` is `@MainActor`
    /// and AppKit drag callbacks run on the main thread, so the capture is
    /// main-actor-isolated without an explicit hop.
    var sidebarDropBuilder: (([SidebarDragPayload]) -> String?)? = nil

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
        if let dropTV = textView as? DropLinkTextView {
            dropTV.sidebarDropBuilder = sidebarDropBuilder
        }

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

        // Re-wire the sidebar drop builder on every SwiftUI update — the closure
        // captures a fresh `store` reference, and `sidebarDropBuilder` being nil
        // (the default) cleanly disables drops on editors that aren't wired up.
        // Dropping into the editor fires `textDidChange` (via
        // `replaceCharacters`) which updates `parent.text` BEFORE the next
        // `updateNSView`; the `textView.string != text` guard above then
        // correctly skips (no clobber) because the binding already reflects the
        // drop.
        if let dropTV = textView as? DropLinkTextView {
            dropTV.sidebarDropBuilder = sidebarDropBuilder
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

    /// Builds the `NSTextView` for the editor. Returns a `DropLinkTextView`
    /// (a subclass that accepts `wikiSidebarItem` sidebar drops alongside the
    /// inherited text drag types) for issue #616 — the same configuration
    /// (no rich text, no substitutions, monospaced font, etc.) as before, just
    /// with the sidebar-drop acceptance layered on. Tests can still type this
    /// as `NSTextView` since `DropLinkTextView` is a subclass.
    static func makeConfiguredTextView(font: NSFont) -> NSTextView {
        let textView = DropLinkTextView()
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
