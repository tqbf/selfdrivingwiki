import Cordis
import Foundation

/// Stable identity for one row in an entry list. `EntryID` is the patch/
/// update identity; two entries of one plugin are independently addressable.
public struct EntryID: Hashable, RawRepresentable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public var description: String { rawValue }
}

/// A scalar-or-composite config value that survives YAML round trips and
/// converts to JSON Data for plugin config decoding.
public enum ConfigValue: Equatable, Sendable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case list([ConfigValue])
    case map([String: ConfigValue], order: [String])
}

/// One row of a resolved entry list.
public struct Entry: Equatable, Sendable {
    public var id: EntryID
    public var plugin: PluginID
    public var config: [String: ConfigValue]?
    public var disabled: Bool

    public init(
        id: EntryID,
        plugin: PluginID,
        config: [String: ConfigValue]? = nil,
        disabled: Bool = false
    ) {
        self.id = id
        self.plugin = plugin
        self.config = config
        self.disabled = disabled
    }
}

/// One patch layer: rows to insert or replace by id, and rows to remove.
public struct PatchFile: Equatable, Sendable {
    public var entries: [Entry]
    public var remove: [EntryID]

    public init(entries: [Entry] = [], remove: [EntryID] = []) {
        self.entries = entries
        self.remove = remove
    }
}

/// Applies ordered patch layers to an entry list. Precedence: each layer
/// replaces a row (whole config) by id or inserts new rows; `remove` rows
/// delete by id. Later layers win.
public enum PatchResolver {
    public static func resolve(layers: [PatchFile]) -> [Entry] {
        var rows: [EntryID: Entry] = [:]
        var order: [EntryID] = []
        for layer in layers {
            for entry in layer.entries {
                if rows[entry.id] == nil {
                    order.append(entry.id)
                }
                rows[entry.id] = entry
            }
            for removed in layer.remove {
                if rows.removeValue(forKey: removed) != nil {
                    order.removeAll { $0 == removed }
                }
            }
        }
        return order.compactMap { rows[$0] }
    }
}
