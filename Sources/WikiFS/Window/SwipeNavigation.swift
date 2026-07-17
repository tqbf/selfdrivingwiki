import AppKit
import SwiftUI
import WikiFSCore

/// Adds Safari-style two-finger horizontal swipe navigation to a subtree,
/// calling `navigateBack()` / `navigateForward()` on the store when the user
/// swipes past a threshold over the detail pane. Mirrors the existing
/// `zoomScroll(_:)` pattern: a local `NSEvent.addLocalMonitorForEvents`
/// scoped to the subtree via `.onHover`, accumulating horizontal scroll delta
/// and committing navigation when the threshold is crossed.
///
/// ```swift
/// WikiDetailView(...)
///     .swipeNavigation(store: store)
/// ```
extension View {
    func swipeNavigation(store: WikiStoreModel) -> some View {
        modifier(SwipeNavigationModifier(store: store))
    }
}

// MARK: - Private implementation

private struct SwipeNavigationModifier: ViewModifier {
    let store: WikiStoreModel
    @StateObject private var monitor = SwipeNavigationMonitor()

    func body(content: Content) -> some View {
        content
            .onHover { monitor.isHovering = $0 }
            .onAppear {
                monitor.navigateBack = { store.navigateBack() }
                monitor.navigateForward = { store.navigateForward() }
                monitor.canGoBack = { store.canNavigateBack }
                monitor.canGoForward = { store.canNavigateForward }
                monitor.start()
            }
            .onDisappear { monitor.stop() }
    }
}

/// Tracks horizontal two-finger scroll events to detect a deliberate swipe
/// gesture (as opposed to ordinary vertical scrolling). A reference type
/// because the `NSEvent` monitor closure outlives any single `body`
/// evaluation and must accumulate delta across events. All access happens on
/// the main thread (local event monitors deliver there).
private final class SwipeNavigationMonitor: ObservableObject {
    /// Set by the modifier from `.onHover`; gates which subtree handles a swipe.
    var isHovering = false
    var navigateBack: (() -> Void)?
    var navigateForward: (() -> Void)?
    var canGoBack: (() -> Bool)?
    var canGoForward: (() -> Bool)?

    private var token: Any?
    /// Accumulated horizontal delta (in scroll-wheel points). Positive =
    /// rightward swipe (navigate back), negative = leftward (navigate forward).
    private var accumulated: CGFloat = 0
    /// True while we're in a `began` → `changed` gesture (elapsed phase).
    /// Prevents momentum scrolling from triggering additional navigations.
    private var inGesture = false

    /// The horizontal delta threshold (in scroll-wheel points) that commits
    /// a navigation. Trackpad two-finger horizontal swipes typically produce
    /// deltas of 2–8 points per event, so accumulating ~25 is a deliberate
    /// swipe, not incidental horizontal drift during vertical scrolling.
    private let threshold: CGFloat = 25

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
        reset()
    }

    private func reset() {
        accumulated = 0
        inGesture = false
    }

    /// Returns `nil` to swallow a handled swipe (prevents the underlying
    /// content from also scrolling), or the event unchanged to let it pass.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard isHovering else { return event }

        // Only track horizontal movement that's dominant (not vertical scrolling).
        // A two-finger horizontal swipe has |deltaX| > |deltaY|.
        let deltaX = event.scrollingDeltaX
        let deltaY = event.scrollingDeltaY
        guard abs(deltaX) > abs(deltaY) else {
            // Vertical scroll — reset horizontal accumulation and pass through.
            // Don't reset inGesture here; a pure vertical scroll in the same
            // gesture sequence isn't a swipe, but the phase tracking still
            // applies. Just ignore the horizontal component.
            return event
        }

        switch event.phase {
        case .began:
            // Start of a new touch gesture.
            accumulated = deltaX
            inGesture = true
            return nil  // consume

        case .changed:
            guard inGesture else { return event }
            accumulated += deltaX
            // Check for threshold crossing.
            if accumulated >= threshold {
                if canGoBack?() ?? false {
                    navigateBack?()
                }
                reset()
                return nil
            } else if accumulated <= -threshold {
                if canGoForward?() ?? false {
                    navigateForward?()
                }
                reset()
                return nil
            }
            return nil  // consume the horizontal drag

        case .ended, .cancelled:
            // Gesture ended without crossing the threshold — snap back (no navigation).
            reset()
            return nil

        case .mayBegin:
            return event  // pre-gesture, don't interfere

        default:
            // Momentum phase events (after .ended) — ignore to prevent
            // post-gesture inertia from triggering another navigation.
            if event.momentumPhase != [] {
                return event  // let momentum pass through for vertical scrolling
            }
            return event
        }
    }
}
