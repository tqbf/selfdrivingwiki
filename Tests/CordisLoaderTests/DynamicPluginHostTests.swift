import Cordis
@testable import CordisLoader
import Foundation
import Testing

private let dynamicDependencyKey = ServiceKey<String>(label: "dynamic.dependency")
private let dynamicProvidedKey = ServiceKey<Int>(label: "dynamic.provided")

@Suite("Dynamic plugin host", .serialized, .timeLimit(.minutes(1)))
struct DynamicPluginHostTests {
    @Test("define records a dormant trusted definition")
    func defineDoesNotRun() async throws {
        let activations = DynamicHostCounter()
        let context = CordisContext()
        let host = DynamicPluginHost(context: context)
        let trusted = trustedDefinition(id: "fixture", activations: activations)

        #expect(try await host.define(trusted))
        #expect(try await host.define(trusted) == false)
        #expect(await activations.value == 0)
        let inspection = try #require(await host.inspect(trusted.id))
        #expect(inspection.lifecycle == .defined)
        #expect(inspection.currentRunID == nil)
        #expect(inspection.retainedRuns.isEmpty)
        #expect(inspection.declaredWorkCount == 1)
    }

    @Test("static catalog rejects the reserved dynamic definition namespace")
    func staticCatalogRejectsDynamicDefinitionIDs() {
        let pluginID = PluginID(DynamicPluginDefinitionID("fixture").rawValue)
        #expect(throws: CordisError.reservedPluginID(pluginID)) {
            _ = try PluginCatalog([PluginDefinition(id: pluginID) {
                try ComponentDefinition(label: "forbidden") { _ in }
            }])
        }
    }

    @Test("dynamic host rejects a static plugin namespace")
    func dynamicHostRejectsStaticPluginID() async {
        let context = CordisContext()
        let host = DynamicPluginHost(context: context)
        let invalid = TrustedDynamicPluginDefinition(
            id: DynamicPluginDefinitionID("fixture"),
            fingerprint: DynamicPluginDefinitionFingerprint("fingerprint"),
            plugin: PluginDefinition(id: PluginID("static.fixture")) {
                try ComponentDefinition(label: "fixture") { _ in }
            },
            declaredWorkCount: 1)

        await #expect(throws: DynamicPluginHostError.invalidPluginID(invalid.id, invalid.plugin.id)) {
            _ = try await host.define(invalid)
        }
    }

    @Test("same definition identity rejects a conflicting fingerprint")
    func conflictingFingerprintIsRejected() async throws {
        let context = CordisContext()
        let host = DynamicPluginHost(context: context)
        let first = trustedDefinition(id: "fixture", fingerprint: "one")
        let second = trustedDefinition(id: "fixture", fingerprint: "two")

        _ = try await host.define(first)
        await #expect(throws: DynamicPluginHostError.conflictingFingerprint(first.id)) {
            _ = try await host.define(second)
        }
    }

    @Test("each stopped run creates a fresh component and run identity")
    func eachRunCreatesFreshComponentIdentity() async throws {
        let context = CordisContext()
        let host = DynamicPluginHost(context: context)
        let trusted = trustedDefinition(id: "fixture")
        _ = try await host.define(trusted)

        let first = try await host.run(trusted.id)
        let firstIdentity = try activeIdentity(first)
        await host.stop(trusted.id)
        let second = try await host.run(trusted.id)
        let secondIdentity = try activeIdentity(second)

        #expect(firstIdentity.runID != secondIdentity.runID)
        #expect(firstIdentity.componentID != secondIdentity.componentID)
        let inspection = try #require(await host.inspect(trusted.id))
        #expect(inspection.lifecycle == .active)
        #expect(inspection.retainedRuns.count == 2)
    }

    @Test("waiting run activates after dependency supply without another run")
    func waitingRunBecomesActiveWithoutNewRun() async throws {
        let context = CordisContext()
        let host = DynamicPluginHost(context: context)
        let trusted = trustedDefinition(id: "waiting", dependencies: [ServiceDependency(dynamicDependencyKey)])
        _ = try await host.define(trusted)

        let waiting = try await host.run(trusted.id)
        let waitingIdentity = try waitingIdentity(waiting)
        #expect(waitingIdentity.missingDependencies == [ServiceDependency(dynamicDependencyKey).descriptor])

        _ = try await context.supply(dynamicDependencyKey, value: "ready")
        let inspection = try #require(await host.inspect(trusted.id))
        #expect(inspection.lifecycle == .active)
        #expect(inspection.currentRunID == waitingIdentity.runID)
        #expect(inspection.currentComponentID == waitingIdentity.componentID)
        #expect(inspection.retainedRuns.count == 1)
    }

    @Test("stops during registration await exact handle disposal")
    func stopsDuringRegistrationAwaitExactHandleDisposal() async throws {
        let registrationGate = DynamicHostGate()
        let cleanupGate = DynamicHostGate()
        let context = CordisContext()
        let host = DynamicPluginHost(context: context) { definition in
            let handle = try await context.register(definition)
            _ = try await handle.awaitSettled()
            await registrationGate.arriveAndWait()
            return handle
        }
        let trusted = trustedDefinition(id: "registration-race", cleanupGate: cleanupGate)
        _ = try await host.define(trusted)

        let runTask = Task { try await host.run(trusted.id) }
        await registrationGate.waitForArrival()
        // `run` reports `lifecycleBusy` for `.starting` as well as `.stopping`,
        // so it cannot prove a stop reached the host. Await stop admission
        // directly instead of assuming the stop tasks were scheduled first.
        let stopAdmitted = DynamicHostGate()
        await host.setStopAdmittedObserverForTesting { _ in stopAdmitted.signalArrival() }
        let firstStop = Task { await host.stop(trusted.id) }
        let secondStop = Task { await host.stop(trusted.id) }
        await #expect(throws: DynamicPluginHostError.lifecycleBusy(trusted.id)) {
            _ = try await host.run(trusted.id)
        }
        await stopAdmitted.waitForArrival()
        let stopping = try #require(await host.inspect(trusted.id))
        #expect(stopping.lifecycle == .stopping)
        #expect(stopping.currentComponentID != nil)

        await registrationGate.open()
        await cleanupGate.waitForArrival()
        let lateStopCompleted = DynamicHostCounter()
        let lateStop = Task {
            await host.stop(trusted.id)
            await lateStopCompleted.increment()
        }
        await Task.yield()
        #expect(await lateStopCompleted.value == 0)

        await cleanupGate.open()
        guard case .failed(let runID, let componentID, let phase, _) = try await runTask.value else {
            Issue.record("expected a lifecycle failure after registration stop")
            return
        }
        #expect(componentID != nil)
        #expect(phase == .lifecycle)
        await firstStop.value
        await secondStop.value
        await lateStop.value

        let stopped = try #require(await host.inspect(trusted.id))
        #expect(stopped.lifecycle == .stopped)
        #expect(stopped.currentRunID == nil)
        let retained = try #require(stopped.retainedRuns.first { $0.runID == runID })
        #expect(retained.lifecycle == .stopped)
        #expect(retained.componentState?.kind == .disposed)
        #expect(retained.componentStateHistory.contains(.disposed))
        #expect(try await context.find(dynamicProvidedKey) == nil)
    }

    @Test("stop during activation prevents late ownership commit")
    func lateActivationCannotCommitAfterStop() async throws {
        let gate = DynamicHostGate()
        let context = CordisContext()
        let host = DynamicPluginHost(context: context)
        let trusted = TrustedDynamicPluginDefinition(
            id: DynamicPluginDefinitionID("activation-race"),
            fingerprint: DynamicPluginDefinitionFingerprint("fingerprint"),
            plugin: PluginDefinition(
                id: PluginID("dynamic:activation-race"),
                provisions: [ServiceDependency(dynamicProvidedKey)]) {
                    try ComponentDefinition(
                        label: "activation race",
                        provisions: [ServiceDependency(dynamicProvidedKey)]) { activation in
                            await gate.arriveAndWait()
                            _ = try await activation.supply(dynamicProvidedKey, value: 1)
                        }
                },
            declaredWorkCount: 1)
        _ = try await host.define(trusted)

        let runTask = Task { try await host.run(trusted.id) }
        await gate.waitForArrival()
        let stopTask = Task { await host.stop(trusted.id) }
        await gate.open()
        _ = try await runTask.value
        await stopTask.value

        let inspection = try #require(await host.inspect(trusted.id))
        #expect(inspection.lifecycle == .stopped)
        #expect(inspection.currentRunID == nil)
        #expect(try await context.find(dynamicProvidedKey) == nil)
    }

    @Test("failed activation disposes component and retains failure")
    func failedRunDisposesComponent() async throws {
        let context = CordisContext()
        let host = DynamicPluginHost(context: context)
        let trusted = trustedDefinition(id: "failure", failsActivation: true)
        _ = try await host.define(trusted)

        let outcome = try await host.run(trusted.id)
        guard case .failed(let runID, let componentID, let phase, _) = outcome else {
            Issue.record("expected a failed run")
            return
        }
        #expect(componentID != nil)
        #expect(phase == .activation)
        let inspection = try #require(await host.inspect(trusted.id))
        #expect(inspection.lifecycle == .failed)
        #expect(inspection.currentRunID == nil)
        #expect(inspection.lastFailurePhase == .activation)
        let run = try #require(inspection.retainedRuns.first { $0.runID == runID })
        #expect(run.componentState?.kind == .disposed)
    }

    @Test("stop during failed activation rollback wins without stale failure commit")
    func stopDuringFailedActivationRollbackWins() async throws {
        let cleanupGate = DynamicHostGate()
        let attempts = DynamicHostCounter()
        let context = CordisContext()
        let host = DynamicPluginHost(context: context)
        let trusted = TrustedDynamicPluginDefinition(
            id: DynamicPluginDefinitionID("failed-barrier"),
            fingerprint: DynamicPluginDefinitionFingerprint("fingerprint"),
            plugin: PluginDefinition(id: PluginID("dynamic:failed-barrier")) {
                try ComponentDefinition(label: "failed barrier") { activation in
                    await attempts.increment()
                    if await attempts.value == 1 {
                        _ = try await activation.effect { _ in
                            await cleanupGate.arriveAndWait()
                        }
                        throw DynamicHostExpectedError.activation
                    }
                }
            },
            declaredWorkCount: 1)
        _ = try await host.define(trusted)

        let failedRun = Task { try await host.run(trusted.id) }
        await cleanupGate.waitForArrival()
        // The rollback is parked in its cleanup effect, so the record still
        // reads `.starting` and `run` would report `lifecycleBusy` even if no
        // stop had been admitted. Await admission before asserting the state.
        let stopAdmitted = DynamicHostGate()
        await host.setStopAdmittedObserverForTesting { _ in stopAdmitted.signalArrival() }
        let joinedStop = Task { await host.stop(trusted.id) }
        await #expect(throws: DynamicPluginHostError.lifecycleBusy(trusted.id)) {
            _ = try await host.run(trusted.id)
        }
        await stopAdmitted.waitForArrival()
        let nonAdmitting = try #require(await host.inspect(trusted.id))
        #expect(nonAdmitting.lifecycle == .stopping || nonAdmitting.lifecycle == .stopped)
        #expect(nonAdmitting.currentRunID == nil)

        await cleanupGate.open()
        guard case .failed(let stoppedRunID, _, let phase, _) = try await failedRun.value else {
            Issue.record("expected a terminal run outcome")
            return
        }
        #expect(phase == .lifecycle)
        await joinedStop.value
        let stopped = try #require(await host.inspect(trusted.id))
        #expect(stopped.lifecycle == .stopped)
        let retainedRun = try #require(stopped.retainedRuns.first { $0.runID == stoppedRunID })
        #expect(retainedRun.lifecycle == .stopped)
        #expect(retainedRun.componentState?.kind == .disposed)
        #expect(retainedRun.failurePhase == .lifecycle)
        _ = try activeIdentity(try await host.run(trusted.id))
        let active = try #require(await host.inspect(trusted.id))
        #expect(active.lifecycle == .active)
    }

    @Test("stopping a waiting run prevents later activation")
    func stoppingWaitingRunPreventsActivation() async throws {
        let activations = DynamicHostCounter()
        let context = CordisContext()
        let host = DynamicPluginHost(context: context)
        let trusted = trustedDefinition(
            id: "waiting-stop",
            dependencies: [ServiceDependency(dynamicDependencyKey)],
            activations: activations)
        _ = try await host.define(trusted)
        _ = try await host.run(trusted.id)

        await host.stop(trusted.id)
        _ = try await context.supply(dynamicDependencyKey, value: "late")

        #expect(await activations.value == 0)
        let inspection = try #require(await host.inspect(trusted.id))
        #expect(inspection.lifecycle == .stopped)
        #expect(inspection.currentRunID == nil)
    }

    @Test("stop disposes effects once and withdraws staged supplies")
    func stopIsIdempotentAndRetainsDefinition() async throws {
        let cleanups = DynamicHostCounter()
        let context = CordisContext()
        let host = DynamicPluginHost(context: context)
        let trusted = trustedDefinition(id: "cleanup", cleanups: cleanups)
        _ = try await host.define(trusted)
        _ = try await host.run(trusted.id)

        await host.stop(trusted.id)
        await host.stop(trusted.id)

        #expect(await cleanups.value == 1)
        #expect(try await context.find(dynamicProvidedKey) == nil)
        let inspection = try #require(await host.inspect(trusted.id))
        #expect(inspection.lifecycle == .stopped)
        #expect(inspection.currentRunID == nil)
        #expect(inspection.retainedRuns.last?.lifecycle == .stopped)
    }

    @Test("concurrent stops share one disposal barrier and block new runs")
    func concurrentStopsShareBarrier() async throws {
        let cleanupGate = DynamicHostGate()
        let context = CordisContext()
        let host = DynamicPluginHost(context: context)
        let trusted = trustedDefinition(id: "stop-barrier", cleanupGate: cleanupGate)
        _ = try await host.define(trusted)
        let firstIdentity = try activeIdentity(try await host.run(trusted.id))

        let firstStop = Task { await host.stop(trusted.id) }
        await cleanupGate.waitForArrival()
        let secondStop = Task { await host.stop(trusted.id) }
        await #expect(throws: DynamicPluginHostError.lifecycleBusy(trusted.id)) {
            _ = try await host.run(trusted.id)
        }
        let stopping = try #require(await host.inspect(trusted.id))
        #expect(stopping.lifecycle == .stopping)

        await cleanupGate.open()
        await firstStop.value
        await secondStop.value
        let stopped = try #require(await host.inspect(trusted.id))
        let retained = try #require(stopped.retainedRuns.first { $0.runID == firstIdentity.runID })
        #expect(retained.lifecycle == .stopped)
        #expect(retained.componentState?.kind == .disposed)
        #expect(retained.componentStateHistory.contains(.disposed))
        let next = try await host.run(trusted.id)
        _ = try activeIdentity(next)
        let active = try #require(await host.inspect(trusted.id))
        #expect(active.lifecycle == .active)
    }

    @Test("undefine stops and removes retained host state")
    func undefineRemovesDefinition() async throws {
        let context = CordisContext()
        let host = DynamicPluginHost(context: context)
        let trusted = trustedDefinition(id: "fixture")
        _ = try await host.define(trusted)
        _ = try await host.run(trusted.id)

        await host.undefine(trusted.id)
        await host.undefine(trusted.id)

        #expect(await host.inspect(trusted.id) == nil)
        await #expect(throws: DynamicPluginHostError.undefinedDefinition(trusted.id)) {
            _ = try await host.run(trusted.id)
        }
    }

    @Test("concurrent undefine blocks redefine until disposal completes")
    func concurrentUndefineBlocksRedefine() async throws {
        let cleanupGate = DynamicHostGate()
        let context = CordisContext()
        let host = DynamicPluginHost(context: context)
        let trusted = trustedDefinition(id: "undefine-barrier", cleanupGate: cleanupGate)
        _ = try await host.define(trusted)
        _ = try await host.run(trusted.id)

        let first = Task { await host.undefine(trusted.id) }
        await cleanupGate.waitForArrival()
        let second = Task { await host.undefine(trusted.id) }
        #expect(try await host.define(trusted) == false)
        await #expect(throws: DynamicPluginHostError.lifecycleBusy(trusted.id)) {
            _ = try await host.run(trusted.id)
        }

        await cleanupGate.open()
        await first.value
        await second.value
        #expect(await host.inspect(trusted.id) == nil)
        #expect(try await host.define(trusted))
        _ = try activeIdentity(try await host.run(trusted.id))
    }

    @Test("cleanup failures remain visible without retrying consumed effects")
    func cleanupFailuresRemainVisible() async throws {
        let cleanups = DynamicHostCounter()
        let context = CordisContext()
        let host = DynamicPluginHost(context: context)
        let trusted = trustedDefinition(id: "cleanup-failure", cleanups: cleanups, failsCleanup: true)
        _ = try await host.define(trusted)
        _ = try await host.run(trusted.id)

        await host.stop(trusted.id)
        await host.stop(trusted.id)

        #expect(await cleanups.value == 1)
        let inspection = try #require(await host.inspect(trusted.id))
        #expect(inspection.cleanupAnomalies.count == 1)
        #expect(inspection.cordisCleanupFailures.count == 1)
    }

    @Test("retained run history obeys host policy")
    func retainedRunDiagnosticsStayWithinPolicy() async throws {
        let context = CordisContext()
        let host = DynamicPluginHost(
            context: context,
            policy: DynamicPluginHostPolicy(
                maximumRetainedRunsPerDefinition: 2,
                maximumRetainedDiagnosticsPerDefinition: 2))
        let trusted = trustedDefinition(id: "bounded")
        _ = try await host.define(trusted)

        for _ in 0 ..< 4 {
            _ = try await host.run(trusted.id)
            await host.stop(trusted.id)
        }

        let inspection = try #require(await host.inspect(trusted.id))
        #expect(inspection.retainedRuns.count == 2)
        #expect(inspection.retainedRuns.allSatisfy { $0.lifecycle == .stopped })
    }

    @Test("stop and run churn reports Cordis disposed-record growth")
    func stopRunChurnReportsDisposedRecordGrowth() async throws {
        let cycleCount = 4
        let context = CordisContext()
        let host = DynamicPluginHost(
            context: context,
            policy: DynamicPluginHostPolicy(
                maximumRetainedRunsPerDefinition: 2,
                maximumRetainedDiagnosticsPerDefinition: 2))
        let trusted = trustedDefinition(id: "churn")
        _ = try await host.define(trusted)

        for _ in 0 ..< cycleCount {
            _ = try await host.run(trusted.id)
            await host.stop(trusted.id)
        }

        let scope = try await context.scopeDiagnostics()
        #expect(scope.activeRegistrationCount == 0)
        #expect(scope.retainedComponentRecordCount == cycleCount)
        let inspection = try #require(await host.inspect(trusted.id))
        #expect(inspection.retainedRuns.count == 2)
    }

    @Test("reconcile validates desired definitions before mutation")
    func reconcileValidatesBeforeMutation() async throws {
        let context = CordisContext()
        let host = DynamicPluginHost(context: context)
        let existing = trustedDefinition(id: "existing", fingerprint: "one")
        _ = try await host.define(existing)
        _ = try await host.run(existing.id)
        let conflict = trustedDefinition(id: "existing", fingerprint: "two")
        let new = trustedDefinition(id: "new")

        await #expect(throws: DynamicPluginHostError.conflictingFingerprint(existing.id)) {
            _ = try await host.reconcile(desired: [new, conflict])
        }

        let snapshots = await host.inspectAll()
        #expect(snapshots.map(\.definitionID) == [existing.id])
        #expect(snapshots.first?.lifecycle == .active)
    }

    @Test("reconcile rejects every invalid desired definition before mutation")
    func reconcileFullyPrevalidatesDesiredDefinitions() async throws {
        let context = CordisContext()
        let host = DynamicPluginHost(context: context)
        let valid = trustedDefinition(id: "valid-new")
        let invalidBase = trustedDefinition(id: "invalid-new")
        let invalid = TrustedDynamicPluginDefinition(
            id: invalidBase.id,
            fingerprint: invalidBase.fingerprint,
            plugin: invalidBase.plugin,
            declaredWorkCount: -1)

        await #expect(throws: DynamicPluginHostError.invalidDeclaredWorkCount(invalid.id)) {
            _ = try await host.reconcile(desired: [valid, invalid])
        }

        #expect(await host.inspect(valid.id) == nil)
        #expect(await host.inspect(invalid.id) == nil)
    }

    @Test("public inspection contracts contain no source or loader surface")
    func publicContractsAreSourceFree() throws {
        let sourceURL = repositoryRoot().appendingPathComponent("Sources/CordisLoader/DynamicPluginHost.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let trusted = try declaration(named: "public struct TrustedDynamicPluginDefinition", in: source)
        let inspection = try declaration(named: "public struct DynamicPluginInspection", in: source)
        for forbidden in ["source:", "path:", "url:", "module:", "sharedLibrary:", "config:"] {
            #expect(trusted.localizedCaseInsensitiveContains(forbidden) == false)
            #expect(inspection.localizedCaseInsensitiveContains(forbidden) == false)
        }
    }

    @Test("inspection contains identity and lifecycle data without source input")
    func inspectionIsSourceFree() async throws {
        let context = CordisContext()
        let host = DynamicPluginHost(context: context)
        let trusted = trustedDefinition(id: "source-free", fingerprint: "revision-fingerprint")
        _ = try await host.define(trusted)
        _ = try await host.run(trusted.id)

        let inspection = try #require(await host.inspect(trusted.id))
        #expect(inspection.definitionID == trusted.id)
        #expect(inspection.pluginID == trusted.plugin.id)
        #expect(inspection.fingerprint == trusted.fingerprint)
        #expect(inspection.currentComponentState?.kind == .active)
        #expect(inspection.currentComponentStateHistory.contains(.active))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func declaration(named marker: String, in source: String) throws -> String {
        guard let start = source.range(of: marker)?.lowerBound else {
            throw DynamicHostExpectedError.outcome
        }
        var depth = 0
        var foundOpeningBrace = false
        var index = start
        while index < source.endIndex {
            let character = source[index]
            if character == "{" {
                foundOpeningBrace = true
                depth += 1
            } else if character == "}" {
                depth -= 1
                if foundOpeningBrace, depth == 0 {
                    return String(source[start ... index])
                }
            }
            index = source.index(after: index)
        }
        throw DynamicHostExpectedError.outcome
    }

    private func trustedDefinition(
        id: String,
        fingerprint: String = "fingerprint",
        dependencies: [ServiceDependency] = [],
        activations: DynamicHostCounter? = nil,
        cleanups: DynamicHostCounter? = nil,
        cleanupGate: DynamicHostGate? = nil,
        failsActivation: Bool = false,
        failsCleanup: Bool = false
    ) -> TrustedDynamicPluginDefinition {
        let pluginID = PluginID("dynamic:\(id)")
        return TrustedDynamicPluginDefinition(
            id: DynamicPluginDefinitionID(id),
            fingerprint: DynamicPluginDefinitionFingerprint(fingerprint),
            plugin: PluginDefinition(
                id: pluginID,
                dependencies: dependencies,
                provisions: failsActivation ? [] : [ServiceDependency(dynamicProvidedKey)]) {
                    try ComponentDefinition(
                        label: id,
                        dependencies: dependencies,
                        provisions: failsActivation ? [] : [ServiceDependency(dynamicProvidedKey)]) { activation in
                            if let activations { await activations.increment() }
                            if failsActivation { throw DynamicHostExpectedError.activation }
                            _ = try await activation.supply(dynamicProvidedKey, value: 1)
                            if cleanups != nil || cleanupGate != nil || failsCleanup {
                                _ = try await activation.effect { _ in
                                    if let cleanupGate { await cleanupGate.arriveAndWait() }
                                    if let cleanups { await cleanups.increment() }
                                    if failsCleanup { throw DynamicHostExpectedError.cleanup }
                                }
                            }
                        }
                },
            declaredWorkCount: 1)
    }

    private func activeIdentity(
        _ outcome: DynamicPluginRunOutcome
    ) throws -> (runID: DynamicPluginRunID, componentID: ComponentID) {
        guard case .active(let runID, let componentID) = outcome else {
            throw DynamicHostExpectedError.outcome
        }
        return (runID, componentID)
    }

    private func waitingIdentity(
        _ outcome: DynamicPluginRunOutcome
    ) throws -> (
        runID: DynamicPluginRunID,
        componentID: ComponentID,
        missingDependencies: [ServiceDescriptor]
    ) {
        guard case .waiting(let runID, let componentID, let missingDependencies) = outcome else {
            throw DynamicHostExpectedError.outcome
        }
        return (runID, componentID, missingDependencies)
    }
}

private actor DynamicHostCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private actor DynamicHostGate {
    private let arrivalStream: AsyncStream<Void>
    private let arrivalContinuation: AsyncStream<Void>.Continuation
    private let openStream: AsyncStream<Void>
    private let openContinuation: AsyncStream<Void>.Continuation

    init() {
        (arrivalStream, arrivalContinuation) = AsyncStream.makeStream(of: Void.self)
        (openStream, openContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    func arriveAndWait() async {
        arrivalContinuation.yield()
        arrivalContinuation.finish()
        var iterator = openStream.makeAsyncIterator()
        _ = await iterator.next()
    }

    /// Records an arrival without blocking the caller. Used by observation
    /// seams that must not suspend the operation they report on.
    nonisolated func signalArrival() {
        arrivalContinuation.yield()
        arrivalContinuation.finish()
    }

    func waitForArrival() async {
        var iterator = arrivalStream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func open() {
        openContinuation.yield()
        openContinuation.finish()
    }
}

private enum DynamicHostExpectedError: Error {
    case activation
    case cleanup
    case outcome
}
