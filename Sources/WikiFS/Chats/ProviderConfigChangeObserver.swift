import Foundation
import WikiFSCore

/// App-lifetime bridge for process-local and Darwin provider-sidecar signals.
/// Duplicate signals coalesce onto one main-actor reload callback.
@MainActor
final class ProviderConfigChangeObserver {
    private let reload: @MainActor () -> Void
    private var localToken: NSObjectProtocol?
    private var pendingReload: Task<Void, Never>?

    init(reload: @escaping @MainActor () -> Void) {
        self.reload = reload
        localToken = NotificationCenter.default.addObserver(
            forName: .agentProvidersConfigDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleReload() }
        }
        let name = CFNotificationName(AgentProvidersConfigStore.darwinNotificationName as CFString)
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let value = Unmanaged<ProviderConfigChangeObserver>
                    .fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in value.scheduleReload() }
            },
            name.rawValue,
            nil,
            .deliverImmediately)
    }

    private func scheduleReload() {
        guard pendingReload == nil else { return }
        pendingReload = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            pendingReload = nil
            reload()
        }
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque())
    }

    func stop() {
        pendingReload?.cancel()
        pendingReload = nil
        if let localToken {
            NotificationCenter.default.removeObserver(localToken)
            self.localToken = nil
        }
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque())
    }
}
