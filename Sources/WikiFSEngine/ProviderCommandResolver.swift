import Foundation
import WikiFSCore

/// The ONE production provider-command resolution path (issue #1279 AC.9).
///
/// The shipped default provider command is a BARE `bun x
/// @agentclientprotocol/claude-agent-acp`. A GUI daemon's launchd PATH usually
/// lacks the directory mise (or any version manager) puts `bun` in, so a
/// PATH-only resolver drops the provider from the chain (`noAgentConfigured`)
/// even though the login shell can name an absolute bun. `ACPBackend`'s
/// canonicalization already resolves bun through the validated
/// `RuntimeCommandLocator` — but that runs too late for the resolution that
/// decides whether the provider exists at all.
///
/// Every production `AgentProviderProcessInput.resolveCommand` composition
/// (the daemon's `ProductionPluginCatalogs` AND the app/renderer's
/// `RendererCompositionOwner`) resolves through THIS type so both see the
/// same result. Resolution order for each provider:
///
/// 1. The login-shell PATH result (`AgentLauncher.resolveCommand`), unchanged
///    for every provider it resolves — including absolute configured paths
///    and non-Bun commands.
/// 2. If the PATH lookup MISSES and the configured first token names the bare
///    `bun` runtime, `RuntimeCommandLocator.locate` (the validated Bun
///    lookup — the same shell query, identity probe, and timeout contract the
///    canonicalization path uses) supplies the probed absolute bun path.
/// 3. If both lookups fail, the provider resolves to NO command — the
///    existing drop-from-chain failure, unchanged.
///
/// An absolute or relative configured path NEVER gets the fallback: step 2
/// exists to find the runtime a bare name names, not to substitute a
/// different binary for one the user pinned explicitly.
public enum ProviderCommandResolver {

    /// The validated Bun runtime lookup: `RuntimeCommandLocator.locate` for
    /// the `bun` runtime name, returning the probed absolute executable path.
    /// This is the ONLY fallback implementation (issue #1279 Phase 4) — no
    /// call site re-implements the shell query, identity probe, or timeout.
    public static let defaultLocateBun: @Sendable () async -> String? = {
        guard let name = ExtractorRuntimeName(rawValue: "bun") else { return nil }
        guard case .resolved(let resolution) = await RuntimeCommandLocator().locate(name) else {
            return nil
        }
        return resolution.executableURL.path
    }

    /// Resolve a batch of providers in one pass. The Bun locator runs AT MOST
    /// ONCE per call (it shells out to a login shell); providers that never
    /// need it never pay for it.
    public static func resolveCommands(
        for providers: [AgentProvider],
        searchPath: String?,
        locateBun: @escaping @Sendable () async -> String? = ProviderCommandResolver.defaultLocateBun
    ) async -> [ProviderID: [String]] {
        var bunPath: String?
        var bunLookupDone = false
        var resolved: [ProviderID: [String]] = [:]
        resolved.reserveCapacity(providers.count)
        for provider in providers {
            // Step 1: the login-shell PATH result, unchanged when it hits.
            if let path = AgentLauncher.resolveCommand(for: provider, searchPath: searchPath) {
                resolved[provider.id] = path
                continue
            }
            // Step 2 applies ONLY to a bare `bun` first token.
            guard let command = provider.command,
                  let first = command.first,
                  isBareBunToken(first) else {
                continue
            }
            if !bunLookupDone {
                bunPath = await locateBun()
                bunLookupDone = true
            }
            // Step 3: both lookups missed → no command (drop from chain).
            guard let bun = bunPath else { continue }
            resolved[provider.id] = [bun] + Array(command.dropFirst())
        }
        return resolved
    }

    /// Resolve one provider (the single-provider form of `resolveCommands`).
    public static func resolveCommand(
        for provider: AgentProvider,
        searchPath: String?,
        locateBun: @escaping @Sendable () async -> String? = ProviderCommandResolver.defaultLocateBun
    ) async -> [String]? {
        guard let command = provider.command, !command.isEmpty else { return nil }
        if let path = AgentLauncher.resolveCommand(for: provider, searchPath: searchPath) {
            return path
        }
        guard let first = command.first, isBareBunToken(first) else { return nil }
        guard let bun = await locateBun() else { return nil }
        return [bun] + Array(command.dropFirst())
    }

    /// True when `token` names the bare `bun` executable — no directory, no
    /// leading `./`/`../`, no explicit path. Tilde forms expand to absolute
    /// paths and therefore never count: the user pinned a location, and a
    /// locator miss must surface as "provider not resolved", not as a silent
    /// substitution. Case-insensitive because the runtime NAME is what
    /// matters, not the spelling a version manager happened to install.
    static func isBareBunToken(_ token: String) -> Bool {
        ShellArgv.expandTilde(token).lowercased() == "bun"
    }
}
