import AppKit
import SwiftUI
import WikiFSCore
import WikiFSEngine

/// Controls the menu-bar status item and Activity window for the queue engine.
///
/// The status item icon reflects the engine's state:
/// - **idle** (books.vertical) — no active items, queue running
/// - **working** (books.vertical.fill) — items running
/// - **paused** (pause.fill) — a queue is paused
/// - **attention** (exclamationmark.triangle.fill) — failed items need attention
///
/// Clicking the status item toggles the Activity window, which lists
/// active/recent items across all wikis with per-item agent transcripts,
/// per-queue pause/resume/halt controls, and per-row cancel/retry.
///
/// Lives in `WikiFS` because it uses AppKit (`NSStatusItem`, `NSWindow`)
/// and SwiftUI for the window content. The engine itself stays headless.
@MainActor
final class QueueStatusItemController: NSObject, NSMenuDelegate {

    // MARK: - Dependencies

    private let queueEngine: QueueEngine
    private let activityTracker: QueueActivityTracker
    private weak var sessionManager: SessionManager?

    // MARK: - AppKit

    private var statusItem: NSStatusItem?
    private var activityWindow: NSWindow?

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
        DebugLog.tabs("QueueStatusItemController.start: creating status item")

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

        // Header: queue counts.
        let headerItem = NSMenuItem(
            title: activeCount == 0
                ? recentCount == 0 ? "No activity" : "\(recentCount) recent"
                : "\(activeCount) active • \(recentCount) recent",
            action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        // Active items (clickable → opens Activity window).
        if !snapshot.activeItems.isEmpty {
            menu.addItem(.separator())
            let sectionItem = NSMenuItem(
                title: "Active", action: nil, keyEquivalent: "")
            sectionItem.isEnabled = false
            menu.addItem(sectionItem)

            for item in snapshot.activeItems.prefix(5) {
                let title = menuItemTitle(for: item)
                let menuItem = NSMenuItem(
                    title: title, action: #selector(openActivityWindow(_:)),
                    keyEquivalent: "")
                menuItem.target = self
                menuItem.representedObject = item.id
                menu.addItem(menuItem)
            }
        }

        // Recent items (clickable → opens Activity window).
        if !snapshot.recentItems.isEmpty {
            menu.addItem(.separator())
            let sectionItem = NSMenuItem(
                title: "Recent", action: nil, keyEquivalent: "")
            sectionItem.isEnabled = false
            menu.addItem(sectionItem)

            for item in snapshot.recentItems.prefix(5) {
                let title = menuItemTitle(for: item)
                let menuItem = NSMenuItem(
                    title: title, action: #selector(openActivityWindow(_:)),
                    keyEquivalent: "")
                menuItem.target = self
                menuItem.representedObject = item.id
                menu.addItem(menuItem)
            }
        }

        menu.addItem(.separator())

        // Wiki maintenance actions.
        let lintItem = NSMenuItem(
            title: "Lint Wiki",
            action: #selector(lintWiki(_:)),
            keyEquivalent: "")
        lintItem.target = self
        menu.addItem(lintItem)

        let vacuumItem = NSMenuItem(
            title: "Vacuum All…",
            action: #selector(vacuumAll(_:)),
            keyEquivalent: "")
        vacuumItem.target = self
        menu.addItem(vacuumItem)

        menu.addItem(.separator())

        // Open Activity window.
        let openItem = NSMenuItem(
            title: "Open Activity…",
            action: #selector(openActivityWindow(_:)),
            keyEquivalent: "a")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        // Navigation items (moved from Help menu).
        let instructionsItem = NSMenuItem(
            title: "Agent Instructions",
            action: #selector(openAgentInstructions(_:)),
            keyEquivalent: "")
        instructionsItem.target = self
        menu.addItem(instructionsItem)

        let logItem = NSMenuItem(
            title: "Activity Log",
            action: #selector(openActivityLog(_:)),
            keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        menu.addItem(.separator())

        // Quit.
        let quitItem = NSMenuItem(
            title: "Quit Self Driving Wiki",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        menu.addItem(quitItem)
    }

    private func menuItemTitle(for item: QueueItem) -> String {
        let wikiName = sessionManager?.sessions[item.wikiID]?.descriptor.displayName
            ?? String(item.wikiID.prefix(8))
        let kindLabel: String
        if item.payload.lintPageIDs != nil {
            kindLabel = "Lint"
        } else {
            kindLabel = item.queue == .extraction ? "Extraction" : "Ingestion"
        }
        let stateLabel: String
        switch item.state {
        case .running: stateLabel = "Running"
        case .queued: stateLabel = "Queued"
        case .completed: stateLabel = "Completed"
        case .failed: stateLabel = "Failed"
        case .cancelled: stateLabel = "Cancelled"
        }
        return "\(wikiName) — \(kindLabel) (\(stateLabel))"
    }

    @objc private func openActivityWindow(_ sender: NSMenuItem?) {
        showActivityWindow()
    }

    @objc private func lintWiki(_ sender: NSMenuItem?) {
        guard let session = sessionManager?.frontmostSession else { return }
        Task {
            try? await session.queueEngine.enqueue(QueueItemRequest(
                queue: .ingestion,
                wikiID: session.wikiID,
                payload: QueueItemPayload(sourceIDs: [], lintPageIDs: [])
            ))
        }
    }

    @objc private func vacuumAll(_ sender: NSMenuItem?) {
        sessionManager?.frontmostSession?.previewVacuumAll()
    }

    @objc private func openAgentInstructions(_ sender: NSMenuItem?) {
        sessionManager?.frontmostSession?.store.openTab(.systemPrompt)
    }

    @objc private func openActivityLog(_ sender: NSMenuItem?) {
        sessionManager?.frontmostSession?.store.openTab(.changeLog)
    }

    // MARK: - Activity window

    private func showActivityWindow() {
        if activityWindow == nil {
            let contentView = ActivityWindowView(
                queueEngine: queueEngine,
                activityTracker: activityTracker,
                sessionManager: sessionManager
            )
            // NSHostingController (not a bare NSHostingView) so SwiftUI can
            // install the window's unified toolbar from the view's `.toolbar`.
            let window = NSWindow(contentViewController: NSHostingController(rootView: contentView))
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.toolbarStyle = .unified
            window.title = "Activity"
            window.setContentSize(NSSize(width: 760, height: 500))
            window.isReleasedWhenClosed = false
            // Center first; the autosave name then restores any saved frame
            // over it (remember size/position across opens — set AFTER center
            // so center() can't clobber the restored frame).
            window.center()
            window.setFrameAutosaveName("QueueActivityWindow")
            activityWindow = window
        }
        activityWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func closeActivityWindow() {
        activityWindow?.orderOut(nil)
    }

    // MARK: - Icon management

    private enum IconState {
        case idle
        case working
        case paused
        case attention
    }

    private func statusIcon(for state: IconState) -> NSImage? {
        let name: String
        switch state {
        case .idle: name = "books.vertical"
        case .working: name = "books.vertical.fill"
        case .paused: name = "pause.fill"
        case .attention: name = "exclamationmark.triangle.fill"
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
