import Foundation
import WikiFSCore

/// The public identity of a configured provider. Spawn configuration stays private.
public struct AgentProviderDescriptor: Sendable, Equatable, Hashable, CustomStringConvertible {
    public let id: ProviderID
    public let label: String
    public init(id: ProviderID, label: String) { self.id = id; self.label = label }
    public var description: String { "AgentProviderDescriptor(id: \(id.rawValue), label: \(label))" }
}

public enum AgentProviderOperationKind: Sendable, Equatable { case interactive, ingest, lint }
public enum AgentProviderStage: Sendable, Equatable, Hashable, CaseIterable { case chat, planner, executor, finalizer, summarizer, lint }

public struct AgentOperationPolicy: Sendable, Equatable {
    public let kind: AgentProviderOperationKind
    public let permissionPolicy: PermissionPolicy
    public let permissionBudget: Duration?
    public let turnCeiling: TimeInterval
    public init(kind: AgentProviderOperationKind, permissionPolicy: PermissionPolicy, permissionBudget: Duration?, turnCeiling: TimeInterval) {
        self.kind = kind; self.permissionPolicy = permissionPolicy; self.permissionBudget = permissionBudget; self.turnCeiling = turnCeiling
    }
}

public struct AgentOperationModelSelection: Sendable, Equatable {
    public let interactiveModel: ModelID?
    public let stageModels: [AgentProviderStage: ModelID?]
    public init(interactiveModel: ModelID?, stageModels: [AgentProviderStage: ModelID?]) { self.interactiveModel = interactiveModel; self.stageModels = stageModels }
    public func model(for stage: AgentProviderStage) -> ModelID? { stage == .chat ? interactiveModel : stageModels[stage] ?? nil }
}

public struct AgentProviderAttemptToken: Sendable, Equatable, Hashable, CustomStringConvertible {
    fileprivate let value: UUID
    fileprivate init(_ value: UUID) { self.value = value }
    public var description: String { "AgentProviderAttemptToken()" }
}

public struct AgentProviderSelection: Sendable, Equatable {
    public let stage: AgentProviderStage
    public let descriptor: AgentProviderDescriptor
    public let model: ModelID?
    public let token: AgentProviderAttemptToken
    public init(stage: AgentProviderStage, descriptor: AgentProviderDescriptor, model: ModelID?, token: AgentProviderAttemptToken) {
        self.stage = stage; self.descriptor = descriptor; self.model = model; self.token = token
    }
}

public struct AgentOperationPreparation: Sendable, Equatable {
    public let selection: AgentProviderSelection
    public let policy: AgentOperationPolicy
    public let effectiveThinking: String?
    public init(selection: AgentProviderSelection, policy: AgentOperationPolicy, effectiveThinking: String?) {
        self.selection = selection; self.policy = policy; self.effectiveThinking = effectiveThinking
    }
}

public struct AgentInteractivePreparation: Sendable, Equatable {
    public let operation: AgentOperationPreparation
    public let thinkingConfiguration: ResolvedThinkingConfiguration?

    public init(
        operation: AgentOperationPreparation,
        thinkingConfiguration: ResolvedThinkingConfiguration?
    ) {
        self.operation = operation
        self.thinkingConfiguration = thinkingConfiguration
    }
}

public enum AgentProviderSummaryPreparation: Sendable, Equatable {
    case defaultTruncation
    case model(AgentOperationPreparation)
}

public enum AgentProviderRuntimeError: Error, Sendable, Equatable, CustomStringConvertible {
    case unavailable, invalidToken, stageMismatch, providerMismatch, invalidFallback, noProvider
    public var description: String {
        switch self {
        case .unavailable: "Agent provider runtime is unavailable."
        case .invalidToken: "Agent provider token is invalid or disposed."
        case .stageMismatch: "Agent provider token does not authorize this stage."
        case .providerMismatch: "Agent provider token does not authorize this provider."
        case .invalidFallback: "Requested provider is not a frozen fallback."
        case .noProvider: "No provider is configured for this stage."
        }
    }
}

public protocol AgentProviderServices: Sendable {
    func prepareInteractive(
        providerOverride: ProviderID?,
        modelOverride: ModelID?,
        configuredThinkingOptionID: ChatConfigurationValueID?,
        priorEffectiveThinkingOptionID: ChatConfigurationValueID?
    ) async throws -> AgentInteractivePreparation
    func prepare(_ operation: AgentProviderOperationKind, providerOverride: ProviderID?, modelOverride: ModelID?, thinkingOverride: String?) async throws -> AgentOperationPreparation
    func preparation(from token: AgentProviderAttemptToken, stage: AgentProviderStage) async throws -> AgentOperationPreparation
    func fallbackPreparation(from token: AgentProviderAttemptToken, stage: AgentProviderStage, fallbackProviderID: ProviderID) async throws -> AgentOperationPreparation
    func prepareSummarization() async throws -> AgentProviderSummaryPreparation
    func discoverCatalog(for provider: AgentProvider) async throws -> ACPProviderCatalogObservation
    func modelSummary(text: String, preparation: AgentOperationPreparation) async throws -> String?
    func release(_ token: AgentProviderAttemptToken) async
    func readiness() async -> Bool
}

public extension AgentProviderServices {
    func prepareInteractive(
        providerOverride: ProviderID?,
        modelOverride: ModelID?,
        configuredThinkingOptionID: ChatConfigurationValueID?,
        priorEffectiveThinkingOptionID: ChatConfigurationValueID?
    ) async throws -> AgentInteractivePreparation {
        let operation = try await prepare(
            .interactive,
            providerOverride: providerOverride,
            modelOverride: modelOverride,
            thinkingOverride: configuredThinkingOptionID?.rawValue)
        return AgentInteractivePreparation(
            operation: operation,
            thinkingConfiguration: nil)
    }

    func prepare(_ operation: AgentProviderOperationKind) async throws -> AgentOperationPreparation {
        try await prepare(operation, providerOverride: nil, modelOverride: nil, thinkingOverride: nil)
    }
}

public actor MutableAgentProviderServices: AgentProviderPrivateServices {
    public struct Installation: Hashable, Sendable {
        fileprivate let id = UUID()

        public init() {}
    }

    private var installed: any AgentProviderServices
    private var activeInstallation: Installation?
    private var invalidatedInstallations: Set<Installation> = []

    public init(initial: any AgentProviderServices = UnavailableAgentProviderServices()) {
        installed = initial
    }

    public func install(_ services: any AgentProviderServices, for installation: Installation) {
        guard !invalidatedInstallations.contains(installation) else { return }
        installed = services
        activeInstallation = installation
    }

    public func invalidate(_ installation: Installation) {
        invalidatedInstallations.insert(installation)
        guard activeInstallation == installation else { return }
        installed = UnavailableAgentProviderServices()
        activeInstallation = nil
    }

    public func prepareInteractive(
        providerOverride: ProviderID?,
        modelOverride: ModelID?,
        configuredThinkingOptionID: ChatConfigurationValueID?,
        priorEffectiveThinkingOptionID: ChatConfigurationValueID?
    ) async throws -> AgentInteractivePreparation {
        try await installed.prepareInteractive(
            providerOverride: providerOverride,
            modelOverride: modelOverride,
            configuredThinkingOptionID: configuredThinkingOptionID,
            priorEffectiveThinkingOptionID: priorEffectiveThinkingOptionID)
    }

    public func prepare(
        _ operation: AgentProviderOperationKind,
        providerOverride: ProviderID?,
        modelOverride: ModelID?,
        thinkingOverride: String?
    ) async throws -> AgentOperationPreparation {
        try await installed.prepare(
            operation,
            providerOverride: providerOverride,
            modelOverride: modelOverride,
            thinkingOverride: thinkingOverride)
    }

    public func preparation(
        from token: AgentProviderAttemptToken,
        stage: AgentProviderStage
    ) async throws -> AgentOperationPreparation {
        try await installed.preparation(from: token, stage: stage)
    }

    public func fallbackPreparation(
        from token: AgentProviderAttemptToken,
        stage: AgentProviderStage,
        fallbackProviderID: ProviderID
    ) async throws -> AgentOperationPreparation {
        try await installed.fallbackPreparation(
            from: token,
            stage: stage,
            fallbackProviderID: fallbackProviderID)
    }

    public func prepareSummarization() async throws -> AgentProviderSummaryPreparation {
        try await installed.prepareSummarization()
    }

    public func discoverCatalog(
        for provider: AgentProvider
    ) async throws -> ACPProviderCatalogObservation {
        try await installed.discoverCatalog(for: provider)
    }

    public func modelSummary(
        text: String,
        preparation: AgentOperationPreparation
    ) async throws -> String? {
        try await installed.modelSummary(text: text, preparation: preparation)
    }

    public func release(_ token: AgentProviderAttemptToken) async {
        await installed.release(token)
    }

    public func readiness() async -> Bool { await installed.readiness() }

    func frozenProviderDescriptors(
        from token: AgentProviderAttemptToken,
        stage: AgentProviderStage
    ) async throws -> [AgentProviderDescriptor] {
        guard let privateServices = installed as? any AgentProviderPrivateServices else {
            throw AgentProviderRuntimeError.unavailable
        }
        return try await privateServices.frozenProviderDescriptors(
            from: token,
            stage: stage)
    }

    func preparedBackend(
        from token: AgentProviderAttemptToken,
        stage: AgentProviderStage
    ) async throws -> AgentProviderPreparedBackend {
        guard let privateServices = installed as? any AgentProviderPrivateServices else {
            throw AgentProviderRuntimeError.unavailable
        }
        return try await privateServices.preparedBackend(from: token, stage: stage)
    }

    func freshBackend(
        from token: AgentProviderAttemptToken,
        stage: AgentProviderStage
    ) async throws -> AgentProviderPreparedBackend {
        guard let privateServices = installed as? any AgentProviderPrivateServices else {
            throw AgentProviderRuntimeError.unavailable
        }
        return try await privateServices.freshBackend(from: token, stage: stage)
    }
}

public struct UnavailableAgentProviderServices: AgentProviderServices {
    public init() {}
    public func prepareInteractive(providerOverride: ProviderID?, modelOverride: ModelID?, configuredThinkingOptionID: ChatConfigurationValueID?, priorEffectiveThinkingOptionID: ChatConfigurationValueID?) async throws -> AgentInteractivePreparation { throw AgentProviderRuntimeError.unavailable }
    public func prepare(_ operation: AgentProviderOperationKind, providerOverride: ProviderID?, modelOverride: ModelID?, thinkingOverride: String?) async throws -> AgentOperationPreparation { throw AgentProviderRuntimeError.unavailable }
    public func preparation(from token: AgentProviderAttemptToken, stage: AgentProviderStage) async throws -> AgentOperationPreparation { throw AgentProviderRuntimeError.unavailable }
    public func fallbackPreparation(from token: AgentProviderAttemptToken, stage: AgentProviderStage, fallbackProviderID: ProviderID) async throws -> AgentOperationPreparation { throw AgentProviderRuntimeError.unavailable }
    public func prepareSummarization() async throws -> AgentProviderSummaryPreparation { throw AgentProviderRuntimeError.unavailable }
    public func discoverCatalog(for provider: AgentProvider) async throws -> ACPProviderCatalogObservation { throw AgentProviderRuntimeError.unavailable }
    public func modelSummary(text: String, preparation: AgentOperationPreparation) async throws -> String? { throw AgentProviderRuntimeError.unavailable }
    public func release(_ token: AgentProviderAttemptToken) async {}
    public func readiness() async -> Bool { false }
}

/// Engine-only capability surface. It deliberately carries the private hints needed to spawn.
protocol AgentProviderPrivateServices: AgentProviderServices {
    func frozenProviderDescriptors(from token: AgentProviderAttemptToken, stage: AgentProviderStage) async throws -> [AgentProviderDescriptor]
    func preparedBackend(from token: AgentProviderAttemptToken, stage: AgentProviderStage) async throws -> AgentProviderPreparedBackend
    func freshBackend(from token: AgentProviderAttemptToken, stage: AgentProviderStage) async throws -> AgentProviderPreparedBackend
}

struct AgentProviderPreparedBackend: Sendable {
    let backend: any AgentBackend
    let profile: BackendProfile
    let policy: AgentOperationPolicy
    let provider: AgentProvider
}

public actor AgentProviderRuntime: AgentProviderPrivateServices {
    public typealias ConfigurationReader = @Sendable () throws -> AgentProvidersConfig
    public typealias CommandResolver = @Sendable ([AgentProvider]) async -> [ProviderID: [String]]
    public typealias CredentialReader = @Sendable (ProviderID) -> String?
    /// #1159: resolves the SELECTED provider's known secret environment
    /// variables (`ProviderSecretEnvironmentVariable`) from the shared
    /// credential service. Trusted host only — the returned map merges into
    /// this provider's private spawn hints at preparation time and is never
    /// persisted or logged.
    public typealias SpawnSecretReader = @Sendable (ProviderID) -> [String: String]
    public typealias PermissionPolicyResolver = @Sendable (PermissionOperationKind) -> PermissionPolicy
    public typealias BackendFactory = @Sendable (PermissionPolicy, Duration?, TimeInterval) -> any AgentBackend
    public typealias CatalogProbe = @Sendable (
        AgentProvider,
        [String],
        String?
    ) async throws -> ACPProviderCatalogObservation

    private struct SpawnRecord: Sendable { let provider: AgentProvider; let model: ModelID?; let hints: [String: String] }
    private struct Snapshot: Sendable { let policy: AgentOperationPolicy; let thinking: String?; let models: AgentOperationModelSelection; let chains: [AgentProviderStage: [SpawnRecord]] }
    private struct TokenRecord: Sendable { let snapshotID: UUID; let stage: AgentProviderStage; let providerID: ProviderID; let isOriginal: Bool }

    private let readConfiguration: ConfigurationReader
    private let resolveCommand: CommandResolver
    private let readCredential: CredentialReader
    private let readSpawnSecrets: SpawnSecretReader
    private let resolvePermissionPolicy: PermissionPolicyResolver
    private let makeBackend: BackendFactory
    private let probeCatalog: CatalogProbe
    private var snapshots: [UUID: Snapshot] = [:]
    private var tokens: [UUID: TokenRecord] = [:]
    private var cachedBackends: [String: any AgentBackend] = [:]
    private var disposed = false

    public init(
        readConfiguration: @escaping ConfigurationReader,
        resolveCommand: @escaping CommandResolver,
        readCredential: @escaping CredentialReader,
        readSpawnSecrets: @escaping SpawnSecretReader = { _ in [:] },
        resolvePermissionPolicy: @escaping PermissionPolicyResolver,
        makeBackend: @escaping BackendFactory = {
            AgentBackendFactory.makeBackend(
                policy: $0,
                budget: $1,
                turnCeilingTimeout: $2)
        },
        probeCatalog: @escaping CatalogProbe = { provider, resolvedCommand, apiKey in
            try await ACPProviderModelProbe(
                provider: provider,
                resolvedCommand: resolvedCommand,
                apiKey: apiKey)
                .discoverObservation()
        }
    ) {
        self.readConfiguration = readConfiguration
        self.resolveCommand = resolveCommand
        self.readCredential = readCredential
        self.readSpawnSecrets = readSpawnSecrets
        self.resolvePermissionPolicy = resolvePermissionPolicy
        self.makeBackend = makeBackend
        self.probeCatalog = probeCatalog
    }

    public func prepareInteractive(
        providerOverride: ProviderID?,
        modelOverride: ModelID?,
        configuredThinkingOptionID: ChatConfigurationValueID?,
        priorEffectiveThinkingOptionID: ChatConfigurationValueID?
    ) async throws -> AgentInteractivePreparation {
        try requireAvailable()
        let configuration = try readConfiguration()
        let catalogSelection = configuration.resolvedChatCatalogSelection(
            chatOverrideProviderID: providerOverride,
            chatOverrideModelID: modelOverride)
        let thinking = configuration.resolveThinkingCapability(
            chatOverrideProviderID: providerOverride,
            chatOverrideModelID: modelOverride,
            configuredValueID: configuredThinkingOptionID,
            priorEffectiveValueID: priorEffectiveThinkingOptionID)
        let thinkingConfiguration = ResolvedThinkingConfiguration(
            resolution: thinking,
            priorEffectiveValueID: priorEffectiveThinkingOptionID)
        let effectiveModel = thinkingConfiguration?.modelID ?? catalogSelection.model?.modelId
        let snapshotID = UUID()
        let snapshot = try await makeSnapshot(
            configuration: configuration,
            operation: .interactive,
            providerOverride: catalogSelection.provider.id,
            modelOverride: effectiveModel,
            thinkingOverride: thinkingConfiguration?.desiredValueID.rawValue,
            stages: AgentProviderOperationKind.interactive.stages)
        snapshots[snapshotID] = snapshot
        let operation = try makePreparation(
            snapshotID: snapshotID,
            stage: .chat,
            providerID: nil,
            isOriginal: true)
        return AgentInteractivePreparation(
            operation: operation,
            thinkingConfiguration: thinkingConfiguration)
    }

    public func prepare(_ operation: AgentProviderOperationKind, providerOverride: ProviderID? = nil, modelOverride: ModelID? = nil, thinkingOverride: String? = nil) async throws -> AgentOperationPreparation {
        try requireAvailable()
        let configuration = try readConfiguration()
        let snapshotID = UUID()
        let snapshot = try await makeSnapshot(
            configuration: configuration,
            operation: operation,
            providerOverride: providerOverride,
            modelOverride: modelOverride,
            thinkingOverride: thinkingOverride,
            stages: operation.stages)
        snapshots[snapshotID] = snapshot
        return try makePreparation(snapshotID: snapshotID, stage: operation.primaryStage, providerID: nil, isOriginal: true)
    }

    public func preparation(from token: AgentProviderAttemptToken, stage: AgentProviderStage) async throws -> AgentOperationPreparation {
        try requireAvailable(); let record = try record(for: token)
        guard (record.isOriginal || record.stage == stage), let snapshot = snapshots[record.snapshotID], snapshot.chains[stage] != nil else { throw AgentProviderRuntimeError.stageMismatch }
        return try makePreparation(snapshotID: record.snapshotID, stage: stage, providerID: record.isOriginal ? nil : record.providerID)
    }

    public func fallbackPreparation(from token: AgentProviderAttemptToken, stage: AgentProviderStage, fallbackProviderID: ProviderID) async throws -> AgentOperationPreparation {
        try requireAvailable(); let record = try record(for: token)
        guard record.isOriginal || record.stage == stage else { throw AgentProviderRuntimeError.stageMismatch }
        guard let snapshot = snapshots[record.snapshotID], let chain = snapshot.chains[stage] else { throw AgentProviderRuntimeError.stageMismatch }
        guard chain.contains(where: { $0.provider.id == fallbackProviderID }) else { throw AgentProviderRuntimeError.invalidFallback }
        return try makePreparation(snapshotID: record.snapshotID, stage: stage, providerID: fallbackProviderID)
    }

    public func prepareSummarization() async throws -> AgentProviderSummaryPreparation {
        try requireAvailable(); let configuration = try readConfiguration()
        guard MessageSummarizer.mode(for: configuration) == .model else { return .defaultTruncation }
        let snapshotID = UUID()
        let policy = AgentOperationPolicy(
            kind: .interactive,
            permissionPolicy: .bypass,
            permissionBudget: nil,
            turnCeiling: TurnLivenessPolicy.ceiling(for: .chat))
        let snapshot = try await makeSnapshot(
            configuration: configuration,
            operation: .interactive,
            providerOverride: nil,
            modelOverride: nil,
            thinkingOverride: nil,
            stages: [.summarizer],
            policyOverride: policy)
        snapshots[snapshotID] = snapshot
        return .model(try makePreparation(snapshotID: snapshotID, stage: .summarizer, providerID: nil))
    }

    public func discoverCatalog(
        for provider: AgentProvider
    ) async throws -> ACPProviderCatalogObservation {
        try requireAvailable()
        let commands = await resolveCommand([provider])
        try requireAvailable()
        guard let resolvedCommand = commands[provider.id], !resolvedCommand.isEmpty else {
            throw ACPProviderModelProbeError.notConfigured
        }
        return try await probeCatalog(
            provider,
            resolvedCommand,
            readCredential(provider.id))
    }

    public func modelSummary(
        text: String,
        preparation: AgentOperationPreparation
    ) async throws -> String? {
        guard preparation.selection.stage == .summarizer else {
            throw AgentProviderRuntimeError.stageMismatch
        }
        let prepared = try backend(
            from: preparation.selection.token,
            stage: .summarizer,
            cache: true)
        return await MessageSummarizer.modelSummary(
            text: text,
            backend: prepared.backend,
            profile: prepared.profile)
    }

    public func release(_ token: AgentProviderAttemptToken) async {
        guard !disposed, let record = tokens[token.value] else { return }
        let snapshotID = record.snapshotID
        snapshots.removeValue(forKey: snapshotID)
        tokens = tokens.filter { $0.value.snapshotID != snapshotID }
        let cachePrefix = snapshotID.uuidString + ":"
        cachedBackends = cachedBackends.filter { !$0.key.hasPrefix(cachePrefix) }
    }

    public func readiness() async -> Bool {
        guard !disposed else { return false }
        do {
            _ = try readConfiguration()
            return true
        } catch {
            DebugLog.agent("Agent provider readiness failed: \(error)")
            return false
        }
    }

    public func dispose() { disposed = true; snapshots.removeAll(); tokens.removeAll(); cachedBackends.removeAll() }

    func frozenProviderDescriptors(from token: AgentProviderAttemptToken, stage: AgentProviderStage) async throws -> [AgentProviderDescriptor] {
        try requireAvailable()
        let record = try self.record(for: token)
        guard (record.isOriginal || record.stage == stage),
              let chain = snapshots[record.snapshotID]?.chains[stage] else {
            throw AgentProviderRuntimeError.stageMismatch
        }
        return chain.map { AgentProviderDescriptor(id: $0.provider.id, label: $0.provider.label) }
    }

    func preparedBackend(from token: AgentProviderAttemptToken, stage: AgentProviderStage) async throws -> AgentProviderPreparedBackend { try backend(from: token, stage: stage, cache: true) }
    func freshBackend(from token: AgentProviderAttemptToken, stage: AgentProviderStage) async throws -> AgentProviderPreparedBackend { try backend(from: token, stage: stage, cache: false) }
    func activeSnapshotCount() -> Int { snapshots.count }

    private func backend(from token: AgentProviderAttemptToken, stage: AgentProviderStage, cache: Bool) throws -> AgentProviderPreparedBackend {
        let preparation = try preparationSync(from: token, stage: stage)
        let record = try record(for: token); guard let snapshot = snapshots[record.snapshotID], let spawn = snapshot.chains[stage]?.first(where: { $0.provider.id == preparation.selection.descriptor.id }) else { throw AgentProviderRuntimeError.invalidToken }
        let key = "\(record.snapshotID.uuidString):\(spawn.provider.id.rawValue)"
        let backend = cache ? (cachedBackends[key] ?? makeBackend(snapshot.policy.permissionPolicy, snapshot.policy.permissionBudget, snapshot.policy.turnCeiling)) : makeBackend(snapshot.policy.permissionPolicy, snapshot.policy.permissionBudget, snapshot.policy.turnCeiling)
        if cache { cachedBackends[key] = backend }
        return AgentProviderPreparedBackend(backend: backend, profile: BackendProfile(model: spawn.model?.rawValue, providerHints: spawn.hints), policy: snapshot.policy, provider: spawn.provider)
    }

    private func makeSnapshot(
        configuration: AgentProvidersConfig,
        operation: AgentProviderOperationKind,
        providerOverride: ProviderID?,
        modelOverride: ModelID?,
        thinkingOverride: String?,
        stages: [AgentProviderStage],
        policyOverride: AgentOperationPolicy? = nil
    ) async throws -> Snapshot {
        let policy = policyOverride ?? AgentOperationPolicy(
            kind: operation,
            permissionPolicy: resolvePermissionPolicy(operation.permissionKind),
            permissionBudget: operation == .interactive ? nil : .seconds(60),
            turnCeiling: TurnLivenessPolicy.ceiling(for: operation.permissionKind))
        var chains: [AgentProviderStage: [SpawnRecord]] = [:]
        var models: [AgentProviderStage: ModelID?] = [:]
        var stageProviders: [AgentProviderStage: [AgentProvider]] = [:]
        for stage in stages {
            var providers = configuration.providerChain(forStage: stage.configurationKey)
            if stage == operation.primaryStage,
               let providerOverride,
               let selected = providers.first(where: { $0.id == providerOverride }) {
                providers.removeAll { $0.id == providerOverride }
                providers.insert(selected, at: 0)
            }
            stageProviders[stage] = providers
        }
        var uniqueProviders: [ProviderID: AgentProvider] = [:]
        for providers in stageProviders.values {
            for provider in providers { uniqueProviders[provider.id] = provider }
        }
        let commands = await resolveCommand(Array(uniqueProviders.values))
        let credentials = Dictionary(
            uniqueKeysWithValues: uniqueProviders.keys.map { ($0, readCredential($0)) })
        // #1159: resolve each provider's known secret environment variables
        // ONCE per preparation, here in the trusted host. Rotation is visible
        // on the NEXT preparation because this snapshot is rebuilt per prepare
        // call and resolved values are never cached beyond it.
        let spawnSecrets = Dictionary(
            uniqueKeysWithValues: uniqueProviders.keys.map { ($0, readSpawnSecrets($0)) })
        for stage in stages {
            let providers = stageProviders[stage] ?? []
            var records: [SpawnRecord] = []
            for provider in providers {
                let model: ModelID?
                if stage == operation.primaryStage,
                   let providerOverride,
                   provider.id == providerOverride {
                    model = modelOverride ?? configuration.selectedModelId(forProvider: provider.id)
                } else if stage == operation.primaryStage {
                    model = modelOverride ?? configuration.modelId(
                        forStage: stage.configurationKey,
                        fallbackProvider: provider.id)
                } else {
                    model = configuration.modelId(
                        forStage: stage.configurationKey,
                        fallbackProvider: provider.id)
                }
                var hints = AgentBackendFactory.providerHints(
                    provider: provider,
                    resolvedCommand: commands[provider.id] ?? [],
                    apiKey: credentials[provider.id] ?? nil,
                    selectedModelId: model?.rawValue)
                // Resolved secrets ride the established `env.` hint prefix.
                // They override any same-named entry — `provider.env` cannot
                // carry known secret keys anymore (stripped at every
                // boundary), so this is additive in practice.
                for (key, value) in spawnSecrets[provider.id] ?? [:] {
                    hints[HintKey.env(key)] = value
                }
                records.append(SpawnRecord(provider: provider, model: model, hints: hints))
            }
            chains[stage] = records
            models[stage] = records.first?.model
        }
        let selection = AgentOperationModelSelection(
            interactiveModel: models[.chat] ?? nil,
            stageModels: models)
        return Snapshot(
            policy: policy,
            thinking: thinkingOverride,
            models: selection,
            chains: chains)
    }

    private func makePreparation(
        snapshotID: UUID,
        stage: AgentProviderStage,
        providerID: ProviderID?,
        isOriginal: Bool = false
    ) throws -> AgentOperationPreparation {
        guard let snapshot = snapshots[snapshotID], let chain = snapshot.chains[stage] else { throw AgentProviderRuntimeError.stageMismatch }
        guard let spawn = providerID.flatMap({ id in chain.first(where: { $0.provider.id == id }) }) ?? chain.first else { throw AgentProviderRuntimeError.noProvider }
        let value = UUID()
        tokens[value] = TokenRecord(
            snapshotID: snapshotID,
            stage: stage,
            providerID: spawn.provider.id,
            isOriginal: isOriginal)
        return AgentOperationPreparation(selection: .init(stage: stage, descriptor: .init(id: spawn.provider.id, label: spawn.provider.label), model: spawn.model, token: .init(value)), policy: snapshot.policy, effectiveThinking: snapshot.thinking)
    }
    private func preparationSync(from token: AgentProviderAttemptToken, stage: AgentProviderStage) throws -> AgentOperationPreparation {
        let record = try self.record(for: token); guard record.stage == stage else { throw AgentProviderRuntimeError.stageMismatch }
        return try makePreparation(snapshotID: record.snapshotID, stage: stage, providerID: record.providerID)
    }
    private func record(for token: AgentProviderAttemptToken) throws -> TokenRecord { guard let record = tokens[token.value] else { throw AgentProviderRuntimeError.invalidToken }; return record }
    private func requireAvailable() throws { guard !disposed else { throw AgentProviderRuntimeError.unavailable } }
}

private extension AgentProviderOperationKind {
    var permissionKind: PermissionOperationKind { switch self { case .interactive: .chat; case .ingest: .ingest; case .lint: .lint } }
    var primaryStage: AgentProviderStage { switch self { case .interactive: .chat; case .ingest: .planner; case .lint: .lint } }
    var stages: [AgentProviderStage] {
        switch self {
        case .interactive: [.chat]
        case .ingest: [.planner, .executor, .finalizer]
        case .lint: [.lint]
        }
    }
}
private extension AgentProviderStage { var configurationKey: String { switch self { case .chat: "chat"; case .planner: "planner"; case .executor: "executor"; case .finalizer: "finalizer"; case .summarizer: "summarizer"; case .lint: "lint" } } }
