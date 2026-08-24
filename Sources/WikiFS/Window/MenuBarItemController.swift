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

        // Fetch initial snapshot so the icon reflects any items already
        // in the queue (e.g. rehydrated from a previous session).
        Task {
            if let snapshot = await queueSnapshot() {
                lastSnapshot = snapshot
                updateIcon()
            }
        }

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

    private enum IconState {
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
        if daemonHealthMonitor?.state == .disconnected {
            state = .daemonDown
        } else if hasFailedItems {
            state = .attention
        } else if isPaused {
            state = .paused
        } else if !lastSnapshot.activeItems.isEmpty {
            state = .working
        } else {
            state = .idle
        }
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
            let running = lastSnapshot.activeItems.filter { $0.state == .running }.count
            let queued = lastSnapshot.activeItems.filter { $0.state == .queued }.count
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

    private func handleEvent(_ event: QueueEvent) {
        switch event {
        case .runStateChanged(_, let state):
            if state == .paused {
                isPaused = true
            } else {
                Task {
                    guard let snapshot = await queueSnapshot() else { return }
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
                guard let snapshot = await queueSnapshot() else { return }
                hasFailedItems = snapshot.recentItems.contains {
                    $0.state == .failed
                }
                lastSnapshot = snapshot
                updateIcon()
            }
            return
        case .enqueued(let item):
            // Show a transient popover anchored to the status item so the
            // user gets immediate feedback that their ingest / extraction
            // was queued — before the icon even updates.
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
            // Refresh snapshot + update icon so the menu bar immediately
            // reflects queued items (not just running ones). Without this,
            // the icon stays idle when an item is enqueued but hasn't
            // started yet — giving no feedback that work was queued.
            Task {
                guard let snapshot = await queueSnapshot() else { return }
                lastSnapshot = snapshot
                updateIcon()
            }
            return
        case .started:
            // Refresh snapshot + update icon so the menu bar reflects
            // items that have transitioned to running.
            Task {
                guard let snapshot = await queueSnapshot() else { return }
                lastSnapshot = snapshot
                updateIcon()
            }
            return
        case .reordered:
            // A queued item was moved; refresh the snapshot for menu
            // accuracy. No hint popover (this is a reorder, not an enqueue).
            Task {
                guard let snapshot = await queueSnapshot() else { return }
                lastSnapshot = snapshot
            }
            return
        default:
            break
        }
        Task {
            guard let snapshot = await queueSnapshot() else { return }
            lastSnapshot = snapshot
            updateIcon()
        }
        updateIcon()
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
