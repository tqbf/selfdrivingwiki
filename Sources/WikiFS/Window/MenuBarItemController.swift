import AppKit
import ServiceManagement
import SwiftUI
import WikiCtlCore
import WikiFSCore
import WikiFSEngine

/// Controls the menu-bar status item and the per-queue activity windows
/// (Ingestion + Extraction) for the queue engine.
///
/// The status item icon is ALWAYS the books glyph — books.vertical when idle,
/// and while working it *breathes* between books.vertical and
/// books.vertical.fill (a subtle, repeating toggle — never a different shape)
/// so the menu bar shows live progress. Paused/failed states are conveyed by
/// the tooltip and the windows, never by swapping to an alert symbol (a menu
/// bar icon that changes shape reads as a different app).
///
/// The menu-bar dropdown groups queue windows, a Maintenance submenu
/// (Vacuum All, Agent Instructions), Settings, and Quit. Settings lives
/// here rather than in the "Self Driving Wiki" app menu because the status
/// item is the always-available surface — in accessory mode there's no menu
/// bar at all. The app-menu items are removed in
/// `AppDelegate.removeRedundantAppMenuItems`.
///
/// Lives in `WikiFS` because it uses AppKit (`NSStatusItem`, `NSWindow`)
/// and SwiftUI for the window content. The engine itself stays headless.
@MainActor
final class MenuBarItemController: NSObject, NSMenuDelegate {

    // MARK: - Dependencies

    private let queueEngine: any QueueEngineClient
    private let activityTracker: QueueActivityTracker
    private weak var sessionManager: SessionManager?
    private weak var backgroundIngestCoordinator: BackgroundIngestCoordinator?
    /// The wiki registry — drives the "Open Wiki" menu items. Read fresh each
    /// time the menu opens (`menuNeedsUpdate`), so newly-created wikis appear
    /// without a manual refresh.
    private let registry: WikiRegistryClient
    /// Bridges to SwiftUI's `openWindow(value:)` so selecting a wiki from the
    /// status bar menu opens (or focuses) that wiki's window — even in
    /// accessory mode when no windows are visible.
    private let openWindowBridge: OpenWindowBridge
    /// Restarts the wikid daemon by invalidating the XPC connection +
    /// reconnecting. Injected from `WikiFSApp` (owns the
    /// `DaemonHealthMonitor`). Called by the "Restart Daemon" menu item.
    private var daemonRestartHandler: (() -> Void)?
    /// The daemon health monitor (#878). When the daemon is `.disconnected`,
    /// the status item icon swaps to `exclamation.triangle` so the user sees
    /// at a glance that the daemon is down. `nil` in tests that don't care.
    private weak var daemonHealthMonitor: DaemonHealthMonitor?

    // MARK: - AppKit

    private var statusItem: NSStatusItem?

    // MARK: - State tracking

    private var streamTask: Task<Void, Never>?
    /// Repeating loop that breathes the books glyph while the queue is
    /// active (see `startIconAnimation`). Cancelled in `stop()` and whenever
    /// the icon leaves the working state, so it consumes no CPU when idle.
    private var animationTask: Task<Void, Never>?
    private var hasFailedItems = false
    private var isPaused = false
    private var lastSnapshot: QueueSnapshot = QueueSnapshot()
    /// Queue item IDs known to be `.queued`, maintained synchronously from
    /// queue events (#1222). Every `.enqueued` inserts and every terminal
    /// event removes, so the blinker reacts to the event the controller
    /// actually received instead of waiting on an async snapshot RPC.
    private var queuedItemIDs: Set<QueueItem.ID> = []
    /// Queue item IDs known to be `.running` (`.started` → insert, terminal
    /// event → remove). Split from ``queuedItemIDs`` so the tooltip's
    /// "Processing (N active, M queued)" counts are consistent with the icon
    /// state by construction.
    private var runningItemIDs: Set<QueueItem.ID> = []
    /// Bumped on every event-driven membership change. Snapshot refresh tasks
    /// capture the epoch when the fetch starts and discard the result if the
    /// epoch moved while the RPC was in flight — a snapshot taken BEFORE an
    /// enqueue must never land AFTER it and clear the blinker (the #1222
    /// stale-snapshot race).
    private var membershipEpoch: UInt64 = 0
    /// The icon state most recently derived by ``updateIcon()``. Test seam for
    /// the lint/queue blinker regression tests (#1222) — AppKit offers no way
    /// to read a status item's animation state back.
    private(set) var lastDerivedIconState: IconState?
    private var hintPopover: NSPopover?
    private var hintDismissTask: Task<Void, Never>?
    /// Previous daemon connection state, used to detect the
    /// disconnected/reconnecting → `.connected` transition (which fires the
    /// "wikid daemon reconnected." hint popover). Seeded in `start()` from the
    /// monitor's current state so the first transition is a real one, not a
    /// duplicate of the initial state.
    private var previousDaemonState: DaemonConnectionState?

    // MARK: - Init

    init(
        queueEngine: any QueueEngineClient,
        activityTracker: QueueActivityTracker,
        sessionManager: SessionManager,
        registry: WikiRegistryClient,
        openWindowBridge: OpenWindowBridge,
        backgroundIngestCoordinator: BackgroundIngestCoordinator? = nil,
        daemonRestartHandler: (() -> Void)? = nil,
        daemonHealthMonitor: DaemonHealthMonitor? = nil
    ) {
        self.queueEngine = queueEngine
        self.activityTracker = activityTracker
        self.sessionManager = sessionManager
        self.registry = registry
        self.openWindowBridge = openWindowBridge
        self.backgroundIngestCoordinator = backgroundIngestCoordinator
        self.daemonRestartHandler = daemonRestartHandler
        self.daemonHealthMonitor = daemonHealthMonitor
    }

    // MARK: - Lifecycle

    /// Create the status item and start observing the engine's event stream.
    func start() {
        guard statusItem == nil else { return }
        DebugLog.tabs("MenuBarItemController.start: creating status item")

        // #745: wire the Activity window opener so the Provenance panel and
        // SourceDetailView's Transcribe button can navigate to the running
        // job. Routes through `openQueueWindow` (the scene-managed
        // `WindowGroup(for: QueueKind.self)` in `WikiFSApp`). PR2 (#842):
        // the closure takes a `QueueKind` so callers open the correct window
        // (extraction or ingestion) — the Provenance panel
        // passes `.ingestion`, SourceDetailView passes `.extraction`.
        openWindowBridge.openActivityWindow = { [weak self] queue in
            NSApplication.shared.activate(ignoringOtherApps: true)
            self?.openWindowBridge.openQueueWindow?(queue)
        }

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

        // Fetch initial snapshot so the icon reflects any items already in
        // the queue (e.g. hosted by the daemon before this subscription
        // existed). The guarded apply seeds the membership sets from that
        // snapshot — events emitted before we subscribed are not replayed
        // (#1222) — while still refusing stale data if events have already
        // changed membership since the fetch started.
        refreshSnapshotGuarded()

        // Observe engine events to update the icon + menu.
        streamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await event in self.queueEngine.events {
                self.handleEvent(event)
            }
        }

        // #878: observe daemon health to swap the icon to a warning variant
        // when the daemon is disconnected, and to surface a small "reconnected"
        // hint popover (matching the "Ingest queued" / "Lint queued" treatment)
        // when the daemon recovers from a disconnected state.
        previousDaemonState = daemonHealthMonitor?.state
        daemonHealthMonitor?.onStateChange = { [weak self] newState in
            self?.handleDaemonStateChange(newState)
        }
        // Reflect the initial state immediately.
        if daemonHealthMonitor?.state == .disconnected {
            updateIcon()
        }
    }

    private func queueSnapshot() async -> QueueSnapshot? {
        do {
            return try await queueEngine.snapshot()
        } catch {
            DebugLog.store("MenuBarItemController: queue snapshot failed: \(error)")
            return nil
        }
    }

    /// Tear down the status item (e.g. on app termination).
    func stop() {
        dismissHint()
        streamTask?.cancel()
        streamTask = nil
        stopIconAnimation()
        closeActivityWindow()
        // #1222: drop the event-maintained membership so a restarted
        // controller re-seeds from its own initial snapshot instead of
        // inheriting stale activity.
        queuedItemIDs.removeAll()
        runningItemIDs.removeAll()
        membershipEpoch &+= 1
        lastDerivedIconState = nil
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    // MARK: - Daemon health

    /// Handle a daemon connection state transition: refresh the icon on every
    /// change, and surface a small "reconnected." hint popover when the daemon
    /// recovers from a disconnected/reconnecting state. This replaces the old
    /// full-width green banner (`DaemonStatusBanner` now only owns the red
    /// disconnected banner) so the positive signal matches the "Ingest queued"
    /// / "Lint queued" treatment.
    private func handleDaemonStateChange(_ newState: DaemonConnectionState) {
        let oldState = previousDaemonState
        previousDaemonState = newState
        if newState == .connected, oldState == .disconnected || oldState == .reconnecting {
            showTransientHint(
                message: "wikid daemon reconnected.",
                symbol: "checkmark.circle.fill"
            )
        }
        updateIcon()
    }

    // MARK: - Menu

    /// Rebuild the menu from the latest snapshot each time it's about to
    /// open (NSMenuDelegate).
    func menuNeedsUpdate(_ menu: NSMenu) {
        dismissHint()
        menu.removeAllItems()
        buildMenu(menu, snapshot: lastSnapshot)
    }

    private func buildMenu(_ menu: NSMenu, snapshot: QueueSnapshot) {
        // Open Wiki section: lists every wiki so the user can get back to a
        // window even when all windows are closed (accessory mode). Each item
        // calls `openWindowBridge.openWiki(wiki.id)` which opens or focuses
        // that wiki's window via SwiftUI's `WindowGroup(for: WikiID.self)`.
        if !registry.wikis.isEmpty {
            // Nest the wiki list under a "Wikis" submenu to keep the top-level
            // status menu compact — the list can grow arbitrarily long.
            let wikisItem = NSMenuItem(
                title: "Wikis",
                action: nil,
                keyEquivalent: "")
            let wikisMenu = NSMenu()
            for wiki in registry.wikis {
                let item = NSMenuItem(
                    title: wiki.displayName,
                    action: #selector(openWikiWindow(_:)),
                    keyEquivalent: "")
                item.target = self
                item.representedObject = wiki.id
                // Show an "open" icon next to wikis whose window is
                // currently on screen, rather than a checkmark on the
                // most-recently-used wiki. The MRU wiki can differ from
                // what's actually loaded: in accessory mode every window
                // may be closed while `activeWikiID` still holds the last
                // one. A window's presence is the true "loaded" signal.
                if windowForWiki(wiki.id) != nil {
                    let symbol = NSImage(
                        systemSymbolName: "macwindow",
                        accessibilityDescription: "Wiki is open")
                    symbol?.isTemplate = true
                    item.image = symbol
                }
                wikisMenu.addItem(item)
            }
            wikisItem.submenu = wikisMenu
            menu.addItem(wikisItem)
            menu.addItem(.separator())
        } else {
            // No wikis exist: offer the main window so the user can create one.
            let item = NSMenuItem(
                title: "New Wiki…",
                action: #selector(openMainWindow(_:)),
                keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        }

        let continuousIngestItem = NSMenuItem(
            title: "Continuous Ingest",
            action: #selector(toggleContinuousIngest(_:)),
            keyEquivalent: "")
        continuousIngestItem.target = self
        continuousIngestItem.state = UserDefaults.standard.bool(forKey: "backgroundIngestEnabled") ? .on : .off
        menu.addItem(continuousIngestItem)

        menu.addItem(.separator())

        // Per-queue windows.
        let ingestionItem = NSMenuItem(
            title: "Agent Queue…",
            action: #selector(openIngestionWindow(_:)),
            keyEquivalent: "i")
        ingestionItem.target = self
        menu.addItem(ingestionItem)

        let extractionItem = NSMenuItem(
            title: "Extraction Queue…",
            action: #selector(openExtractionWindow(_:)),
            keyEquivalent: "e")
        extractionItem.target = self
        menu.addItem(extractionItem)

        menu.addItem(.separator())

        // #528 spike: today's cumulative token/cost usage. The summary line
        // stays unchanged; #583 adds per-model inline disabled items below it
        // (heaviest model first) so the user sees which model drove the
        // aggregate. Kept compact — one segment per token kind, middle-dot
        // separator, 6pt left indent so the group reads as a sub-section.
        if activityTracker.todayUsage.hasData {
            let usageItem = NSMenuItem(
                title: UsageFormatter.dailySummary(usage: activityTracker.todayUsage),
                action: nil,
                keyEquivalent: "")
            usageItem.isEnabled = false
            menu.addItem(usageItem)

            // #583: per-model breakdown. One disabled indented item per model.
            let breakdown = activityTracker.todayUsageByModel
            if breakdown.hasData {
                for entry in breakdown.sortedForDisplay {
                    let line = UsageFormatter.modelBreakdownLine(
                        modelId: entry.modelId,
                        breakdown: entry.breakdown,
                        displayNameProvider: nil)
                    let item = NSMenuItem(
                        title: "    \(line)",
                        action: nil,
                        keyEquivalent: "")
                    item.isEnabled = false
                    // Secondary-label gray so the breakdown reads as
                    // supporting detail under the summary line, not as
                    // primary content matching the summary's weight.
                    let attrTitle = NSAttributedString(
                        string: "    \(line)",
                        attributes: [
                            .foregroundColor: NSColor.secondaryLabelColor,
                            .font: NSFont.menuFont(ofSize: 0)
                        ])
                    item.attributedTitle = attrTitle
                    menu.addItem(item)
                }
            }
            menu.addItem(.separator())
        }

        // Wiki maintenance actions.
        let maintenanceItem = NSMenuItem(
            title: "Maintenance",
            action: nil,
            keyEquivalent: "")
        let maintenanceMenu = NSMenu()
        maintenanceMenu.addItem(withTitle: "Vacuum All…",
            action: #selector(vacuumAll(_:)), keyEquivalent: "").target = self
        maintenanceMenu.addItem(withTitle: "Restart Daemon",
            action: #selector(restartDaemon(_:)), keyEquivalent: "").target = self
        maintenanceItem.submenu = maintenanceMenu
        menu.addItem(maintenanceItem)

        menu.addItem(.separator())

        // Settings — moved here from the "Self Driving Wiki" app menu (the
        // status item is reachable even in accessory mode; the app menu
        // isn't). Opens the Settings scene via the `OpenWindowBridge`
        // `openSettings` closure, which is wired from `@Environment(\.openSettings)`
        // — the same supported SwiftUI API the gear buttons use. The old
        // `sendAction(showSettingsWindow:)` selector was unreliable: it walks
        // the responder chain, which has no handler when all windows are
        // closed (accessory mode) or after the auto-generated Settings menu
        // item was removed by `removeRedundantAppMenuItems`.
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings(_:)),
            keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        // Launch-at-login toggle, backed by `SMAppService.mainApp` (no
        // separate login-item helper needed on macOS 13+). Read fresh on
        // every menu build so a change made through System Settings ▸
        // General ▸ Login Items is reflected without a manual refresh.
        let launchAtLoginItem = NSMenuItem(
            title: "Open at Login",
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: "")
        launchAtLoginItem.target = self
        launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launchAtLoginItem)

        // Confirm-before-quit toggle. The Settings UI toggle for this was
        // removed along with the old Permissions tab, but `AppDelegate` still
        // reads `confirmBeforeQuitting` to gate the quit dialog — this menu
        // item is now the only way to turn it off, so it lives in the
        // always-reachable status menu rather than Settings.
        let confirmQuitItem = NSMenuItem(
            title: "Confirm Before Quitting",
            action: #selector(toggleConfirmBeforeQuitting(_:)),
            keyEquivalent: "")
        confirmQuitItem.target = self
        confirmQuitItem.state = AppDelegate.confirmBeforeQuitting ? .on : .off
        menu.addItem(confirmQuitItem)

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

    @objc private func openWikiWindow(_ sender: NSMenuItem?) {
        guard let wikiID = sender?.representedObject as? WikiID else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)

        // Focus an already-open window for this wiki rather than opening a
        // duplicate. `openWindow(value:)` only dedups within the value-driven
        // WindowGroup; a wiki adopted by the main window is invisible to it,
        // so we look the window up by the identifier WindowIdentifierTagger
        // stamps on it.
        if let existing = windowForWiki(wikiID) {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        openWindowBridge.openWiki?(wikiID)
    }

    /// Returns the on-screen `NSWindow` currently showing the given wiki, if
    /// any. Used to focus an already-open wiki window (avoiding duplicates in
    /// `openWikiWindow`) and to show the "open" icon in the Wikis submenu for
    /// wikis that are loaded.
    private func windowForWiki(_ wikiID: WikiID) -> NSWindow? {
        let identifier = NSUserInterfaceItemIdentifier(wikiWindowIdentifierPrefix + wikiID.rawValue)
        return NSApplication.shared.windows.first { $0.identifier == identifier }
    }

    @objc private func openMainWindow(_ sender: NSMenuItem?) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindowBridge.openMain?()
    }

    @objc private func toggleContinuousIngest(_ sender: NSMenuItem?) {
        let newValue = !UserDefaults.standard.bool(forKey: "backgroundIngestEnabled")
        UserDefaults.standard.set(newValue, forKey: "backgroundIngestEnabled")
        sender?.state = newValue ? .on : .off
        if newValue {
            backgroundIngestCoordinator?.start()
        } else {
            backgroundIngestCoordinator?.stop()
        }
    }

    @objc private func toggleConfirmBeforeQuitting(_ sender: NSMenuItem?) {
        let newValue = !AppDelegate.confirmBeforeQuitting
        UserDefaults.standard.set(newValue, forKey: AppDelegate.confirmQuitKey)
        sender?.state = newValue ? .on : .off
    }

    /// Register/unregister the app as a login item via `SMAppService`. If
    /// registering leaves the service in `.requiresApproval` (macOS requires
    /// the user to flip it on in System Settings the first time), open
    /// System Settings ▸ Login Items directly so the request doesn't look
    /// like it silently failed.
    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem?) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            DebugLog.store("MenuBarItemController: failed to toggle launch-at-login: \(error)")
        }
        sender?.state = service.status == .enabled ? .on : .off
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    @objc private func openIngestionWindow(_ sender: NSMenuItem?) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindowBridge.openQueueWindow?(.ingestion)
    }

    @objc private func openExtractionWindow(_ sender: NSMenuItem?) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindowBridge.openQueueWindow?(.extraction)
    }

    /// The session menu actions target: the frontmost wiki window's session,
    /// falling back to ANY live session — a status-item menu is reachable
    /// while no wiki window is key, and a silent `return` there reads as a
    /// dead menu item.
    private var targetSession: (any WikiSessionProtocol)? {
        sessionManager?.frontmostSession ?? sessionManager?.allSessions.first
    }

    @objc private func vacuumAll(_ sender: NSMenuItem?) {
        targetSession?.previewVacuumAll()
        activateWikiWindow()
    }

    /// Restarts the wikid daemon by invalidating the XPC connection +
    /// reconnecting (the system relaunches the XPC service on-demand).
    /// Delegates to the injected `daemonRestartHandler` (which calls
    /// `DaemonHealthMonitor.forceReconnect()`).
    @objc private func restartDaemon(_ sender: NSMenuItem?) {
        DebugLog.store("wikid: restart requested")
        daemonRestartHandler?()
    }

    /// Open the Settings window. Calls the `OpenWindowBridge`'s
    /// `openSettings` closure — wired from `@Environment(\.openSettings)`
    /// inside `WindowBridgeProbe` — so a single supported code path opens
    /// Settings everywhere (gear buttons, "Open Settings…", status item).
    @objc private func openSettings(_ sender: NSMenuItem?) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindowBridge.openSettings?()
    }

    /// Bring a wiki window to the front. `openTab` switches the tab inside
    /// the store, but from the menu bar the app is usually inactive — without
    /// activation the switch happens in a background window and the click
    /// looks like it did nothing.
    private func activateWikiWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        // Focus the first visible, main-capable window. Queue windows are
        // now scene-managed (#835), so they're indistinguishable from wiki
        // windows here — but `activateWikiWindow` is only called after a wiki
        // operation (Vacuum, etc.), where the wiki window is the relevant one.
        if let window = NSApplication.shared.windows.first(where: { window in
            window.isVisible && window.canBecomeMain
        }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Per-queue activity windows

    /// #835: Queue Activity windows are now scene-managed
    /// (`WindowGroup(for: QueueKind.self)` in `WikiFSApp`). Opening is done
    /// via `openWindowBridge.openQueueWindow?(queue)`, which calls SwiftUI's
    /// `openWindow(value:)`. This method closes any open queue windows during
    /// `stop()` (app teardown) — the system will close them during termination
    /// anyway, but this makes them disappear before the status item is removed.
    func closeActivityWindow() {
        // Scene-managed windows have the queue title in `title`. Close any
        // visible window whose title matches a queue window title.
        let queueTitles: Set<String> = ["Agent Queue", "Extraction Queue", "Transcription Queue"]
        for window in NSApplication.shared.windows where window.isVisible {
            if queueTitles.contains(window.title) {
                window.orderOut(nil)
            }
        }
    }

    // MARK: - Icon management

    /// Internal (not private) so `lastDerivedIconState` is assertable from
    /// the @testable blinker regression tests (#1222).
    enum IconState {
        case idle
        case working
        case paused
        case attention
        /// #878: the wikid daemon is disconnected. Shows `exclamation.triangle`
        /// so the user sees at a glance that the daemon is down and the app is
        /// running on a local fallback.
        case daemonDown
    }

    private func statusIcon(for state: IconState) -> NSImage? {
        // When the daemon is down, show the warning triangle (#878 BLOCKER 1.5).
        // Otherwise, ALWAYS the books glyph — paused/attention states convey
        // via the tooltip and the activity windows.
        if state == .daemonDown {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            return NSImage(systemSymbolName: "exclamation.triangle", accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
        }
        let filled: Bool
        switch state {
        case .working: filled = true
        case .idle, .paused, .attention: filled = false
        case .daemonDown: filled = false // unreachable (handled above)
        }
        return booksIcon(filled: filled)
    }

    /// The shared books glyph used for every status state and for each frame
    /// of the working-state animation. `filled` selects the filled variant
    /// (`books.vertical.fill`) vs the outline (`books.vertical`). SF Symbol
    /// images are template by default, so each frame tints correctly in light
    /// and dark menu bars without reasserting `isTemplate`.
    private func booksIcon(filled: Bool) -> NSImage? {
        let name = filled ? "books.vertical.fill" : "books.vertical"
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    private func updateIcon() {
        let state: IconState
        // #878: daemon-disconnected takes precedence — even if items are
        // running on the local fallback, the user needs to know the daemon is
        // down.
        // #1222: the working decision reads the event-maintained membership
        // sets, NOT `lastSnapshot.activeItems`. The snapshot is refreshed by
        // an async RPC per event, so it can return stale or empty data after
        // the user already saw the "Lint queued" hint — leaving the icon idle
        // while a lint sits queued or running. The events themselves are the
        // timely truth; the snapshot only corrects them when provably fresh
        // (see `applySnapshot`).
        if daemonHealthMonitor?.state == .disconnected {
            state = .daemonDown
        } else if hasFailedItems {
            state = .attention
        } else if isPaused {
            state = .paused
        } else if !queuedItemIDs.isEmpty || !runningItemIDs.isEmpty {
            state = .working
        } else {
            state = .idle
        }
        lastDerivedIconState = state
        statusItem?.button?.toolTip = tooltipText(for: state)

        // While working, breathe the books glyph between its outline and
        // filled forms so the menu bar shows live progress without opening
        // the Activity window. Every other state is a static glyph; leaving
        // the working state cancels the loop (no CPU when idle).
        if state == .working {
            startIconAnimation()
        } else {
            stopIconAnimation()
            statusItem?.button?.image = statusIcon(for: state)
        }
    }

    private func tooltipText(for state: IconState) -> String {
        switch state {
        case .idle: return "Self Driving Wiki — Idle"
        case .working:
            // #1222: counts come from the event-maintained membership sets so
            // the tooltip always agrees with the blinker — even in the window
            // before a snapshot RPC returns (or when it returned stale data).
            let running = runningItemIDs.count
            let queued = queuedItemIDs.count
            if running > 0 && queued > 0 {
                return "Self Driving Wiki — Processing (\(running) active, \(queued) queued)"
            } else if running > 0 {
                return "Self Driving Wiki — Processing (\(running) active)"
            } else {
                return "Self Driving Wiki — \(queued) item\(queued == 1 ? "" : "s") queued"
            }
        case .paused: return "Self Driving Wiki — Paused"
        case .attention: return "Self Driving Wiki — Attention needed"
        case .daemonDown: return "Self Driving Wiki — wikid daemon not running (local fallback)"
        }
    }

    // MARK: - Working-state animation

    /// Begin breathing the books glyph between `books.vertical` and
    /// `books.vertical.fill` every 0.8 s while queue work is active. A
    /// `Task`-based loop (rather than `Timer`) keeps every frame on the
    /// `@MainActor` — `NSStatusItem` is main-thread-only — and is trivially
    /// cancellable. Guarded so the many `updateIcon` calls during a busy run
    /// only start one loop per working period.
    private func startIconAnimation() {
        guard animationTask == nil else { return }
        DebugLog.tabs("MenuBarItemController: start icon animation")
        var isFilled = false
        // Render the first (outline) frame immediately so the icon responds
        // the instant work starts, rather than after one full interval.
        setAnimationFrame(filled: false)
        animationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // Task.sleep only throws CancellationError — expected, not actionable.
                // swiftlint:disable:next silent_try_optional
                try? await Task.sleep(nanoseconds: 800_000_000)
                if Task.isCancelled { break }
                isFilled.toggle()
                self?.setAnimationFrame(filled: isFilled)
            }
        }
    }

    /// Set one frame of the working-state animation.
    private func setAnimationFrame(filled: Bool) {
        statusItem?.button?.image = booksIcon(filled: filled)
    }

    /// Stop the breathing animation and release the loop.
    private func stopIconAnimation() {
        guard animationTask != nil else { return }
        animationTask?.cancel()
        animationTask = nil
    }

    // MARK: - Event handling

    /// Handle one queue event. Membership changes (enqueued / started /
    /// terminal) are applied SYNCHRONOUSLY to ``queuedItemIDs`` /
    /// ``runningItemIDs`` — the blinker must react to the event itself, not
    /// to a snapshot RPC that races it (#1222). Every membership change also
    /// spawns an epoch-guarded snapshot refresh so `lastSnapshot` (menu,
    /// failure badge) and the membership sets converge on daemon ground
    /// truth without ever letting a stale snapshot override event truth.
    private func handleEvent(_ event: QueueEvent) {
        switch event {
        case .runStateChanged(_, let state):
            if state == .paused {
                isPaused = true
            } else {
                refreshSnapshotGuarded(recomputesPaused: true)
                return
            }
        case .failed(let item, _):
            hasFailedItems = true
            // Terminal: drop from the active membership so the icon decision
            // doesn't retain the failed item (the attention state takes over
            // the icon here, matching the pre-#1222 behavior).
            removeMembership(itemID: item.id)
        case .completed(let item):
            beginTerminalRefresh(itemID: item.id)
            return
        case .cancelled(let item):
            beginTerminalRefresh(itemID: item.id)
            return
        case .enqueued(let item):
            // Show a transient popover anchored to the status item so the
            // user gets immediate feedback that their ingest / extraction /
            // lint was queued — before the icon even updates.
            let isLint = item.queue == .ingestion
                && item.payload.lintPageIDs != nil
            showTransientHint(
                message: isLint
                    ? "Lint queued"
                    : (item.queue == .ingestion
                        ? "Ingest queued"
                        : "Extraction queued"),
                symbol: isLint
                    ? "checkmark.seal"
                    : (item.queue == .ingestion
                        ? "books.vertical.fill"
                        : "doc.text.magnifyingglass")
            )
            // #1222: record the queued membership synchronously so the icon
            // enters the working state on THIS event. The old code only
            // refreshed `lastSnapshot` via an async RPC — a stale or empty
            // reply (or one racing the daemon's immediate dispatch) left the
            // icon idle even though the user just saw the "Lint queued"
            // hint.
            queuedItemIDs.insert(item.id)
            runningItemIDs.remove(item.id)
            noteMembershipChanged()
            return
        case .started(let item):
            // Move the item queued → running on the event itself, then let
            // the guarded refresh reconcile `lastSnapshot`.
            queuedItemIDs.remove(item.id)
            runningItemIDs.insert(item.id)
            noteMembershipChanged()
            return
        case .reordered:
            // A queued item was moved; refresh the snapshot for menu
            // accuracy. No hint popover (this is a reorder, not an enqueue),
            // and no membership change (state is unchanged).
            refreshSnapshotGuarded()
            return
        default:
            break
        }
        // Non-membership events (progress, usage, transcripts, …): the icon
        // decision can't change from the event alone, but keep refreshing the
        // snapshot so `lastSnapshot`/`hasFailedItems` track daemon truth.
        // The synchronous `updateIcon()` reasserts the current state (it is
        // idempotent while membership is unchanged).
        refreshSnapshotGuarded()
        updateIcon()
    }

    // MARK: - Membership + guarded snapshot refresh (#1222)

    /// Remove an item from the active membership sets. Returns whether the
    /// membership actually changed, so terminal handlers only spawn a
    /// refresh (and bump the epoch) when needed.
    @discardableResult
    private func removeMembership(itemID: QueueItem.ID) -> Bool {
        let removedQueued = queuedItemIDs.remove(itemID) != nil
        let removedRunning = runningItemIDs.remove(itemID) != nil
        return removedQueued || removedRunning
    }

    /// Bump the membership epoch, spawn a guarded snapshot refresh, and
    /// re-derive the icon. Called after every event-driven membership change.
    private func noteMembershipChanged() {
        membershipEpoch &+= 1
        refreshSnapshotGuarded()
        updateIcon()
    }

    /// Terminal-event path: drop the item from membership, recompute the
    /// failure badge from the fresh snapshot (as the pre-#1222 handler did),
    /// and re-derive the icon.
    private func beginTerminalRefresh(itemID: QueueItem.ID) {
        let changed = removeMembership(itemID: itemID)
        // Bump BEFORE capturing the epoch (and before spawning the fetch) so
        // this refresh is discarded only by a LATER membership change, never
        // by its own bump.
        if changed {
            membershipEpoch &+= 1
            updateIcon()
        }
        let epochAtFetch = membershipEpoch
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let snapshot = await self.queueSnapshot() else { return }
            // Stale guard: a membership change bumped the epoch while this
            // fetch was in flight — its own refresh applies fresher data.
            guard epochAtFetch == self.membershipEpoch else { return }
            self.lastSnapshot = snapshot
            self.hasFailedItems = snapshot.recentItems.contains {
                $0.state == .failed
            }
            if changed { self.applySnapshotMembership(from: snapshot) }
            self.updateIcon()
        }
    }

    /// Spawn a snapshot fetch that applies `lastSnapshot` (+ optional
    /// reconciliation) ONLY if no membership change occurred while the RPC
    /// was in flight. This is what makes snapshot data safe to apply as a
    /// full membership replace: it can never resurrect an item a terminal
    /// event already removed, nor erase one an enqueue event already added.
    private func refreshSnapshotGuarded(recomputesPaused: Bool = false) {
        let epochAtFetch = membershipEpoch
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let snapshot = await self.queueSnapshot() else { return }
            guard epochAtFetch == self.membershipEpoch else { return }
            if recomputesPaused {
                self.isPaused = snapshot.runStates.values.contains(.paused)
            }
            self.lastSnapshot = snapshot
            self.applySnapshotMembership(from: snapshot)
            self.updateIcon()
        }
    }

    /// Replace the membership sets from a provably-fresh snapshot. This is
    /// the seed path for items the controller never saw events for — e.g.
    /// daemon-hosted items already queued or running when the app launched —
    /// and the reconcile path that drops items whose terminal event was
    /// lost. `activeItems` contains only non-terminal items; anything not
    /// `.running` counts toward the queued side.
    private func applySnapshotMembership(from snapshot: QueueSnapshot) {
        var queued: Set<QueueItem.ID> = []
        var running: Set<QueueItem.ID> = []
        for item in snapshot.activeItems {
            if item.state == .running {
                running.insert(item.id)
            } else {
                queued.insert(item.id)
            }
        }
        queuedItemIDs = queued
        runningItemIDs = running
    }

    // MARK: - Transient hint

    private var lastHintMessage: String?
    
    /// Show a brief popover below the status item, anchored to its button.
    /// Auto-dismisses after 2.5 seconds, or when the user clicks elsewhere
    /// (`.semitransient` behavior), or when the menu opens (`menuNeedsUpdate`
    /// calls `dismissHint`).
    private func showTransientHint(message: String, symbol: String) {
        // #622: If the same message is already showing, just extend the timer
        // to avoid visual flicker during batch operations.
        if hintPopover?.isShown == true, lastHintMessage == message {
            startHintDismissTimer()
            return
        }

        dismissHint()
        lastHintMessage = message

        let popover = NSPopover()
        // .semitransient is more robust than .transient when the app is
        // performing other UI updates (like spinners) that might steal focus.
        popover.behavior = .semitransient
        popover.contentSize = NSSize(width: 220, height: 40)
        popover.contentViewController = NSHostingController(
            rootView: QueueHintView(message: message, symbol: symbol)
        )

        guard let button = statusItem?.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        hintPopover = popover

        startHintDismissTimer()
    }

    private func startHintDismissTimer() {
        hintDismissTask?.cancel()
        hintDismissTask = Task { @MainActor [weak self] in
            // Task.sleep only throws CancellationError — expected, not actionable.
            // swiftlint:disable:next silent_try_optional
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            self?.dismissHint()
        }
    }

    /// Close the transient hint popover (if any) and cancel its auto-dismiss.
    private func dismissHint() {
        hintDismissTask?.cancel()
        hintDismissTask = nil
        hintPopover?.close()
        hintPopover = nil
        lastHintMessage = nil
    }
}

// MARK: - Hint view

/// Compact one-line hint shown in the transient status-item popover.
private struct QueueHintView: View {
    let message: String
    let symbol: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.accentColor)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minWidth: 190)
    }
}
