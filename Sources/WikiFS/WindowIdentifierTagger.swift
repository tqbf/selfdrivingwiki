import AppKit
import SwiftUI

/// The `NSUserInterfaceItemIdentifier` prefix used to tag a wiki's hosting
/// `NSWindow` with its wiki ID. `MenuBarItemController` scans
/// `NSApplication.shared.windows` for `wikiWindowIdentifierPrefix + wikiID`
/// to focus an already-open wiki window instead of spawning a duplicate.
///
/// Duplicates arise because the main `WindowGroup(id: "main")` window *adopts*
/// a wiki (via `registry.activeWikiID`) but is invisible to the value-driven
/// `WindowGroup(for: String.self)`'s `==` dedup — so `openWindow(value: id)`
/// can't see that the wiki is already on screen and opens a second window.
/// Tagging every wiki-showing window (main or value-driven) with a stable
/// identifier gives AppKit a reliable way to find and focus it.
let wikiWindowIdentifierPrefix = "wiki:"

/// Invisible helper that stamps its hosting window's `identifier` with the
/// given wiki ID (or clears it when `wikiID` is nil). Re-runs whenever the
/// bound `wikiID` changes — e.g. an in-window Option+click switch — so the
/// tag always reflects the wiki the window is currently showing.
struct WindowIdentifierTagger: NSViewRepresentable {
    let wikiID: String?

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: NSView) {
        // The window isn't attached synchronously during make/update on the
        // first pass, so defer to the next run loop turn to read `view.window`.
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.identifier = wikiID.map {
                NSUserInterfaceItemIdentifier(wikiWindowIdentifierPrefix + $0)
            }
        }
    }
}
