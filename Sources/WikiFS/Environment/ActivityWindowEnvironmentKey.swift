import SwiftUI
import WikiFSCore

/// Environment key for opening the Activity (queue) window (#745).
///
/// The `OpenWindowBridge` is owned by `WikiFSApp` and wired into
/// `MenuBarItemController` (which creates the `NSWindow`). This environment
/// key bridges the SwiftUI view hierarchy (the Provenance panel) to that
/// AppKit-side opener without threading `OpenWindowBridge` through
/// `RootScene → RootView → ContentView → WikiDetailView → PageDetailView`.
///
/// Defaults to `nil` (no-op) when not injected — a no-op is the correct
/// degradation for views that don't need Activity navigation.
///
/// PR2 (#842): the closure takes a `QueueKind` argument so callers can open
/// the transcription, extraction, or ingestion Activity window — the
/// `WindowGroup(for: QueueKind.self)` deduplicates by `==`, so the correct
/// window is focused or created.
private struct ActivityWindowEnvironmentKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: ((QueueKind) -> Void)? = nil
}

extension EnvironmentValues {
    /// A closure that opens the Activity (queue) window for the given queue
    /// kind. Injected at the scene root (`WikiFSApp`) so any descendant view
    /// can call it. PR2 (#842): parameterized with `QueueKind` so the
    /// transcription Activity window can be opened from `SourceDetailView`.
    var openActivityWindow: ((QueueKind) -> Void)? {
        get { self[ActivityWindowEnvironmentKey.self] }
        set { self[ActivityWindowEnvironmentKey.self] = newValue }
    }
}
