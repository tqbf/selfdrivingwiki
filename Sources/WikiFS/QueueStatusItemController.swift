import AppKit
import SwiftUI
import WikiFSCore
import WikiFSEngine

/// Controls the menu-bar status item and Activity window for the queue engine.
///
/// The status item icon reflects the engine's state:
/// - **idle** (circle) — no active items, queue running
/// - **working** (circle.fill) — items running
/// - **paused** (circle.dashed) — a queue is paused
/// - **attention** (exclamationmark.circle) — failed items need attention
///
/// Clicking the status item toggles the Activity window, which lists
/// active/recent items across all wikis with per-item agent transcripts,
/// per-queue pause/resume/halt controls, and per-row cancel/retry.
///
/// Lives in `WikiFS` because it uses AppKit (`NSStatusItem`, `NSWindow`)
/// and SwiftUI for the window content. The engine itself stays headless.
@MainActor
final class QueueStatusItemController {

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

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        // Set up the button.
        if let button = item.button {
            button.image = statusIcon(for: .idle)
            button.image?.isTemplate = true
            button.action = #selector(toggleActivityWindow(_:))
            button.target = self
            button.toolTip = "Self Driving Wiki — Activity"
        }

        // Observe engine events to update the icon.
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

    // MARK: - Activity window

    @objc private func toggleActivityWindow(_ sender: AnyObject?) {
        if let window = activityWindow, window.isVisible {
            window.orderOut(nil)
        } else {
            showActivityWindow()
        }
    }

    private func showActivityWindow() {
        if activityWindow == nil {
            let contentView = ActivityWindowView(
                queueEngine: queueEngine,
                activityTracker: activityTracker,
                sessionManager: sessionManager
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Activity"
            window.contentView = NSHostingView(rootView: contentView)
            window.isReleasedWhenClosed = false
            window.center()
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
        case .idle: name = "circle"
        case .working: name = "circle.fill"
        case .paused: name = "pause.circle"
        case .attention: name = "exclamationmark.circle"
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
        case .runStateChanged(let queue, let state):
            if state == .paused {
                isPaused = true
            } else {
                // Check if both queues are running.
                Task {
                    let snapshot = await queueEngine.snapshot()
                    isPaused = snapshot.runStates.values.contains(.paused)
                    updateIcon()
                }
                return
            }
        case .failed:
            hasFailedItems = true
        case .completed, .cancelled:
            // Re-check failed status from snapshot.
            Task {
                let snapshot = await queueEngine.snapshot()
                hasFailedItems = snapshot.recentItems.contains {
                    $0.state == .failed
                }
                updateIcon()
            }
            return
        default:
            break
        }
        updateIcon()
    }
}
