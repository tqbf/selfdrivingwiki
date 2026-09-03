#if os(macOS)
import Observation
import WikiFSCore

/// Stable publication point for the app-wide daemon chat coordinator.
///
/// `WikiFSApp` is a value type whose initialization instance is not the mounted
/// scene value. Transport callbacks retain this holder instead of capturing the
/// transient app value, so successful daemon admission invalidates every scene
/// that reads `coordinator`.
@MainActor
@Observable
final class ChatDaemonCoordinatorHolder {
    private(set) var coordinator: ChatDaemonCoordinator?

    func replace(with replacement: ChatDaemonCoordinator?) {
        coordinator?.stop()
        coordinator = replacement
        DebugLog.store("WikiFSApp: chat daemon coordinator \(replacement == nil ? "cleared" : "published")")
    }
}
#endif
