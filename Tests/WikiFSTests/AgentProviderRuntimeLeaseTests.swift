import Foundation
import Synchronization
import Testing
@testable import WikiFSCore
@testable import WikiFSEngine

/// Summarizer snapshot ownership of the package-runner staging lease
/// (issue #1279 Phase 2 + 5): unique pre-created directories per snapshot,
/// teardown only after cached backends shut down, no lease for non-adapter
/// commands or non-strict runs, and cleanup on every disposal path.
///
/// The strict gate is pinned per test through
/// `AgentProviderRuntime.pinStrictSummarizerOverride` (reset in a `defer`) —
/// the suite is serialized so the pin cannot leak into concurrently running
/// suites.
@Suite("AgentProviderRuntime package-runner lease", .serialized, .timeLimit(.minutes(2)))
struct AgentProviderRuntimeLeaseTests {

    private let alpha = ProviderID(rawValue: "alpha")

    /// A config whose summarizer stage runs the SHIPPED adapter shape
    /// through bun (the frozen resolved command `resolveCommand` reports).
    private func adapterConfig() -> AgentProvidersConfig {
        AgentProvidersConfig(
            providers: [
                AgentProvider(id: alpha, label: "Alpha", command: ["bun", "x", "@agentclientprotocol/claude-agent-acp"], isDefault: true),
            ],
            selectedModelIds: [alpha.rawValue: ModelID(rawValue: "alpha-default")],
            ingestStageModelIds: ["summarizer": ModelID(rawValue: "summary-model")],
            stageProviderIds: ["summarizer": alpha])
    }

    /// A config whose summarizer stage is a PLAIN provider binary.
    private func plainBinaryConfig() -> AgentProvidersConfig {
        AgentProvidersConfig(
            providers: [
                AgentProvider(id: alpha, label: "Alpha", command: ["/secret/claude"], isDefault: true),
            ],
            selectedModelIds: [alpha.rawValue: ModelID(rawValue: "alpha-default")],
            ingestStageModelIds: ["summarizer": ModelID(rawValue: "summary-model")],
            stageProviderIds: ["summarizer": alpha])
    }

    private func makeRuntime(
        config: LockedBox<AgentProvidersConfig>,
        leaseParent: URL,
        backendFactory: @escaping AgentProviderRuntime.BackendFactory = { _, _, _ in FakeAgentBackend() }
    ) -> AgentProviderRuntime {
        AgentProviderRuntime(
            readConfiguration: { config.read() },
            resolveCommand: { providers in
                Dictionary(uniqueKeysWithValues: providers.compactMap { provider in
                    provider.command.map { (provider.id, $0) }
                })
            },
            readCredential: { _ in nil },
            resolvePermissionPolicy: { _ in .bypass },
            makeBackend: backendFactory,
            packageRunnerTempParent: leaseParent)
    }

    private func summarizerPreparation(_ service: AgentProviderRuntime) async throws -> AgentOperationPreparation {
        let result = try await service.prepareSummarization()
        guard case .model(let preparation) = result else {
            throw AgentProviderRuntimeError.noProvider
        }
        return preparation
    }

    /// The isolated lease root with a marker child directory named like the
    /// production leaf, so "parent survived, owned child removed" is
    /// observable.
    private func isolatedLeaseRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-lease-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("Strict summarizer allocates a unique pre-created lease per snapshot; release removes it")
    func strictSummarizerOwnsUniqueLeaseAndReleaseRemovesIt() async throws {
        AgentProviderRuntime.pinStrictSummarizerOverride(true)
        defer { AgentProviderRuntime.pinStrictSummarizerOverride(nil) }
        let config = LockedBox(adapterConfig())
        let leaseRoot = try isolatedLeaseRoot()
        defer {
            do { try FileManager.default.removeItem(at: leaseRoot) }
            catch { Issue.record("lease root cleanup failed: \(error)") }
        }
        let service = makeRuntime(config: config, leaseParent: leaseRoot)

        let first = try await summarizerPreparation(service)
        let prepared1 = try await service.preparedBackend(from: first.selection.token, stage: .summarizer)
        let lease1 = try #require(prepared1.profile.packageRunnerTempURL, "strict adapter-shaped summarizer owns a lease")
        #expect(lease1.deletingLastPathComponent().path == leaseRoot.path)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: lease1.path, isDirectory: &isDirectory) && isDirectory.boolValue,
                "the lease directory exists BEFORE any spawn")

        let second = try await summarizerPreparation(service)
        let prepared2 = try await service.preparedBackend(from: second.selection.token, stage: .summarizer)
        let lease2 = try #require(prepared2.profile.packageRunnerTempURL)
        #expect(lease1.path != lease2.path, "each snapshot owns its own staging directory")

        await service.release(first.selection.token)
        #expect(!FileManager.default.fileExists(atPath: lease1.path),
                "release removes the released snapshot's lease")
        #expect(FileManager.default.fileExists(atPath: lease2.path),
                "the live snapshot's lease survives")

        await service.release(second.selection.token)
        #expect(!FileManager.default.fileExists(atPath: lease2.path))
    }

    @Test("Dispose removes every owned lease only after backends shut down")
    func disposeRemovesLeasesAfterBackendShutdown() async throws {
        AgentProviderRuntime.pinStrictSummarizerOverride(true)
        defer { AgentProviderRuntime.pinStrictSummarizerOverride(nil) }
        let config = LockedBox(adapterConfig())
        let leaseRoot = try isolatedLeaseRoot()
        defer {
            do { try FileManager.default.removeItem(at: leaseRoot) }
            catch { Issue.record("lease root cleanup failed: \(error)") }
        }
        let gated = GatedSummarizerBackend(gate: GateBox(), order: TeardownOrder(), replyText: "s")
        let service = makeRuntime(config: config, leaseParent: leaseRoot, backendFactory: { _, _, _ in gated })

        let preparation = try await summarizerPreparation(service)
        let prepared = try await service.preparedBackend(from: preparation.selection.token, stage: .summarizer)
        let lease = try #require(prepared.profile.packageRunnerTempURL)

        await service.dispose()
        #expect(!FileManager.default.fileExists(atPath: lease.path))
        // The parent leaf (this suite's isolated root) survives; only owned
        // children were removed.
        #expect(FileManager.default.fileExists(atPath: leaseRoot.path))
    }

    @Test("Lease survives an active summary; removal happens after the backend shuts down")
    func leaseOutlivesActiveSummaryAndIsRemovedAfterShutdown() async throws {
        AgentProviderRuntime.pinStrictSummarizerOverride(true)
        defer { AgentProviderRuntime.pinStrictSummarizerOverride(nil) }
        let config = LockedBox(adapterConfig())
        let leaseRoot = try isolatedLeaseRoot()
        defer {
            do { try FileManager.default.removeItem(at: leaseRoot) }
            catch { Issue.record("lease root cleanup failed: \(error)") }
        }
        let order = TeardownOrder()
        let gate = GateBox()
        let gated = GatedSummarizerBackend(gate: gate, order: order, replyText: "summary")
        let service = makeRuntime(config: config, leaseParent: leaseRoot, backendFactory: { _, _, _ in gated })

        let preparation = try await summarizerPreparation(service)
        let prepared = try await service.preparedBackend(from: preparation.selection.token, stage: .summarizer)
        let lease = try #require(prepared.profile.packageRunnerTempURL)

        let summaryTask = Task {
            _ = try? await service.modelSummary(text: "text", preparation: preparation)
        }
        try await waitFor { await order.values.contains("send-start") }

        let releaseTask = Task {
            await service.release(preparation.selection.token)
            await order.record("release-done")
        }
        // While the summary lease is ACTIVE the staging dir must survive.
        #expect(FileManager.default.fileExists(atPath: lease.path))

        await gate.open()
        try await waitForTask(releaseTask)
        await summaryTask.value
        let values = await order.values
        let shutdownIndex = try #require(values.firstIndex(of: "shutdown"))
        let doneIndex = try #require(values.firstIndex(of: "release-done"))
        #expect(doneIndex > shutdownIndex, "removal follows backend shutdown")
        #expect(!FileManager.default.fileExists(atPath: lease.path),
                "the lease is gone after release completes")
    }

    @Test("A non-adapter summarizer command allocates no lease")
    func plainBinarySummarizerAllocatesNoLease() async throws {
        AgentProviderRuntime.pinStrictSummarizerOverride(true)
        defer { AgentProviderRuntime.pinStrictSummarizerOverride(nil) }
        let config = LockedBox(plainBinaryConfig())
        let leaseRoot = try isolatedLeaseRoot()
        defer {
            do { try FileManager.default.removeItem(at: leaseRoot) }
            catch { Issue.record("lease root cleanup failed: \(error)") }
        }
        let service = makeRuntime(config: config, leaseParent: leaseRoot)
        let preparation = try await summarizerPreparation(service)
        let prepared = try await service.preparedBackend(from: preparation.selection.token, stage: .summarizer)
        #expect(prepared.profile.packageRunnerTempURL == nil,
                "a plain provider binary keeps the scratch temp policy — no staging lease")
        #expect(leaseChildren(of: leaseRoot).isEmpty)
        await service.dispose()
    }

    @Test("Non-strict runs allocate no lease even for adapter-shaped commands")
    func nonStrictRunAllocatesNoLease() async throws {
        AgentProviderRuntime.pinStrictSummarizerOverride(false)
        defer { AgentProviderRuntime.pinStrictSummarizerOverride(nil) }
        let config = LockedBox(adapterConfig())
        let leaseRoot = try isolatedLeaseRoot()
        defer {
            do { try FileManager.default.removeItem(at: leaseRoot) }
            catch { Issue.record("lease root cleanup failed: \(error)") }
        }
        let service = makeRuntime(config: config, leaseParent: leaseRoot)
        let preparation = try await summarizerPreparation(service)
        let prepared = try await service.preparedBackend(from: preparation.selection.token, stage: .summarizer)
        #expect(prepared.profile.packageRunnerTempURL == nil)
        #expect(leaseChildren(of: leaseRoot).isEmpty)
        await service.dispose()
    }

    @Test("Disposal racing a suspended preparation still removes the allocated lease")
    func disposalDuringPreparationRemovesAllocatedLease() async throws {
        AgentProviderRuntime.pinStrictSummarizerOverride(true)
        defer { AgentProviderRuntime.pinStrictSummarizerOverride(nil) }
        let config = LockedBox(adapterConfig())
        let commandGate = GateBox()
        let signals = TeardownOrder()
        let leaseRoot = try isolatedLeaseRoot()
        defer {
            do { try FileManager.default.removeItem(at: leaseRoot) }
            catch { Issue.record("lease root cleanup failed: \(error)") }
        }
        let service = AgentProviderRuntime(
            readConfiguration: { config.read() },
            resolveCommand: { providers in
                await signals.record("resolve-entered")
                await commandGate.wait()
                return Dictionary(uniqueKeysWithValues: providers.compactMap { provider in
                    provider.command.map { (provider.id, $0) }
                })
            },
            readCredential: { _ in nil },
            resolvePermissionPolicy: { _ in .bypass },
            packageRunnerTempParent: leaseRoot)

        let prepareTask = Task {
            _ = try? await service.prepareSummarization()
        }
        try await waitFor { await signals.values.contains("resolve-entered") }
        // Parked before lease allocation: nothing owned yet.
        #expect(leaseChildren(of: leaseRoot).isEmpty)

        await service.dispose()
        await commandGate.open()
        await prepareTask.value

        // The disposed runtime refuses; any lease the resumed preparation
        // allocated on its way to the refusal is removed with it.
        try await waitFor(
            { leaseChildren(of: leaseRoot).isEmpty },
            timeout: .seconds(2),
            pollInterval: .milliseconds(20))
    }

    /// Children of the isolated lease root (what an allocated lease looks like).
    private func leaseChildren(of root: URL) -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return contents.map(\.lastPathComponent)
    }
}

/// The pure strict-tier environment parser (issue #1279 AC.12): unset and
/// `"1"` enable; `"0"` and case-insensitive `"false"` disable; every other
/// value enables so malformed configuration fails SECURE.
@Suite("StrictSummarizerEnvironmentParser")
struct StrictSummarizerEnvironmentParserTests {

    @Test(arguments: [
        // (environment, expected)
        ([:], true),                                              // unset → default
        (["WIKIFS_SUMMARIZER_STRICT": "1"], true),
        (["WIKIFS_SUMMARIZER_STRICT": "0"], false),
        (["WIKIFS_SUMMARIZER_STRICT": "false"], false),
        (["WIKIFS_SUMMARIZER_STRICT": "FALSE"], false),
        (["WIKIFS_SUMMARIZER_STRICT": "False"], false),
        (["WIKIFS_SUMMARIZER_STRICT": " 0 "], false),             // surrounding whitespace tolerated
        (["WIKIFS_SUMMARIZER_STRICT": "true"], true),             // unknown → fail secure
        (["WIKIFS_SUMMARIZER_STRICT": "yes"], true),
        (["WIKIFS_SUMMARIZER_STRICT": ""], true),
        (["WIKIFS_SUMMARIZER_STRICT": "2"], true),
    ])
    func parserSemantics(environment: [String: String], expected: Bool) {
        #expect(AgentProviderRuntime.strictSummarizerEnabled(environment: environment) == expected)
    }
}

/// Box for the lease tests (mirrors the existing suite's helpers, which are
/// private to `AgentProviderRuntimeTests`).
private final class LockedBox<Value: Sendable>: Sendable {
    private let storage: Mutex<Value>
    init(_ value: Value) { storage = Mutex(value) }
    func read() -> Value { storage.withLock { $0 } }
}

private actor GateBox {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var opened = false
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuations.append($0) }
    }
    func open() {
        opened = true
        let waiters = continuations
        continuations = []
        for waiter in waiters { waiter.resume() }
    }
}

private actor TeardownOrder {
    private var storage: [String] = []
    func record(_ event: String) { storage.append(event) }
    var values: [String] { storage }
}

private actor GatedSummarizerBackend: AgentBackend {
    private let gate: GateBox
    private let order: TeardownOrder
    private let replyText: String
    private var sessionCounter = 0

    init(gate: GateBox, order: TeardownOrder, replyText: String) {
        self.gate = gate
        self.order = order
        self.replyText = replyText
    }

    func start(
        profile: BackendProfile,
        systemPrompt: String,
        onExit: @escaping @Sendable (Int) -> Void
    ) async throws -> SessionHandle {
        sessionCounter += 1
        return SessionHandle(id: "gated-lease-\(sessionCounter)")
    }

    func send(_ turn: TurnInput, into session: SessionHandle) async -> AsyncStream<AgentEvent> {
        await order.record("send-start")
        await gate.wait()
        await order.record("send-end")
        return AsyncStream { continuation in
            continuation.yield(.assistantText(replyText))
            continuation.yield(.messageStop)
            continuation.finish()
        }
    }

    func resume(sessionID: String, profile: BackendProfile) async throws -> SessionHandle? { nil }

    func cancel(_ session: SessionHandle) async {
        await order.record("cancel")
    }

    func shutdown() async {
        await order.record("shutdown")
    }
}

private func waitFor(
    _ predicate: () async -> Bool,
    timeout: Duration = .seconds(5),
    pollInterval: Duration = .milliseconds(20)
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !(await predicate()) {
        if ContinuousClock.now >= deadline { throw TeardownTimeout() }
        try await Task.sleep(for: pollInterval)
    }
}

private func waitForTask(_ task: Task<Void, Never>, timeout: Duration = .seconds(10)) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await task.value }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TeardownTimeout()
        }
        try await group.next()
        group.cancelAll()
    }
}
