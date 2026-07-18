import AppKit
import SwiftUI
import WikiFSCore
import WikiFSEngine

/// Tracks the app's open windows so the standard Window menu can list them.
///
/// SwiftUI's `WindowGroup(for: String.self)` should auto-populate the Window
/// menu's open-windows list, but value-driven windows aren't reliably surfaced
/// (issue #567). This tracker re-derives the list from
/// `NSApplication.shared.windows` whenever a window becomes key/main, changes
/// occlusion state, or closes, so the Window menu always reflects reality.
///
/// Wiki windows are tagged with `wikiWindowIdentifierPrefix + wikiID`
/// (`WindowIdentifierTagger`); the commands resolve the display name from the
/// registry so the list shows "My Wiki" rather than an empty/page title.
@MainActor
@Observable
final class WindowListTracker {
    /// One row in the Window menu's open-windows list.
    struct Entry: Identifiable {
        let id: ObjectIdentifier
        /// The wiki ID parsed from the window's `wiki:` identifier, if any.
        let wikiID: String?
        /// The window's raw AppKit title (fallback when no wiki name resolves).
        let title: String
    }

    private(set) var entries: [Entry] = []
    private var observers: [NSObjectProtocol] = []
    private var didStart = false

    /// Register for window lifecycle notifications and seed the list. Called
    /// once from `startStatusItem` (app-lifetime, idempotent).
    func start() {
        guard !didStart else { return }
        didStart = true
        let center = NotificationCenter.default
        // Recompute whenever a window appears, focuses, hides, or closes —
        // the open-windows list must stay in sync without a manual refresh.
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.willCloseNotification,
            NSApplication.didBecomeActiveNotification
        ]
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // The observer fires on the main queue; hop to the main actor
                // before touching @Observable state.
                Task { @MainActor in self?.refresh() }
            }
        }
        refresh()
    }

    /// Recompute `entries` from the current AppKit window stack. Visible,
    /// main-capable, non-panel windows are listed. A window with a `wiki:`
    /// identifier is always included (its title may be momentarily empty
    /// during state restoration); others are included only when titled.
    func refresh() {
        entries = NSApplication.shared.windows
            .filter { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }
            .map { window in
                var wikiID: String?
                if let raw = window.identifier?.rawValue,
                   raw.hasPrefix(wikiWindowIdentifierPrefix) {
                    wikiID = String(raw.dropFirst(wikiWindowIdentifierPrefix.count))
                }
                return Entry(id: ObjectIdentifier(window), wikiID: wikiID, title: window.title)
            }
            .filter { entry in entry.wikiID != nil || !entry.title.isEmpty }
    }

    /// Bring the selected window to the front (Window menu click action).
    func bringToFront(_ id: ObjectIdentifier) {
        guard let window = NSApplication.shared.windows.first(where: {
            ObjectIdentifier($0) == id
        }) else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// The Window menu commands: the open-windows list (below "Bring All to
/// Front") plus the standard "Show Previous/Next Tab" items (⇧⌘[ / ⇧⌘]).
///
/// Placed after `.windowList` so the list sits in the standard Window-menu
/// position without clobbering the system-provided Minimize/Zoom/Bring-All-to-
/// Front items. The tab-cycling actions target the frontmost window's session
/// via `SessionManager.frontmostSession` and cycle `WikiStoreModel.tabs`.
struct WindowMenuCommands: Commands {
    let sessionManager: SessionManager
    let windowTracker: WindowListTracker
    let registry: WikiRegistryClient

    var body: some Commands {
        CommandGroup(after: .windowList) {
            if !windowTracker.entries.isEmpty {
                ForEach(windowTracker.entries) { entry in
                    Button(displayTitle(for: entry)) {
                        windowTracker.bringToFront(entry.id)
                    }
                }
                Divider()
            }
            // Standard macOS tab-cycling items. macOS apps put these in the
            // Window menu (e.g. Safari, Finder); ⇧⌘[ / ⇧⌘] are the expected
            // shortcuts. The action self-guards so the shortcuts always fire
            // and no-op when there is no frontmost session or <2 tabs.
            Button("Show Previous Tab") { cycleTab(by: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Show Next Tab") { cycleTab(by: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
        }
    }

    /// Resolve a window's menu label: the wiki display name when the window
    /// carries a `wiki:` identifier, otherwise its AppKit title (falling back
    /// to "Untitled" so a row never renders blank).
    private func displayTitle(for entry: WindowListTracker.Entry) -> String {
        if let wikiID = entry.wikiID,
           let name = registry.wikis.first(where: { $0.id == wikiID })?.displayName,
           !name.isEmpty {
            return name
        }
        return entry.title.isEmpty ? "Untitled" : entry.title
    }

    /// Cycle the active tab in the frontmost wiki window by `delta` (-1 / +1),
    /// wrapping at the ends. No-op when there is no frontmost session, fewer
    /// than two tabs, or no active tab.
    private func cycleTab(by delta: Int) {
        guard let store = sessionManager.frontmostSession?.store else { return }
        let tabs = store.tabs
        guard tabs.count > 1,
              let current = store.activeTabID,
              let index = tabs.firstIndex(where: { $0.id == current }) else { return }
        let count = tabs.count
        // Euclidean modulo so negative deltas wrap correctly.
        let newIndex = ((index + delta) % count + count) % count
        store.selectTab(id: tabs[newIndex].id)
    }
}
