import Cordis
import Foundation
import Yams

/// Natural-shape YAML patch files:
///
/// ```yaml
/// entries:
///   - id: store
///     plugin: wiki.store
///     config:
///       backend: grdb
///       path: /tmp/wiki.sqlite
///     disabled: false
/// remove:
///   - search
/// ```
public enum PatchFileCodec {
    public enum PatchError: Error, Equatable, Sendable {
        case notAMapping
        case missing(String)
        case invalidRow(String)
        case invalidValue(field: String)
    }

    public static func decode(_ yamlText: String) throws -> PatchFile {
        guard let object = try Yams.load(yaml: yamlText) else {
            return PatchFile()
        }
        return try decode(object: object)
    }

    public static func decode(data: Data) throws -> PatchFile {
        guard let text = String(data: data, encoding: .utf8) else {
            throw PatchError.notAMapping
        }
        return try decode(text)
    }

    public static func decode(object: Any) throws -> PatchFile {
        guard let root = object as? [String: Any] else {
            throw PatchError.notAMapping
        }
        var entries: [Entry] = []
        if let rawEntries = root["entries"] {
            guard let entryList = rawEntries as? [[String: Any]] else {
                throw PatchError.invalidRow("entries")
            }
            for (index, raw) in entryList.enumerated() {
                guard let id = raw["id"] as? String,
                      let plugin = raw["plugin"] as? String else {
                    throw PatchError.invalidRow("entries[\(index)]")
                }
                var config: [String: ConfigValue]?
                if let rawConfig = raw["config"] {
                    guard let configMap = rawConfig as? [String: Any] else {
                        throw PatchError.invalidValue(field: "entries[\(index)].config")
                    }
                    config = try configMap.mapValues { try configValue(from: $0, field: "config") }
                }
                entries.append(Entry(
                    id: EntryID(id),
                    plugin: PluginID(plugin),
                    config: config,
                    disabled: raw["disabled"] as? Bool ?? false))
            }
        }
        var remove: [EntryID] = []
        if let rawRemove = root["remove"] {
            guard let removeList = rawRemove as? [String] else {
                throw PatchError.invalidRow("remove")
            }
            remove = removeList.map { EntryID($0) }
        }
        return PatchFile(entries: entries, remove: remove)
    }

    public static func encode(_ patch: PatchFile) throws -> String {
        var root: [String: Any] = [:]
        if !patch.entries.isEmpty {
            root["entries"] = patch.entries.map { entry in
                var row: [String: Any] = [
                    "id": entry.id.rawValue,
                    "plugin": entry.plugin.rawValue,
                ]
                if let config = entry.config {
                    row["config"] = config.mapValues(plainValue)
                }
                if entry.disabled {
                    row["disabled"] = true
                }
                return row
            }
        }
        if !patch.remove.isEmpty {
            root["remove"] = patch.remove.map(\.rawValue)
        }
        return try Yams.dump(object: root, indent: 2, allowUnicode: true)
    }

    private static func configValue(from object: Any, field: String) throws -> ConfigValue {
        switch object {
        case let value as String:
            return .string(value)
        case let value as Bool:
            return .bool(value)
        case let value as Int:
            return .int(Int64(value))
        case let value as Int64:
            return .int(value)
        case let value as Double:
            return .double(value)
        case let value as [Any]:
            return .list(try value.map { try configValue(from: $0, field: field) })
        case let value as [String: Any]:
            var map: [String: ConfigValue] = [:]
            var order: [String] = []
            for (key, inner) in value.sorted(by: { $0.key < $1.key }) {
                map[key] = try configValue(from: inner, field: field)
                order.append(key)
            }
            return .map(map, order: order)
        default:
            throw PatchError.invalidValue(field: field)
        }
    }

    private static func plainValue(_ value: ConfigValue) -> Any {
        switch value {
        case .string(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .bool(let value): return value
        case .list(let values): return values.map(plainValue)
        case .map(let map, let order):
            var result: [String: Any] = [:]
            for key in order {
                result[key] = plainValue(map[key] ?? .string(""))
            }
            return result
        }
    }
}
