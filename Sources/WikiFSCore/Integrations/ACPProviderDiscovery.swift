import Foundation

/// Filesystem discovery of installed ACP agents (slice of #217): for each
/// catalog entry, check whether its `detectExecutable` is on the login-shell
/// PATH. Found agents become candidate ACP providers (the app surfaces them for
/// the user to enable).
///
/// PURE-ish: the PATH resolver is injectable so the discovery logic is unit-
/// tested without touching the real filesystem.
///
/// Discovery checks the BINARY exists — it does NOT verify the agent actually
/// speaks ACP (that's validated when `ACPBackend` launches it). A found agent is
/// a candidate, not a guarantee.
///
/// Entries where `KnownACPAgent.autoDetectable == false` are SKIPPED. Those
/// entries' `detectExecutable` is a generic JS/Python runtime (`bun`, `npx`,
/// `uvx`, `node`) — finding the runtime on PATH doesn't mean the agent package
/// is installed (false positive). The user adds those manually via the Add
/// Provider sheet and discovers models via the refresh-probe button.
public struct DiscoveredACPAgent: Sendable, Equatable {
    public let agent: KnownACPAgent
    public let resolvedPath: String   // absolute path the binary was found at

    public init(agent: KnownACPAgent, resolvedPath: String) {
        self.agent = agent
        self.resolvedPath = resolvedPath
    }
}

public enum ACPProviderDiscovery {

    /// Discover installed ACP agents from `catalog` (defaults to the known
    /// catalog). `resolve` maps an executable name to a `PathPreflight.Result`;
    /// the default resolves on the current process PATH. Returns the catalog
    /// agents whose binary was found, each with its resolved path.
    ///
    /// Non-autoDetectable entries (runtime-launched agents like `claude-acp`
    /// via `bun`, or npx/uvx packages) are skipped — see
    /// `KnownACPAgent.autoDetectable`.
    public static func discover(
        in catalog: [KnownACPAgent] = ACPProviderCatalog.agents,
        resolve: (String) -> PathPreflight.Result = { executable in
            PathPreflight.resolve(
                executable: executable,
                usingSearchPath: ProcessInfo.processInfo.environment["PATH"] ?? "")
        }
    ) -> [DiscoveredACPAgent] {
        catalog.compactMap { agent in
            // Skip runtime-launched agents — finding the runtime on PATH does
            // NOT mean the agent package is installed.
            guard agent.autoDetectable else { return nil }
            switch resolve(agent.detectExecutable) {
            case .found(let path):
                return DiscoveredACPAgent(agent: agent, resolvedPath: path)
            case .missing:
                return nil
            }
        }
    }

    public static func discoverOnLoginShell(
        in catalog: [KnownACPAgent] = ACPProviderCatalog.agents
    ) async -> [DiscoveredACPAgent] {
        await discoverOnLoginShell(in: catalog, runProcess: AsyncProcessRunner.run)
    }

    static func discoverOnLoginShell(
        in catalog: [KnownACPAgent] = ACPProviderCatalog.agents,
        runProcess: (AsyncProcessRequest) async throws -> AsyncProcessResult
    ) async -> [DiscoveredACPAgent] {
        let path = await PathPreflight.loginShellPATH(using: runProcess)
            ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        return discover(in: catalog) { executable in
            PathPreflight.resolve(executable: executable, usingSearchPath: path)
        }
    }
}
