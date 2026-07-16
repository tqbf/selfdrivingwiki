import Foundation
import SwiftUI

/// Bridges SwiftUI's `@Environment(\.openWindow)` action to AppKit code that
/// can't access the SwiftUI environment (notably `MenuBarItemController` and
/// `AppDelegate.applicationShouldHandleReopen`).
///
/// The app is single-window-per-wiki: `WindowGroup(for: String.self)`
/// deduplicates by `==`, so `openWiki(id)` either opens a new wiki window or
/// focuses the existing one for that wiki — the Safari/Xcode "open in new
/// window" pattern used by `WikiSwitcher`.
///
/// A hidden helper view (`WindowBridgeProbe`) installed in the main
/// `WindowGroup` captures `@Environment(\.openWindow)` and sets
/// `openWiki` via `wire(openWindow:)`. Everything is `@MainActor` (the
/// environment value, the bridge, and all call sites), so no `Sendable`
/// concerns.
///
/// Before the bridge is wired (briefly, during launch), `openWiki` is nil —
/// calling it is a no-op. The menu items read `registry.wikis` directly so
/// the list is always current; the bridge is only the action transport.
@MainActor
final class OpenWindowBridge {
    /// Opens (or focuses) the wiki window for the given wiki ID. Set by
    /// `WindowBridgeProbe` from a SwiftUI view that has access to
    /// `@Environment(\.openWindow)`.
    var openWiki: ((String) -> Void)?

    /// Opens the main (launch) window — used when there are no wikis yet, or
    /// as a fallback from `applicationShouldHandleReopen`. Set by
    /// `WindowBridgeProbe` via `openWindow(id: "main")`.
    var openMain: (() -> Void)?
}

/// Invisible helper view that captures `@Environment(\.openWindow)` (only
/// available inside a `WindowGroup`'s view hierarchy) and wires it into the
/// ``OpenWindowBridge`` so AppKit code can trigger window opening.
///
/// `Color.clear` with zero size renders nothing visible. `.onAppear` fires
/// once when the hosting window first renders; the closures capture the
/// `OpenWindowAction` struct by value, so they remain callable even after the
/// window hosting this probe is closed — the system action outlives the view.
struct WindowBridgeProbe: View {
    let bridge: OpenWindowBridge
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(maxWidth: 0, maxHeight: 0)
            .onAppear { wire() }
    }

    private func wire() {
        // `openWindow(value: wikiID)` targets `WindowGroup(for: String.self)`,
        // deduplicating by ==: if a window for that wiki is already open, it's
        // focused instead of spawning a duplicate.
        bridge.openWiki = { wikiID in
            openWindow(value: wikiID)
        }
        // `openWindow(id: "main")` targets the main `WindowGroup(id: "main")`.
        bridge.openMain = {
            openWindow(id: "main")
        }
    }
}
