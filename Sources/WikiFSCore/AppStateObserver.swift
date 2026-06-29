import AppKit
import Foundation

/// Tracks whether the app is in the foreground so the MiniLM backfill can
/// avoid submitting MLX/Metal GPU work while backgrounded — Metal crashes with
/// `Insufficient Permission` if the app loses GPU access mid-inference.
///
/// Call `start()` once at app launch. The backfill loop checks `isActive`
/// before each inference and spins (Thread.sleep) while false.
public final class AppStateObserver: @unchecked Sendable {
    public static let shared = AppStateObserver()

    private let lock = NSLock()
    private var _isActive = true

    public var isActive: Bool {
        lock.withLock { _isActive }
    }

    private var observers: [NSObjectProtocol] = []

    public func start() {
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == Bundle.main.bundleIdentifier else { return }
            self?.set(true)
        })
        observers.append(nc.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == Bundle.main.bundleIdentifier else { return }
            self?.set(false)
        })
    }

    private func set(_ active: Bool) {
        lock.withLock { _isActive = active }
        DebugLog.store("AppStateObserver: app \(active ? "active" : "backgrounded")")
    }
}
