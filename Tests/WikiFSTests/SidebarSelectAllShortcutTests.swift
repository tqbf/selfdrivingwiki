import AppKit
import CoreGraphics
import Testing
@testable import WikiFS

/// Verifies the Cmd+A "select all rows" shortcut on the sidebar table views is
/// scoped to when the table (or a descendant) is the first responder, so it
/// does not steal Cmd+A from the omnibox or other text fields that share the
/// window (issue #154).
///
/// `performKeyEquivalent(with:)` is dispatched across the window's entire view
/// hierarchy for every key-down, not just to the first responder — so the table
/// must confirm it actually owns focus before consuming Cmd+A.
@MainActor
@Suite struct SidebarSelectAllShortcutTests {

    // MARK: - Helpers

    /// A Cmd+A key-down event, matching what AppKit dispatches for ⌘A.
    private func cmdAEvent() -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0)
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
    }

    // MARK: - Pure gating predicate (no window/visibility dependency)

    @Test func predicateReturnsFalseForNilFirstResponder() {
        let table = PagesNSTableView()
        #expect(NSView.isFirstResponder(nil, selfOrDescendantOf: table) == false)
    }

    @Test func predicateReturnsTrueWhenViewIsItselfFirstResponder() {
        let table = PagesNSTableView()
        #expect(NSView.isFirstResponder(table, selfOrDescendantOf: table))
    }

    @Test func predicateReturnsTrueForDescendantFirstResponder() {
        // Mimics an inline field editor hosted inside the table: a subview of
        // the table being first responder still counts as "table owns focus".
        let table = PagesNSTableView()
        let hosted = NSView()
        table.addSubview(hosted)
        #expect(NSView.isFirstResponder(hosted, selfOrDescendantOf: table))
    }

    @Test func predicateReturnsFalseForUnrelatedFirstResponder() {
        // The omnibox is a sibling in the window, not a descendant of the table.
        let table = PagesNSTableView()
        let omnibox = NSTextField(string: "query")
        #expect(NSView.isFirstResponder(omnibox, selfOrDescendantOf: table) == false)
    }

    // MARK: - Integration: the reported bug (issue #154)

    @Test func pagesTableDoesNotStealCmdAFromOmniboxField() throws {
        let event = try #require(cmdAEvent())
        let window = makeWindow()
        let table = PagesNSTableView()
        window.contentView?.addSubview(table)
        let omnibox = NSTextField(string: "omnibox text")
        window.contentView?.addSubview(omnibox)

        // The omnibox owns focus. AppKit swaps in the window's shared field
        // editor (an NSTextView) as first responder — it is NOT a descendant of
        // the table, exactly the scenario in issue #154.
        #expect(window.makeFirstResponder(omnibox))
        #expect(window.firstResponder !== table)
        #expect(table.isSelfOrDescendantFirstResponder() == false)

        // Cmd+A must fall through so the field can select its own text.
        #expect(table.performKeyEquivalent(with: event) == false)
    }

    @Test func sourcesTableDoesNotStealCmdAFromOmniboxField() throws {
        let event = try #require(cmdAEvent())
        let window = makeWindow()
        let table = SourcesNSTableView()
        window.contentView?.addSubview(table)
        let omnibox = NSTextField(string: "omnibox text")
        window.contentView?.addSubview(omnibox)

        #expect(window.makeFirstResponder(omnibox))
        #expect(window.firstResponder !== table)
        #expect(table.isSelfOrDescendantFirstResponder() == false)

        #expect(table.performKeyEquivalent(with: event) == false)
    }

    // MARK: - Only Cmd+A is intercepted

    @Test func pagesTableDoesNotInterceptOtherCommandKeys() throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "b",
            charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11))
        let window = makeWindow()
        let table = PagesNSTableView()
        window.contentView?.addSubview(table)
        // Anything that isn't Cmd+A defers to super regardless of focus.
        window.makeFirstResponder(table)

        #expect(table.performKeyEquivalent(with: event) == false)
    }
}
