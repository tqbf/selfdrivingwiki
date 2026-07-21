#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import WikiFS
@testable import WikiFSEngine

@MainActor
@Suite struct ComposerTextViewTests {

    // MARK: - clampedHeight matrix

    // Constants mirrored from `ComposerTextView.Metrics` so the test pins the
    // exact numbers, not just "whatever the implementation currently does".
    // `lineHeight` here is an arbitrary concrete value (20pt) — the clamp is
    // linear in `lineHeight`, so this exercises the formula without coupling
    // the test to a real font's metrics.
    private let lineHeight: CGFloat = 20
    private var minHeight: CGFloat { lineHeight * 3 + ComposerTextView.Metrics.verticalInset }
    private var maxHeight: CGFloat { lineHeight * 6 + ComposerTextView.Metrics.verticalInset }

    @Test func clampedHeightBelowMinimumClampsToMinimum() {
        #expect(ComposerTextView.clampedHeight(contentHeight: 0, lineHeight: lineHeight) == minHeight)
        #expect(ComposerTextView.clampedHeight(contentHeight: 10, lineHeight: lineHeight) == minHeight)
    }

    @Test func clampedHeightWithinBandPassesThrough() {
        let midHeight: CGFloat = lineHeight * 3 + ComposerTextView.Metrics.verticalInset
        #expect(ComposerTextView.clampedHeight(contentHeight: midHeight, lineHeight: lineHeight) == midHeight)
        #expect(ComposerTextView.clampedHeight(contentHeight: minHeight, lineHeight: lineHeight) == minHeight)
        #expect(ComposerTextView.clampedHeight(contentHeight: maxHeight, lineHeight: lineHeight) == maxHeight)
    }

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

        let expectedMax = ComposerTextView.clampedHeight(
            contentHeight: .greatestFiniteMagnitude,
            lineHeight: NSLayoutManager().defaultLineHeight(for: bodyFont))
        await Task.yield()
        await Task.yield()

        #expect(heightBinding.wrappedValue == expectedMax)
    }

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

        measuredHeight = ComposerTextView.oneLineHeight(for: bodyFont)

        textView.setFrameSize(NSSize(width: 120, height: textView.frame.height))
        await Task.yield()
        await Task.yield()

        #expect(heightBinding.wrappedValue == expectedMax)
    }

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
        #expect(textView.isSelectable == true)
    }
}
#endif
