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

/// Per-snapshot summarizer lease state (issue #1276). Tracks the ACTIVE
/// summary and title operations on one `prepareSummarization` snapshot so
/// release/dispose can retire the snapshot, drain the active work, terminate
/// the cached backends, and ONLY THEN remove the scratch directory. After
/// `retire()` starts, `acquire()` returns false — no new work enters a
/// snapshot that is going away.
///
/// Actor isolation makes the count/flag/waiter transitions atomic; the
/// checked-continuation queue is how `awaitQuiesce` suspends without blocking
/// a cooperative thread.
actor SummarizerLeaseGate {
    private var activeCount = 0
    private var retired = false
    private var quiesceWaiters: [CheckedContinuation<Void, Never>] = []

    /// Enter one summary/title operation. `false` = the snapshot is retired;
    /// the caller must abandon the work (the token is invalid anyway).
    func acquire() -> Bool {
        guard !retired else { return false }
        activeCount += 1
        return true
    }

    /// Leave one summary/title operation. Resumes quiesce waiters when this
    /// was the last active lease on a retired snapshot.
    func release() {
        activeCount = max(0, activeCount - 1)
        drainIfQuiesced()
    }

    /// Reject new leases. Idempotent.
    func retire() {
        retired = true
        drainIfQuiesced()
    }

    /// Suspend until every lease acquired BEFORE retirement finished. Callers
    /// that arrive after full quiesce return immediately.
    func awaitQuiesce() async {
        if retired && activeCount == 0 { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            quiesceWaiters.append(continuation)
        }
    }

    /// The check-and-resume must be one actor-isolated step: both `release()`
    /// and `retire()` funnel through here so a waiter cannot be missed between
    /// the count hitting zero and the resume.
    private func drainIfQuiesced() {
        guard retired, activeCount == 0, !quiesceWaiters.isEmpty else { return }
        let waiters = quiesceWaiters
        quiesceWaiters = []
        for waiter in waiters { waiter.resume() }
    }
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
    /// Generate a conversation title from the opening question and the
    /// assistant's first reply, through the summarizer-stage preparation.
    /// Throws `.unavailable` when no summarizer model is configured; returns
    /// nil when the model produced nothing usable.
    func modelTitle(
        question: String,
        answer: String?,
        preparation: AgentOperationPreparation
    ) async throws -> String?
    func release(_ token: AgentProviderAttemptToken) async
    func readiness() async -> Bool
}

public extension AgentProviderServices {
    /// Default for conformers that carry no summarizer backend (throws
    /// `.unavailable`).
    func modelTitle(
        question: String,
        answer: String?,
        preparation: AgentOperationPreparation
    ) async throws -> String? {
        throw AgentProviderRuntimeError.unavailable
    }
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

    public func modelTitle(
        question: String,
        answer: String?,
        preparation: AgentOperationPreparation
    ) async throws -> String? {
        try await installed.modelTitle(
            question: question,
            answer: answer,
            preparation: preparation)
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
    /// #1276: the seatbelt front-end usability check. Injected so the catalog
    /// path's fail-closed ORDERING (sandbox gate BEFORE command resolution) is
    /// testable without touching `/usr/bin/sandbox-exec`.
    public typealias SandboxUsabilityCheck = @Sendable (String) -> Bool
    public typealias CatalogProbe = @Sendable (
        AgentProvider,
        [String],
        String?
    ) async throws -> ACPProviderCatalogObservation

    private struct SpawnRecord: Sendable { let provider: AgentProvider; let model: ModelID?; let hints: [String: String] }

    /// One preparation's frozen state. For the summarizer stage it also owns
    /// the scratch world (issue #1276): a unique read-only sandboxed scratch
    /// directory that lives exactly as long as the snapshot's cached backends,
    /// plus the lease gate that serializes teardown against active
    /// summary/title operations.
    private struct Snapshot: Sendable {
        let policy: AgentOperationPolicy
        let thinking: String?
        let models: AgentOperationModelSelection
        let chains: [AgentProviderStage: [SpawnRecord]]
        /// The summarizer scratch world. Non-nil ONLY for summarizer-stage
        /// snapshots (`prepareSummarization`); other stages get the launcher's
        /// wiki-aware run context instead.
        let summarizerScratch: LLMSandboxScratch?
        /// The summarizer lease gate. Non-nil together with `summarizerScratch`.
        let summarizerLease: SummarizerLeaseGate?
    }
    private struct TokenRecord: Sendable { let snapshotID: UUID; let stage: AgentProviderStage; let providerID: ProviderID; let isOriginal: Bool }

    private let readConfiguration: ConfigurationReader
    private let resolveCommand: CommandResolver
    private let readCredential: CredentialReader
    private let readSpawnSecrets: SpawnSecretReader
    private let resolvePermissionPolicy: PermissionPolicyResolver
    private let makeBackend: BackendFactory
    private let probeCatalog: CatalogProbe
    private let sandboxUsable: SandboxUsabilityCheck
    private var snapshots: [UUID: Snapshot] = [:]
    private var tokens: [UUID: TokenRecord] = [:]
    private var cachedBackends: [String: any AgentBackend] = [:]
    private var disposed = false

    /// The production sandbox-usability check: the same fail-closed gate
    /// `ACPBackend.startProcess` applies (issue #1276). Public because it is
    /// this public initializer's default argument.
    public static let defaultSandboxUsability: SandboxUsabilityCheck = { path in
        #if os(macOS)
        ACPBackend.sandboxExecutableIsUsable(at: path)
        #else
        // Linux diagnostic builds have no seatbelt; never blocks there.
        true
        #endif
    }

    /// The strict summarizer sandbox tier is default-on; setting
    /// `WIKIFS_SUMMARIZER_STRICT=0` disables it without a rebuild. The
    /// escape hatch exists because an unknown adapter could fail to launch
    /// under the strict denies — and when it does, summarization degrades to
    /// default truncation (never silently disappears; see the model-summary
    /// call sites).
    public static let strictSummarizerEnabled: Bool =
        ProcessInfo.processInfo.environment["WIKIFS_SUMMARIZER_STRICT"] != "0"

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
        },
        sandboxUsability: @escaping SandboxUsabilityCheck = AgentProviderRuntime.defaultSandboxUsability
    ) {
        self.readConfiguration = readConfiguration
        self.resolveCommand = resolveCommand
        self.readCredential = readCredential
        self.readSpawnSecrets = readSpawnSecrets
        self.resolvePermissionPolicy = resolvePermissionPolicy
        self.makeBackend = makeBackend
        self.probeCatalog = probeCatalog
        self.sandboxUsable = sandboxUsability
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
        // Issue #1276: allocate ONE dedicated scratch world for this snapshot.
        // Cached summarizer backends keep this directory (and its read-only
        // sandbox) for their full lifetime; `release`/`dispose` remove it only
        // after the leases drain and the backends terminate. A scratch
        // allocation failure throws — summarization never runs unsandboxed.
        // The summarizer runs the STRICT profile tier (W^X scratch/temp, macOS
        // pivot exec denies, credential read denies): a one-shot LLM call with
        // no file-tool needs is the most fenceable spawn in the app.
        let scratch = try LLMSandboxScratch.make(
            namePrefix: "summarizer",
            strict: Self.strictSummarizerEnabled)
        let snapshotID = UUID()
        let policy = AgentOperationPolicy(
            kind: .interactive,
            permissionPolicy: .bypass,
            permissionBudget: nil,
            turnCeiling: TurnLivenessPolicy.ceiling(for: .chat))
        // Review HIGH: `makeSnapshot` suspends (command resolution). On
        // failure the scratch is removed — a failed preparation leaks no
        // temp directory.
        let snapshot: Snapshot
        do {
            snapshot = try await makeSnapshot(
                configuration: configuration,
                operation: .interactive,
                providerOverride: nil,
                modelOverride: nil,
                thinkingOverride: nil,
                stages: [.summarizer],
                policyOverride: policy,
                summarizerScratch: scratch)
        } catch {
            scratch.remove()
            throw error
        }
        // Review HIGH: disposal may have raced the suspension above. A
        // disposed runtime never regains an LLM spawn path — remove the
        // scratch and refuse instead of resurrecting a snapshot.
        guard !disposed else {
            scratch.remove()
            throw AgentProviderRuntimeError.unavailable
        }
        snapshots[snapshotID] = snapshot
        return .model(try makePreparation(snapshotID: snapshotID, stage: .summarizer, providerID: nil))
    }

    public func discoverCatalog(
        for provider: AgentProvider
    ) async throws -> ACPProviderCatalogObservation {
        try requireAvailable()
        // Issue #1276 fail-closed ORDERING: the sandbox gate runs BEFORE
        // command resolution (and before the probe spawn). An unusable
        // seatbelt front-end means no probe subprocess at all — nothing is
        // resolved, configured, or launched.
        guard sandboxUsable(SandboxProfile.sandboxExecutablePath) else {
            DebugLog.agent("AgentProviderRuntime.discoverCatalog: sandbox front-end unusable — refusing to probe (fail closed)")
            throw ACPProviderModelProbeError.sandboxUnavailable
        }
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
        // Issue #1276 lease protocol: acquire BEFORE the backend is obtained
        // so release cannot retire + terminate + remove scratch underneath an
        // operation that is about to start.
        let gate = try summarizerLease(for: preparation.selection.token)
        guard await gate.acquire() else {
            throw AgentProviderRuntimeError.invalidToken
        }
        do {
            let prepared = try backend(
                from: preparation.selection.token,
                stage: .summarizer,
                cache: true)
            let summary = await MessageSummarizer.modelSummary(
                text: text,
                backend: prepared.backend,
                profile: prepared.profile)
            await gate.release()
            return summary
        } catch {
            await gate.release()
            throw error
        }
    }

    public func modelTitle(
        question: String,
        answer: String?,
        preparation: AgentOperationPreparation
    ) async throws -> String? {
        guard preparation.selection.stage == .summarizer else {
            throw AgentProviderRuntimeError.stageMismatch
        }
        // Same lease protocol as `modelSummary` — titles and summaries share
        // one snapshot scratch + one cached backend, and release drains BOTH
        // before teardown.
        let gate = try summarizerLease(for: preparation.selection.token)
        guard await gate.acquire() else {
            throw AgentProviderRuntimeError.invalidToken
        }
        do {
            let prepared = try backend(
                from: preparation.selection.token,
                stage: .summarizer,
                cache: true)
            let title = await MessageSummarizer.modelTitle(
                question: question,
                answer: answer,
                backend: prepared.backend,
                profile: prepared.profile)
            await gate.release()
            return title
        } catch {
            await gate.release()
            throw error
        }
    }

    /// The summarizer snapshot's lease gate, resolved from a preparation
    /// token. Throws when the token is invalid/retired (`invalidToken`) or the
    /// snapshot has no gate (a non-summarizer token — `stageMismatch`).
    private func summarizerLease(
        for token: AgentProviderAttemptToken
    ) throws -> SummarizerLeaseGate {
        let record = try record(for: token)
        guard let snapshot = snapshots[record.snapshotID] else {
            throw AgentProviderRuntimeError.invalidToken
        }
        guard let gate = snapshot.summarizerLease else {
            throw AgentProviderRuntimeError.stageMismatch
        }
        return gate
    }

    public func release(_ token: AgentProviderAttemptToken) async {
        guard !disposed, let record = tokens[token.value] else { return }
        let snapshotID = record.snapshotID
        let snapshot = snapshots.removeValue(forKey: snapshotID)
        tokens = tokens.filter { $0.value.snapshotID != snapshotID }
        // Issue #1276 review HIGH: DETACH this snapshot's cached backends
        // BEFORE any suspension, so an overlapping `dispose` can never capture
        // (and shut down) a backend whose lease is still active.
        let cachePrefix = snapshotID.uuidString + ":"
        var detached: [any AgentBackend] = []
        for (key, backend) in cachedBackends where key.hasPrefix(cachePrefix) {
            detached.append(backend)
        }
        cachedBackends = cachedBackends.filter { !$0.key.hasPrefix(cachePrefix) }
        // Teardown order — retire, quiesce, terminate, remove:
        // 1. RETIRE: new summary/title work is rejected from here on.
        // 2. QUIESCE: every lease acquired before retirement finishes (the
        //    in-flight operation still uses its cached backend).
        if let gate = snapshot?.summarizerLease {
            await gate.retire()
            await gate.awaitQuiesce()
        }
        // 3. TERMINATE each detached backend at the process level — a cached
        //    backend is NOT terminated by dropping it, and `cancel(_:)` is
        //    session-scoped.
        for backend in detached {
            await backend.shutdown()
        }
        // 4. ONLY NOW remove the scratch — no process can still use it.
        snapshot?.summarizerScratch?.remove()
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

    /// Full runtime shutdown (issue #1276): same detach → retire → quiesce →
    /// terminate → remove ordering as `release`, applied to every live
    /// snapshot. Async because it drains leases and terminates processes;
    /// owners already await it (actor method). The cache is detached before
    /// the first suspension, so two overlapping `dispose()` calls (or a
    /// `dispose` racing a `release`) can never double-shutdown a backend or
    /// shut one down while its lease is active.
    public func dispose() async {
        disposed = true
        let retiring = snapshots
        snapshots.removeAll()
        tokens.removeAll()
        let backends = cachedBackends
        cachedBackends.removeAll()
        for snapshot in retiring.values {
            if let gate = snapshot.summarizerLease {
                await gate.retire()
                await gate.awaitQuiesce()
            }
        }
        for (_, backend) in backends {
            await backend.shutdown()
        }
        for snapshot in retiring.values {
            snapshot.summarizerScratch?.remove()
        }
    }

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
        // Issue #1276: the summarizer stage is a read-only LLM spawn with no
        // wiki — its profile MUST carry the snapshot's scratch directory and
        // the matching read-only sandbox invocation. A snapshot without a
        // scratch world fails closed here (`unavailable`) instead of spawning
        // unfenced. Other stages stay plain: the launcher layers its wiki-aware
        // run context + write sandbox onto those spawns itself.
        let profile: BackendProfile
        if stage == .summarizer {
            guard let scratch = snapshot.summarizerScratch else {
                throw AgentProviderRuntimeError.unavailable
            }
            profile = BackendProfile(
                model: spawn.model?.rawValue,
                providerHints: spawn.hints,
                scratchDirectory: scratch.directoryURL,
                isReadOnly: true,
                sandbox: scratch.sandbox)
        } else {
            profile = BackendProfile(model: spawn.model?.rawValue, providerHints: spawn.hints)
        }
        return AgentProviderPreparedBackend(backend: backend, profile: profile, policy: snapshot.policy, provider: spawn.provider)
    }

    private func makeSnapshot(
        configuration: AgentProvidersConfig,
        operation: AgentProviderOperationKind,
        providerOverride: ProviderID?,
        modelOverride: ModelID?,
        thinkingOverride: String?,
        stages: [AgentProviderStage],
        policyOverride: AgentOperationPolicy? = nil,
        summarizerScratch: LLMSandboxScratch? = nil
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
            chains: chains,
            summarizerScratch: summarizerScratch,
            summarizerLease: summarizerScratch == nil ? nil : SummarizerLeaseGate())
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
