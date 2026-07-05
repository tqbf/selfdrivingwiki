import AppKit
import SwiftUI
import WikiFSCore

/// AppKit-backed omnibox field for the window toolbar. A SwiftUI `TextField`
/// cannot accept first responder inside an `NSToolbar` item (the toolbar hosts
/// its items in a separate view tree, isolated from the window's responder
/// chain), so the editable field is a real `NSSearchField`. Suggestions are
/// shown in a `.nonactivatingPanel` child window so the field keeps focus while
/// the user types to refine.
struct OmniboxSearchField: NSViewRepresentable {
    @Binding var text: String
    /// The current location (`[[Page Title]]`) shown when the field isn't being
    /// edited — the browser URL-bar "where am I" cue.
    var locationText: String
    var results: [WikiPageSummary]
    /// Bumped by the parent (Cmd-L) to request focus.
    var focusToken: Int
    var onTextChange: (String) -> Void
    var onSubmit: () -> Void
    var onEscape: () -> Void
    var onBlur: () -> Void
    var onSelect: (WikiPageSummary) -> Void
    /// Leading inset for the editable text, so it clears the overlaid Page Menu
    /// and add-bookmark icons. Varies with hover (the "+" only needs room when
    /// it's shown), so it's applied live in `updateNSView`.
    var textLeadingInset: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: - Icon-less search field

    /// An `NSSearchField` styled as an address bar: the leading magnifier is
    /// suppressed by zeroing the search-button rect on its cell, so the omnibox
    /// carries no built-in icon (the reader button is the only leading glyph).
    final class AddressSearchField: NSSearchField {
        override class var cellClass: AnyClass? {
            get { AddressSearchFieldCell.self }
            set {}
        }
    }

    final class AddressSearchFieldCell: NSSearchFieldCell {
        /// Set live from `updateNSView`; how far the text is inset to clear the
        /// overlaid leading icons.
        var leadingTextInset: CGFloat = AddressBarMetrics.textLeadingInset

        override func searchButtonRect(forBounds rect: NSRect) -> NSRect { .zero }

        // Suppress the trailing circular "clear" (✕) button — the omnibox is an
        // address bar, not a search box, so it carries no built-in glyphs.
        override func cancelButtonRect(forBounds rect: NSRect) -> NSRect { .zero }

        override func searchTextRect(forBounds rect: NSRect) -> NSRect {
            var r = super.searchTextRect(forBounds: rect)
            let newX = rect.minX + leadingTextInset
            r.size.width += r.origin.x - newX
            r.origin.x = newX
            return r
        }
    }

    func makeNSView(context: Context) -> NSSearchField {
        // `AddressSearchField` suppresses the built-in magnifier so the reader
        // button is the omnibox's single leading icon (address bar, not search).
        let field = AddressSearchField()
        field.delegate = context.coordinator
        field.placeholderString = "Search for pages"
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = false
        field.focusRingType = .none
        field.controlSize = .large
        field.font = .systemFont(ofSize: NSFont.systemFontSize(for: .regular))
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        let coord = context.coordinator
        coord.parent = self

        // Apply the (hover-dependent) text inset live so the text reflows to
        // clear the icons as the "+" appears/disappears.
        if let cell = field.cell as? AddressSearchFieldCell,
           cell.leadingTextInset != textLeadingInset {
            cell.leadingTextInset = textLeadingInset
            field.needsDisplay = true
            field.needsLayout = true
        }

        // When the field isn't being edited, mirror the current location into it
        // (Safari shows the URL when idle). While editing, leave the user's text.
        let isEditing = field.currentEditor() != nil
        if !isEditing && field.stringValue != locationText {
            field.stringValue = locationText
        }

        // Focus request (Cmd-L): make first responder and select-all so typing
        // replaces the shown location.
        if focusToken != coord.lastFocusToken {
            coord.lastFocusToken = focusToken
            DispatchQueue.main.async { [weak field] in
                guard let field, let window = field.window else { return }
                window.makeFirstResponder(field)
                field.currentEditor()?.selectAll(nil)
            }
        }

        coord.render(results: results, anchor: field)
    }

    static func dismantleNSView(_ field: NSSearchField, coordinator: Coordinator) {
        coordinator.hidePanel()
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate, @unchecked Sendable {
        var parent: OmniboxSearchField
        var lastFocusToken = 0
        private var panel: SuggestionsPanel?

        // Keyboard-driven highlight. The arrow keys never reliably reach
        // `control(_:textView:doCommandBy:)` when the field lives inside an
        // `NSToolbar` item (the toolbar hosts its field editor in a responder
        // chain isolated from the window), so arrow navigation is handled by a
        // local `NSEvent` key monitor (`handleArrowKey`) that intercepts the
        // event ahead of the responder chain. The "which row is selected" state
        // still lives here and is pushed into the SwiftUI list for rendering.
        //
        // `@unchecked Sendable`: the coordinator is touched only on the main
        // thread — SwiftUI's `updateNSView`/delegate callbacks and local event
        // monitors both deliver there — so the cross-isolation capture in
        // `handleArrowKey` is race-free.
        private var selectedIndex: Int?
        private var results: [WikiPageSummary] = []
        private var cachedResultIDs: [PageID] = []
        private weak var anchor: NSSearchField?
        private var keyMonitor: Any?

        init(_ parent: OmniboxSearchField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            parent.text = field.stringValue
            parent.onTextChange(field.stringValue)
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            // Fires when focus leaves the field to another responder in the main
            // window (clicking the page, sidebar, etc.). The non-activating
            // suggestions panel never becomes key, so clicking a result does NOT
            // end editing here.
            parent.onBlur()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                // Enter navigates to the arrow-selected row when there is one;
                // otherwise it falls back to the top result (the default target).
                if let index = selectedIndex, results.indices.contains(index) {
                    parent.onSelect(results[index])
                } else {
                    parent.onSubmit()
                }
                control.window?.makeFirstResponder(nil)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
                control.window?.makeFirstResponder(nil)
                return true
            // Arrow keys are handled by the local key monitor (`handleArrowKey`),
            // not here: the field editor for an `NSSearchField` inside an
            // `NSToolbar` item lives in a responder chain isolated from the
            // window, so `moveDown:`/`moveUp:` don't reliably reach this delegate
            // method in the running app (issue #155).
            default:
                return false
            }
        }

        @MainActor
        func render(results: [WikiPageSummary], anchor: NSSearchField) {
            // Reset the keyboard highlight whenever the result set changes, so a
            // stale index can't point past the end of a new, shorter list.
            let ids = results.map(\.id)
            if ids != cachedResultIDs {
                cachedResultIDs = ids
                selectedIndex = nil
            }
            self.results = results
            self.anchor = anchor
            presentPanel()
        }

        @MainActor
        private func presentPanel() {
            guard let anchor, !results.isEmpty, anchor.window != nil else { hidePanel(); return }
            let panel = self.panel ?? SuggestionsPanel()
            self.panel = panel
            panel.update(results: results, selectedIndex: selectedIndex, width: anchor.bounds.width) { [weak self, weak anchor] result in
                self?.parent.onSelect(result)
                anchor?.window?.makeFirstResponder(nil)
            }
            panel.present(under: anchor)
            installKeyMonitor()
        }

        @MainActor
        func hidePanel() {
            removeKeyMonitor()
            guard let panel else { return }
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }

        // MARK: - Arrow-key monitor

        /// Installs a local keyDown monitor (idempotent). Removed in
        /// `hidePanel` so arrows fall through to the field normally when the
        /// panel isn't showing.
        private func installKeyMonitor() {
            guard keyMonitor == nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return self.handleArrowKey(event)
            }
        }

        private func removeKeyMonitor() {
            guard let keyMonitor else { return }
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }

        /// Consumes up/down arrow keys while the suggestions panel is showing;
        /// passes every other event through untouched. The monitor is installed
        /// only while the panel is up (and removed in `hidePanel`, which runs
        /// when the field blurs / results clear), so by the time we're here the
        /// omnibox field editor holds first responder. The consume/pass-through
        /// decision is made here from nonisolated state + the (Sendable) key
        /// code; the `@MainActor` panel update runs synchronously via
        /// `assumeIsolated` (local monitors deliver on the main thread).
        private func handleArrowKey(_ event: NSEvent) -> NSEvent? {
            guard !results.isEmpty else { return event }
            let delta: Int
            switch event.keyCode {
            case 125: delta = 1   // Down arrow
            case 126: delta = -1  // Up arrow
            default: return event
            }
            MainActor.assumeIsolated { self.applyArrow(delta: delta) }
            return nil
        }

        /// Advances the keyboard highlight and pushes the new row into the panel.
        @MainActor
        private func applyArrow(delta: Int) {
            guard let next = OmniboxSelection.advance(current: selectedIndex,
                                                     count: results.count,
                                                     delta: delta) else { return }
            selectedIndex = next
            presentPanel()
        }
    }
}

/// Pure, testable keyboard-highlight advancement for the omnibox suggestions
/// list. `current == nil` means nothing is selected yet; `delta > 0` moves toward
/// the end of the list, `delta < 0` toward the start. Clamps at the ends (no
/// wrap), matching the caret-free behavior of a browser address-bar dropdown.
enum OmniboxSelection {
    /// Returns the new selected index, or `nil` if there is nothing to select
    /// (empty list). When `current == nil`, the first down selects row 0 and the
    /// first up selects the last row.
    static func advance(current: Int?, count: Int, delta: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return delta > 0 ? 0 : count - 1 }
        return max(0, min(count - 1, current + delta))
    }
}

/// A borderless, non-activating child window that hosts the ranked suggestions
/// list under the omnibox. Non-key so the search field keeps first responder.
@MainActor
final class SuggestionsPanel: NSPanel {
    private var hosting: NSHostingView<AnyView>?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = true
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(results: [WikiPageSummary], selectedIndex: Int?, width: CGFloat, onSelect: @escaping (WikiPageSummary) -> Void) {
        let content = AddressResultsList(results: results, selectedIndex: selectedIndex, onSelect: onSelect)
            .frame(width: width)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
        let root = AnyView(content)

        let host: NSHostingView<AnyView>
        if let existing = hosting {
            existing.rootView = root
            host = existing
        } else {
            host = NSHostingView(rootView: root)
            contentView = host
            hosting = host
        }
        host.frame = NSRect(x: 0, y: 0, width: width, height: host.fittingSize.height)
        setContentSize(NSSize(width: width, height: host.fittingSize.height))
    }

    /// Position the panel just below the anchor field and attach it as a child
    /// so it tracks window moves.
    func present(under field: NSView) {
        guard let window = field.window else { return }
        let rectInWindow = field.convert(field.bounds, to: nil)
        let rectOnScreen = window.convertToScreen(rectInWindow)
        let origin = NSPoint(x: rectOnScreen.minX, y: rectOnScreen.minY - frame.height - 4)
        setFrameOrigin(origin)
        if parent == nil {
            window.addChildWindow(self, ordered: .above)
        }
        orderFront(nil)
    }
}
