import AppKit
import SwiftUI

/// NSTextView-backed chat composer, replacing the SwiftUI
/// `TextField(..., axis: .vertical).lineLimit(1...6)` that previously backed
/// the chat views' composer.
///
/// Why this exists: on macOS, `TextField` is NSTextField/field-editor backed.
/// Every keystroke, cursor move, or selection change re-lays-out the *entire*
/// string, and `.lineLimit(1...6)` re-measures the full ideal height on every
/// pass. Pasting ~150 lines of markdown into that field beachballed the app.
/// `NSTextView` (the standard Slack/Messages-style chat composer: an
/// `NSScrollView` wrapping a single `NSTextView`, growing 1–6 lines and then
/// scrolling internally) does incremental layout and doesn't re-measure the
/// whole document on every edit.
///
/// Mirrors `OmniboxSearchField.swift` — this repo's existing
/// `NSViewRepresentable` text-input precedent: a `Coordinator` owns delegate
/// state and forwards through to SwiftUI bindings/callbacks; `updateNSView`
/// only touches AppKit state that has actually changed, so it doesn't fight
/// the user's in-flight edit/selection/IME state on every SwiftUI update.
///
/// Placeholder text is intentionally NOT drawn here — `NSTextView` has no
/// built-in placeholder (unlike `NSTextField`/`NSSearchField`), so the caller
/// overlays a SwiftUI `Text` when `text.isEmpty`.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    let isEditable: Bool
    /// Callers pass `.preferredFont(forTextStyle: .body)` to match the rest of
    /// the composer's type scale.
    let font: NSFont
    /// Invoked when the user presses plain Return (see `keyAction`). Shift+Return
    /// and Option+Return insert a line break instead.
    let onSubmit: () -> Void
    /// Written (asynchronously — never from inside `updateNSView` synchronously)
    /// whenever the measured content height changes. The caller applies
    /// `.frame(height: measuredHeight)`.
    @Binding var measuredHeight: CGFloat
    /// When true, the text view becomes first responder (keyboard focus) once
    /// it's added to a window. Used by ChatView's draft state so the user can
    /// start typing immediately after clicking "Add chat".
    var autoFocus: Bool = false

    nonisolated static let accessibilityLabel = "Message"
    private let placeholderText = "Ask a question, or ask the Agent to update the wiki…"

    // MARK: - Height clamping (pure, testable)

    /// Clamp + inset constants. `verticalInsetPerSide` is applied to the text
    /// container's top AND bottom, so the total vertical inset baked into every
    /// height measurement is double this. `verticalInset` is used in the
    /// clamp and the text container's vertical inset, so the two can't drift
    /// apart (the inset is baked into every `contentHeight` measurement fed
    /// into `clampedHeight`, so the clamp's own `+ verticalInset` term has to
    /// match exactly).
    nonisolated enum Metrics {
        static let minLines: CGFloat = 3
        static let maxLines: CGFloat = 6
        static let verticalInsetPerSide: CGFloat = 4
        static var verticalInset: CGFloat { verticalInsetPerSide * 2 }
    }

    /// Pure: clamp measured content height to the 1–6 line band.
    nonisolated static func clampedHeight(contentHeight: CGFloat, lineHeight: CGFloat) -> CGFloat {
        let minHeight = lineHeight * Metrics.minLines + Metrics.verticalInset
        let maxHeight = lineHeight * Metrics.maxLines + Metrics.verticalInset
        return min(max(contentHeight, minHeight), maxHeight)
    }

    /// The one-line height for `font`, used as the initial `@State` value on
    /// the SwiftUI side before any layout pass has run.
    nonisolated static func oneLineHeight(for font: NSFont) -> CGFloat {
        clampedHeight(contentHeight: 0, lineHeight: NSLayoutManager().defaultLineHeight(for: font))
    }

    // MARK: - Key handling (pure, testable)

    nonisolated enum ComposerKeyAction {
        case send
        case insertNewline
        case unhandled
    }

    /// Pure: decide what a `doCommandBy:` selector + the live modifier flags
    /// mean for the composer.
    ///
    /// Plain Return sends. Shift/Option+Return insert a literal line break.
    /// Cmd+Return falls through (`.unhandled`) so the send button's own
    /// `.keyboardShortcut(.return, modifiers: .command)` is the single path —
    /// otherwise a Cmd+Return keystroke would send twice.
    nonisolated static func keyAction(for selector: Selector, modifiers: NSEvent.ModifierFlags) -> ComposerKeyAction {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return .unhandled }
        if modifiers.contains(.shift) || modifiers.contains(.option) { return .insertNewline }
        if modifiers.contains(.command) { return .unhandled }
        return .send
    }

    // MARK: - NSViewRepresentable

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Builds and configures the `NSTextView` used both by `makeNSView` and by
    /// tests that need a directly-constructible, fully-configured text view
    /// without going through the SwiftUI representable machinery.
    static func makeConfiguredTextView(font: NSFont) -> NSTextView {
        let textView = NSTextView()
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.font = font
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 0, height: Metrics.verticalInsetPerSide)

        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: 0)
        // Unregister drag types so the NSTextView doesn't intercept sidebar
        // drags routed to the SwiftUI .dropDestination on the composer
        // container. Without this, dragging a page/source/bookmark over the
        // text view (including the placeholder) gets swallowed by AppKit's
        // default text-drag handling and never reaches the composer's
        // dropDestination (issue #385).
        textView.unregisterDraggedTypes()
        if let container = textView.textContainer {
            container.widthTracksTextView = true
            container.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
            // Zero line-fragment padding so typed text aligns exactly with the
            // SwiftUI placeholder overlay (NSTextContainer defaults to 5pt/side).
            container.lineFragmentPadding = 0
        }

        textView.setAccessibilityLabel(accessibilityLabel)
        return textView
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = Self.makeConfiguredTextView(font: font)
        textView.delegate = context.coordinator
        textView.isEditable = isEditable
        textView.string = text
        textView.setAccessibilityPlaceholderValue(placeholderText)
        textView.postsFrameChangedNotifications = true
        context.coordinator.observeFrameChanges(for: textView)

        scrollView.documentView = textView

        if autoFocus {
            DispatchQueue.main.async { [weak scrollView] in
                guard let scrollView,
                      let tv = scrollView.documentView as? NSTextView,
                      tv.window?.firstResponder !== tv else { return }
                tv.window?.makeFirstResponder(tv)
            }
        }
        return scrollView
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.stopObservingFrameChanges()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }

        if textView.string != text {
            textView.string = text
        }
        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
        }
        if textView.font != font {
            textView.font = font
        }
        textView.setAccessibilityPlaceholderValue(placeholderText)
        context.coordinator.recomputeHeight(for: textView)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        private var frameObserver: NSObjectProtocol?
        private var lastObservedWidth: CGFloat?

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if parent.text != textView.string {
                parent.text = textView.string
            }
            recomputeHeight(for: textView)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let modifiers = (NSApp.currentEvent?.modifierFlags ?? []).intersection(.deviceIndependentFlagsMask)
            switch ComposerTextView.keyAction(for: selector, modifiers: modifiers) {
            case .send:
                parent.onSubmit()
                return true
            case .insertNewline, .unhandled:
                return false
            }
        }

        /// Measures content height and writes the clamped result back to the
        /// binding — deferred to the next main-actor turn (must never write
        /// synchronously, since this also runs from inside `updateNSView`).
        func recomputeHeight(for textView: NSTextView) {
            guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            let contentHeight = layoutManager.usedRect(for: container).height + textView.textContainerInset.height * 2
            let lineHeight = layoutManager.defaultLineHeight(for: parent.font)
            let clamped = ComposerTextView.clampedHeight(contentHeight: contentHeight, lineHeight: lineHeight)
            guard clamped != parent.measuredHeight else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.parent.measuredHeight = clamped
            }
        }

        func observeFrameChanges(for textView: NSTextView) {
            guard frameObserver == nil else { return }
            lastObservedWidth = textView.frame.width
            frameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: textView,
                queue: .main
            ) { [weak self, weak textView] _ in
                guard let self, let textView else { return }
                MainActor.assumeIsolated {
                    self.handleFrameChange(for: textView)
                }
            }
        }

        func stopObservingFrameChanges() {
            guard let frameObserver else { return }
            NotificationCenter.default.removeObserver(frameObserver)
            self.frameObserver = nil
        }

        @MainActor
        private func handleFrameChange(for textView: NSTextView) {
            let width = textView.frame.width
            guard width != lastObservedWidth else { return }
            lastObservedWidth = width
            recomputeHeight(for: textView)
        }
    }
}
