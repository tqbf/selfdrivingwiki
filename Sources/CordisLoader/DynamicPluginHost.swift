import Cordis
import Foundation

/// Stable process-local identity for one trusted dynamic definition.
public struct DynamicPluginDefinitionID: RawRepresentable, Hashable, Sendable, Comparable {
    public static let reservedPrefix = "dynamic:"

    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue.hasPrefix(Self.reservedPrefix)
            ? rawValue
            : Self.reservedPrefix + rawValue
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Immutable fingerprint for the host-owned inputs that generated a definition.
public struct DynamicPluginDefinitionFingerprint: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }
}

/// Identity for one process-local activation attempt.
public struct DynamicPluginRunID: RawRepresentable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// A definition created by trusted host code. This type contains no source or package path.
public struct TrustedDynamicPluginDefinition: Sendable {
    public let id: DynamicPluginDefinitionID
    public let fingerprint: DynamicPluginDefinitionFingerprint
    public let plugin: PluginDefinition
    public let declaredWorkCount: Int

    public init(
        id: DynamicPluginDefinitionID,
        fingerprint: DynamicPluginDefinitionFingerprint,
        plugin: PluginDefinition,
        declaredWorkCount: Int
    ) {
        self.id = id
        self.fingerprint = fingerprint
        self.plugin = plugin
        self.declaredWorkCount = declaredWorkCount
    }
}

public struct DynamicPluginHostPolicy: Hashable, Sendable {
    public static let standard = DynamicPluginHostPolicy(
        maximumRetainedRunsPerDefinition: 16,
        maximumRetainedDiagnosticsPerDefinition: 32)

    public let maximumRetainedRunsPerDefinition: Int
    public let maximumRetainedDiagnosticsPerDefinition: Int

    public init(
        maximumRetainedRunsPerDefinition: Int,
        maximumRetainedDiagnosticsPerDefinition: Int
    ) {
        precondition(maximumRetainedRunsPerDefinition > 0)
        precondition(maximumRetainedDiagnosticsPerDefinition > 0)
        self.maximumRetainedRunsPerDefinition = maximumRetainedRunsPerDefinition
        self.maximumRetainedDiagnosticsPerDefinition = maximumRetainedDiagnosticsPerDefinition
    }
}

public enum DynamicPluginLifecycleState: String, Hashable, Sendable {
    case defined
    case starting
    case waiting
    case active
    case failed
    case stopping
    case stopped
    case undefined
}

public enum DynamicPluginFailurePhase: String, Hashable, Sendable {
    case definitionFactory
    case componentRegistration
    case activation
    case lifecycle
    case disposal
    case inspection
}

public enum DynamicPluginHostError: Error, Equatable, Sendable {
    case undefinedDefinition(DynamicPluginDefinitionID)
    case conflictingFingerprint(DynamicPluginDefinitionID)
    case definitionRequiresConfig(DynamicPluginDefinitionID)
    case duplicateDesiredDefinition(DynamicPluginDefinitionID)
    case invalidDeclaredWorkCount(DynamicPluginDefinitionID)
    case invalidPluginID(DynamicPluginDefinitionID, PluginID)
    case lifecycleBusy(DynamicPluginDefinitionID)
}

public enum DynamicPluginRunOutcome: Equatable, Sendable {
    case active(runID: DynamicPluginRunID, componentID: ComponentID)
    case waiting(
        runID: DynamicPluginRunID,
        componentID: ComponentID,
        missingDependencies: [ServiceDescriptor])
    case failed(
        runID: DynamicPluginRunID,
        componentID: ComponentID?,
        phase: DynamicPluginFailurePhase,
        failure: CordisFailure)
}

public struct DynamicPluginRunInspection: Equatable, Sendable {
    public let runID: DynamicPluginRunID
    public let componentID: ComponentID?
    public let lifecycle: DynamicPluginLifecycleState
    public let componentState: ComponentState?
    public let componentStateHistory: [ComponentState.Kind]
    public let missingDependencies: [ServiceDescriptor]
    public let failurePhase: DynamicPluginFailurePhase?
    public let failure: CordisFailure?

    public init(
        runID: DynamicPluginRunID,
        componentID: ComponentID?,
        lifecycle: DynamicPluginLifecycleState,
        componentState: ComponentState?,
        componentStateHistory: [ComponentState.Kind],
        missingDependencies: [ServiceDescriptor],
        failurePhase: DynamicPluginFailurePhase?,
        failure: CordisFailure?
    ) {
        self.runID = runID
        self.componentID = componentID
        self.lifecycle = lifecycle
        self.componentState = componentState
        self.componentStateHistory = componentStateHistory
        self.missingDependencies = missingDependencies
        self.failurePhase = failurePhase
        self.failure = failure
    }
}

public struct DynamicPluginInspection: Equatable, Sendable {
    public let definitionID: DynamicPluginDefinitionID
    public let pluginID: PluginID
    public let fingerprint: DynamicPluginDefinitionFingerprint
    public let lifecycle: DynamicPluginLifecycleState
    public let currentRunID: DynamicPluginRunID?
    public let currentComponentID: ComponentID?
    public let currentComponentState: ComponentState?
    public let currentComponentStateHistory: [ComponentState.Kind]
    public let missingDependencies: [ServiceDescriptor]
    public let declaredWorkCount: Int
    public let retainedRuns: [DynamicPluginRunInspection]
    public let lastFailurePhase: DynamicPluginFailurePhase?
    public let cleanupAnomalies: [CordisFailure]
    public let cordisCleanupFailures: [CleanupFailure]

    public init(
        definitionID: DynamicPluginDefinitionID,
        pluginID: PluginID,
        fingerprint: DynamicPluginDefinitionFingerprint,
        lifecycle: DynamicPluginLifecycleState,
        currentRunID: DynamicPluginRunID?,
        currentComponentID: ComponentID?,
        currentComponentState: ComponentState?,
        currentComponentStateHistory: [ComponentState.Kind],
        missingDependencies: [ServiceDescriptor],
        declaredWorkCount: Int,
        retainedRuns: [DynamicPluginRunInspection],
        lastFailurePhase: DynamicPluginFailurePhase?,
        cleanupAnomalies: [CordisFailure],
        cordisCleanupFailures: [CleanupFailure]
    ) {
        self.definitionID = definitionID
        self.pluginID = pluginID
        self.fingerprint = fingerprint
        self.lifecycle = lifecycle
        self.currentRunID = currentRunID
        self.currentComponentID = currentComponentID
        self.currentComponentState = currentComponentState
        self.currentComponentStateHistory = currentComponentStateHistory
        self.missingDependencies = missingDependencies
        self.declaredWorkCount = declaredWorkCount
        self.retainedRuns = retainedRuns
        self.lastFailurePhase = lastFailurePhase
        self.cleanupAnomalies = cleanupAnomalies
        self.cordisCleanupFailures = cordisCleanupFailures
    }
}

public struct DynamicPluginReconcileReport: Equatable, Sendable {
    public let outcomes: [DynamicPluginDefinitionID: DynamicPluginRunOutcome]
    public let operationFailures: [DynamicPluginDefinitionID: CordisFailure]
    public let removedDefinitionIDs: [DynamicPluginDefinitionID]

    public init(
        outcomes: [DynamicPluginDefinitionID: DynamicPluginRunOutcome],
        operationFailures: [DynamicPluginDefinitionID: CordisFailure],
        removedDefinitionIDs: [DynamicPluginDefinitionID]
    ) {
        self.outcomes = outcomes
        self.operationFailures = operationFailures
        self.removedDefinitionIDs = removedDefinitionIDs
    }
}

/// Hosts trusted in-memory definitions without loading package code into the Swift process.
public actor DynamicPluginHost {
    private final class RunRecord {
        let id: DynamicPluginRunID
        var componentID: ComponentID?
        var handle: ComponentHandle?
        var lifecycle: DynamicPluginLifecycleState = .starting
        var componentState: ComponentState?
        var history: [ComponentState.Kind] = []
        var missingDependencies: [ServiceDescriptor] = []
        var failurePhase: DynamicPluginFailurePhase?
        var failure: CordisFailure?
        var stopRequested = false
        private var completionContinuations: [AsyncStream<Void>.Continuation] = []
        private var didFinish = false

        init(id: DynamicPluginRunID) {
            self.id = id
        }

        func completionStream() -> AsyncStream<Void> {
            let (stream, continuation) = AsyncStream.makeStream(
                of: Void.self,
                bufferingPolicy: .bufferingNewest(1))
            if didFinish {
                continuation.yield()
                continuation.finish()
            } else {
                completionContinuations.append(continuation)
            }
            return stream
        }

        func finish() {
            guard didFinish == false else { return }
            didFinish = true
            for continuation in completionContinuations {
                continuation.yield()
                continuation.finish()
            }
            completionContinuations.removeAll()
        }

        var inspection: DynamicPluginRunInspection {
            DynamicPluginRunInspection(
                runID: id,
                componentID: componentID,
                lifecycle: lifecycle,
                componentState: componentState,
                componentStateHistory: history,
                missingDependencies: missingDependencies,
                failurePhase: failurePhase,
                failure: failure)
        }
    }

    private final class DefinitionRecord {
        struct DisposalBarrier {
            let token: UUID
            let run: RunRecord
            let terminalLifecycle: DynamicPluginLifecycleState
            let task: Task<DisposalResult, Never>
        }

        let trusted: TrustedDynamicPluginDefinition
        var lifecycle: DynamicPluginLifecycleState = .defined
        var current: RunRecord?
        var retainedRuns: [RunRecord] = []
        var disposalBarrier: DisposalBarrier?
        var cleanupAnomalies: [CordisFailure] = []
        var cordisCleanupFailures: [CleanupFailure] = []

        init(trusted: TrustedDynamicPluginDefinition) {
            self.trusted = trusted
        }
    }

    private struct DisposalResult: Sendable {
        let state: ComponentState?
        let history: [ComponentState.Kind]
        let cleanupFailures: [CleanupFailure]
        let anomaly: CordisFailure?
    }

    private let context: CordisContext
    private let policy: DynamicPluginHostPolicy
    private let registerComponent: @Sendable (ComponentDefinition) async throws -> ComponentHandle
    private var records: [DynamicPluginDefinitionID: DefinitionRecord] = [:]

    public init(
        context: CordisContext,
        policy: DynamicPluginHostPolicy = .standard
    ) {
        self.context = context
        self.policy = policy
        self.registerComponent = { definition in
            try await context.register(definition)
        }
    }

    package init(
        context: CordisContext,
        policy: DynamicPluginHostPolicy = .standard,
        registerComponent: @escaping @Sendable (ComponentDefinition) async throws -> ComponentHandle
    ) {
        self.context = context
        self.policy = policy
        self.registerComponent = registerComponent
    }

    @discardableResult
    public func define(_ trusted: TrustedDynamicPluginDefinition) throws -> Bool {
        try validate(trusted)
        if let existing = records[trusted.id] {
            guard existing.trusted.fingerprint == trusted.fingerprint,
                  existing.trusted.plugin.id == trusted.plugin.id else {
                throw DynamicPluginHostError.conflictingFingerprint(trusted.id)
            }
            return false
        }
        records[trusted.id] = DefinitionRecord(trusted: trusted)
        return true
    }

    public func run(_ id: DynamicPluginDefinitionID) async throws -> DynamicPluginRunOutcome {
        guard let record = records[id] else {
            throw DynamicPluginHostError.undefinedDefinition(id)
        }
        guard record.disposalBarrier == nil else {
            throw DynamicPluginHostError.lifecycleBusy(id)
        }
        if let current = record.current {
            switch record.lifecycle {
            case .waiting, .active, .failed:
                return await observeOutcome(record: record, run: current)
            case .starting, .stopping:
                throw DynamicPluginHostError.lifecycleBusy(id)
            case .defined, .stopped, .undefined:
                break
            }
        }
        guard record.lifecycle != .stopping else {
            throw DynamicPluginHostError.lifecycleBusy(id)
        }

        let run = RunRecord(id: DynamicPluginRunID())
        record.current = run
        record.lifecycle = .starting
        appendRun(run, to: record)

        let definition: ComponentDefinition
        do {
            definition = try record.trusted.plugin.makeDefinition(config: nil)
        } catch {
            return failWithoutHandle(
                record: record,
                run: run,
                phase: .definitionFactory,
                failure: CordisFailure(error))
        }
        run.componentID = definition.id
        let identityIsFresh = record.retainedRuns.dropLast().allSatisfy { $0.componentID != definition.id }
        guard identityIsFresh else {
            return failWithoutHandle(
                record: record,
                run: run,
                phase: .componentRegistration,
                failure: CordisFailure("trusted definition factory reused a retained component identity"))
        }

        let handle: ComponentHandle
        do {
            handle = try await registerComponent(definition)
        } catch {
            if run.stopRequested {
                removeCurrentIfOwned(run, from: record)
                run.lifecycle = .stopped
                record.lifecycle = .stopped
                let outcome = lifecycleFailure(
                    run: run,
                    message: "run stopped during failed component registration")
                run.finish()
                return outcome
            }
            return failWithoutHandle(
                record: record,
                run: run,
                phase: .componentRegistration,
                failure: CordisFailure(error))
        }

        if run.stopRequested {
            run.handle = handle
            record.current = nil
            let outcome = lifecycleFailure(
                run: run,
                message: "run stopped during component registration")
            let barrier = makeDisposalBarrier(
                handle: handle,
                run: run,
                terminalLifecycle: .stopped)
            record.disposalBarrier = barrier
            let result = await barrier.task.value
            finishDisposal(
                id: id,
                record: record,
                barrier: barrier,
                result: result)
            return outcome
        }
        guard record.current === run, record.lifecycle == .starting else {
            await disposeStaleHandle(handle, record: record, run: run)
            run.finish()
            return lifecycleFailure(run: run, message: "run lost ownership before settlement")
        }
        run.handle = handle

        let settled: ComponentState
        do {
            settled = try await handle.awaitSettled()
        } catch {
            return await failAndDispose(
                id: id,
                record: record,
                run: run,
                handle: handle,
                phase: .activation,
                failure: CordisFailure(error))
        }

        guard record.current === run else {
            await captureHandleState(handle, record: record, run: run)
            return lifecycleFailure(run: run, message: "run stopped during settlement")
        }
        return await outcome(for: settled, record: record, run: run)
    }

    public func stop(_ id: DynamicPluginDefinitionID) async {
        guard let record = records[id] else { return }
        if let barrier = record.disposalBarrier {
            let result = await barrier.task.value
            finishDisposal(
                id: id,
                record: record,
                barrier: barrier,
                result: result)
            return
        }
        guard let run = record.current else {
            if record.lifecycle != .undefined { record.lifecycle = .stopped }
            return
        }

        record.current = nil
        record.lifecycle = .stopping
        run.lifecycle = .stopping
        guard let handle = run.handle else {
            run.stopRequested = true
            record.current = run
            var iterator = run.completionStream().makeAsyncIterator()
            _ = await iterator.next()
            return
        }

        let barrier = makeDisposalBarrier(
            handle: handle,
            run: run,
            terminalLifecycle: .stopped)
        record.disposalBarrier = barrier
        let result = await barrier.task.value
        finishDisposal(
            id: id,
            record: record,
            barrier: barrier,
            result: result)
    }

    public func undefine(_ id: DynamicPluginDefinitionID) async {
        guard let record = records[id] else { return }
        await stop(id)
        guard records[id] === record,
              record.disposalBarrier == nil,
              record.current == nil else { return }
        record.lifecycle = .undefined
        records.removeValue(forKey: id)
    }

    public func inspect(_ id: DynamicPluginDefinitionID) async -> DynamicPluginInspection? {
        guard let record = records[id] else { return nil }
        if let current = record.current {
            _ = await observeOutcome(record: record, run: current)
        }
        return makeInspection(record)
    }

    public func inspectAll() async -> [DynamicPluginInspection] {
        var snapshots: [DynamicPluginInspection] = []
        for id in records.keys.sorted() {
            if let snapshot = await inspect(id) { snapshots.append(snapshot) }
        }
        return snapshots
    }

    public func reconcile(
        desired: [TrustedDynamicPluginDefinition]
    ) async throws -> DynamicPluginReconcileReport {
        var desiredByID: [DynamicPluginDefinitionID: TrustedDynamicPluginDefinition] = [:]
        for definition in desired {
            guard desiredByID[definition.id] == nil else {
                throw DynamicPluginHostError.duplicateDesiredDefinition(definition.id)
            }
            try validate(definition)
            if let existing = records[definition.id],
               existing.trusted.fingerprint != definition.fingerprint
                    || existing.trusted.plugin.id != definition.plugin.id {
                throw DynamicPluginHostError.conflictingFingerprint(definition.id)
            }
            desiredByID[definition.id] = definition
        }

        for definition in desired {
            _ = try define(definition)
        }

        var outcomes: [DynamicPluginDefinitionID: DynamicPluginRunOutcome] = [:]
        var operationFailures: [DynamicPluginDefinitionID: CordisFailure] = [:]
        for id in desiredByID.keys.sorted() {
            do {
                outcomes[id] = try await run(id)
            } catch {
                operationFailures[id] = CordisFailure(error)
            }
        }

        let undesired = records.keys.filter { desiredByID[$0] == nil }.sorted()
        for id in undesired { await undefine(id) }
        return DynamicPluginReconcileReport(
            outcomes: outcomes,
            operationFailures: operationFailures,
            removedDefinitionIDs: undesired)
    }

    private func outcome(
        for state: ComponentState,
        record: DefinitionRecord,
        run: RunRecord
    ) async -> DynamicPluginRunOutcome {
        run.componentState = state
        guard let componentID = run.componentID else {
            return markFailed(
                record: record,
                run: run,
                phase: .componentRegistration,
                failure: CordisFailure("registered run has no component identity"))
        }
        switch state {
        case .pending:
            let missing = await missingDependencies(for: componentID, record: record)
            await captureHandleState(run.handle, record: record, run: run)
            guard records[record.trusted.id] === record,
                  record.current === run,
                  record.disposalBarrier == nil else {
                return lifecycleFailure(run: run, message: "waiting observation lost ownership")
            }
            run.lifecycle = .waiting
            record.lifecycle = .waiting
            run.missingDependencies = missing
            return .waiting(
                runID: run.id,
                componentID: componentID,
                missingDependencies: missing)
        case .active:
            await captureHandleState(run.handle, record: record, run: run)
            guard records[record.trusted.id] === record,
                  record.current === run,
                  record.disposalBarrier == nil else {
                return lifecycleFailure(run: run, message: "active observation lost ownership")
            }
            run.lifecycle = .active
            record.lifecycle = .active
            run.missingDependencies = []
            return .active(runID: run.id, componentID: componentID)
        case .failed(_, let failure):
            guard let handle = run.handle else {
                removeCurrentIfOwned(run, from: record)
                return markFailed(record: record, run: run, phase: .activation, failure: failure)
            }
            return await failAndDispose(
                id: record.trusted.id,
                record: record,
                run: run,
                handle: handle,
                phase: .activation,
                failure: failure)
        case .disposed:
            removeCurrentIfOwned(run, from: record)
            run.lifecycle = .stopped
            record.lifecycle = .stopped
            await captureHandleState(run.handle, record: record, run: run)
            return lifecycleFailure(run: run, message: "component was disposed before activation")
        case .loading, .unloading:
            return lifecycleFailure(run: run, message: "component did not settle")
        }
    }

    private func observeOutcome(
        record: DefinitionRecord,
        run: RunRecord
    ) async -> DynamicPluginRunOutcome {
        guard let handle = run.handle, run.componentID != nil else {
            return lifecycleFailure(run: run, message: "run has not registered a component")
        }
        do {
            let state = try await handle.awaitSettled()
            guard record.current === run else {
                await captureHandleState(handle, record: record, run: run)
                return lifecycleFailure(run: run, message: "run no longer owns the definition")
            }
            return await outcome(for: state, record: record, run: run)
        } catch {
            removeCurrentIfOwned(run, from: record)
            appendDiagnostic(CordisFailure(error), to: &record.cleanupAnomalies)
            return markFailed(
                record: record,
                run: run,
                phase: .inspection,
                failure: CordisFailure(error))
        }
    }

    private func failWithoutHandle(
        record: DefinitionRecord,
        run: RunRecord,
        phase: DynamicPluginFailurePhase,
        failure: CordisFailure
    ) -> DynamicPluginRunOutcome {
        let owned = record.current === run
        removeCurrentIfOwned(run, from: record)
        let outcome = markFailed(record: record, run: run, phase: phase, failure: failure)
        if owned, record.current == nil, record.disposalBarrier == nil {
            record.lifecycle = .failed
        }
        return outcome
    }

    private func markFailed(
        record: DefinitionRecord,
        run: RunRecord,
        phase: DynamicPluginFailurePhase,
        failure: CordisFailure
    ) -> DynamicPluginRunOutcome {
        run.lifecycle = .failed
        run.failurePhase = phase
        run.failure = failure
        if record.current === run, record.disposalBarrier == nil {
            record.lifecycle = .failed
        }
        return .failed(
            runID: run.id,
            componentID: run.componentID,
            phase: phase,
            failure: failure)
    }

    private func lifecycleFailure(
        run: RunRecord,
        message: String
    ) -> DynamicPluginRunOutcome {
        let failure = CordisFailure(message)
        run.failurePhase = .lifecycle
        run.failure = failure
        return .failed(
            runID: run.id,
            componentID: run.componentID,
            phase: .lifecycle,
            failure: failure)
    }

    private func removeCurrentIfOwned(_ run: RunRecord, from record: DefinitionRecord) {
        if record.current === run { record.current = nil }
    }

    private func disposeStaleHandle(
        _ handle: ComponentHandle,
        record: DefinitionRecord,
        run: RunRecord
    ) async {
        let barrier = makeDisposalBarrier(
            handle: handle,
            run: run,
            terminalLifecycle: .stopped)
        let result = await barrier.task.value
        apply(result, to: run, record: record)
        run.handle = nil
        run.lifecycle = .stopped
    }

    private func failAndDispose(
        id: DynamicPluginDefinitionID,
        record: DefinitionRecord,
        run: RunRecord,
        handle: ComponentHandle,
        phase: DynamicPluginFailurePhase,
        failure: CordisFailure
    ) async -> DynamicPluginRunOutcome {
        removeCurrentIfOwned(run, from: record)
        record.lifecycle = .stopping
        run.lifecycle = .stopping
        run.failurePhase = phase
        run.failure = failure
        let barrier = makeDisposalBarrier(
            handle: handle,
            run: run,
            terminalLifecycle: .failed)
        record.disposalBarrier = barrier
        let result = await barrier.task.value
        finishDisposal(
            id: id,
            record: record,
            barrier: barrier,
            result: result)
        return .failed(
            runID: run.id,
            componentID: run.componentID,
            phase: phase,
            failure: failure)
    }

    private func makeDisposalBarrier(
        handle: ComponentHandle,
        run: RunRecord,
        terminalLifecycle: DynamicPluginLifecycleState
    ) -> DefinitionRecord.DisposalBarrier {
        DefinitionRecord.DisposalBarrier(
            token: UUID(),
            run: run,
            terminalLifecycle: terminalLifecycle,
            task: Task {
            var anomaly: CordisFailure?
            do {
                try await handle.dispose()
            } catch {
                anomaly = CordisFailure(error)
            }
            let state: ComponentState?
            let history: [ComponentState.Kind]
            let cleanupFailures: [CleanupFailure]
            do {
                state = try await handle.state
                history = try await handle.stateHistory
                cleanupFailures = try await handle.cleanupFailures
            } catch {
                return DisposalResult(
                    state: nil,
                    history: [],
                    cleanupFailures: [],
                    anomaly: anomaly ?? CordisFailure(error))
            }
            return DisposalResult(
                state: state,
                history: history,
                cleanupFailures: cleanupFailures,
                anomaly: anomaly)
        })
    }

    private func finishDisposal(
        id: DynamicPluginDefinitionID,
        record: DefinitionRecord,
        barrier: DefinitionRecord.DisposalBarrier,
        result: DisposalResult
    ) {
        guard records[id] === record,
              record.disposalBarrier?.token == barrier.token else { return }
        apply(result, to: barrier.run, record: record)
        barrier.run.handle = nil
        barrier.run.lifecycle = barrier.terminalLifecycle
        record.disposalBarrier = nil
        if record.current == nil {
            record.lifecycle = barrier.terminalLifecycle
        }
        barrier.run.finish()
    }

    private func apply(
        _ result: DisposalResult,
        to run: RunRecord,
        record: DefinitionRecord
    ) {
        run.componentState = result.state
        run.history = result.history
        if let anomaly = result.anomaly {
            appendDiagnostic(anomaly, to: &record.cleanupAnomalies)
        }
        for failure in result.cleanupFailures where record.cordisCleanupFailures.contains(failure) == false {
            record.cordisCleanupFailures.append(failure)
        }
        trimDiagnostics(&record.cordisCleanupFailures)
    }

    private func captureHandleState(
        _ handle: ComponentHandle?,
        record: DefinitionRecord,
        run: RunRecord
    ) async {
        guard let handle else { return }
        do {
            run.componentState = try await handle.state
            run.history = try await handle.stateHistory
            let failures = try await handle.cleanupFailures
            for failure in failures where record.cordisCleanupFailures.contains(failure) == false {
                record.cordisCleanupFailures.append(failure)
            }
            trimDiagnostics(&record.cordisCleanupFailures)
        } catch {
            appendDiagnostic(CordisFailure(error), to: &record.cleanupAnomalies)
        }
    }

    private func missingDependencies(
        for componentID: ComponentID,
        record: DefinitionRecord
    ) async -> [ServiceDescriptor] {
        do {
            guard let diagnostic = try await context.diagnostics().first(where: { $0.componentID == componentID }) else {
                return []
            }
            switch diagnostic.reason {
            case .missingDependencies(let dependencies), .possibleDependencyCycle(let dependencies):
                return dependencies.sorted { $0.label < $1.label }
            case .failed:
                return []
            }
        } catch {
            appendDiagnostic(CordisFailure(error), to: &record.cleanupAnomalies)
            return []
        }
    }

    private func validate(_ trusted: TrustedDynamicPluginDefinition) throws {
        guard trusted.plugin.hasConfigSchema == false else {
            throw DynamicPluginHostError.definitionRequiresConfig(trusted.id)
        }
        guard trusted.declaredWorkCount >= 0 else {
            throw DynamicPluginHostError.invalidDeclaredWorkCount(trusted.id)
        }
        guard trusted.plugin.id.rawValue.hasPrefix(PluginCatalog.reservedDynamicIDPrefix) else {
            throw DynamicPluginHostError.invalidPluginID(trusted.id, trusted.plugin.id)
        }
    }

    private func appendRun(_ run: RunRecord, to record: DefinitionRecord) {
        record.retainedRuns.append(run)
        if record.retainedRuns.count > policy.maximumRetainedRunsPerDefinition {
            record.retainedRuns.removeFirst(record.retainedRuns.count - policy.maximumRetainedRunsPerDefinition)
        }
    }

    private func appendDiagnostic(_ failure: CordisFailure, to diagnostics: inout [CordisFailure]) {
        diagnostics.append(failure)
        trimDiagnostics(&diagnostics)
    }

    private func trimDiagnostics<Value>(_ diagnostics: inout [Value]) {
        if diagnostics.count > policy.maximumRetainedDiagnosticsPerDefinition {
            diagnostics.removeFirst(diagnostics.count - policy.maximumRetainedDiagnosticsPerDefinition)
        }
    }

    private func makeInspection(_ record: DefinitionRecord) -> DynamicPluginInspection {
        let current = record.current
        return DynamicPluginInspection(
            definitionID: record.trusted.id,
            pluginID: record.trusted.plugin.id,
            fingerprint: record.trusted.fingerprint,
            lifecycle: record.lifecycle,
            currentRunID: current?.id,
            currentComponentID: current?.componentID,
            currentComponentState: current?.componentState,
            currentComponentStateHistory: current?.history ?? [],
            missingDependencies: current?.missingDependencies ?? [],
            declaredWorkCount: record.trusted.declaredWorkCount,
            retainedRuns: record.retainedRuns.map(\.inspection),
            lastFailurePhase: record.retainedRuns.reversed().compactMap(\.failurePhase).first,
            cleanupAnomalies: record.cleanupAnomalies,
            cordisCleanupFailures: record.cordisCleanupFailures)
    }
}
