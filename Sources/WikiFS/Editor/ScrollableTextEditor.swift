import AppKit
import SwiftUI
import WikiFSCore
import WikiFSLinks
import WikiFSSearch

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

    // MARK: - Wiki-link autocomplete (#680)

    /// Optional autocomplete integration (issue #680). When non-nil, the
    /// coordinator runs a debounced query for each keystroke that lands inside
    /// an open `[[kind:partial` trigger, surfaces the results in the same
    /// `ChatAutocompletePanel` the chat composer uses (#684 just generalized
    /// the panel's `present(caretRect:in:placement:)` API for this reuse), and
    /// inserts the canonical `[[kind:ULID|Title]]` form on Return / click.
    ///
    /// The hooks (`fetch`: Tantivy autocomplete, `format`: canonical link)
    /// are decoupled from `WikiFSCore` / `DroppedLinkFormatter` so the AppKit
    /// controller stays dependency-light. Built by `PageDetailView` and
    /// `SourceDetailView` from `store.tantivySearch` (same pattern as
    /// `ChatDetailView.chatAutocompleteHooks`).
    var autocomplete: WikiLinkAutocompleteHooks? = nil

    /// Preferred dropdown placement relative to the caret. The chat composer
    /// uses `.above` (composer sits at the bottom of the chat window); the
    /// editor MUST use `.below` (a tall NSTextView in the middle of the window
    /// has more room below the caret than above). Defaults to `.below` since
    /// the only consumer of `ScrollableTextEditor` is the page/source editor.
    var autocompletePlacement: ChatAutocompletePanel.Placement = .below

    /// Debounce window (ms) for the autocomplete Tantivy query. Mirrors the
    /// chat composer's `ComposerTextView.autocompleteDebounce` (150 ms). Tests
    /// pass a smaller value via the construction-time `debounce` parameter.
    var autocompleteDebounce: UInt64 = ComposerTextView.autocompleteDebounce

    /// Optional debounce scheduler seam (issue #661 — same goal as the chat
    /// composer's): tests inject a manual scheduler that captures work for an
    /// explicit `fireAll()` call so the timing is fully deterministic with no
    /// real `Task.sleep`. Production leaves `nil` and the controller uses its
    /// built-in `Task.sleep` scheduler.
    var autocompleteScheduleDebounce:
        ((UInt64, @escaping () async -> Void) -> WikiLinkAutocompleteDebounceHandle)? = nil

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

    /// Final teardown — cancel any in-flight autocomplete query and release the
    /// dropdown panel so it can't leak across SwiftUI view rebuilds. Mirrors
    /// `ComposerTextView.dismantleNSView` (#436).
    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.teardownAutocomplete()
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

        // MARK: - Autocomplete (#680)

        /// The reusable autocomplete pipeline (extracted from
        /// `ComposerTextView.Coordinator` so the chat composer and this editor
        /// share one implementation). Built lazily from the parent's hooks /
        /// debounce / scheduler. The Coordinator's `textDidChange` /
        /// `doCommandBy:` delegate methods route to this controller.
        private var autocompleteController: WikiLinkAutocompleteController?

        init(_ parent: ScrollableTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if parent.text != textView.string {
                parent.text = textView.string
            }
            reportCaret(in: textView)
            ensureAutocompleteController()
            autocompleteController?.textDidChange(textView: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            reportCaret(in: textView)
        }

        /// `doCommandBy:` is the NSTextView's hook for "the user just did
        /// this text command" — Return, Tab, Backspace, etc. The editor uses
        /// it only to intercept Plain Return when the autocomplete dropdown is
        /// open (consume → commit the selected row). Every other selector
        /// falls through to NSTextView's default behavior (insert newline,
        /// insert tab, etc.) by returning `false`.
        ///
        /// Mirrors `ComposerTextView.Coordinator.textView(_:doCommandBy:)` but
        /// is simpler because the editor doesn't have a "send" action — plain
        /// Return in the editor just inserts a newline (NSTextView's default).
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            ensureAutocompleteController()
            let modifiers = (NSApp.currentEvent?.modifierFlags ?? []).intersection(.deviceIndependentFlagsMask)
            // The controller returns true only when the dropdown is open AND
            // the Return was plain (no Shift/Option/Cmd). Shift+Return etc.
            // fall through to NSTextView's literal-newline default behavior.
            return autocompleteController?.shouldConsumeReturn(modifiers: modifiers) ?? false
        }

        // MARK: - Autocomplete controller lifecycle

        /// Lazily build / refresh the controller from the parent's current
        /// `autocomplete` hooks. Safe to call on every `textDidChange` (no-op
        /// when the parent hasn't changed). The host view (PageDetailView /
        /// SourceDetailView) builds `autocomplete` once from
        /// `store.tantivySearch` — it doesn't change between SwiftUI updates
        /// for the same wiki — but the controller is rebuilt if `autocomplete`
        /// transitions to nil (wiki closed) so a stale dropdown doesn't linger.
        private func ensureAutocompleteController() {
            guard parent.autocomplete != nil else {
                if let existing = autocompleteController {
                    existing.teardown()
                    autocompleteController = nil
                }
                return
            }
            if autocompleteController == nil {
                autocompleteController = WikiLinkAutocompleteController(
                    hooksProvider: { [weak self] in self?.parent.autocomplete },
                    debounceProvider: { [weak self] in
                        self?.parent.autocompleteDebounce ?? ComposerTextView.autocompleteDebounce
                    },
                    scheduleDebounceProvider: { [weak self] debounce, work in
                        guard let scheduler = self?.parent.autocompleteScheduleDebounce else { return nil }
                        return scheduler(debounce, work)
                    },
                    placement: parent.autocompletePlacement,
                    widthProvider: { textView in
                        // The editor is monospaced + wide; a 460pt dropdown
                        // (same as the chat composer's default width) is
                        // readable and doesn't visually overpower the line
                        // the caret is on. Clamp to the text view's bounds so
                        // a narrow editor window (split-view on a small
                        // screen) doesn't overflow.
                        max(min(textView.bounds.width, 460), 240)
                    }
                )
                autocompleteController?.textBinding = { [weak self] newText in
                    guard let self else { return }
                    self.parent.text = newText
                }
            }
        }

        /// Final teardown on dismantle: cancel in-flight query, drop the key
        /// monitor, close the panel. Called from `dismantleNSView`.
        func teardownAutocomplete() {
            autocompleteController?.teardown()
            autocompleteController = nil
        }

        private func reportCaret(in textView: NSTextView) {
            let caret = textView.selectedRange().location
            guard caret != lastReportedCaret else { return }
            lastReportedCaret = caret
            parent.onCaretChange?(caret)
        }
    }
}
