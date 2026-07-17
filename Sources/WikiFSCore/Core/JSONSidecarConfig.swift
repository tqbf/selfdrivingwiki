import Foundation

/// A config value type persisted as a single pretty-printed JSON sidecar file
/// in the App Group container (e.g. `zotero-config.json`, `extraction-config.json`,
/// `agent-providers.json`).
///
/// Conformers supply only `fileName` (and whatever type-specific fields they
/// need); the protocol's default implementations provide the load/save
/// boilerplate that was previously copy-pasted across `ZoteroConfig`,
/// `ExtractionConfig`, and `AgentProvidersConfig`.
///
/// Semantics (matching the prior hand-written implementations):
/// - `save(to:)` writes atomically, pretty-printed with sorted keys, so diffs
///   are reviewable and a mid-write crash can't truncate the file.
/// - `load(from:)` returns `nil` for a missing file (fresh install) or a corrupt
///   file (a diagnostic is emitted via `DebugLog.config` on the corrupt path, but
///   the call never throws — callers degrade to a default).
///
/// Types that want non-optional "default-on-missing" loading keep a one-line
/// delegator, e.g. `ZoteroConfig.load(from:) -> ZoteroConfig`.
///
/// Notes:
/// - `WikiRegistry` deliberately does NOT conform here: it uses an ISO-8601 date
///   coding strategy in both load and save, so it can't share the dateless
///   default encoder/decoder without specializing the protocol — out of scope for
///   issue #518.
/// - No secret ever lives in these files (keys go in Keychain); the protocol only
///   handles the secrets-free JSON sidecar.
public protocol JSONSidecarConfig: Codable, Equatable, Sendable {
    /// The JSON filename inside the App Group container, e.g.
    /// `"zotero-config.json"`.
    static var fileName: String { get }
}

public extension JSONSidecarConfig {

    /// Load from `<directory>/<fileName>`. Returns `nil` if the file is missing
    /// (fresh install) or corrupt; on the corrupt path a diagnostic is emitted via
    /// `DebugLog.config`. Never throws — callers degrade to a default.
    static func load(from directory: URL) -> Self? {
        let url = directory.appendingPathComponent(fileName, isDirectory: false)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let config = try? JSONDecoder().decode(Self.self, from: data) else {
            DebugLog.config("\(String(describing: Self.self)): corrupt \(fileName), discarding")
            return nil
        }
        return config
    }

    /// Persist to `<directory>/<fileName>`, atomically, pretty-printed +
    /// sorted keys (matches the prior hand-written `save` implementations'
    /// reviewable-diff rationale). Never writes secrets — only the conforming
    /// value's own `Codable` payload.
    func save(to directory: URL) throws {
        let url = directory.appendingPathComponent(Self.fileName, isDirectory: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
}
