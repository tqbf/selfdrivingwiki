import Foundation

/// The macOS seatbelt (`sandbox-exec`) sandbox settings for the spawned agent.
///
/// When `enabled`, `AgentLauncher` wraps the provider invocation in
/// `/usr/bin/sandbox-exec` with a **default-deny write whitelist** profile (generated
/// by `SandboxProfile`): only the per-run scratch dir and the active wiki's SQLite DB
/// are writable; reads, network, and process execution stay open. The provider's own
/// config/temp are relocated into the scratch dir so the allowlist stays tiny and
/// provider-agnostic. See `plans/sandbox-agent.md`.
///
/// App-wide (one config for all wikis) and opt-in (`enabled` defaults to `false`),
/// exactly like `AgentCommandConfig`. Follows the same `Codable` + atomic
/// JSON-in-App-Group-container pattern as `ZoteroConfig` / `AgentCommandConfig` /
/// `WikiRegistry`. Loaded fresh at spawn time so Settings changes apply on the next
/// run without a restart.
public struct SandboxConfig: Codable, Equatable, Sendable {

    /// Off by default — the sandbox is opt-in. When `true`, the next agent spawn is
    /// confined to the write whitelist.
    public var enabled: Bool

    /// Additional paths the agent may write to, as `KEY`-less `PATH` lines (one
    /// absolute path per line). These are **additive**: they can only WIDEN the
    /// allowlist, never remove the scratch-dir / active-DB core (by design — removing
    /// either would break the agent). `~` is expanded; non-absolute entries are
    /// dropped (the seatbelt does not understand `~`).
    public var extraAllowedPaths: String

    public init(enabled: Bool = false, extraAllowedPaths: String = "") {
        self.enabled = enabled
        self.extraAllowedPaths = extraAllowedPaths
    }

    /// The default config reproduces an OFF (un-sandboxed) run exactly. Used when no
    /// `sandbox-config.json` exists yet.
    public static let `default` = SandboxConfig()

    /// The config's JSON filename inside the App Group container.
    public static let fileName = "sandbox-config.json"

    // MARK: - Persistence

    /// Load from `sandbox-config.json` in `directory`. Missing or corrupt file
    /// degrades to `.default` (sandbox off) rather than throwing — same fresh-install
    /// behavior as `AgentCommandConfig.load` / `ZoteroConfig.load`.
    public static func load(from directory: URL) -> SandboxConfig {
        let url = directory.appendingPathComponent(fileName, isDirectory: false)
        guard let data = try? Data(contentsOf: url) else { return .default }
        guard let config = try? JSONDecoder().decode(SandboxConfig.self, from: data) else {
            DebugLog.config("SandboxConfig: corrupt \(fileName), starting default")
            return .default
        }
        return config
    }

    /// Persist to `sandbox-config.json` in `directory`, atomically, pretty-printed +
    /// sorted keys (matches `WikiRegistry.save`'s reviewable-diff rationale).
    public func save(to directory: URL) throws {
        let url = directory.appendingPathComponent(SandboxConfig.fileName, isDirectory: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Derived values

    /// Parse `extraAllowedPaths` into absolute path strings ready for the seatbelt
    /// profile. Blank lines are skipped; a leading `~` (or `~user`) is expanded via
    /// `AgentCommandConfig.expandTilde`; any entry that is not absolute AFTER
    /// expansion is dropped (the seatbelt needs a concrete absolute path — a `~` it
    /// cannot resolve, or a relative path, is meaningless to it).
    public func parsedExtraAllowedPaths() -> [String] {
        var paths: [String] = []
        for line in extraAllowedPaths.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let expanded = AgentCommandConfig.expandTilde(trimmed)
            // Drop non-absolute entries (relative paths, or unexpanded `~`).
            guard expanded.hasPrefix("/") else { continue }
            paths.append(expanded)
        }
        return paths
    }
}
