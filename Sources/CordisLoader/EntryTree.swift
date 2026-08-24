import Cordis
import Foundation
import Yams

public enum CordisLoaderError: Error, Equatable, Sendable {
    case missingPlugin(pluginID: PluginID, entryID: EntryID)
    case invalidEntry(entryID: EntryID, reason: String)
    case entryFailed(entryID: EntryID, label: String, failure: CordisFailure)
    case configDecodingFailed(entryID: EntryID, problem: String)
}

extension ConfigValue {
    /// JSON object view for plugin schema decoding.
    public func plain() -> Any {
        switch self {
        case .string(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .bool(let value): return value
        case .list(let values): return values.map { $0.plain() }
        case .map(let map, let order):
            var result: [String: Any] = [:]
            for key in order {
                result[key] = (map[key] ?? .string("")).plain()
            }
            return result
        }
    }
}

/// Mounts, updates, and removes entries on a live context. Diffing is by
/// `EntryID`: a changed row (whole config) is disposed and re-registered.
public actor EntryTree {
    private let context: CordisContext
    private let catalog: PluginCatalog
    private var mounted: [EntryID: ComponentHandle] = [:]
    private var rows: [Entry] = []

    public init(context: CordisContext, catalog: PluginCatalog) {
        self.context = context
        self.catalog = catalog
    }

    public func update(to newRows: [Entry]) async throws {
        var nextMounted = mounted
        let newRowIDs = Set(newRows.filter { !$0.disabled }.map(\.id))

        // Removals first (LIFO over the removed set), then adds and changes.
        for (entryID, handle) in mounted where !newRowIDs.contains(entryID) {
            try await handle.dispose()
            nextMounted.removeValue(forKey: entryID)
        }

        for row in newRows where !row.disabled {
            if nextMounted[row.id] != nil, row == currentRow(row.id) {
                continue
            }
            if let existing = nextMounted[row.id] {
                try await existing.dispose()
                nextMounted.removeValue(forKey: row.id)
            }
            let handle = try await mount(row)
            nextMounted[row.id] = handle
        }

        mounted = nextMounted
        rows = newRows
    }

    private func currentRow(_ id: EntryID) -> Entry? {
        rows.first { $0.id == id }
    }

    private func mount(_ row: Entry) async throws -> ComponentHandle {
        guard let plugin = catalog.definition(for: row.plugin) else {
            throw CordisLoaderError.missingPlugin(pluginID: row.plugin, entryID: row.id)
        }
        let config: (any Sendable)?
        if plugin.hasConfigSchema {
            let plain: Any
            if let rowConfig = row.config {
                plain = rowConfig.mapValues { $0.plain() }
            } else {
                plain = [String: Any]()
            }
            let data: Data
            do {
                data = try JSONSerialization.data(withJSONObject: plain, options: [.sortedKeys])
            } catch {
                throw CordisLoaderError.configDecodingFailed(
                    entryID: row.id,
                    problem: CordisFailure(error).message)
            }
            let decoded: any Sendable
            do {
                decoded = try plugin.decodeConfig(data)
            } catch {
                let issues: [ConfigIssue]
                if let decoding = error as? DecodingError {
                    issues = [ConfigIssue(field: "$", message: decodingDescription(decoding))]
                } else {
                    issues = [ConfigIssue(field: "$", message: CordisFailure(error).message)]
                }
                throw CordisError.invalidConfig(
                    pluginID: row.plugin,
                    entryID: row.id.rawValue,
                    issues: issues)
            }
            let validationIssues = plugin.validateConfig(decoded)
            if !validationIssues.isEmpty {
                throw CordisError.invalidConfig(
                    pluginID: row.plugin,
                    entryID: row.id.rawValue,
                    issues: validationIssues)
            }
            config = decoded
        } else {
            if row.config != nil {
                throw CordisError.invalidConfig(
                    pluginID: row.plugin,
                    entryID: row.id.rawValue,
                    issues: [ConfigIssue(
                        field: "$",
                        message: "plugin declares no config schema but the entry carries config")])
            }
            config = nil
        }

        let definition: ComponentDefinition
        do {
            definition = try plugin.makeDefinition(config: config)
        } catch let error as CordisError {
            if case .invalidConfig(let pluginID, _, let issues) = error {
                throw CordisError.invalidConfig(pluginID: pluginID, entryID: row.id.rawValue, issues: issues)
            }
            throw error
        }
        let handle = try await context.register(definition)
        let state = try await handle.awaitSettled()
        guard state.kind == .active else {
            if case .failed(_, let failure) = state {
                throw CordisLoaderError.entryFailed(entryID: row.id, label: definition.label, failure: failure)
            }
            throw CordisLoaderError.entryFailed(
                entryID: row.id,
                label: definition.label,
                failure: CordisFailure("entry settled as \(state.kind)"))
        }
        return handle
    }

    public var mountedEntryIDs: [EntryID] {
        mounted.keys.sorted { $0.rawValue < $1.rawValue }
    }

    public func resolvedRows() -> [Entry] {
        rows
    }

    /// The resolved entry tree as YAML — the `--dump-config` contract.
    public func dumpConfig() throws -> String {
        try PatchFileCodec.encode(PatchFile(entries: rows, remove: []))
    }

    public func dispose() async throws {
        for (entryID, handle) in mounted.sorted(by: { $0.key.rawValue > $1.key.rawValue }) {
            try await handle.dispose()
            _ = entryID
        }
        mounted.removeAll()
        rows = []
    }

    private func decodingDescription(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let context):
            "missing key \(key.stringValue) at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case .typeMismatch(_, let context):
            "type mismatch at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case .valueNotFound(_, let context):
            "missing value at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case .dataCorrupted(let context):
            "corrupted data at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        @unknown default:
            String(describing: error)
        }
    }
}

/// Boots a profile: root context, ambient facts, resolved entry tree,
/// activation, diagnostics.
public enum CordisBoot {
    public struct Options: Sendable {
        public var catalog: PluginCatalog
        public var layers: [PatchFile]
        /// Supplies ambient facts (home path, app group id, wiki id) on the
        /// root context before entries mount.
        public var configure: (@Sendable (CordisContext) async throws -> Void)?

        public init(
            catalog: PluginCatalog,
            layers: [PatchFile],
            configure: (@Sendable (CordisContext) async throws -> Void)? = nil
        ) {
            self.catalog = catalog
            self.layers = layers
            self.configure = configure
        }
    }

    public static func boot(_ options: Options) async throws -> BootedProfile {
        let context = CordisContext()
        if let configure = options.configure {
            try await configure(context)
        }
        let resolved = PatchResolver.resolve(layers: options.layers)
        let tree = EntryTree(context: context, catalog: options.catalog)
        try await tree.update(to: resolved)
        return BootedProfile(context: context, tree: tree)
    }
}

public struct BootedProfile: Sendable {
    public let context: CordisContext
    public let tree: EntryTree

    public func dumpConfig() async throws -> String {
        try await tree.dumpConfig()
    }

    public func shutdown() async throws {
        try await tree.dispose()
        try await context.dispose()
    }
}
