import SwiftUI

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
private struct ActivityWindowEnvironmentKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    /// A closure that opens the Activity (queue) window. Injected at the
    /// scene root (`WikiFSApp`) so any descendant view can call it.
    var openActivityWindow: (() -> Void)? {
        get { self[ActivityWindowEnvironmentKey.self] }
        set { self[ActivityWindowEnvironmentKey.self] = newValue }
    }
}
