import Foundation

/// Stable identity for one plugin in the catalog. Unlike `ComponentID`
/// (runtime instance) or `EntryID` (loader row), the plugin id is the
/// link-time identity a patch file references.
public struct PluginID: Hashable, RawRepresentable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public var description: String { rawValue }
}

/// One structured validation problem with a config value.
public struct ConfigIssue: Hashable, Sendable, CustomStringConvertible {
    public let field: String
    public let message: String

    public init(field: String, message: String) {
        self.field = field
        self.message = message
    }

    public var description: String { "\(field): \(message)" }
}

/// A plugin's declared config schema: a Swift value type plus a validator.
/// Validation runs at mount; boot fails with structured issues instead of
/// silently defaulting.
public protocol PluginConfig: Sendable, Decodable {
    static func validate(_ config: Self) -> [ConfigIssue]
}

extension PluginConfig {
    public static func validate(_ config: Self) -> [ConfigIssue] {
        []
    }
}

/// A declarative validation builder: collect field-level checks with
/// messages, in declaration order.
public struct ConfigValidation: Sendable {
    private var issues: [ConfigIssue] = []

    public init() {}

    public mutating func check(
        _ field: String,
        _ condition: @autoclosure @escaping () -> Bool,
        _ message: String
    ) {
        if !condition() {
            issues.append(ConfigIssue(field: field, message: message))
        }
    }

    public var allIssues: [ConfigIssue] {
        issues
    }
}

/// A dormant plugin declaration: what the plugin provides and requires, its
/// optional config schema, and the factory that turns a validated config
/// into a `ComponentDefinition`.
public struct PluginDefinition: Sendable {
    public typealias Factory = @Sendable (_ config: (any Sendable)?) throws -> ComponentDefinition

    public let id: PluginID
    public let label: String
    public let dependencies: [ServiceDependency]
    public let provisions: [ServiceDependency]

    private let configDecode: (@Sendable (Data) throws -> any Sendable)?
    private let configValidate: (@Sendable (any Sendable) -> [ConfigIssue])?
    private let factory: Factory

    private init(
        id: PluginID,
        label: String,
        dependencies: [ServiceDependency],
        provisions: [ServiceDependency],
        configDecode: (@Sendable (Data) throws -> any Sendable)?,
        configValidate: (@Sendable (any Sendable) -> [ConfigIssue])?,
        factory: @escaping Factory
    ) {
        self.id = id
        self.label = label
        self.dependencies = dependencies
        self.provisions = provisions
        self.configDecode = configDecode
        self.configValidate = configValidate
        self.factory = factory
    }

    /// A plugin with no config surface.
    public init(
        id: PluginID,
        label: String? = nil,
        dependencies: [ServiceDependency] = [],
        provisions: [ServiceDependency] = [],
        makeDefinition: @escaping @Sendable () throws -> ComponentDefinition
    ) {
        self.init(
            id: id,
            label: label ?? id.rawValue,
            dependencies: dependencies,
            provisions: provisions,
            configDecode: nil,
            configValidate: nil,
            factory: { _ in try makeDefinition() })
    }

    /// A plugin with a typed config schema. The config decodes from JSON
    /// (the loader converts YAML rows before this point) and validates at
    /// mount; boot fails with structured issues on failure.
    public init<C: PluginConfig>(
        id: PluginID,
        label: String? = nil,
        dependencies: [ServiceDependency] = [],
        provisions: [ServiceDependency] = [],
        config: C.Type,
        makeDefinition: @escaping @Sendable (_ config: C) throws -> ComponentDefinition
    ) {
        self.init(
            id: id,
            label: label ?? id.rawValue,
            dependencies: dependencies,
            provisions: provisions,
            configDecode: { data in
                try JSONDecoder().decode(C.self, from: data)
            },
            configValidate: { box in
                guard let typed = box as? C else { return [] }
                return C.validate(typed)
            },
            factory: { box in
                guard let typed = box as? C else {
                    throw CordisError.invalidConfig(
                        pluginID: id,
                        entryID: nil,
                        issues: [ConfigIssue(
                            field: "$",
                            message: "config was not validated as \(String(reflecting: C.self))")])
                }
                return try makeDefinition(typed)
            })
    }

    /// Decodes raw JSON config data with this plugin's schema.
    public func decodeConfig(_ data: Data) throws -> any Sendable {
        guard let configDecode else {
            throw CordisError.invalidConfig(
                pluginID: id,
                entryID: nil,
                issues: [ConfigIssue(field: "$", message: "plugin declares no config schema")])
        }
        return try configDecode(data)
    }

    /// Validates a decoded config value against this plugin's schema.
    public func validateConfig(_ value: any Sendable) -> [ConfigIssue] {
        configValidate?(value) ?? []
    }

    /// Builds the component definition from a validated config value.
    public func makeDefinition(config: (any Sendable)?) throws -> ComponentDefinition {
        try factory(config)
    }

    public var hasConfigSchema: Bool {
        configDecode != nil
    }
}

/// The link-time plugin catalog: plugin id → definition. Populated by each
/// SwiftPM target's static plugin list; there is no dynamic loading in v1.
public struct PluginCatalog: Sendable {
    private let definitions: [PluginID: PluginDefinition]

    public init(_ definitions: [PluginDefinition]) throws {
        var map: [PluginID: PluginDefinition] = [:]
        for definition in definitions {
            guard map[definition.id] == nil else {
                throw CordisError.duplicatePlugin(definition.id)
            }
            map[definition.id] = definition
        }
        self.definitions = map
    }

    public func definition(for id: PluginID) -> PluginDefinition? {
        definitions[id]
    }

    public var ids: [PluginID] {
        definitions.keys.sorted { $0.rawValue < $1.rawValue }
    }
}
