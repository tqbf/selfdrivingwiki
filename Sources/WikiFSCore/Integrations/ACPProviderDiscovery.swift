import Foundation

/// Filesystem discovery of installed ACP agents (slice of #217): for each
/// catalog entry, check whether its `detectExecutable` is on the login-shell
/// PATH. Found agents become candidate ACP providers (the app surfaces them for
/// the user to enable).
///
/// PURE-ish: the PATH resolver is injectable so the discovery logic is unit-
/// tested without touching the real filesystem (the production resolver is
/// `PathPreflight.resolveOnLoginShell`, which does a real `zsh -lc` hop because
/// the GUI app's PATH isn't the user's login PATH).
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
    /// the default resolves on the login-shell PATH. Returns the catalog agents
    /// whose binary was found, each with its resolved path.
    ///
    /// Non-autoDetectable entries (runtime-launched agents like `claude-acp`
    /// via `bun`, or npx/uvx packages) are skipped — see
    /// `KnownACPAgent.autoDetectable`.
    public static func discover(
        in catalog: [KnownACPAgent] = ACPProviderCatalog.agents,
        resolve: (String) -> PathPreflight.Result = PathPreflight.resolveOnLoginShell
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
}
