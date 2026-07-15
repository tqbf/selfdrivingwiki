import AppKit
import SwiftUI
import WikiFSCore
import WikiFSEngine

/// Controls the menu-bar status item and the per-queue activity windows
/// (Ingestion + Extraction) for the queue engine.
///
/// The status item icon is ALWAYS the books glyph — books.vertical when idle,
/// books.vertical.fill while working. Paused/failed states are conveyed by
/// the tooltip and the windows, never by swapping to an alert symbol (a menu
/// bar icon that changes shape reads as a different app).
///
/// The menu-bar dropdown groups queue windows, a Maintenance submenu
/// (Vacuum All, Agent Instructions), and Quit.
///
/// Lives in `WikiFS` because it uses AppKit (`NSStatusItem`, `NSWindow`)
/// and SwiftUI for the window content. The engine itself stays headless.
@MainActor
final class MenuBarItemController: NSObject, NSMenuDelegate {

    // MARK: - Dependencies

    private let queueEngine: QueueEngine
    private let activityTracker: QueueActivityTracker
    private weak var sessionManager: SessionManager?

    // MARK: - AppKit

    private var statusItem: NSStatusItem?
    private var queueWindows: [QueueKind: NSWindow] = [:]

    // MARK: - State tracking

    private var streamTask: Task<Void, Never>?
    private var hasFailedItems = false
    private var isPaused = false
    private var lastSnapshot: QueueSnapshot = QueueSnapshot()

    // MARK: - Init

    init(
        queueEngine: QueueEngine,
        activityTracker: QueueActivityTracker,
        sessionManager: SessionManager
    ) {
        self.queueEngine = queueEngine
        self.activityTracker = activityTracker
        self.sessionManager = sessionManager
    }

    // MARK: - Lifecycle

    /// Create the status item and start observing the engine's event stream.
    func start() {
        guard statusItem == nil else { return }
        DebugLog.tabs("MenuBarItemController.start: creating status item")

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        if let button = item.button {
            button.image = statusIcon(for: .idle)
            button.image?.isTemplate = true
            button.toolTip = "Self Driving Wiki — Activity"
        }

        // A persistent menu (rebuilt in `menuNeedsUpdate` just before it
        // opens) — NOT a button action that assigns `item.menu`. Assigning
        // the menu from inside a click action only arms it for the NEXT
        // click, so the first click appears to do nothing.
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        // Observe engine events to update the icon + menu.
        streamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await event in self.queueEngine.events {
                self.handleEvent(event)
            }
        }
    }

    /// Tear down the status item (e.g. on app termination).
    func stop() {
        streamTask?.cancel()
        streamTask = nil
        closeActivityWindow()
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    // MARK: - Menu

    /// Rebuild the menu from the latest snapshot each time it's about to
    /// open (NSMenuDelegate).
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        buildMenu(menu, snapshot: lastSnapshot)
    }

    private func buildMenu(_ menu: NSMenu, snapshot: QueueSnapshot) {
        let activeCount = snapshot.activeItems.count
        let recentCount = snapshot.recentItems.count

        // Header: queue counts. (Individual items live in the per-queue
        // windows, not the menu — a dropdown of truncated item rows was
        // noise, and clicking any of them opened the same window anyway.)
        let headerItem = NSMenuItem(
            title: activeCount == 0
                ? recentCount == 0 ? "No activity" : "\(recentCount) recent"
                : "\(activeCount) active • \(recentCount) recent",
            action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        menu.addItem(.separator())

        // Per-queue windows.
        let ingestionItem = NSMenuItem(
            title: "Agent Queue…",
            action: #selector(openIngestionWindow(_:)),
            keyEquivalent: "i")
        ingestionItem.target = self
        menu.addItem(ingestionItem)

        let extractionItem = NSMenuItem(
            title: "Extraction Activity…",
            action: #selector(openExtractionWindow(_:)),
            keyEquivalent: "e")
        extractionItem.target = self
        menu.addItem(extractionItem)

        menu.addItem(.separator())

        // Wiki maintenance actions.
        let maintenanceItem = NSMenuItem(
            title: "Maintenance",
            action: nil,
            keyEquivalent: "")
        let maintenanceMenu = NSMenu()
        maintenanceMenu.addItem(withTitle: "Vacuum All…",
            action: #selector(vacuumAll(_:)), keyEquivalent: "").target = self
        maintenanceMenu.addItem(withTitle: "Agent Instructions",
            action: #selector(openAgentInstructions(_:)), keyEquivalent: "").target = self
        maintenanceItem.submenu = maintenanceMenu
        menu.addItem(maintenanceItem)

        menu.addItem(.separator())

        // About + Quit.
        let aboutItem = NSMenuItem(
            title: "About Self Driving Wiki",
            action: #selector(NSApplication.shared.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "")
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(
            title: "Quit Self Driving Wiki",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        menu.addItem(quitItem)
    }

    @objc private func openIngestionWindow(_ sender: NSMenuItem?) {
        showQueueWindow(for: .ingestion)
    }

    @objc private func openExtractionWindow(_ sender: NSMenuItem?) {
        showQueueWindow(for: .extraction)
    }

    /// The session menu actions target: the frontmost wiki window's session,
    /// falling back to ANY live session — a status-item menu is reachable
    /// while no wiki window is key, and a silent `return` there reads as a
    /// dead menu item.
    private var targetSession: WikiSession? {
        sessionManager?.frontmostSession ?? sessionManager?.allSessions.first
    }

    @objc private func vacuumAll(_ sender: NSMenuItem?) {
        targetSession?.previewVacuumAll()
        activateWikiWindow()
    }

    @objc private func openAgentInstructions(_ sender: NSMenuItem?) {
        targetSession?.store.openTab(.systemPrompt)
        activateWikiWindow()
    }

    /// Bring a wiki window to the front. `openTab` switches the tab inside
    /// the store, but from the menu bar the app is usually inactive — without
    /// activation the switch happens in a background window and the click
    /// looks like it did nothing.
    private func activateWikiWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let ownedWindowIDs = Set(queueWindows.values.map(ObjectIdentifier.init))
        if let window = NSApplication.shared.windows.first(where: { window in
            window.isVisible
                && window.canBecomeMain
                && !ownedWindowIDs.contains(ObjectIdentifier(window))
        }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Per-queue activity windows

    private func showQueueWindow(for queue: QueueKind) {
        if queueWindows[queue] == nil {
            let contentView = ActivityWindowView(
                queue: queue,
                queueEngine: queueEngine,
                activityTracker: activityTracker,
                sessionManager: sessionManager
            )
            // NSHostingController (not a bare NSHostingView) so SwiftUI can
            // install the window's unified toolbar from the view's `.toolbar`.
            let window = NSWindow(contentViewController: NSHostingController(rootView: contentView))
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.toolbarStyle = .unified
            window.title = queue == .extraction ? "Extraction" : "Ingestion"
            window.setContentSize(NSSize(width: 760, height: 500))
            window.isReleasedWhenClosed = false
            // Center first; the autosave name then restores any saved frame
            // over it (remember size/position across opens — set AFTER center
            // so center() can't clobber the restored frame). Distinct names
            // per queue so the two windows keep independent frames.
            window.center()
            window.setFrameAutosaveName(
                queue == .extraction ? "ExtractionActivityWindow" : "IngestionActivityWindow")
            queueWindows[queue] = window
        }
        queueWindows[queue]?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func closeActivityWindow() {
        for window in queueWindows.values {
            window.orderOut(nil)
        }
    }

    // MARK: - Icon management

    private enum IconState {
        case idle
        case working
        case paused
        case attention
    }

    private func statusIcon(for state: IconState) -> NSImage? {
        // ALWAYS the books glyph — paused/attention states convey via the
        // tooltip and the activity windows. A menu bar icon that morphs into
        // an alert triangle reads as a different app's item.
        let name: String
        switch state {
        case .working: name = "books.vertical.fill"
        case .idle, .paused, .attention: name = "books.vertical"
        }
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    private func updateIcon() {
        let state: IconState
        if hasFailedItems {
            state = .attention
        } else if isPaused {
            state = .paused
        } else if activityTracker.isExtracting || activityTracker.isIngesting {
            state = .working
        } else {
            state = .idle
        }
        statusItem?.button?.image = statusIcon(for: state)
        statusItem?.button?.toolTip = tooltipText(for: state)
    }

    private func tooltipText(for state: IconState) -> String {
        switch state {
        case .idle: "Self Driving Wiki — Idle"
        case .working: "Self Driving Wiki — Processing"
        case .paused: "Self Driving Wiki — Paused"
        case .attention: "Self Driving Wiki — Attention needed"
        }
    }

    // MARK: - Event handling

    private func handleEvent(_ event: QueueEvent) {
        switch event {
        case .runStateChanged(_, let state):
            if state == .paused {
                isPaused = true
            } else {
                Task {
                    let snapshot = await queueEngine.snapshot()
                    isPaused = snapshot.runStates.values.contains(.paused)
                    lastSnapshot = snapshot
                    updateIcon()
                }
                return
            }
        case .failed:
            hasFailedItems = true
        case .completed, .cancelled:
            Task {
                let snapshot = await queueEngine.snapshot()
                hasFailedItems = snapshot.recentItems.contains {
                    $0.state == .failed
                }
                lastSnapshot = snapshot
                updateIcon()
            }
            return
        case .enqueued, .started:
            // Refresh snapshot for menu accuracy.
            Task {
                lastSnapshot = await queueEngine.snapshot()
            }
        default:
            break
        }
        Task {
            lastSnapshot = await queueEngine.snapshot()
        }
        updateIcon()
    }
}
