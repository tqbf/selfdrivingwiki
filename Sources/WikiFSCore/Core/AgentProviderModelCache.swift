import Foundation

/// The implementation name reported by ACP `InitializeResponse.agentInfo`.
/// This is process identity, not provider routing state or a display label.
public struct ACPAgentIdentity: Codable, Hashable, Sendable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
}

/// The implementation version reported by ACP. Versions are opaque unless a
/// compatibility rule explicitly declares semantic-version matching.
public struct ACPAgentVersion: Codable, Hashable, Sendable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
}

/// Identity of the ACP implementation that produced a catalog observation.
/// `title` is diagnostic-only and must never participate in capability matching.
public struct ACPAgentFingerprint: Codable, Hashable, Sendable {
    public let identity: ACPAgentIdentity
    public let version: ACPAgentVersion?
    public let title: String?

    public init(identity: ACPAgentIdentity, version: ACPAgentVersion?, title: String? = nil) {
        self.identity = identity
        self.version = version
        self.title = title
    }
}

/// A resolved, secrets-free ACP process invocation used only for trusted
/// compatibility matching. `argv[0]` must be an absolute canonical path.
public struct ACPAgentCommandFingerprint: Hashable, Sendable {
    public let canonicalExecutableURL: URL
    public let arguments: [String]

    public init?(resolvedCommand: [String]) {
        guard let executable = resolvedCommand.first, executable.hasPrefix("/") else { return nil }
        let standardized = URL(fileURLWithPath: executable).standardizedFileURL
        guard standardized.path == executable else { return nil }
        canonicalExecutableURL = standardized
        arguments = Array(resolvedCommand.dropFirst())
    }

    /// Returns a fingerprint only when the complete ordered configured argv
    /// equals an immutable catalog command after both executables resolve.
    public static func trustedMatch(
        configuredCommand: [String]?,
        catalogCommand: [String],
        resolve: ([String]) -> [String]?
    ) -> Self? {
        guard let configuredCommand,
              configuredCommand.count == catalogCommand.count,
              Array(configuredCommand.dropFirst()) == Array(catalogCommand.dropFirst()),
              let configuredResolved = resolve(configuredCommand),
              let catalogResolved = resolve(catalogCommand),
              let configuredFingerprint = Self(resolvedCommand: configuredResolved),
              let catalogFingerprint = Self(resolvedCommand: catalogResolved),
              configuredFingerprint == catalogFingerprint else { return nil }
        return configuredFingerprint
    }
}

public struct ThinkingCapabilityAdapterID: Codable, Hashable, Sendable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct ThinkingCapabilityOverrideID: Codable, Hashable, Sendable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// Explicit version matching for compatibility metadata. Opaque versions can
/// match only exactly. Semantic ranges are bounded on both sides.
public enum ACPAgentVersionPredicate: Codable, Hashable, Sendable {
    case exact(ACPAgentVersion)
    case semanticRange(lowerInclusive: ACPAgentVersion, upperExclusive: ACPAgentVersion)

    public func contains(_ version: ACPAgentVersion?) -> Bool {
        guard let version else { return false }
        switch self {
        case .exact(let expected):
            return version == expected
        case .semanticRange(let lower, let upper):
            guard let value = SemanticAgentVersion(version.rawValue),
                  let minimum = SemanticAgentVersion(lower.rawValue),
                  let maximum = SemanticAgentVersion(upper.rawValue),
                  minimum < maximum else { return false }
            return value >= minimum && value < maximum
        }
    }
}

private struct SemanticAgentVersion: Comparable {
    let components: [Int]

    init?(_ rawValue: String) {
        let core = rawValue.split(separator: "+", maxSplits: 1).first?
            .split(separator: "-", maxSplits: 1).first ?? Substring(rawValue)
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        let parsed = parts.compactMap { Int($0) }
        guard parsed.count == parts.count else { return nil }
        components = parsed + Array(repeating: 0, count: 3 - parts.count)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

/// How a selectable thinking value is applied and confirmed.
public enum ThinkingCapabilityMechanism: Codable, Hashable, Sendable {
    case sessionConfig(optionID: ChatConfigurationOptionID)
    case modelVariants(valueToModelID: [ChatConfigurationValueID: ModelID])

    public var configOptionID: ChatConfigurationOptionID? {
        guard case .sessionConfig(let optionID) = self else { return nil }
        return optionID
    }

    public func modelID(for valueID: ChatConfigurationValueID) -> ModelID? {
        guard case .modelVariants(let mapping) = self else { return nil }
        return mapping[valueID]
    }
}

/// Evidence source that established a normalized capability.
public enum ThinkingCapabilitySource: Codable, Hashable, Sendable {
    case observedACP
    case agentAdapter(adapterID: ThinkingCapabilityAdapterID)
    case localOverride(overrideID: ThinkingCapabilityOverrideID)
}

/// One selectable thinking value advertised by an agent for a model.
public struct ThinkingOptionCatalogChoice: Codable, Hashable, Sendable, Identifiable {
    public let id: ChatConfigurationValueID
    public let label: String

    public init(id: ChatConfigurationValueID, label: String) {
        self.id = id
        self.label = label
    }
}

/// Durable, secrets-free thinking capability for one cached model.
///
/// The exact ACP option id is retained because agents may identify thinking by
/// category while advertising a non-literal option id. Choice order is the
/// agent's advertised order. Runtime session metadata may overlay the current
/// value, but it does not own capability discovery.
public struct ThinkingOptionCatalog: Codable, Hashable, Sendable {
    public let configOptionID: ChatConfigurationOptionID
    public let choices: [ThinkingOptionCatalogChoice]
    public let defaultValueID: ChatConfigurationValueID?

    public init(
        configOptionID: ChatConfigurationOptionID,
        choices: [ThinkingOptionCatalogChoice],
        defaultValueID: ChatConfigurationValueID? = nil
    ) {
        self.configOptionID = configOptionID
        self.choices = choices
        self.defaultValueID = defaultValueID
    }

    public func contains(_ valueID: ChatConfigurationValueID?) -> Bool {
        guard let valueID else { return false }
        return choices.contains { $0.id == valueID }
    }
}

/// Normalized, evidence-backed capability consumed by every lifecycle path.
public struct ThinkingCapabilityCatalog: Codable, Hashable, Sendable {
    public let choices: [ThinkingOptionCatalogChoice]
    public let defaultValueID: ChatConfigurationValueID?
    public let mechanism: ThinkingCapabilityMechanism
    public let source: ThinkingCapabilitySource
    public let fingerprint: ACPAgentFingerprint?
    public let modelID: ModelID?
    /// Aliases that presentation code may remove from a model-name suffix.
    public let displayAliases: [String]
    /// False for startup-only or externally configured effort that cannot be
    /// applied and confirmed through this runtime.
    public let isSelectable: Bool

    public init(
        choices: [ThinkingOptionCatalogChoice],
        defaultValueID: ChatConfigurationValueID? = nil,
        mechanism: ThinkingCapabilityMechanism,
        source: ThinkingCapabilitySource,
        fingerprint: ACPAgentFingerprint? = nil,
        modelID: ModelID? = nil,
        displayAliases: [String] = [],
        isSelectable: Bool = true
    ) {
        self.choices = choices
        self.defaultValueID = defaultValueID
        self.mechanism = mechanism
        self.source = source
        self.fingerprint = fingerprint
        self.modelID = modelID
        self.displayAliases = displayAliases
        self.isSelectable = isSelectable
    }

    public func contains(_ valueID: ChatConfigurationValueID?) -> Bool {
        guard let valueID else { return false }
        return choices.contains { $0.id == valueID }
    }

    public static func observedACP(_ legacy: ThinkingOptionCatalog) -> Self {
        ThinkingCapabilityCatalog(
            choices: legacy.choices,
            defaultValueID: legacy.defaultValueID,
            mechanism: .sessionConfig(optionID: legacy.configOptionID),
            source: .observedACP,
            displayAliases: legacy.choices.flatMap { [$0.id.rawValue, $0.label] })
    }
}

/// Pure policy result shared by draft, restored, idle, live, and daemon paths.
public struct ThinkingSelectionResolution: Hashable, Sendable {
    public let capability: ThinkingCapabilityCatalog?
    public let configuredValueID: ChatConfigurationValueID?
    public let effectiveValueID: ChatConfigurationValueID?
    public let priorEffectiveValueID: ChatConfigurationValueID?
    public let diagnostic: String?

    public var choices: [ThinkingOptionCatalogChoice] { capability?.choices ?? [] }
    public var mechanism: ThinkingCapabilityMechanism? { capability?.mechanism }
    public var source: ThinkingCapabilitySource? { capability?.source }
    public var configOptionID: ChatConfigurationOptionID? { mechanism?.configOptionID }
    public var modelIDByValueID: [ChatConfigurationValueID: ModelID] {
        guard case .modelVariants(let mapping) = mechanism else { return [:] }
        return mapping
    }
    public var shouldRenderSelector: Bool {
        capability?.isSelectable == true && !choices.isEmpty && effectiveValueID != nil
    }
    public var isUsingFallback: Bool {
        guard let configuredValueID else { return false }
        return configuredValueID != effectiveValueID
    }

    /// Compatibility projection while older call sites migrate to `capability`.
    public var catalog: ThinkingOptionCatalog? {
        guard let capability,
              case .sessionConfig(let optionID) = capability.mechanism else { return nil }
        return ThinkingOptionCatalog(
            configOptionID: optionID,
            choices: capability.choices,
            defaultValueID: capability.defaultValueID)
    }

    public init(
        capability: ThinkingCapabilityCatalog?,
        configuredValueID: ChatConfigurationValueID?,
        effectiveValueID: ChatConfigurationValueID?,
        priorEffectiveValueID: ChatConfigurationValueID? = nil,
        diagnostic: String? = nil
    ) {
        self.capability = capability
        self.configuredValueID = configuredValueID
        self.effectiveValueID = effectiveValueID
        self.priorEffectiveValueID = priorEffectiveValueID
        self.diagnostic = diagnostic
    }

    public init(
        catalog: ThinkingOptionCatalog?,
        configuredValueID: ChatConfigurationValueID?,
        effectiveValueID: ChatConfigurationValueID?
    ) {
        self.init(
            capability: catalog.map(ThinkingCapabilityCatalog.observedACP),
            configuredValueID: configuredValueID,
            effectiveValueID: effectiveValueID)
    }
}

public struct ThinkingModelVariantFamily: Hashable, Sendable {
    public let baseModelID: String
    public let choices: [ThinkingOptionCatalogChoice]
    public let modelIDByValueID: [ChatConfigurationValueID: ModelID]

    public func modelID(for valueID: ChatConfigurationValueID) -> ModelID? {
        modelIDByValueID[valueID]
    }
}

/// Adapter-private syntax parser for the supported Codex ACP implementation.
/// Bracket syntax is not a general capability-discovery convention.
public enum CodexThinkingModelVariantParser {
    /// Builds a family only from provider-advertised model IDs shaped as
    /// `base[value]`. At least two variants must share a base. Display-name
    /// suffixes never define legal choices.
    public static func family(
        containing selectedModelID: ModelID?,
        models: [CachedModelInfo]
    ) -> ThinkingModelVariantFamily? {
        guard let selectedModelID,
              let selected = split(selectedModelID) else { return nil }
        let variants = models.compactMap { model -> (ChatConfigurationValueID, ModelID)? in
            guard let parsed = split(model.modelId), parsed.base == selected.base else { return nil }
            return (parsed.valueID, model.modelId)
        }
        guard variants.count >= 2,
              Set(variants.map(\.0)).count == variants.count,
              Set(variants.map(\.1)).count == variants.count else { return nil }
        return ThinkingModelVariantFamily(
            baseModelID: selected.base,
            choices: variants.map {
                ThinkingOptionCatalogChoice(id: $0.0, label: displayLabel(for: $0.0))
            },
            modelIDByValueID: Dictionary(uniqueKeysWithValues: variants))
    }

    public static func split(_ modelID: ModelID) -> (base: String, valueID: ChatConfigurationValueID)? {
        let raw = modelID.rawValue
        guard raw.last == "]", let open = raw.lastIndex(of: "[") else { return nil }
        let base = String(raw[..<open])
        let value = raw[raw.index(after: open)..<raw.index(before: raw.endIndex)]
        guard !base.isEmpty, !value.isEmpty else { return nil }
        return (base, ChatConfigurationValueID(rawValue: String(value)))
    }

    private static func displayLabel(for valueID: ChatConfigurationValueID) -> String {
        let raw = valueID.rawValue
        if raw.lowercased() == "xhigh" { return "Extra High" }
        return raw.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }
}

/// Explicit Codex adapter. It requires the ACP-reported identity and a supported
/// version before interpreting Codex's final `base[value]` model-ID convention.
public enum CodexThinkingCapabilityAdapter {
    public static let adapterID = ThinkingCapabilityAdapterID(rawValue: "codex-model-variants-v1")
    public static let identity = ACPAgentIdentity(rawValue: "@agentclientprotocol/codex-acp")
    public static let supportedVersions = ACPAgentVersionPredicate.semanticRange(
        lowerInclusive: ACPAgentVersion(rawValue: "0.1.0"),
        upperExclusive: ACPAgentVersion(rawValue: "2.0.0"))

    /// Immutable commands that prior app versions stored before catalog
    /// observations included ACP `agentInfo`. Each command pins the package
    /// version that supplies the matching compatibility fingerprint.
    public static let trustedLegacyCommands: [([String], ACPAgentFingerprint)] = [
        (
            ["npx", "@agentclientprotocol/codex-acp@1.1.7"],
            ACPAgentFingerprint(
                identity: identity,
                version: ACPAgentVersion(rawValue: "1.1.7"),
                title: "Codex"))
    ]

    /// Returns compatibility identity only when the complete configured argv
    /// equals an immutable command that a prior app version stored.
    public static func trustedLegacyFingerprint(
        configuredCommand: [String]?
    ) -> ACPAgentFingerprint? {
        trustedLegacyCommands.first { command, _ in
            configuredCommand == command
        }?.1
    }

    public static func resolve(
        fingerprint: ACPAgentFingerprint?,
        selectedModelID: ModelID?,
        models: [CachedModelInfo]
    ) -> ThinkingCapabilityCatalog? {
        guard let fingerprint,
              fingerprint.identity == identity,
              supportedVersions.contains(fingerprint.version),
              let selectedModelID,
              let family = CodexThinkingModelVariantParser.family(
                containing: selectedModelID, models: models) else { return nil }
        return ThinkingCapabilityCatalog(
            choices: family.choices,
            defaultValueID: CodexThinkingModelVariantParser.split(selectedModelID)?.valueID,
            mechanism: .modelVariants(valueToModelID: family.modelIDByValueID),
            source: .agentAdapter(adapterID: adapterID),
            fingerprint: fingerprint,
            modelID: selectedModelID,
            displayAliases: family.choices.flatMap { [$0.id.rawValue, $0.label] })
    }
}

public struct LocalThinkingCapabilityOverride: Codable, Hashable, Sendable, Identifiable {
    public let id: ThinkingCapabilityOverrideID
    public let identity: ACPAgentIdentity
    public let version: ACPAgentVersionPredicate
    public let modelIDs: Set<ModelID>
    public let capability: ThinkingCapabilityCatalog

    public init(
        id: ThinkingCapabilityOverrideID,
        identity: ACPAgentIdentity,
        version: ACPAgentVersionPredicate,
        modelIDs: Set<ModelID>,
        capability: ThinkingCapabilityCatalog
    ) {
        self.id = id
        self.identity = identity
        self.version = version
        self.modelIDs = modelIDs
        self.capability = capability
    }
}

public struct LocalThinkingCapabilityRegistry: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let entries: [LocalThinkingCapabilityOverride]

    public init(schemaVersion: Int = 1, entries: [LocalThinkingCapabilityOverride]) throws {
        guard schemaVersion == 1 else { throw LocalThinkingCapabilityRegistryError.unsupportedSchema }
        var ids: Set<ThinkingCapabilityOverrideID> = []
        for entry in entries {
            guard ids.insert(entry.id).inserted else {
                throw LocalThinkingCapabilityRegistryError.duplicateID(entry.id)
            }
            guard !entry.identity.rawValue.isEmpty,
                  !entry.modelIDs.isEmpty,
                  !entry.capability.choices.isEmpty,
                  entry.capability.source == .localOverride(overrideID: entry.id) else {
                throw LocalThinkingCapabilityRegistryError.malformedEntry(entry.id)
            }
        }
        for (index, lhs) in entries.enumerated() {
            for rhs in entries.dropFirst(index + 1)
            where lhs.identity == rhs.identity && !lhs.modelIDs.isDisjoint(with: rhs.modelIDs) {
                throw LocalThinkingCapabilityRegistryError.overlappingEntries(lhs.id, rhs.id)
            }
        }
        self.schemaVersion = schemaVersion
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, entries }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            entries: container.decode([LocalThinkingCapabilityOverride].self, forKey: .entries))
    }

    public static let bundled: LocalThinkingCapabilityRegistry = {
        do { return try LocalThinkingCapabilityRegistry(entries: []) }
        catch { preconditionFailure("The bundled thinking override registry is invalid.") }
    }()

    public func resolve(
        fingerprint: ACPAgentFingerprint?, modelID: ModelID?
    ) -> ThinkingCapabilityCatalog? {
        guard let fingerprint, let modelID else { return nil }
        return entries.first {
            $0.identity == fingerprint.identity
                && $0.version.contains(fingerprint.version)
                && $0.modelIDs.contains(modelID)
        }?.capability
    }
}

public enum LocalThinkingCapabilityRegistryError: Error, Equatable, Sendable {
    case unsupportedSchema
    case duplicateID(ThinkingCapabilityOverrideID)
    case malformedEntry(ThinkingCapabilityOverrideID)
    case overlappingEntries(ThinkingCapabilityOverrideID, ThinkingCapabilityOverrideID)
}

/// Pure source-priority resolver. A selected source is a complete capability;
/// lower-priority choices are never merged into it.
public enum ThinkingCapabilityResolver {
    public struct Input: Hashable, Sendable {
        public let selectedProviderID: ProviderID
        public let selectedModelID: ModelID?
        public let liveACP: ThinkingCapabilityCatalog?
        public let liveCurrentValueID: ChatConfigurationValueID?
        public let cachedObservation: ACPProviderCatalogObservation?
        public let adapter: ThinkingCapabilityCatalog?
        public let localOverride: ThinkingCapabilityCatalog?
        public let configuredValueID: ChatConfigurationValueID?
        public let priorEffectiveValueID: ChatConfigurationValueID?

        public init(
            selectedProviderID: ProviderID,
            selectedModelID: ModelID?,
            liveACP: ThinkingCapabilityCatalog? = nil,
            liveCurrentValueID: ChatConfigurationValueID? = nil,
            cachedObservation: ACPProviderCatalogObservation? = nil,
            adapter: ThinkingCapabilityCatalog? = nil,
            localOverride: ThinkingCapabilityCatalog? = nil,
            configuredValueID: ChatConfigurationValueID? = nil,
            priorEffectiveValueID: ChatConfigurationValueID? = nil
        ) {
            self.selectedProviderID = selectedProviderID
            self.selectedModelID = selectedModelID
            self.liveACP = liveACP
            self.liveCurrentValueID = liveCurrentValueID
            self.cachedObservation = cachedObservation
            self.adapter = adapter
            self.localOverride = localOverride
            self.configuredValueID = configuredValueID
            self.priorEffectiveValueID = priorEffectiveValueID
        }
    }

    public static func resolve(_ input: Input) -> ThinkingSelectionResolution {
        let capability = applicableLive(input.liveACP)
            ?? applicableCached(input.cachedObservation, providerID: input.selectedProviderID, modelID: input.selectedModelID)
            ?? applicableNonstandard(input.adapter, observation: input.cachedObservation, modelID: input.selectedModelID)
            ?? applicableNonstandard(input.localOverride, observation: input.cachedObservation, modelID: input.selectedModelID)
        guard let capability else {
            return ThinkingSelectionResolution(
                capability: nil,
                configuredValueID: input.configuredValueID,
                effectiveValueID: input.priorEffectiveValueID,
                priorEffectiveValueID: input.priorEffectiveValueID,
                diagnostic: "No trusted thinking capability is applicable.")
        }
        let effective: ChatConfigurationValueID?
        if capability.contains(input.liveCurrentValueID), capability.source == .observedACP {
            effective = input.liveCurrentValueID
        } else if capability.contains(input.configuredValueID) {
            effective = input.configuredValueID
        } else if capability.contains(capability.defaultValueID) {
            effective = capability.defaultValueID
        } else {
            effective = capability.choices.first?.id
        }
        return ThinkingSelectionResolution(
            capability: capability,
            configuredValueID: input.configuredValueID,
            effectiveValueID: effective,
            priorEffectiveValueID: input.priorEffectiveValueID,
            diagnostic: input.configuredValueID != nil && input.configuredValueID != effective
                ? "The configured thinking value is unavailable; a supported fallback is active."
                : nil)
    }

    private static func applicableLive(_ capability: ThinkingCapabilityCatalog?) -> ThinkingCapabilityCatalog? {
        guard let capability,
              capability.source == .observedACP,
              capability.isSelectable,
              !capability.choices.isEmpty,
              case .sessionConfig = capability.mechanism else { return nil }
        return capability
    }

    private static func applicableCached(
        _ observation: ACPProviderCatalogObservation?,
        providerID: ProviderID,
        modelID: ModelID?
    ) -> ThinkingCapabilityCatalog? {
        guard let observation,
              observation.providerID == providerID,
              observation.currentModelID == modelID,
              observation.models.contains(where: { $0.modelId == modelID }),
              let capability = observation.thinkingCapability,
              capability.source == .observedACP else { return nil }
        return applicableLive(capability)
    }

    private static func applicableNonstandard(
        _ capability: ThinkingCapabilityCatalog?,
        observation: ACPProviderCatalogObservation?,
        modelID: ModelID?
    ) -> ThinkingCapabilityCatalog? {
        guard let capability,
              capability.source != .observedACP,
              capability.isSelectable,
              !capability.choices.isEmpty,
              let capabilityFingerprint = capability.fingerprint,
              let observedFingerprint = observation?.fingerprint,
              capabilityFingerprint == observedFingerprint,
              capability.modelID == modelID else { return nil }
        switch capability.mechanism {
        case .sessionConfig:
            return capability
        case .modelVariants(let mapping):
            guard Set(mapping.keys).count == mapping.count,
                  Set(mapping.values).count == mapping.count,
                  mapping.values.contains(where: { $0 == modelID }) else { return nil }
            return capability
        }
    }
}

/// A complete successful ACP catalog observation for one configured provider.
/// Legacy sidecars may have only `providerModels`; in that case callers create
/// an observation with an unknown fingerprint and observed ACP catalogs copied
/// from those models.
public struct ACPProviderCatalogObservation: Codable, Hashable, Sendable {
    public let providerID: ProviderID
    public let fingerprint: ACPAgentFingerprint?
    public let models: [CachedModelInfo]
    public let currentModelID: ModelID?
    public let thinkingCapability: ThinkingCapabilityCatalog?
    public let observedAt: Date

    public init(
        providerID: ProviderID,
        fingerprint: ACPAgentFingerprint?,
        models: [CachedModelInfo],
        currentModelID: ModelID?,
        thinkingCapability: ThinkingCapabilityCatalog?,
        observedAt: Date = Date()
    ) {
        self.providerID = providerID
        self.fingerprint = fingerprint
        self.models = models
        self.currentModelID = currentModelID
        self.thinkingCapability = thinkingCapability
        self.observedAt = observedAt
    }
}

/// A secrets-free snapshot of one model an ACP agent advertised in its
/// `session/new` response (`ModelsInfo.availableModels`). This is the
/// "ModelInfo-lite" the chat-composer model picker reads to populate a
/// provider's model list — decoupled from the ACP SDK's `ModelInfo` (which
/// lives in the `ACPModel` module and is not part of `WikiFSCore`).
///
/// Persisted in `AgentProvidersConfig.providerModels`, keyed by provider id.
/// **Never** contains credentials, keys, or auth data — only display/model
/// routing metadata the agent itself advertises publicly.
public struct CachedModelInfo: Codable, Hashable, Sendable, Identifiable {
    /// The model id passed back to the agent via `session/set_model` — the same
    /// value the ACP SDK's `ModelInfo.modelId` advertises.
    public let modelId: ModelID
    /// Human label (e.g. "GLM-4.7", "Claude Sonnet 4.5"). Falls back to
    /// `modelId` at the display seam when the agent omits a friendly name.
    public let name: String
    /// Optional one-line description the agent advertised.
    public let description: String?
    /// Durable thinking choices/default for this model, when advertised.
    public let thinkingOptionCatalog: ThinkingOptionCatalog?
    /// True when this was the agent's current/default model during discovery.
    public let isDefault: Bool

    /// `Identifiable` over `modelId` so SwiftUI `ForEach`/`List` can drive the
    /// model picker without an extra `.id()`.
    public var id: ModelID { modelId }

    public init(
        modelId: ModelID,
        name: String,
        description: String? = nil,
        thinkingOptionCatalog: ThinkingOptionCatalog? = nil,
        isDefault: Bool = false
    ) {
        self.modelId = modelId
        self.name = name
        self.description = description
        self.thinkingOptionCatalog = thinkingOptionCatalog
        self.isDefault = isDefault
    }

    private enum CodingKeys: String, CodingKey {
        case modelId, name, description, thinkingOptionCatalog, isDefault
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelId = try container.decode(ModelID.self, forKey: .modelId)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        thinkingOptionCatalog = try container.decodeIfPresent(
            ThinkingOptionCatalog.self, forKey: .thinkingOptionCatalog)
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
    }

    /// The display label the picker trigger uses: the agent's friendly name when
    /// present, else the raw `modelId` (so a bad-default model like `glm-4-7`
    /// is still visible/recognizable — the whole point of the picker). PURE.
    public var displayLabel: String {
        name.isEmpty ? modelId.rawValue : name
    }
}

/// Pure model-selection decision: given the agent's advertised `currentModelId`
/// + `availableModels`, and the user's per-provider selected model id, decide
/// whether `session/set_model` should be sent and with which id.
///
/// Extracted as a pure enum-returning helper so the selection logic is unit-
/// tested WITHOUT a live agent subprocess (the spike forbids end-to-end
/// testing). `ACPBackend.applyModelIfNeeded` consumes this to drive
/// `client.setModel` (mechanism #1) or `client.setConfigOption` (mechanism #2).
///
/// - `useAgentDefault`: no selection (or the selection matches the agent's
///   current model) → do nothing; today's behavior is unchanged (default).
/// - `apply(selectedId:)`: the user picked a model that differs from the agent's
///   current one AND is in the advertised list → call `setModel` with it
///   (the `ModelsInfo.availableModels` path — unchanged).
/// - `applyViaModelConfigOption(selectedValue:)`: #834 — the agent advertises
///   model selection as a `"model"` config option (`session/set_config_option`)
///   rather than via `availableModels` (e.g. claude-acp). The value is the raw
///   option value id, validated against the option's advertised `options`.
///   Driven by `ACPModelSelectionResolver.resolveConfigOptionModel` (in
///   `WikiFSEngine` — it touches `ACPModel.SessionConfigOption`).
public enum ACPModelSelectionDecision: Equatable, Sendable {
    case useAgentDefault
    case apply(selectedId: String)
    case applyViaModelConfigOption(selectedValue: String)
}

public enum ACPModelSelectionResolver {

    /// PURE. Decides whether to call `session/set_model` for a newly-started
    /// ACP session.
    ///
    /// - Parameters:
    ///   - selectedModelId: the user's per-provider model choice (`nil` =
    ///     "no preference → agent default"; the app's default state).
    ///   - currentModelId: the agent's advertised `ModelsInfo.currentModelId`.
    ///   - advertisedModelIds: the model ids the agent advertised
    ///     (`ModelsInfo.availableModels.map(\.modelId)`). Empty/nil = the agent
    ///     did not advertise a list (older agents) → we never override.
    public static func resolve(
        selectedModelId: String?,
        currentModelId: String?,
        advertisedModelIds: [String]
    ) -> ACPModelSelectionDecision {
        guard let selectedModelId, !selectedModelId.isEmpty else {
            return .useAgentDefault
        }
        // If the agent didn't advertise a list, we can't validate the selection
        // — and we don't know its "current" model, so don't guess. Fall back to
        // the agent default (no behavior change for agents that predate models).
        guard !advertisedModelIds.isEmpty else { return .useAgentDefault }
        // Stale selection: the agent no longer offers this model. Sending it
        // would reproduce the exact 404 the picker exists to prevent.
        guard advertisedModelIds.contains(selectedModelId) else {
            return .useAgentDefault
        }
        // Already the agent's current model → a no-op setModel round-trip.
        if let currentModelId, currentModelId == selectedModelId {
            return .useAgentDefault
        }
        return .apply(selectedId: selectedModelId)
    }
}
