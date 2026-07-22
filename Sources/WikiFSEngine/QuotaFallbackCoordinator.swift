#if os(macOS)
import Foundation
import WikiFSCore

/// #727: tracks which providers are exhausted (dead until a reset time) for
/// the duration of one ingestion run. The launcher consults this before each
/// phase to skip dead providers and pick the next live one in the stage's
/// chain.
///
/// @MainActor: the coordinator is touched only from the launcher's run path
/// (itself @MainActor). No lock is required — main-actor isolation serializes
/// all access. It is instantiated per-run (a provider can revive between runs
/// without cross-run state coupling).
@MainActor
final class QuotaFallbackCoordinator {

    /// providerId → revival time. A provider is "dead" while now < revival
    /// time. Entries are auto-pruned when `now >= revival` (lazy revival).
    private var deadUntil: [String: Date] = [:]

    /// providerId → the backend spawned for it (for teardown when it dies or
    /// the run ends). Each fallback provider gets its own `ACPBackend` actor;
    /// the coordinator owns its teardown so no backend leaks.
    private(set) var backends: [String: AgentBackend] = [:]

    /// The provider the planner ACTUALLY ran on (post-fallback), used by the
    /// executor to decide fork-vs-fresh-start (§3.6 step e of the plan). nil
    /// until the planner phase completes.
    private(set) var plannerProviderId: String?

    /// Mark `providerId` dead until `resetTime` (clamped to a minimum when nil
    /// — the detector already applies a default, so this is defensive). If the
    /// provider is already dead with a later reset time, keep the later one
    /// (the longer window wins).
    func markExhausted(_ providerId: String, resetTime: Date?, kind: QuotaSignal.Kind) {
        let revival: Date
        if let resetTime {
            if resetTime > Date() {
                // Future reset — honor it.
                revival = resetTime
            } else {
                // Past timestamp — provider is already revivable. Use a tiny
                // offset (1 second) so `isExhausted`'s auto-revival fires on
                // the next query.
                revival = resetTime
            }
        } else {
            // Defensive — the detector already applies a default, but if
            // the error carried no timestamp, apply one here.
            revival = Date(timeIntervalSinceNow: ProviderQuotaDetector.defaultResetInterval(for: kind))
        }
        // Keep the LATER revival time (the longer dead window wins).
        if let existing = deadUntil[providerId], existing > revival {
            // Already dead longer — no change needed.
            return
        }
        deadUntil[providerId] = revival
        DebugLog.agent("QuotaFallback: provider \(providerId) marked dead until \(revival) (kind: \(kind))")
    }

    /// True if `providerId` is currently dead (now < its revival time). Auto-
    /// revives (prunes the entry) if now >= revival time.
    func isExhausted(_ providerId: String) -> Bool {
        guard let revival = deadUntil[providerId] else { return false }
        if Date() >= revival {
            // Auto-revival — the provider's quota window has reset.
            deadUntil.removeValue(forKey: providerId)
            return false
        }
        return true
    }

    /// The first live (non-exhausted) provider in `chain`, or nil if all are
    /// dead. This is the coordinator's primary query — the launcher calls it
    /// to pick the provider for each phase.
    func firstLive(in chain: [AgentProvider]) -> AgentProvider? {
        chain.first { !isExhausted($0.id) }
    }

    /// Record a backend for teardown purposes.
    func recordBackend(_ backend: AgentBackend, forProvider providerId: String) {
        backends[providerId] = backend
    }

    /// Record which provider + backend the planner actually used (post-
    /// fallback). This is the source of truth for "which provider the planner
    /// ran on" — the executor compares its resolved provider against this to
    /// decide fork-vs-fresh-start.
    func recordPlanner(providerId: String, backend: AgentBackend) {
        plannerProviderId = providerId
        recordBackend(backend, forProvider: providerId)
    }

    /// Teardown: cancel all fallback backends (those in `backends` that are
    /// NOT for the `primaryProviderId`). The primary backend (planner
    /// provider's) is owned by `run()`'s lifecycle; fallback backends are
    /// owned by the coordinator.
    func finishFallbackBackends(excludingPrimaryProvider primaryProviderId: String?) async {
        for (providerId, backend) in backends {
            if let primaryProviderId, providerId == primaryProviderId {
                continue
            }
            DebugLog.agent("QuotaFallback: tearing down fallback backend for \(providerId)")
            await backend.cancel(SessionHandle(id: ""))
        }
        if let primaryProviderId {
            backends = backends.filter { $0.key == primaryProviderId }
        } else {
            backends.removeAll()
        }
    }
}
#endif
