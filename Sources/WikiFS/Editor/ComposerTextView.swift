import AppKit
import SwiftUI
import WikiFSLinks
import WikiFSSearch

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
    /// it's added to a window. Used by ChatDetailView's draft state so the user can
    /// start typing immediately after clicking "Add chat".
    var autoFocus: Bool = false

    // MARK: - Wiki-link autocomplete (#436 / #638)

    /// Optional autocomplete integration. When non-nil, the coordinator runs
    /// a debounced query for each keystroke that lands inside an open
    /// `[[kind:partial` trigger, surfaces the results in a dropdown, and
    /// inserts the canonical `[[kind:ULID|Title]]` form on selection.
    ///
    /// Three injected closures so the AppKit coordinator stays pure about the
    /// engine + formatter (it doesn't import `WikiFSCore` / `DroppedLinkFormatter`
    /// directly — the SwiftUI parent wires those in from `ChatDetailView`):
    ///   - `fetch`: runs the Tantivy `autocomplete(partial:kinds:...)` query.
    ///     Must be async-cancellable on the caller side (the coordinator cancels
    ///     the prior in-flight Task before each new keystroke — AC #5). Returns
    ///     the ranked hits for the dropdown.
    ///   - `format`: builds the canonical `[[kind:ULID|Title]]` string for the
    ///     selected hit (`DroppedLinkFormatter.link(for:id:displayName:)`). The
    ///     coordinator does the actual range-replace in the text view.
    ///   - `geometry`: returns the anchor `NSView` the dropdown should track
    ///     (the composer's text view). Called each time the dropdown is shown.
    var autocomplete: AutocompleteHooks?

    /// #740: when non-nil, pressing Arrow ↑ while the composer is empty recalls
    /// the previously queued message back into the draft for editing. The caller
    /// loads the queued text into the `text` binding and clears its queue state.
    /// `nil` (default) disables the recall behavior (no queue → no-op).
    var onRecallQueued: (() -> Void)? = nil

    /// `AutocompleteHooks` and `DebounceHandle` are typealias back-compat
    /// shims defined on `ComposerTextView` in
    /// `WikiLinkAutocompleteController.swift` (pointing to the top-level
    /// `WikiLinkAutocompleteHooks` / `WikiLinkAutocompleteDebounceHandle`
    /// shared with the page/source editor, #680). See that file for the type
    /// definitions.

    nonisolated static let accessibilityLabel = "Message"
    private let placeholderText = "Ask a question, or ask the Agent to update the wiki…"

    /// Debounce window for the autocomplete query (AC #5). 150 ms is fast
    /// enough to feel instant while keeping per-keystroke Tantivy queries from
    /// stacking up. Sidebar search uses 300 ms; autocomplete feels more
    /// time-critical so it's tighter. This is the canonical production value
    /// (read by ``debounce``'s default). Tests override ``debounce`` to a much
    /// smaller value (e.g. 5 ms) so the schedule/cancel timing is deterministic
    /// without long `Task.sleep` waits — see `ComposerAutocompleteHostedTests`.
    nonisolated static let autocompleteDebounce: UInt64 = 150

    /// Per-instance debounce override (microseconds... no — milliseconds,
    /// matching ``autocompleteDebounce``'s unit). Tests pass a small value
    /// (e.g. 5 ms) so the debounce window is tight and the cancel/collapse
    /// logic is exercised without relying on CI-timing-sensitive `Task.sleep`
    /// tolerances. Production leaves the default (``autocompleteDebounce``).
    /// The coordinator reads this fresh on every schedule.
    var debounce: UInt64 = ComposerTextView.autocompleteDebounce

    /// Optional debounce scheduler seam (issue #661). When `nil` (default), the
    /// coordinator uses a built-in `Task.sleep`-based scheduler (production
    /// behavior — unchanged from before this seam). Tests inject a manual
    /// scheduler that captures work for an explicit `fireAll()` call so timing
    /// is fully deterministic with no real `Task.sleep`: the prior
    /// `Task.sleep`-based approach deadlocked CI for 6 hours under heavy
    /// integration-tier load because the `@MainActor`-isolated Task bodies
    /// never got scheduled within the polling timeout. Pattern mirrors
    /// `Tests/WikiFSTests/ChangeCoalescerTests.swift`'s `ManualScheduler`.
    var scheduleDebounce: ((UInt64, @escaping () async -> Void) -> DebounceHandle)? = nil

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

    /// Pure: convert a UTF-16 (NSTextView) caret offset to a Swift
    /// `String.Index`/`Character`-count offset the prefix scanner expects.
    /// Clamps to `[0, text.count]`. The scanner rebuilds via `Array(text)` so
    /// the offset must count `Character`s, not UTF-16 units. ASCII wiki-link
    /// prefixes are BMP-stable so the two are equal for the common case;
    /// non-ASCII is still correct because the scanner handles it on its side.
    nonisolated static func clampedSwiftOffset(utf16Offset: Int, in text: String) -> Int {
        guard utf16Offset > 0 else { return 0 }
        let utf16 = Array(text.utf16)
        guard utf16Offset <= utf16.count else { return text.count }
        let prefix = String(decoding: utf16.prefix(utf16Offset), as: UTF16.self)
        return prefix.count
    }

    // MARK: - Key handling (pure, testable)

    nonisolated enum ComposerKeyAction {
        case send
        case insertNewline
        case unhandled
        /// Plain Return while the autocomplete dropdown is open with results:
        /// the coordinator should insert the canonical link for the selected
        /// (or top) row and consume the keystroke (no message send).
        case insertAutocomplete
    }

    /// Pure: decide what a `doCommandBy:` selector + the live modifier flags
    /// mean for the composer.
    ///
    /// Plain Return sends. Shift/Option+Return insert a literal line break.
    /// Cmd+Return falls through (`.unhandled`) so the send button's own
    /// `.keyboardShortcut(.return, modifiers: .command)` is the single path —
    /// otherwise a Cmd+Return keystroke would send twice.
    ///
    /// When `autocompleteOpen` is true AND results are present, plain Return
    /// returns `.insertAutocomplete` instead of `.send` so the coordinator
    /// inserts the canonical link rather than sending the message.
    nonisolated static func keyAction(
        for selector: Selector,
        modifiers: NSEvent.ModifierFlags,
        autocompleteOpen: Bool = false
    ) -> ComposerKeyAction {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return .unhandled }
        if modifiers.contains(.shift) || modifiers.contains(.option) { return .insertNewline }
        if modifiers.contains(.command) { return .unhandled }
        return autocompleteOpen ? .insertAutocomplete : .send
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
        coordinator.teardownAutocomplete()
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

        // MARK: - Autocomplete (#436 / #638 / #680)

        /// The reusable autocomplete pipeline. Owns the dropdown panel, the
        /// debounce scheduler, the local ↑/↓/Escape monitor, and the canonical
        /// link insertion. The coordinator delegates its `textDidChange` /
        /// `doCommandBy:` hooks to this controller so the chat composer and
        /// the page/source editor share one implementation.
        ///
        /// Built lazily from the parent's hooks/debounce/scheduler so a fresh
        /// `Coordinator` (e.g. when SwiftUI rebuilds the representable) picks
        /// up current configuration. Rebuilt on `updateNSView` via
        /// `syncAutocompleteController()`.
        private var autocompleteController: WikiLinkAutocompleteController?

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if parent.text != textView.string {
                parent.text = textView.string
            }
            recomputeHeight(for: textView)
            ensureAutocompleteController()
            autocompleteController?.textDidChange(textView: textView)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let modifiers = (NSApp.currentEvent?.modifierFlags ?? []).intersection(.deviceIndependentFlagsMask)
            ensureAutocompleteController()
            let open = autocompleteController?.hasResults ?? false
            // #740: Arrow ↑ on an empty composer recalls the queued message into
            // the draft for editing (only when the caller wired `onRecallQueued`).
            // We check `string.isEmpty` so ↑ still navigates within multi-line
            // text normally — recall fires only when the draft is clear.
            if (selector == #selector(NSResponder.moveUp(_:))
                || selector == #selector(NSResponder.moveToBeginningOfParagraph(_:)))
                && textView.string.isEmpty,
                let onRecall = parent.onRecallQueued {
                onRecall()
                return true
            }
            switch ComposerTextView.keyAction(for: selector, modifiers: modifiers, autocompleteOpen: open) {
            case .send:
                parent.onSubmit()
                return true
            case .insertAutocomplete:
                // Plain Return while the dropdown is up: insert the selected
                // (or top) row's canonical link and consume. Shift/Option/Cmd
                // still fall through to insert-newline / unhandled via keyAction.
                autocompleteController?.commitAutocomplete()
                return true
            case .insertNewline, .unhandled:
                return false
            }
        }

        // MARK: - Autocomplete controller lifecycle

        /// Lazily build / refresh the controller from the parent's current
        /// `autocomplete` hooks, `debounce`, and `scheduleDebounce`. Safe to
        /// call on every `textDidChange` (no-op when the parent hasn't
        /// changed). The chat composer doesn't change `autocomplete` after
        /// makeNSView (it's bound once in ChatDetailView) — but `updateNSView`
        /// could in principle swap closures, so we re-sync the binding
        /// through the controller's hooks provider.
        private func ensureAutocompleteController() {
            guard parent.autocomplete != nil else {
                // Hooks are nil → autocomplete disabled. Tear down any
                // existing controller so a stale dropdown doesn't linger.
                if let existing = autocompleteController {
                    existing.teardown()
                    autocompleteController = nil
                }
                return
            }
            if autocompleteController == nil {
                autocompleteController = WikiLinkAutocompleteController(
                    hooksProvider: { [weak self] in self?.parent.autocomplete },
                    debounceProvider: { [weak self] in self?.parent.debounce ?? ComposerTextView.autocompleteDebounce },
                    scheduleDebounceProvider: { [weak self] debounce, work in
                        guard let scheduler = self?.parent.scheduleDebounce else { return nil }
                        return scheduler(debounce, work)
                    },
                    placement: .above,  // chat composer convention (composer sits at bottom of chat window)
                    widthProvider: { textView in textView.bounds.width }
                )
                autocompleteController?.textBinding = { [weak self] newText in
                    guard let self else { return }
                    self.parent.text = newText
                }
            }
        }

        /// Called from `dismantleNSView` — release the panel + cancel
        /// in-flight work so it can't leak across SwiftUI rebuilds.
        func teardownAutocomplete() {
            autocompleteController?.teardown()
            autocompleteController = nil
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
