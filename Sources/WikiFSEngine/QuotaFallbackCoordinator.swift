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
///
/// **Phase 2 (#813):** Quota state is persisted to the app group container
/// as a JSON file (`quota-state.json`), so exhausted providers stay in cooldown
/// across app restarts. The background ingest coordinator checks this state
/// before enqueuing work.
@MainActor
public final class QuotaFallbackCoordinator {

    /// #813: persisted quota state structure (JSON)
    public struct QuotaState: Codable {
        public var version: Int
        public var providers: [ProviderQuotaEntry]
    }

    /// #813: individual provider quota entry
    public struct ProviderQuotaEntry: Codable {
        public let providerId: String
        public let deadUntil: Date
        public let kind: QuotaSignal.Kind
    }

    /// #813: providerId → (revival time, kind). A provider is "dead" while
    /// now < revival time. Entries are auto-pruned when `now >= revival`
    /// (lazy revival).
    private var deadUntil: [String: (revival: Date, kind: QuotaSignal.Kind)] = [:]

    /// #813: URL to the quota-state.json file. Defaults to the app group
    /// container; overridable for tests.
    private let quotaStateURL: URL

    /// providerId → the backend spawned for it (for teardown when it dies or
    /// the run ends). Each fallback provider gets its own `ACPBackend` actor;
    /// the coordinator owns its teardown so no backend leaks.
    private(set) var backends: [String: AgentBackend] = [:]

    /// The provider the planner ACTUALLY ran on (post-fallback), used by the
    /// executor to decide fork-vs-fresh-start (§3.6 step e of the plan). nil
    /// until the planner phase completes.
    private(set) var plannerProviderId: String?

    /// #813: initialize the coordinator and load persisted quota state.
    /// - Parameter quotaStateURL: override the persistence location (for
    ///   tests). Defaults to the app group container.
    public init(quotaStateURL: URL? = nil) {
        if let quotaStateURL {
            self.quotaStateURL = quotaStateURL
        } else {
            if let containerURL = try? DatabaseLocation.appGroupContainerDirectory() {
                self.quotaStateURL = containerURL.appendingPathComponent("quota-state.json")
            } else {
                DebugLog.store("QuotaFallbackCoordinator: failed to resolve app group container, using temp dir")
                self.quotaStateURL = FileManager.default.temporaryDirectory.appendingPathComponent("quota-state.json")
            }
        }
        loadQuotaState()
    }

    /// Mark `providerId` dead until `resetTime` (clamped to a minimum when nil
    /// — the detector already applies a default, so this is defensive). If the
    /// provider is already dead with a later reset time, keep the later one
    /// (the longer window wins).
    public func markExhausted(_ providerId: String, resetTime: Date?, kind: QuotaSignal.Kind) {
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
        if let existing = deadUntil[providerId], existing.revival > revival {
            // Already dead longer — no change needed.
            return
        }
        deadUntil[providerId] = (revival, kind)
        DebugLog.agent("QuotaFallback: provider \(providerId) marked dead until \(revival) (kind: \(kind))")
        saveQuotaState()
    }

    /// True if `providerId` is currently dead (now < its revival time). Auto-
    /// revives (prunes the entry) if now >= revival time.
    public func isExhausted(_ providerId: String) -> Bool {
        guard let entry = deadUntil[providerId] else { return false }
        if Date() >= entry.revival {
            // Auto-revival — the provider's quota window has reset.
            deadUntil.removeValue(forKey: providerId)
            saveQuotaState()
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

    // MARK: - #813: Persistence

    /// Load persisted quota state from JSON file in the app group container.
    /// Populates the `deadUntil` map with entries that are still valid
    /// (not yet expired). Prunes expired entries.
    private func loadQuotaState() {
        let url = quotaStateURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            DebugLog.agent("QuotaFallback: no persisted quota state found at \(url.path)")
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let state = try decoder.decode(QuotaState.self, from: data)

            guard state.version == 1 else {
                DebugLog.store("QuotaFallback: unsupported quota state version \(state.version), ignoring")
                return
            }

            let now = Date()
            var loadedCount = 0
            var prunedCount = 0

            for entry in state.providers {
                if entry.deadUntil > now {
                    deadUntil[entry.providerId] = (entry.deadUntil, entry.kind)
                    loadedCount += 1
                } else {
                    prunedCount += 1
                }
            }

            DebugLog.agent("QuotaFallback: loaded \(loadedCount) persisted quota entries, pruned \(prunedCount) expired")
        } catch {
            DebugLog.store("QuotaFallback: failed to load quota state from \(url.path): \(error.localizedDescription)")
        }
    }

    /// Save current quota state to JSON file in the app group container.
    /// Writes atomically via a temporary file. Logs errors but does not throw.
    private func saveQuotaState() {
        let url = quotaStateURL
        let state = QuotaState(
            version: 1,
            providers: deadUntil.map { providerId, entry in
                ProviderQuotaEntry(
                    providerId: providerId,
                    deadUntil: entry.revival,
                    kind: entry.kind
                )
            }
        )

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(state)

            // Atomic write handles the replace-existing case correctly.
            try data.write(to: url, options: .atomic)

            DebugLog.agent("QuotaFallback: saved \(state.providers.count) quota entries to \(url.path)")
        } catch {
            DebugLog.store("QuotaFallback: failed to save quota state to \(url.path): \(error.localizedDescription)")
        }
    }
}
#endif
