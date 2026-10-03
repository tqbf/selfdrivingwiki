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

    /// Where the coordinator forwards "a chat tool call completed — the agent
    /// may have committed external writes" hints. Set by the app once the
    /// change bridge exists; applied to every coordinator this holder
    /// publishes (transport reconnects replace the instance).
    var suspectedExternalWriteSink: (@MainActor (WikiID) -> Void)? {
        didSet { applySuspectedExternalWriteSink() }
    }

    func replace(with replacement: ChatDaemonCoordinator?) {
        coordinator?.stop()
        coordinator = replacement
        DebugLog.store("WikiFSApp: chat daemon coordinator \(replacement == nil ? "cleared" : "published")")
        applySuspectedExternalWriteSink()
    }

    private func applySuspectedExternalWriteSink() {
        coordinator?.onSuspectedExternalWrite = suspectedExternalWriteSink
    }
}
#endif
