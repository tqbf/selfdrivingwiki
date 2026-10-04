#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import WikiFS
@testable import WikiFSEngine

@MainActor
struct ComposerTextViewTests {

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
    ) async -> (lease: HostedAppKitTestGate.Lease, window: NSWindow, textView: NSTextView, coordinator: ComposerTextView.Coordinator) {
        let lease = await HostedAppKitTestGate.shared.acquire()
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

        return (lease, window, textView, coordinator)
    }

    @Test func largePasteClampsToSixLineMaximum() async {
        var text = ""
        var measuredHeight: CGFloat = ComposerTextView.oneLineHeight(for: bodyFont)
        let textBinding = Binding(get: { text }, set: { text = $0 })
        let heightBinding = Binding(get: { measuredHeight }, set: { measuredHeight = $0 })

        let (lease, window, textView, coordinator) = await makeHostedComposer(
            text: textBinding, isEditable: true, measuredHeight: heightBinding)
        defer { window.orderOut(nil); lease.release() }

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

    // MARK: - Pending height write lifecycle (2026-10-03 beachball follow-up)

    /// Counts every `measuredHeight` binding set so tests can tell the
    /// coordinator's deferred writes from external writes (zoom resets).
    @MainActor
    private final class HeightBox {
        var value: CGFloat
        private(set) var setCount = 0

        init(_ value: CGFloat) {
            self.value = value
        }

        var binding: Binding<CGFloat> {
            Binding { self.value } set: {
                self.value = $0
                self.setCount += 1
            }
        }
    }

    private func makePendingWriteFixture() async -> (
        lease: HostedAppKitTestGate.Lease, window: NSWindow, textView: NSTextView,
        coordinator: ComposerTextView.Coordinator, height: HeightBox
    ) {
        let height = HeightBox(ComposerTextView.oneLineHeight(for: bodyFont))
        let text = ""
        let textBinding = Binding(get: { text }, set: { _ in })
        let (lease, window, textView, coordinator) = await makeHostedComposer(
            text: textBinding, isEditable: true, measuredHeight: height.binding)
        return (lease, window, textView, coordinator, height)
    }

    private var pastedLongText: String {
        Array(repeating: "Line of pasted markdown text.", count: 150).joined(separator: "\n")
    }

    private var expectedMaxHeight: CGFloat {
        ComposerTextView.clampedHeight(
            contentHeight: .greatestFiniteMagnitude,
            lineHeight: NSLayoutManager().defaultLineHeight(for: bodyFont))
    }

    private var expectedMinHeight: CGFloat {
        ComposerTextView.clampedHeight(
            contentHeight: 0,
            lineHeight: NSLayoutManager().defaultLineHeight(for: bodyFont))
    }

    /// The same measured height must not spawn a second deferred write while
    /// one for that value is still in flight (the pre-fix loop spawned a task
    /// on every frame; measured live at ~75 spawns/second against the
    /// 2026-10-03 beachball). Five recomputes before any drain must produce
    /// exactly one binding write.
    @Test func repeatedRecomputeWithSameHeightWritesOnce() async {
        let (lease, window, textView, coordinator, height) = await makePendingWriteFixture()
        defer { window.orderOut(nil); lease.release() }

        textView.string = pastedLongText
        for _ in 0..<5 {
            coordinator.recomputeHeight(for: textView)
        }
        await Task.yield()
        await Task.yield()

        #expect(height.value == expectedMaxHeight)
        #expect(height.setCount == 1)

        // After the drain, the same layout must stay silent (the measurement
        // now equals the published height).
        coordinator.recomputeHeight(for: textView)
        await Task.yield()
        await Task.yield()
        #expect(height.setCount == 1)
    }

    /// A newer measurement while a write is still pending must win. Here the
    /// text clears back to the already-published height: the pending
    /// max-height write is superseded (dropped, not landed), so the binding
    /// never receives a stale value.
    @Test func desiredHeightChangeWhilePendingWritesLatestValueOnly() async {
        let (lease, window, textView, coordinator, height) = await makePendingWriteFixture()
        defer { window.orderOut(nil); lease.release() }
        let seedHeight = height.value

        textView.string = pastedLongText
        coordinator.recomputeHeight(for: textView)
        // No yields: the max-height write is still pending when the text
        // clears and the measurement returns to the published height.
        textView.string = ""
        coordinator.recomputeHeight(for: textView)
        await Task.yield()
        await Task.yield()

        #expect(height.value == seedHeight)
        #expect(height.setCount == 0)
    }

    /// When the binding already equals the pending value by the time the
    /// deferred task drains (e.g. an external reset converged it), the task
    /// must skip the redundant write instead of publishing again.
    @Test func stalePendingValueSkipsWriteWhenAlreadyConverged() async {
        let (lease, window, textView, coordinator, height) = await makePendingWriteFixture()
        defer { window.orderOut(nil); lease.release() }

        textView.string = pastedLongText
        coordinator.recomputeHeight(for: textView)
        // External convergence (zoom reset writes the same clamped value)
        // before the coordinator's deferred task drains.
        height.binding.wrappedValue = expectedMaxHeight
        let externalWrites = height.setCount

        await Task.yield()
        await Task.yield()

        #expect(height.value == expectedMaxHeight)
        #expect(height.setCount == externalWrites)
    }

    /// The in-flight dedupe keys on the pending value, not on "a write ever
    /// happened": after a completed cycle for height H, an external change
    /// away from H followed by the same measurement H must write again.
    @Test func futureSameHeightUpdateIsNotLostAfterConvergedWrite() async {
        let (lease, window, textView, coordinator, height) = await makePendingWriteFixture()
        defer { window.orderOut(nil); lease.release() }

        textView.string = pastedLongText
        coordinator.recomputeHeight(for: textView)
        await Task.yield()
        await Task.yield()
        #expect(height.value == expectedMaxHeight)
        #expect(height.setCount == 1)

        // External reset to a different height (chat zoom change reseeds the
        // @State), then the same layout measures max again.
        height.binding.wrappedValue = expectedMinHeight
        coordinator.recomputeHeight(for: textView)
        await Task.yield()
        await Task.yield()

        #expect(height.value == expectedMaxHeight)
        // 1 = first drain, 2 = external reset, 3 = coordinator's repeat write.
        #expect(height.setCount == 3)
    }

    /// The deferred task holds the coordinator weakly: a coordinator released
    /// before its write drains must not crash and must not write through a
    /// stale binding.
    @Test func coordinatorDeallocationBeforeDrainSkipsWrite() async {
        let height = HeightBox(ComposerTextView.oneLineHeight(for: bodyFont))
        let parent = ComposerTextView(
            text: .constant(""),
            isEditable: true,
            font: bodyFont,
            onSubmit: {},
            measuredHeight: height.binding)
        var coordinator: ComposerTextView.Coordinator? = ComposerTextView.Coordinator(parent)
        let textView = ComposerTextView.makeConfiguredTextView(font: bodyFont)
        textView.string = pastedLongText
        coordinator?.recomputeHeight(for: textView)

        // Release the only strong reference while the write is still pending.
        coordinator = nil

        await Task.yield()
        await Task.yield()

        #expect(height.setCount == 0)
    }

    @Test func editPropagatesToBoundText() async {
        var text = "initial"
        var measuredHeight: CGFloat = ComposerTextView.oneLineHeight(for: bodyFont)
        let textBinding = Binding(get: { text }, set: { text = $0 })
        let heightBinding = Binding(get: { measuredHeight }, set: { measuredHeight = $0 })

        let (lease, window, textView, coordinator) = await makeHostedComposer(
            text: textBinding, isEditable: true, measuredHeight: heightBinding)
        defer { window.orderOut(nil); lease.release() }

        textView.string = "edited by the user"
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))

        #expect(textBinding.wrappedValue == "edited by the user")
    }

    @Test func narrowingWidthRecomputesHeightViaFrameObserver() async {
        var text = ""
        var measuredHeight: CGFloat = ComposerTextView.oneLineHeight(for: bodyFont)
        let textBinding = Binding(get: { text }, set: { text = $0 })
        let heightBinding = Binding(get: { measuredHeight }, set: { measuredHeight = $0 })

        let (lease, window, textView, coordinator) = await makeHostedComposer(
            text: textBinding, isEditable: true, measuredHeight: heightBinding)
        defer { window.orderOut(nil); lease.release() }
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

    @Test func isEditableTogglesTextViewEditability() async {
        var text = "hello"
        var measuredHeight: CGFloat = ComposerTextView.oneLineHeight(for: bodyFont)
        let textBinding = Binding(get: { text }, set: { text = $0 })
        let heightBinding = Binding(get: { measuredHeight }, set: { measuredHeight = $0 })

        let (lease, window, textView, _) = await makeHostedComposer(
            text: textBinding, isEditable: true, measuredHeight: heightBinding)
        defer { window.orderOut(nil); lease.release() }
        #expect(textView.isEditable == true)
        #expect(textView.isSelectable == true)

        textView.isEditable = false
        #expect(textView.isEditable == false)
        #expect(textView.isSelectable == true)
    }
}
#endif
