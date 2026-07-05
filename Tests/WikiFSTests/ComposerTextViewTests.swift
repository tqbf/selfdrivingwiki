import AppKit
import SwiftUI
import Testing
@testable import WikiFS

/// Tests for `ComposerTextView`, the `NSTextView`-backed chat composer that
/// replaced the `TextField(axis: .vertical)` composer in
/// `QueryConversationView` (which beachballed the app on pasting ~150 lines of
/// markdown — every keystroke re-measured the entire string on macOS's
/// NSTextField/field-editor path).
///
/// Three things to pin down:
///   1. `clampedHeight` — the pure 1–6 line height clamp fed into
///      `.frame(height:)`.
///   2. `keyAction` — the pure Return/Shift+Return/Option+Return/Cmd+Return
///      decision table fed into the `NSTextViewDelegate` callback.
///   3. Window-hosted integration — a real `NSTextView` built by
///      `ComposerTextView.makeConfiguredTextView`, wired to a `Coordinator`,
///      exercising layout + delegate callbacks against real AppKit state
///      (following the `SidebarSelectAllShortcutTests` pattern of hosting real
///      AppKit views in a headless `NSWindow`).
@MainActor
@Suite struct ComposerTextViewTests {

    // MARK: - clampedHeight matrix

    // Constants mirrored from `ComposerTextView.Metrics` so the test pins the
    // exact numbers, not just "whatever the implementation currently does".
    // `lineHeight` here is an arbitrary concrete value (20pt) — the clamp is
    // linear in `lineHeight`, so this exercises the formula without coupling
    // the test to a real font's metrics.
    private let lineHeight: CGFloat = 20
    private var minHeight: CGFloat { lineHeight * 1 + ComposerTextView.Metrics.verticalInset }
    private var maxHeight: CGFloat { lineHeight * 6 + ComposerTextView.Metrics.verticalInset }

    /// Below one line's worth of content → clamps up to the 1-line minimum.
    @Test func clampedHeightBelowOneLineClampsToMinimum() {
        #expect(ComposerTextView.clampedHeight(contentHeight: 0, lineHeight: lineHeight) == minHeight)
        #expect(ComposerTextView.clampedHeight(contentHeight: 10, lineHeight: lineHeight) == minHeight)
    }

    /// Between 1 and 6 lines → passes through unchanged.
    @Test func clampedHeightWithinBandPassesThrough() {
        let midHeight: CGFloat = lineHeight * 3 + ComposerTextView.Metrics.verticalInset
        #expect(ComposerTextView.clampedHeight(contentHeight: midHeight, lineHeight: lineHeight) == midHeight)
        // Exactly at the min/max boundary also passes through unchanged.
        #expect(ComposerTextView.clampedHeight(contentHeight: minHeight, lineHeight: lineHeight) == minHeight)
        #expect(ComposerTextView.clampedHeight(contentHeight: maxHeight, lineHeight: lineHeight) == maxHeight)
    }

    /// Above six lines' worth of content → clamps down to the 6-line maximum.
    @Test func clampedHeightAboveSixLinesClampsToMaximum() {
        #expect(ComposerTextView.clampedHeight(contentHeight: 10_000, lineHeight: lineHeight) == maxHeight)
    }

    // MARK: - keyAction matrix

    private let insertNewline = #selector(NSResponder.insertNewline(_:))
    private let insertTab = #selector(NSResponder.insertTab(_:))

    @Test func plainReturnSends() {
        #expect(ComposerTextView.keyAction(for: insertNewline, modifiers: []) == .send)
    }

    @Test func shiftReturnInsertsNewline() {
        #expect(ComposerTextView.keyAction(for: insertNewline, modifiers: .shift) == .insertNewline)
    }

    @Test func optionReturnInsertsNewline() {
        #expect(ComposerTextView.keyAction(for: insertNewline, modifiers: .option) == .insertNewline)
    }

    @Test func shiftOptionReturnInsertsNewline() {
        #expect(ComposerTextView.keyAction(for: insertNewline, modifiers: [.shift, .option]) == .insertNewline)
    }

    @Test func unrelatedSelectorIsUnhandled() {
        #expect(ComposerTextView.keyAction(for: insertTab, modifiers: []) == .unhandled)
    }

    /// Cmd+Return is pinned to `.unhandled`, NOT `.send`: the send button
    /// already carries `.keyboardShortcut(.return, modifiers: .command)`, so
    /// if the delegate also called `onSubmit()` for Cmd+Return the message
    /// would be sent twice — once via the button's key equivalent, once via
    /// this callback. Falling through here makes the button's key equivalent
    /// the single path for Cmd+Return.
    @Test func commandReturnIsUnhandledSoTheSendButtonOwnsIt() {
        #expect(ComposerTextView.keyAction(for: insertNewline, modifiers: .command) == .unhandled)
    }

    // MARK: - Window-hosted integration

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
    }

    private var bodyFont: NSFont { .preferredFont(forTextStyle: .body) }

    /// Hosts a real, fully-configured `NSTextView` (as built by
    /// `ComposerTextView.makeConfiguredTextView`) inside a headless `NSWindow`
    /// and wires it to a live `Coordinator`, mirroring what
    /// `ComposerTextView.makeNSView` does — without going through SwiftUI's
    /// `NSViewRepresentable` update cycle, which requires a `Context` that
    /// isn't constructible outside of SwiftUI's own rendering.
    private func makeHostedComposer(
        text: Binding<String>,
        isEditable: Bool,
        measuredHeight: Binding<CGFloat>
    ) -> (window: NSWindow, textView: NSTextView, coordinator: ComposerTextView.Coordinator) {
        let parent = ComposerTextView(
            text: text,
            isEditable: isEditable,
            font: bodyFont,
            onSubmit: {},
            measuredHeight: measuredHeight
        )
        let coordinator = ComposerTextView.Coordinator(parent)
        let textView = ComposerTextView.makeConfiguredTextView(font: bodyFont)
        textView.delegate = coordinator
        textView.isEditable = isEditable
        textView.string = text.wrappedValue

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        scrollView.documentView = textView

        let window = makeWindow()
        window.contentView?.addSubview(scrollView)

        return (window, textView, coordinator)
    }

    /// Setting a large (150-line) string and forcing layout completes and
    /// yields a `measuredHeight` equal to the 6-line clamp — the case that
    /// previously beachballed the field-editor-backed `TextField`.
    @Test func largePasteClampsToSixLineMaximum() async {
        var text = ""
        var measuredHeight: CGFloat = ComposerTextView.oneLineHeight(for: bodyFont)
        let textBinding = Binding(get: { text }, set: { text = $0 })
        let heightBinding = Binding(get: { measuredHeight }, set: { measuredHeight = $0 })

        let (_, textView, coordinator) = makeHostedComposer(
            text: textBinding, isEditable: true, measuredHeight: heightBinding)

        let pasted = Array(repeating: "Line of pasted markdown text.", count: 150).joined(separator: "\n")
        textView.string = pasted
        coordinator.recomputeHeight(for: textView)

        // `recomputeHeight` defers the actual write (see its doc comment: it
        // must never write synchronously, since it also runs from inside
        // `updateNSView`). Yield to the main actor's task queue so the
        // deferred `Task { @MainActor in ... }` has a chance to run before we
        // assert on its effect.
        let expectedMax = ComposerTextView.clampedHeight(
            contentHeight: .greatestFiniteMagnitude,
            lineHeight: NSLayoutManager().defaultLineHeight(for: bodyFont))
        await Task.yield()
        await Task.yield()

        #expect(heightBinding.wrappedValue == expectedMax)
    }

    /// Simulating an edit (replacing the text storage, which fires
    /// `textDidChange` the same way live typing does) propagates the new
    /// string into the bound `text`.
    @Test func editPropagatesToBoundText() {
        var text = "initial"
        var measuredHeight: CGFloat = ComposerTextView.oneLineHeight(for: bodyFont)
        let textBinding = Binding(get: { text }, set: { text = $0 })
        let heightBinding = Binding(get: { measuredHeight }, set: { measuredHeight = $0 })

        let (_, textView, coordinator) = makeHostedComposer(
            text: textBinding, isEditable: true, measuredHeight: heightBinding)

        textView.string = "edited by the user"
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))

        #expect(textBinding.wrappedValue == "edited by the user")
    }

    /// Narrowing the text view's width (what a window resize does to the
    /// document view) must re-trigger the height measurement even though
    /// nothing about the *text* changed — otherwise a multi-line draft goes
    /// stale (clipped or gapped) until the next keystroke. `makeHostedComposer`
    /// doesn't wire the frame observer (that's specific to the live
    /// `makeNSView` circuit), so this test installs it manually the same way
    /// `makeNSView` does: `postsFrameChangedNotifications = true` +
    /// `observeFrameChanges(for:)`.
    ///
    /// This is a headless host with no real window layout pass, so there's no
    /// way to actually observe re-wrapping change the *value* of the clamp
    /// (150 explicit lines already exceed the 6-line max at any width the
    /// text container could plausibly have). What this test can and does
    /// assert: the observer path runs without crashing, and — by resetting
    /// `measuredHeight` to a sentinel before narrowing — that the frame-change
    /// callback actually re-fires `recomputeHeight` and writes the clamp back
    /// (not just that the value happens to already match).
    @Test func narrowingWidthRecomputesHeightViaFrameObserver() async {
        var text = ""
        var measuredHeight: CGFloat = ComposerTextView.oneLineHeight(for: bodyFont)
        let textBinding = Binding(get: { text }, set: { text = $0 })
        let heightBinding = Binding(get: { measuredHeight }, set: { measuredHeight = $0 })

        let (_, textView, coordinator) = makeHostedComposer(
            text: textBinding, isEditable: true, measuredHeight: heightBinding)
        textView.postsFrameChangedNotifications = true
        coordinator.observeFrameChanges(for: textView)

        let pasted = Array(repeating: "Line of pasted markdown text.", count: 150).joined(separator: "\n")
        textView.string = pasted
        coordinator.recomputeHeight(for: textView)
        await Task.yield()
        await Task.yield()

        let lineHeight = NSLayoutManager().defaultLineHeight(for: bodyFont)
        let expectedMax = ComposerTextView.clampedHeight(contentHeight: .greatestFiniteMagnitude, lineHeight: lineHeight)
        #expect(heightBinding.wrappedValue == expectedMax)

        // Reset to a sentinel so the final assertion demonstrates the
        // frame-change path re-wrote the value, not that it happened to
        // already hold the right answer.
        measuredHeight = ComposerTextView.oneLineHeight(for: bodyFont)

        textView.setFrameSize(NSSize(width: 120, height: textView.frame.height))
        await Task.yield()
        await Task.yield()

        #expect(heightBinding.wrappedValue == expectedMax)
    }

    /// Toggling `isEditable` on the underlying `NSTextView` is respected —
    /// this is the same knob `updateNSView` flips from the caller's `canType`.
    @Test func isEditableTogglesTextViewEditability() {
        var text = "hello"
        var measuredHeight: CGFloat = ComposerTextView.oneLineHeight(for: bodyFont)
        let textBinding = Binding(get: { text }, set: { text = $0 })
        let heightBinding = Binding(get: { measuredHeight }, set: { measuredHeight = $0 })

        let (_, textView, _) = makeHostedComposer(
            text: textBinding, isEditable: true, measuredHeight: heightBinding)
        #expect(textView.isEditable == true)
        #expect(textView.isSelectable == true)

        textView.isEditable = false
        #expect(textView.isEditable == false)
        // `isSelectable` stays true regardless — a non-editable composer (e.g.
        // while the agent is generating) should still let the user select/copy
        // the draft.
        #expect(textView.isSelectable == true)
    }
}
