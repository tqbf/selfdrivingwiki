import Foundation
import SwiftUI
import WikiFSCore
import WikiFSEngine

/// The app-layer owner of the adapter upgrade check (the bootstrap trigger
/// the plan names). Runs the manager:
/// - automatically at app activation, throttled (the registry client's own
///   24h cache TTL gates the network fetch; this throttle keeps the cheap
///   re-decision from running on every window focus), and
/// - manually from Settings ("Check for Adapter Updates"), which bypasses
///   the throttle, the probe backoff, and restore suppression.
///
/// Also hosts the one-click **Restore previous command** action: a single
/// locked `AgentProvidersConfigStore` mutation that swaps the command back
/// and records the adopted version as suppressed.
@MainActor
final class ACPAdapterUpgradeCoordinator: ObservableObject {
    /// Minimum seconds between automatic checks. The registry fetch is
    /// TTL-gated separately; this bounds the (cheap) decision pass.
    static let automaticThrottle: TimeInterval = 6 * 3_600

    /// The probe's initialize-handshake bound. Generous enough for a cold
    /// npx first fetch; bounded so a hung candidate cannot pin the check.
    static let probeTimeout: Duration = .seconds(20)

    @Published private(set) var isChecking = false
    /// One-line summary of the last completed check, for the Settings row.
    @Published private(set) var lastCheckSummary: String?

    nonisolated private let manager: ACPAdapterUpgradeManager
    private let store: AgentProvidersConfigStore
    private let containerDirectory: URL
    private let chatDaemonHolder: ChatDaemonCoordinatorHolder
    private var lastAutomaticCheck: Date?

    init(
        containerDirectory: URL,
        providerServices: any AgentProviderServices,
        chatDaemonHolder: ChatDaemonCoordinatorHolder
    ) {
        self.containerDirectory = containerDirectory
        self.chatDaemonHolder = chatDaemonHolder
        self.store = AgentProvidersConfigStore(directory: containerDirectory)
        let store = self.store
        let directory = containerDirectory
        self.manager = ACPAdapterUpgradeManager(
            directory: directory,
            store: store,
            dependencies: .init(
                loadRegistryAgents: {
                    await ACPProviderCatalog.loadAgents()
                },
                probeCandidate: { candidate in
                    try await Self.probeCandidate(
                        candidate, providerServices: providerServices)
                },
                providersInLiveUse: {
                    // Conservative defer-all: when any chat is generating, no
                    // provider is adoption-eligible this check. The next
                    // eligible check (or launch) retries.
                    let anyChatGenerating = await chatDaemonHolder
                        .coordinator?.anyChatGenerating ?? false
                    guard anyChatGenerating else { return [] }
                    let config = AgentProvidersConfig.load(from: directory)
                        ?? AgentProvidersConfig.seed(discovered: [])
                    return Set(config.providers.map(\.id))
                }))
    }

    /// The automatic activation path: no-op when the throttle window is
    /// still open or a check is already running.
    public func runAutomaticCheckIfDue() async {
        if let lastAutomaticCheck,
           Date().timeIntervalSince(lastAutomaticCheck) < Self.automaticThrottle {
            return
        }
        await runCheck(mode: .automatic, bypassThrottle: true)
        lastAutomaticCheck = Date()
    }

    /// The Settings "Check for Adapter Updates" action: always runs, in
    /// manual mode (bypasses backoff and restore suppression).
    public func checkNow() async {
        await runCheck(mode: .manual, bypassThrottle: true)
    }

    /// One-click rollback of the provider's last adoption (AC 3).
    public func restorePreviousCommand(for providerID: ProviderID) async {
        do {
            _ = try await store.mutate { config in
                config.restoringPreviousAdapterCommand(forProvider: providerID) ?? config
            }
            DebugLog.agent("ACPAdapterUpgradeCoordinator: restored previous command for \(providerID.rawValue)")
        } catch {
            DebugLog.agent("ACPAdapterUpgradeCoordinator: restore failed for \(providerID.rawValue): \(error)")
        }
    }

    private func runCheck(mode: ACPAdapterUpgradeManager.CheckMode, bypassThrottle: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        let outcome = await manager.runCheck(mode: mode)
        lastCheckSummary = Self.summarize(outcome)
    }

    // MARK: - Seams

    /// Probe one candidate through the production launch machinery:
    /// login-shell PATH resolution, Keychain credentials, and the
    /// initialize-only candidate probe (sandboxed, hard-bounded).
    nonisolated private static func probeCandidate(
        _ candidate: AgentProvider,
        providerServices: any AgentProviderServices
    ) async throws -> ACPAdapterCandidateReport {
        let words = candidate.command ?? []
        guard let executable = words.first, !executable.isEmpty else {
            throw ACPProviderModelProbeError.notConfigured
        }
        // The SDK's Process.launch does no PATH lookup (#640) — resolve the
        // executable on the login-shell PATH first.
        let resolvedPath: String
        switch await PathPreflight.resolveOnLoginShell(executable: executable) {
        case .found(let path):
            resolvedPath = path
        default:
            throw ACPProviderModelProbeError.notConfigured
        }
        let resolvedCommand = [resolvedPath] + words.dropFirst()
        // The candidate's Keychain secrets (the closed known-variable set) —
        // the probe never authenticates, but resolveSpawnConfig shapes the
        // same hints a real launch would, so the spawn shape matches.
        let secrets = ProviderSecretEnvironment.resolvedSpawnSecrets(
            for: candidate.id, resolving: KeychainCredentialService())
        let probe = ACPAdapterCandidateProbe(
            provider: candidate,
            resolvedCommand: resolvedCommand,
            apiKey: secrets.values.first,
            loginShellPATH: await PathPreflight.loginShellPATH())
        return try await probe.runHandshake(timeout: probeTimeout)
    }

    /// A one-line human summary of a check outcome for the Settings row.
    nonisolated private static func summarize(
        _ outcome: ACPAdapterUpgradeManager.Outcome
    ) -> String {
        var adopted = 0
        var failed = 0
        var available = 0
        for (_, result) in outcome.results {
            switch result {
            case .adopted: adopted += 1
            case .probeFailed: failed += 1
            case .updateAvailable: available += 1
            default: break
            }
        }
        let parts: [String] = [
            adopted == 1 ? "1 adapter updated" : "\(adopted) adapters updated",
            available == 1 ? "1 update available" : "\(available) updates available",
            failed == 1 ? "1 probe failed" : "\(failed) probes failed",
        ]
        return parts.joined(separator: " · ")
    }
}
