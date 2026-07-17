import AppKit
import SwiftUI
import WikiFSCore

/// Adds Safari-style `⌘`+scroll zooming to a subtree, mutating the same zoom
/// scale binding the keyboard shortcuts drive.
///
/// Scope mirrors `zoomShortcuts(_:)`: the modifier only acts while the pointer is
/// over its subtree, so attaching it to the reader subtree zooms `reader.zoom`
/// and attaching it to the editor subtree zooms `editor.zoom`. Scrolling up with
/// `⌘` held zooms in, down zooms out; without `⌘` the event passes straight
/// through so ordinary scrolling is untouched.
///
/// ```swift
/// WikiReaderView(...)
///     .zoomScroll($readerZoom)
/// ```
extension View {
    func zoomScroll(_ scale: Binding<Double>) -> some View {
        modifier(ZoomScrollModifier(scale: scale))
    }
}

// MARK: - Private implementation

private struct ZoomScrollModifier: ViewModifier {
    @Binding var scale: Double
    @StateObject private var monitor = ZoomScrollMonitor()

    func body(content: Content) -> some View {
        content
            .onHover { monitor.isHovering = $0 }
            .onAppear {
                monitor.onSteps = applySteps
                monitor.start()
            }
            .onDisappear { monitor.stop() }
    }

    /// Apply `steps` discrete zoom steps (positive = in, negative = out) by
    /// reusing the same clamped stepping the keyboard chords use, so scroll and
    /// keyboard zoom land on identical values.
    private func applySteps(_ steps: Int) {
        var next = CGFloat(scale)
        if steps > 0 {
            for _ in 0..<steps { next = ZoomScale.zoomedIn(next) }
        } else {
            for _ in 0..<(-steps) { next = ZoomScale.zoomedOut(next) }
        }
        scale = Double(next)
    }
}

/// Owns the app-local scroll-wheel monitor. A reference type because the
/// `NSEvent` monitor closure outlives any single `body` evaluation and must
/// mutate accumulator state across events. All access happens on the main thread
/// (the modifier wires it from `body`/`onHover`/`onAppear`, and local event
/// monitors are delivered on the main thread).
private final class ZoomScrollMonitor: ObservableObject {
    /// Set by the modifier from `.onHover`; gates which subtree handles a scroll.
    var isHovering = false
    /// Invoked with a signed step count when the accumulated delta crosses the
    /// threshold. Set by the modifier in `.onAppear`.
    var onSteps: ((Int) -> Void)?

    private var token: Any?
    /// Sub-threshold scroll delta carried between events so momentum is neither
    /// lost nor double-counted.
    private var accumulated: CGFloat = 0

    func start() {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func stop() {
        if let token {
            NSEvent.removeMonitor(token)
            self.token = nil
        }
        accumulated = 0
    }

    /// Returns `nil` to swallow a handled `⌘`+scroll (so the underlying scroll
    /// view does not also scroll), or the event unchanged to let it pass.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard isHovering, event.modifierFlags.contains(.command) else { return event }
        accumulated += event.scrollingDeltaY
        let (steps, remainder) = ZoomScale.scrollSteps(accumulated: accumulated)
        accumulated = remainder
        if steps != 0 { onSteps?(steps) }
        return nil
    }
}
