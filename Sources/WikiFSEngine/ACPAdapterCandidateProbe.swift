#if os(macOS)
import Foundation
import ACP
import WikiFSCore

/// An initialize-only probe for a CANDIDATE adapter command — the upgrade
/// manager's gate before any adoption.
///
/// Deliberately NARROW (design review MUST-FIX): the probe reuses
/// `ACPProviderModelProbe`'s launch preparation — the fail-closed sandbox
/// gate, `resolveSpawnConfig`, bun canonicalization, the typed
/// `sandboxedSpawnPlan`, and the hard-bounded race + unconditional teardown —
/// but it performs ONLY the ACP initialize handshake. It never authenticates
/// and never opens a session: no auth material is exercised, no model traffic
/// flows, and a broken candidate cannot do anything beyond answering (or not
/// answering) one request.
///
/// What it verifies is a PURE decision (`ACPAdapterProbeVerification` on the
/// returned `ACPAdapterCandidateReport` + the package's
/// `ACPAdapterContract`): protocol version, reported identity, and the
/// version predicate re-checked against what the candidate on disk actually
/// reports — not what the registry claimed.
public struct ACPAdapterCandidateProbe: Sendable {
    /// The candidate provider (its `command` is the candidate argv).
    public let provider: AgentProvider
    /// The PATH-resolved argv for the candidate executable (first element
    /// MUST be an absolute path) — same contract as `ACPProviderModelProbe`.
    public let resolvedCommand: [String]
    /// The Keychain-backed API key, carried ONLY so `resolveSpawnConfig`
    /// builds the same hints a real launch would. The probe never
    /// authenticates, so the key is never sent anywhere.
    public let apiKey: String?
    /// The resolved login-shell `PATH` for the child environment (#1368).
    public let loginShellPATH: String?
    /// Where the probe's sandbox scratch world is created. `nil` (production)
    /// uses the process temporary directory; tests pin a root they own.
    public let scratchParent: URL?

    // Injectable seams — same shape as `ACPProviderModelProbe`.
    let sandboxUsability: @Sendable (String) -> Bool
    let resolveBunRuntime: @Sendable () async -> RuntimeCommandResolution?
    let makeClient: @Sendable () -> Client
    let performLaunch: @Sendable (Client, ACPBackend.SandboxedSpawnPlan, String) async throws -> Void

    public init(
        provider: AgentProvider,
        resolvedCommand: [String],
        apiKey: String?,
        loginShellPATH: String? = nil,
        scratchParent: URL? = nil,
        sandboxUsability: @escaping @Sendable (String) -> Bool = ACPProviderModelProbe.defaultSandboxUsability,
        resolveBunRuntime: @escaping @Sendable () async -> RuntimeCommandResolution? = ACPProviderModelProbe.defaultBunResolver,
        makeClient: @escaping @Sendable () -> Client = { Client() },
        performLaunch: @escaping @Sendable (Client, ACPBackend.SandboxedSpawnPlan, String) async throws -> Void = ACPProviderModelProbe.defaultLaunch
    ) {
        self.provider = provider
        self.resolvedCommand = resolvedCommand
        self.apiKey = apiKey
        self.loginShellPATH = loginShellPATH
        self.scratchParent = scratchParent
        self.sandboxUsability = sandboxUsability
        self.resolveBunRuntime = resolveBunRuntime
        self.makeClient = makeClient
        self.performLaunch = performLaunch
    }

    /// Run the initialize-only handshake with a hard bound. Returns the
    /// candidate's report; throws `ACPProviderModelProbeError` on any
    /// launch/transport failure or timeout. The subprocess is terminated on
    /// EVERY exit path, outside the race, exactly like the model probe.
    public func runHandshake(timeout: Duration = .seconds(20)) async throws -> ACPAdapterCandidateReport {
        DebugLog.agent("ACPAdapterCandidateProbe.runHandshake: enter provider=\(provider.id) timeout=\(timeout)")

        // Fail-closed gate BEFORE everything (issue #1276 ordering).
        guard sandboxUsability(SandboxProfile.sandboxExecutablePath) else {
            DebugLog.agent("ACPAdapterCandidateProbe: sandbox front-end unusable — refusing to probe (fail closed)")
            throw ACPProviderModelProbeError.sandboxUnavailable
        }

        let hints = AgentBackendFactory.providerHints(
            provider: provider,
            resolvedCommand: resolvedCommand,
            apiKey: apiKey,
            selectedModelId: nil)
        guard !hints.isEmpty else {
            DebugLog.agent("ACPAdapterCandidateProbe: FAIL notConfigured provider=\(provider.id)")
            throw ACPProviderModelProbeError.notConfigured
        }
        let profile = BackendProfile(providerHints: hints, loginShellPATH: loginShellPATH)
        guard let configuredSpawn = ACPBackend.resolveSpawnConfig(from: profile) else {
            DebugLog.agent("ACPAdapterCandidateProbe: FAIL resolveSpawnConfig nil provider=\(provider.id)")
            throw ACPProviderModelProbeError.notConfigured
        }

        // The probe scratch: the child's working directory and only writable
        // subtree. Tests pin `scratchParent` so fixture logs survive teardown
        // for inspection; production sweeps the process-temp scratch.
        let scratch: LLMSandboxScratch
        do {
            scratch = try LLMSandboxScratch.make(
                under: scratchParent, namePrefix: "acp-candidate-probe")
        } catch {
            DebugLog.agent("ACPAdapterCandidateProbe: FAIL could not create probe scratch: \(error.localizedDescription)")
            throw ACPProviderModelProbeError.launchFailed(
                "Could not create the probe scratch directory: \(error.localizedDescription)",
                stderr: nil, hint: nil)
        }
        defer { scratch.remove() }

        // Canonicalize adapter shapes exactly like the real launch path
        // (#1257) so the probe exercises the runtime an adoption will use.
        let bunPath = ACPBackend.isJSAdapterLaunch(
            executablePath: configuredSpawn.executablePath,
            arguments: configuredSpawn.arguments)
            ? await resolveBunRuntime()?.executableURL.path
            : nil
        let spawn = ACPBackend.canonicalizedSpawn(configuredSpawn, resolvedBunPath: bunPath)
            ?? configuredSpawn

        let env = ProcessInfo.processInfo.environment.merging(spawn.environment) { _, new in new }
        let plan = ACPBackend.sandboxedSpawnPlan(
            invocation: scratch.sandbox,
            executablePath: spawn.executablePath,
            arguments: spawn.arguments,
            environment: env,
            scratchDirectory: scratch.directoryURL)

        let client = makeClient()

        // Hard-bounded unstructured race (review HIGH, same shape as the
        // model probe): a child that ignores cancellation cannot pin the
        // caller past the bound.
        let race = Task {
            try await withThrowingTaskGroup(of: ACPAdapterCandidateReport.self) { group in
                group.addTask {
                    try await self.runInitializeOnly(on: client, plan: plan, probeCWD: scratch.directoryURL.path)
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw ACPProviderModelProbeError.timedOut
                }
                guard let first = try await group.next() else {
                    throw ACPProviderModelProbeError.timedOut
                }
                group.cancelAll()
                return first
            }
        }
        let outcome = await Self.boundedRace(race, timeout: timeout + Self.hardBoundGrace)

        // Terminate OUTSIDE the race on every path — this is what actually
        // kills the pinned subprocess after the hard bound.
        let succeeded: Bool
        if case .success = outcome { succeeded = true } else { succeeded = false }
        await Self.terminateAndLog(
            client,
            reason: succeeded ? "success" : "error/timeout",
            providerID: provider.id)

        switch outcome {
        case .success(let report):
            return report
        case .failure(let error):
            throw Self.mapProbeError(error)
        }
    }

    static let hardBoundGrace: Duration = .seconds(2)

    /// The racing operation: launch → initialize → report. NEVER
    /// authenticates and NEVER opens a session — the report is built purely
    /// from the initialize response.
    private func runInitializeOnly(
        on client: Client,
        plan: ACPBackend.SandboxedSpawnPlan,
        probeCWD: String
    ) async throws -> ACPAdapterCandidateReport {
        let delegate = ACPPermissionDelegate(policy: .bypass)
        await client.setDelegate(delegate)

        let earlyStderrBuffer = EarlyStderrBuffer()
        let initResponse: InitializeResponse
        do {
            try await performLaunch(client, plan, probeCWD)
            let stderrTask = Task { [client] in
                guard let stream = await client.stderrLines() else { return }
                for await line in stream {
                    earlyStderrBuffer.append(line)
                }
            }
            DebugLog.agent("ACPAdapterCandidateProbe: process launched, sending initialize")
            initResponse = try await client.initialize(
                protocolVersion: ACPAdapterProbeVerification.supportedProtocolVersion,
                capabilities: ACPBackend.defaultCapabilities,
                clientInfo: ClientInfo(
                    name: "SelfDrivingWikiAdapterProbe",
                    title: "Self Driving Wiki (adapter candidate probe)",
                    version: GeneratedVersion.appVersion))
            stderrTask.cancel()
            _ = earlyStderrBuffer.flush()
        } catch {
            DebugLog.agent("ACPAdapterCandidateProbe: launch/initialize failed: \(error.localizedDescription)")
            let stderr = earlyStderrBuffer.flush()
            throw ACPProviderModelProbeError.launchFailed(
                error.localizedDescription, stderr: stderr, hint: nil)
        }

        let report = ACPAdapterCandidateReport(
            protocolVersion: initResponse.protocolVersion,
            reportedIdentity: initResponse.agentInfo.map {
                ACPAgentIdentity(rawValue: $0.name)
            },
            reportedVersion: initResponse.agentInfo.map {
                ACPAgentVersion(rawValue: $0.version)
            })
        DebugLog.agent(
            "ACPAdapterCandidateProbe: initialize OK protocol=\(initResponse.protocolVersion) identity=\(report.reportedIdentity?.rawValue ?? "none") version=\(report.reportedVersion?.rawValue ?? "none") — terminating (no auth, no session)")
        return report
    }

    // MARK: - Bounded race (same primitive as the model probe)

    private actor BoundedRaceBox<Value: Sendable> {
        private var settledValue: Value?
        private var continuation: CheckedContinuation<Value, Never>?

        func resume(_ value: Value) {
            guard settledValue == nil else { return }
            settledValue = value
            continuation?.resume(returning: value)
            continuation = nil
        }

        func wait() async -> Value {
            if let settledValue { return settledValue }
            return await withCheckedContinuation { continuation = $0 }
        }
    }

    private static func boundedRace(
        _ task: Task<ACPAdapterCandidateReport, Error>,
        timeout: Duration
    ) async -> Result<ACPAdapterCandidateReport, Error> {
        let box = BoundedRaceBox<Result<ACPAdapterCandidateReport, Error>>()
        let bound = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            await box.resume(.failure(ACPProviderModelProbeError.timedOut))
        }
        let racer = Task {
            do {
                await box.resume(.success(try await task.value))
            } catch {
                await box.resume(.failure(error))
            }
        }
        let outcome = await box.wait()
        bound.cancel()
        _ = racer
        return outcome
    }

    private static func mapProbeError(_ error: Error) -> Error {
        if let probeErr = error as? ACPProviderModelProbeError {
            return probeErr
        }
        if error is CancellationError {
            return ACPProviderModelProbeError.timedOut
        }
        return error
    }

    private static func terminateAndLog(
        _ client: Client, reason: String, providerID: ProviderID
    ) async {
        await client.terminate()
        DebugLog.agent("ACPAdapterCandidateProbe.terminate(\(reason)): provider=\(providerID.rawValue)")
    }
}
#endif
