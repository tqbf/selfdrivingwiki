import AppKit
import SwiftUI

/// NSTextView-backed chat composer, replacing the SwiftUI
/// `TextField(..., axis: .vertical).lineLimit(1...6)` that previously backed
/// `QueryConversationView.composer(maxWidth:)`.
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
/// overlays a SwiftUI `Text` when `text.isEmpty` (see
/// `QueryConversationView.composer(maxWidth:)`).
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

    /// Accessibility label + placeholder value applied to the text view. Kept
    /// as a stored default (rather than threading a parameter through) since
    /// every call site in this app uses the same composer copy today; if a
    /// second composer instance needs different copy, thread it through here.
    static let accessibilityLabel = "Message"

    // MARK: - Height clamp (pure, testable)

    /// Height-band constants. The single source of truth for both the 1–6 line
    /// clamp and the text container's vertical inset, so the two can't drift
    /// apart (the inset is baked into every `contentHeight` measurement fed
    /// into `clampedHeight`, so the clamp's own `+ verticalInset` term has to
    /// match exactly).
    enum Metrics {
        static let minLines: CGFloat = 1
        static let maxLines: CGFloat = 6
        /// Applied to the text container's top AND bottom (NSTextView's
        /// `textContainerInset.height` is added on both sides), so the total
        /// vertical inset baked into every height measurement is double this.
        static let verticalInsetPerSide: CGFloat = 4
        static var verticalInset: CGFloat { verticalInsetPerSide * 2 }
    }

    /// Pure: clamp measured content height to the 1–6 line band.
    ///
    /// `contentHeight` is the text view's laid-out content height (usedRect +
    /// vertical inset); `lineHeight` is the font's default line height
    /// (`NSLayoutManager.defaultLineHeight(for:)`). Both bounds include
    /// `Metrics.verticalInset` so they're directly comparable to a
    /// `contentHeight` that already has the inset baked in.
    static func clampedHeight(contentHeight: CGFloat, lineHeight: CGFloat) -> CGFloat {
        let minHeight = lineHeight * Metrics.minLines + Metrics.verticalInset
        let maxHeight = lineHeight * Metrics.maxLines + Metrics.verticalInset
        return min(max(contentHeight, minHeight), maxHeight)
    }

    /// The one-line height for `font`, used as the initial `@State` value on
    /// the SwiftUI side before any layout pass has run.
    static func oneLineHeight(for font: NSFont) -> CGFloat {
        clampedHeight(contentHeight: 0, lineHeight: NSLayoutManager().defaultLineHeight(for: font))
    }

    // MARK: - Key handling (pure, testable)

    enum ComposerKeyAction {
        case send
        case insertNewline
        case unhandled
    }

    /// Pure: decide what a `doCommandBy:` selector + the live modifier flags
    /// mean for the composer.
    ///
    /// Plain Return (`insertNewline:`, no shift/option) sends. Shift+Return and
    /// Option+Return insert a literal line break — returning `.insertNewline`
    /// tells the caller to return `false` from the delegate method so the text
    /// view performs its own default handling (inserting `\n`).
    ///
    /// Cmd+Return deliberately resolves to `.unhandled`, NOT `.send`: the send
    /// button already carries `.keyboardShortcut(.return, modifiers: .command)`,
    /// so if this also fired `onSubmit()` a Cmd+Return keystroke would send the
    /// message twice (once via the button's key equivalent, once via the text
    /// view delegate). Falling through here lets the button's key equivalent be
    /// the single path for Cmd+Return.
    static func keyAction(for selector: Selector, modifiers: NSEvent.ModifierFlags) -> ComposerKeyAction {
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
        // The SwiftUI capsule behind the composer provides the background;
        // the text view itself must stay transparent.
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.font = font
        textView.isContinuousSpellCheckingEnabled = true
        // Users paste markdown into this field; smart quotes/dashes would
        // silently corrupt pasted `"`/`--`/`->` sequences.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 0, height: Metrics.verticalInsetPerSide)

        // Standard "grow with content, no horizontal scroll" wiring: the
        // container tracks the scroll view's width so text wraps instead of
        // scrolling sideways, and the text view itself only grows vertically.
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: 0)
        if let container = textView.textContainer {
            container.widthTracksTextView = true
            container.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
            // NSTextContainer defaults to 5pt of horizontal line-fragment
            // padding on each side. Left alone, that shifts typed text 5pt to
            // the right of the SwiftUI placeholder overlay (which uses the
            // same leading padding as this view's frame) — the placeholder
            // and the first typed character visibly jump apart. Zeroing it
            // makes the horizontal alignment exact. (Vertical alignment is
            // unaffected — line-fragment padding is horizontal-only; see
            // `Metrics.verticalInsetPerSide` for the vertical half of this fix,
            // applied on the SwiftUI side in `QueryConversationView`.)
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
        // Measured height depends on wrap width: narrowing the window
        // re-wraps a multi-line draft to more (or fewer) lines. Without this,
        // the height stays stale until the next keystroke — clipping content
        // or leaving a gap. `frameDidChangeNotification` catches resizes that
        // never touch the text (window resize, split-view drag, etc).
        textView.postsFrameChangedNotifications = true
        context.coordinator.observeFrameChanges(for: textView)

        scrollView.documentView = textView
        return scrollView
    }

    /// Removes the frame-change observer installed in `makeNSView` when
    /// SwiftUI tears the view down, so it doesn't outlive the text view (and
    /// so re-mounting doesn't accumulate duplicate observers). Mirrors
    /// `OmniboxSearchField.dismantleNSView`, this repo's existing convention
    /// for `NSViewRepresentable` teardown.
    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.stopObservingFrameChanges()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }

        // Only reassign `.string` when it actually differs — reassigning on
        // every SwiftUI update would destroy the user's selection/IME
        // composition state on every keystroke (the exact "re-lays-out the
        // whole string" problem this type exists to avoid).
        if textView.string != text {
            textView.string = text
        }
        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
        }
        textView.setAccessibilityPlaceholderValue(placeholderText)

        // Re-measure after any programmatic replacement too (e.g. the caller
        // clearing `draftMessage` after `sendMessage()` — that's a `text`
        // change arriving from outside the text view, so nothing here
        // triggers `textDidChange`).
        context.coordinator.recomputeHeight(for: textView)
    }

    private let placeholderText = "Ask a question, or ask the Agent to update the wiki…"

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        /// Token for the `frameDidChangeNotification` observer installed by
        /// `observeFrameChanges`; removed in `stopObservingFrameChanges`
        /// (called from `dismantleNSView`).
        private var frameObserver: NSObjectProtocol?
        /// Last width seen by the frame observer, so a notification that
        /// fires without an actual width change (e.g. our own vertical resize
        /// as `isVerticallyResizable` grows the text view) is a cheap no-op
        /// rather than a redundant re-layout.
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

        /// Measures `textView`'s current content height via the layout
        /// manager and, if the clamped result differs from the bound
        /// `measuredHeight`, writes it back — deferred to the next main-actor
        /// turn.
        ///
        /// The defer is required, not cosmetic: this method is called from
        /// `updateNSView` (to catch programmatic `text` replacement), and
        /// `updateNSView` runs during a SwiftUI view-update pass. Writing a
        /// `@Binding` synchronously from inside a view update triggers
        /// "Modifying state during view update, which will cause undefined
        /// behavior." Dispatching to the next main-actor turn (and guarding on
        /// value-changed so steady-state calls are a no-op) sidesteps that
        /// while still converging within the same runloop pass.
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

        /// Installs a `frameDidChangeNotification` observer for `textView`
        /// (idempotent — a second call while one is already installed is a
        /// no-op). The block runs on `.main` via the notification's `queue:`
        /// parameter, which guarantees main-thread execution but isn't
        /// visible to the type checker as main-actor isolation, hence the
        /// `MainActor.assumeIsolated` hop — the same pattern
        /// `OmniboxSearchField.Coordinator.handleArrowKey` uses for its local
        /// event monitor.
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

        /// Re-measures height only when the text view's width actually
        /// changed — the notification also fires from our own vertical
        /// resizing (`isVerticallyResizable`), which `recomputeHeight`'s
        /// value-changed guard already dedupes, but skipping the layout pass
        /// entirely on a same-width fire is cheaper still.
        @MainActor
        private func handleFrameChange(for textView: NSTextView) {
            let width = textView.frame.width
            guard width != lastObservedWidth else { return }
            lastObservedWidth = width
            recomputeHeight(for: textView)
        }
    }
}
