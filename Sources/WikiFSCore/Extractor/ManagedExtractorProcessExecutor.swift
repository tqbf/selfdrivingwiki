import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import WikiFSTypes

public protocol ManagedProcessExecuting: Sendable {
    func execute(
        _ operation: ManagedExtractorProcessRequest,
        onFrame: @escaping @Sendable (ExtractorProtocolFrame) -> Void
    ) async throws -> ManagedExtractorProcessResult
}

public struct ManagedExtractorProcessPaths: Sendable {
    public let operationRoot: URL
    public let packageRoot: URL
    public let homeRoot: URL
    public let temporaryRoot: URL
    public let privateCacheRoot: URL
    public let sharedRuntimeCacheRoot: URL?
    public let sharedModelCacheRoot: URL?

    public init(
        operationRoot: URL,
        packageRoot: URL,
        homeRoot: URL,
        temporaryRoot: URL,
        privateCacheRoot: URL,
        sharedRuntimeCacheRoot: URL? = nil,
        sharedModelCacheRoot: URL? = nil
    ) {
        self.operationRoot = operationRoot.standardizedFileURL
        self.packageRoot = packageRoot.standardizedFileURL
        self.homeRoot = homeRoot.standardizedFileURL
        self.temporaryRoot = temporaryRoot.standardizedFileURL
        self.privateCacheRoot = privateCacheRoot.standardizedFileURL
        self.sharedRuntimeCacheRoot = sharedRuntimeCacheRoot?.standardizedFileURL
        self.sharedModelCacheRoot = sharedModelCacheRoot?.standardizedFileURL
    }
}

public struct ManagedExtractorProcessRequest: Sendable {
    public let revision: ExtractorPackageRevisionID
    public let manifest: ExtractorManifest
    public let protocolRequest: ExtractorProtocolRequest
    public let paths: ManagedExtractorProcessPaths
    /// The runtime resolution retained by the prepared operation. Required
    /// for a `runtime` launch: the host launches exactly this executable and
    /// never searches a PATH again.
    public let runtimeResolution: RuntimeCommandResolution?
    /// The host-owned durable token-cache root for one exact revision. Not
    /// part of the operation layout (it outlives the operation) and never a
    /// manifest capability: the executor exposes it to the child only
    /// through its dedicated environment key.
    public let durableTokenCacheRoot: URL?
    public let cancellationGracePeriod: Duration

    public init(
        revision: ExtractorPackageRevisionID,
        manifest: ExtractorManifest,
        protocolRequest: ExtractorProtocolRequest,
        paths: ManagedExtractorProcessPaths,
        runtimeResolution: RuntimeCommandResolution? = nil,
        durableTokenCacheRoot: URL? = nil,
        cancellationGracePeriod: Duration = .seconds(1)
    ) {
        self.revision = revision
        self.manifest = manifest
        self.protocolRequest = protocolRequest
        self.paths = paths
        self.runtimeResolution = runtimeResolution
        self.durableTokenCacheRoot = durableTokenCacheRoot?.standardizedFileURL
        self.cancellationGracePeriod = cancellationGracePeriod
    }
}

public struct ManagedExtractorProcessResult: Sendable, Equatable {
    public let terminationCause: ProcessTerminationCause
    public let terminalFrame: ExtractorProtocolFrame
    public let progressEventCount: Int
    public let standardOutputByteCount: Int
    public let standardError: Data
    public let executableURL: URL

    public init(
        terminationCause: ProcessTerminationCause,
        terminalFrame: ExtractorProtocolFrame,
        progressEventCount: Int,
        standardOutputByteCount: Int,
        standardError: Data,
        executableURL: URL
    ) {
        self.terminationCause = terminationCause
        self.terminalFrame = terminalFrame
        self.progressEventCount = progressEventCount
        self.standardOutputByteCount = standardOutputByteCount
        self.standardError = standardError
        self.executableURL = executableURL
    }
}

public enum ManagedExtractorProcessError: Error, Equatable, Sendable {
    case invalidOperationLayout
    case revisionMismatch
    case requestMismatch
    /// The runtime command did not resolve. `cause` carries the typed
    /// login-shell resolution failure when the operation retained one.
    case missingRuntime(ExtractorRuntimeName, cause: RuntimeCommandResolutionFailure?)
    case executableChanged
    case launch(RaceFreeProcessGroupError)
    case malformedProtocol
    case protocolSequence(ExtractorProtocolSequenceError)
    /// The extractor exceeded its deadline. `detail` carries the elapsed and
    /// limit durations plus the last progress line and its age, so a user
    /// can see which phase hung without attaching a debugger.
    case timeout(detail: String)
    case cancellation
    case outputLimit
    case processTermination(ProcessTerminationCause)
    /// macOS seatbelt confinement could not be applied, so nothing was
    /// spawned. Fail closed: a managed package never runs unsandboxed on
    /// macOS (Linux diagnostic builds spawn unwrapped and are loudly logged
    /// instead).
    case sandboxUnavailable
}

extension ManagedExtractorProcessError: LocalizedError {
    /// Short, safe user-facing messages. They contain no executable paths
    /// and no subprocess output — actionable detail lives in Console
    /// diagnostics.
    public var errorDescription: String? {
        switch self {
        case .invalidOperationLayout:
            "The extractor operation directory layout is invalid."
        case .revisionMismatch:
            "The extractor package revision does not match the manifest."
        case .requestMismatch:
            "The extractor request does not match the prepared operation."
        case .missingRuntime(let command, _):
            "Runtime \(command.rawValue) is not available. Install it and make sure your login shell runs it."
        case .executableChanged:
            "The extractor executable changed before launch. Try again."
        case .launch:
            "The extractor process could not start."
        case .malformedProtocol:
            "The extractor produced malformed protocol output."
        case .protocolSequence:
            "The extractor produced an invalid protocol sequence."
        case .timeout(let detail):
            detail
        case .cancellation:
            "The extraction was cancelled."
        case .outputLimit:
            "The extractor exceeded its output limit."
        case .processTermination(let cause):
            "The extractor process stopped unexpectedly (\(cause))."
        case .sandboxUnavailable:
            "The extractor sandbox could not be set up, so the package did not run."
        }
    }
}

public struct ManagedExtractorProcessExecutor: ManagedProcessExecuting, Sendable {
    private let diagnostics: any ExtractorDiagnosticsSink
    /// The seatbelt front-end this executor requires and applies on macOS.
    /// Injectable so the fail-closed tests can point at a missing,
    /// non-executable, or non-regular path; production always uses
    /// `ExtractorSandboxProfile.sandboxExecutablePath`.
    let sandboxExecutableURL: URL?

    public init(diagnostics: (any ExtractorDiagnosticsSink)? = nil) {
        self.diagnostics = diagnostics ?? DebugLogExtractorDiagnosticsSink()
        #if os(macOS)
        self.sandboxExecutableURL = URL(fileURLWithPath: ExtractorSandboxProfile.sandboxExecutablePath)
        #else
        self.sandboxExecutableURL = nil
        #endif
    }

    /// Test seam: an explicit sandbox-executable URL. On macOS a `nil` here
    /// fails closed (typed `sandboxUnavailable`, nothing spawns); on Linux it
    /// is ignored because Linux applies no seatbelt.
    init(
        diagnostics: (any ExtractorDiagnosticsSink)? = nil,
        sandboxExecutableURL: URL?
    ) {
        self.diagnostics = diagnostics ?? DebugLogExtractorDiagnosticsSink()
        self.sandboxExecutableURL = sandboxExecutableURL
    }

    public func execute(
        _ operation: ManagedExtractorProcessRequest,
        onFrame: @escaping @Sendable (ExtractorProtocolFrame) -> Void = { _ in }
    ) async throws -> ManagedExtractorProcessResult {
        try validate(operation)
        let launch = try resolveLaunch(operation)
        let environment = try makeEnvironment(operation)
        let input = try encodeRequest(operation.protocolRequest)
        let cancellationSlot = ManagedProcessCancellationSlot(
            gracePeriod: operation.cancellationGracePeriod)
        // Progress tracking for timeout diagnostics: the last progress line
        // and when it arrived tell a user which phase hung without a debugger.
        let progressClock = ContinuousClock()
        let runStartedAt = progressClock.now
        let lastProgress = LastProgressBox()
        let callerOnFrame = onFrame
        let trackedOnFrame: @Sendable (ExtractorProtocolFrame) -> Void = { frame in
            if case .progress(let progress) = frame {
                lastProgress.record(progress.message ?? "", at: progressClock.now, since: runStartedAt)
            }
            callerOnFrame(frame)
        }
        let protocolState = ManagedProtocolState(
            requestID: operation.protocolRequest.requestID,
            outputPath: operation.protocolRequest.outputPath,
            maximumProgressEventCount: operation.manifest.limits.maximumProgressEventCount,
            onFrame: trackedOnFrame,
            onFailure: { cancellationSlot.requestTermination() },
            onCompletion: { cancellationSlot.requestTermination() })
        let stdoutLimit = managedStandardOutputLimit(operation.manifest.limits)
        let handle: RaceFreeProcessGroupHandle
        do {
            // Revalidate both pinned identities immediately before spawn:
            // always the package entry point (no symlink following), and for
            // a runtime launch the host executable (symlink following, the
            // same rule used at resolution). Any change fails closed.
            do {
                try verifyIdentity(
                    launch.entryPointIdentity,
                    at: launch.entryPointURL,
                    requirement: launch.entryPointRequirement,
                    followingSymlinks: false)
                if launch.launchesHostExecutable {
                    try verifyIdentity(
                        launch.executableIdentity,
                        at: launch.executableURL,
                        requirement: .executable,
                        followingSymlinks: true)
                }
            } catch {
                diagnostics.send(ManagedExtractorDiagnostics.Event.executableChanged(
                    command: launch.commandDescription,
                    identity: ManagedExtractorDiagnostics.identityFingerprint(
                        for: launch.executableIdentity)).consoleLine)
                throw error
            }
            // Seatbelt confinement (macOS): build the per-spawn profile from
            // the validated operation layout plus manifest capabilities,
            // require the sandbox front-end (fail closed), and wrap the
            // spawn argv. Identity pinning above is unchanged — it validated
            // the real target before this wrap. The result continues to
            // report the real executable, never sandbox-exec.
            var spawnExecutableURL = launch.executableURL
            var spawnArguments = launch.arguments
            #if os(macOS)
            let networkDenied = !operation.manifest.capabilities.contains(.network)
            let sandboxInvocation = ExtractorSandboxProfile.invocation(
                paths: operation.paths,
                capabilities: operation.manifest.capabilities,
                durableTokenCacheRoot: operation.durableTokenCacheRoot)
            let sandboxURL = try requireSandboxExecutable(
                sandboxExecutableURL,
                command: launch.commandDescription)
            spawnExecutableURL = sandboxURL
            spawnArguments = ExtractorSandboxProfile.wrappedArguments(
                executablePath: launch.executableURL.path,
                arguments: launch.arguments,
                invocation: sandboxInvocation)
            #else
            // Linux diagnostic builds apply no seatbelt; the gap is loud.
            diagnostics.send(ManagedExtractorDiagnostics.Event.sandboxUnavailablePlatform(
                command: launch.commandDescription).consoleLine)
            #endif
            handle = try RaceFreeProcessGroupRunner.launch(.init(
                executableURL: spawnExecutableURL,
                arguments: spawnArguments,
                environment: environment,
                currentDirectoryURL: operation.paths.operationRoot,
                standardInput: input,
                stdoutLimit: stdoutLimit,
                stderrLimit: ExtractorHostLimits.maximumStandardErrorByteCount,
                observeStdout: { protocolState.consume($0) }))
            #if os(macOS)
            // The spawn is live inside the profile. Mirrors `runtimeResolved`
            // observability: every successful macOS spawn logs whether it
            // was network-confined (AC.8).
            diagnostics.send(ManagedExtractorDiagnostics.Event.sandboxApplied(
                networkDenied: networkDenied).consoleLine)
            #endif
            cancellationSlot.install(handle)
        } catch let error as RaceFreeProcessGroupError {
            diagnostics.send(ManagedExtractorDiagnostics.Event.spawnFailure(
                command: launch.commandDescription,
                detail: ManagedExtractorDiagnostics.sanitize(
                    error.localizedDescription,
                    limit: ManagedExtractorDiagnostics.maximumDetailLength)).consoleLine)
            throw ManagedExtractorProcessError.launch(error)
        }

        let timeout = effectiveTimeout(operation)
        let execution: ProcessGroupExecutionResult
        do {
            execution = try await handle.result(timeout: timeout)
        } catch is CancellationError {
            throw ManagedExtractorProcessError.cancellation
        } catch RaceFreeProcessGroupError.timedOut {
            throw ManagedExtractorProcessError.timeout(detail: ManagedExtractorProcessError.timeoutDetail(
                limit: timeout,
                elapsed: progressClock.now - runStartedAt,
                lastProgress: lastProgress.value))
        } catch RaceFreeProcessGroupError.outputLimitExceeded {
            throw ManagedExtractorProcessError.outputLimit
        } catch let error as RaceFreeProcessGroupError {
            diagnostics.send(ManagedExtractorDiagnostics.Event.spawnFailure(
                command: launch.commandDescription,
                detail: ManagedExtractorDiagnostics.sanitize(
                    error.localizedDescription,
                    limit: ManagedExtractorDiagnostics.maximumDetailLength)).consoleLine)
            throw ManagedExtractorProcessError.launch(error)
        }

        if protocolState.hasFailure {
            diagnostics.send(protocolFailureLine(launch))
            throw ManagedExtractorProcessError.malformedProtocol
        }
        // The package contract makes a valid terminal frame the operation's
        // completion. When the wrapper process outlives the package —
        // observed with `uv run` lingering after the package exits — the
        // completion hook kills the group, so a signaled (or nonzero)
        // termination alongside a terminal frame is success, not a crash.
        // Without a terminal frame the strict termination rules still hold.
        let protocolCompleted = protocolState.hasTerminalFrame
        switch execution.terminationCause {
        case .exited(code: 0):
            break
        case .exited, .signaled:
            guard !protocolCompleted else { break }
            diagnostics.send(ManagedExtractorDiagnostics.Event.nonzeroExit(
                command: launch.commandDescription,
                termination: String(describing: execution.terminationCause),
                stderrTail: ManagedExtractorDiagnostics.singleLineTail(
                    execution.stderr,
                    displayLimit: ManagedExtractorDiagnostics
                        .maximumStderrTailDisplayLength)).consoleLine)
            throw ManagedExtractorProcessError.processTermination(execution.terminationCause)
        }
        do {
            let summary = try protocolState.finish()
            return ManagedExtractorProcessResult(
                terminationCause: execution.terminationCause,
                terminalFrame: summary.terminalFrame,
                progressEventCount: summary.progressEventCount,
                standardOutputByteCount: execution.stdout.count,
                standardError: execution.stderr,
                executableURL: launch.executableURL)
        } catch let error as ExtractorProtocolSequenceError {
            diagnostics.send(protocolFailureLine(launch))
            throw ManagedExtractorProcessError.protocolSequence(error)
        } catch {
            diagnostics.send(protocolFailureLine(launch))
            throw ManagedExtractorProcessError.malformedProtocol
        }
    }

    private func protocolFailureLine(_ launch: ManagedLaunch) -> String {
        ManagedExtractorDiagnostics.Event.protocolFailure(
            command: launch.commandDescription,
            detail: "stdout is protocol data; see the protocol sequence error").consoleLine
    }

    private func validate(_ operation: ManagedExtractorProcessRequest) throws {
        guard operation.revision.packageID == operation.manifest.packageID,
              operation.revision.version == operation.manifest.version,
              try operation.manifest.packageDigest() == operation.revision.digest else {
            throw ManagedExtractorProcessError.revisionMismatch
        }
        guard operation.protocolRequest.protocolRevision == operation.manifest.protocolRevision else {
            throw ManagedExtractorProcessError.requestMismatch
        }
        let root = operation.paths.operationRoot.standardizedFileURL
        for path in [
            operation.paths.packageRoot,
            operation.paths.homeRoot,
            operation.paths.temporaryRoot,
            operation.paths.privateCacheRoot,
        ] where isContained(path, in: root) == false {
            throw ManagedExtractorProcessError.invalidOperationLayout
        }
    }

    /// Typed launch preparation. A `direct` launch validates and pins the
    /// package entry point as the host executable. A `runtime` launch
    /// validates the package script as a regular, single-link readable file
    /// and uses the retained host executable from resolution — no PATH
    /// search happens here.
    private func resolveLaunch(_ operation: ManagedExtractorProcessRequest) throws -> ManagedLaunch {
        let entryPoint = operation.paths.packageRoot
            .appendingPathComponent(operation.manifest.entryPoint.rawValue)
            .standardizedFileURL
        guard isContained(entryPoint, in: operation.paths.packageRoot) else {
            throw ManagedExtractorProcessError.invalidOperationLayout
        }
        switch operation.manifest.launch {
        case .direct:
            let identity = try entryPointIdentity(
                entryPoint, requirement: .executable)
            return ManagedLaunch(
                commandDescription: entryPoint.lastPathComponent,
                executableURL: entryPoint,
                arguments: [],
                executableIdentity: identity,
                entryPointURL: entryPoint,
                entryPointIdentity: identity,
                entryPointRequirement: .executable,
                launchesHostExecutable: false)
        case .runtime(let command, let arguments):
            // The retained resolution must name the manifest's command; a
            // mismatch is an invalid request, never a launch.
            guard let resolution = operation.runtimeResolution else {
                throw ManagedExtractorProcessError.missingRuntime(command, cause: nil)
            }
            guard resolution.command == command else {
                throw ManagedExtractorProcessError.requestMismatch
            }
            // The package script is data for the runtime: regular,
            // single-link, owner-readable. It needs no execute permission.
            let scriptIdentity = try entryPointIdentity(
                entryPoint, requirement: .readable)
            return ManagedLaunch(
                commandDescription: command.rawValue,
                executableURL: resolution.executableURL,
                // Fixed manifest arguments first, the package entry-point
                // path last.
                arguments: arguments + [entryPoint.path],
                executableIdentity: resolution.identity,
                entryPointURL: entryPoint,
                entryPointIdentity: scriptIdentity,
                entryPointRequirement: .readable,
                launchesHostExecutable: true)
        }
    }

    private func makeEnvironment(_ operation: ManagedExtractorProcessRequest) throws -> [String: String] {
        // A closed allowlist: the managed extractor child receives only
        // these variables. No PATH (launch uses an absolute executable), no
        // inherited environment, no tool-manager configuration.
        var environment = [
            "HOME": operation.paths.homeRoot.path,
            "TMPDIR": operation.paths.temporaryRoot.path,
            "XDG_CACHE_HOME": operation.paths.privateCacheRoot.path,
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "WIKI_EXTRACTOR_REQUEST_ID": operation.protocolRequest.requestID.rawValue.uuidString.lowercased(),
            "WIKI_EXTRACTOR_PROTOCOL_REVISION": String(operation.manifest.protocolRevision.rawValue),
        ]
        if operation.manifest.capabilities.contains(.sharedRuntimeCache),
           let shared = operation.paths.sharedRuntimeCacheRoot {
            environment["WIKI_EXTRACTOR_SHARED_RUNTIME_CACHE"] = shared.path
            // uv-based packages (`uv run --script` runtime launch) keep
            // their CPython installs and wheel cache warm across
            // operations. Without these, uv's defaults live under the
            // operation-private HOME/cache and every run re-downloads a
            // CPython — exceeding the duration limit on slow links.
            environment["UV_CACHE_DIR"] = shared.appendingPathComponent("uv-cache").path
            environment["UV_PYTHON_INSTALL_DIR"] = shared.appendingPathComponent("uv-python").path
        }
        if operation.manifest.capabilities.contains(.modelDownload),
           let shared = operation.paths.sharedModelCacheRoot {
            environment["WIKI_EXTRACTOR_SHARED_MODEL_CACHE"] = shared.path
        }
        // Dedicated, revision-gated durable token-cache root. The host
        // supplies it only for the exact reviewed revision that owns it (see
        // the engine's token-cache closure); the manifest cannot request it.
        if let durableTokenCache = operation.durableTokenCacheRoot {
            environment["WIKI_EXTRACTOR_PACKAGE_TOKEN_CACHE"] = durableTokenCache.path
        }
        return environment
    }

    private func encodeRequest(_ request: ExtractorProtocolRequest) throws -> Data {
        var data = try JSONEncoder().encode(request)
        guard data.count <= ExtractorHostLimits.maximumFrameByteCount else {
            throw ManagedExtractorProcessError.malformedProtocol
        }
        data.append(0x0A)
        return data
    }

    private func effectiveTimeout(_ operation: ManagedExtractorProcessRequest) -> Duration {
        let manifestMilliseconds = operation.manifest.limits.maximumDurationMilliseconds
        let nowMilliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
        let deadlineMilliseconds = max(
            operation.protocolRequest.deadlineMillisecondsSince1970 - nowMilliseconds,
            1)
        return .milliseconds(min(Int64(manifestMilliseconds), deadlineMilliseconds))
    }

    private func managedStandardOutputLimit(_ limits: ExtractorOperationLimits) -> Int {
        let maximumFrames = limits.maximumProgressEventCount + 129
        return min(
            ExtractorHostLimits.maximumPackageByteCount,
            ExtractorHostLimits.maximumFrameByteCount * maximumFrames)
    }

    /// Package payload rule: an `lstat` probe (no symlink following) that
    /// requires a regular, single-link file. `.executable` adds the owner
    /// execute bit (direct launch); `.readable` requires the owner read bit
    /// (a runtime script is data, never launched).
    fileprivate enum EntryPointRequirement {
        case executable
        case readable

        var requiresExecute: Bool { self == .executable }
    }

    private func entryPointIdentity(
        _ url: URL,
        requirement: EntryPointRequirement
    ) throws -> RuntimeExecutableIdentity {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_nlink == 1,
              status.st_mode & S_IRUSR != 0,
              requirement.requiresExecute == false || status.st_mode & S_IXUSR != 0 else {
            throw ManagedExtractorProcessError.executableChanged
        }
        return RuntimeExecutableIdentity(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            mode: UInt32(status.st_mode),
            size: Int64(status.st_size))
    }

    /// Host executable rule: `stat` (follows symlinks — a tool-manager shim
    /// may be a link to the real binary) requiring a regular, single-link,
    /// owner-executable file.
    private func verifyIdentity(
        _ expected: RuntimeExecutableIdentity,
        at url: URL,
        requirement: EntryPointRequirement,
        followingSymlinks: Bool
    ) throws {
        var status = stat()
        let probe = followingSymlinks
            ? stat(url.path, &status)
            : lstat(url.path, &status)
        guard probe == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_nlink == 1,
              status.st_mode & S_IRUSR != 0,
              requirement.requiresExecute == false || status.st_mode & S_IXUSR != 0 else {
            throw ManagedExtractorProcessError.executableChanged
        }
        guard RuntimeExecutableIdentity(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            mode: UInt32(status.st_mode),
            size: Int64(status.st_size)) == expected else {
            throw ManagedExtractorProcessError.executableChanged
        }
    }

    private func isContained(_ candidate: URL, in root: URL) -> Bool {
        let candidate = candidate.standardizedFileURL.path
        let root = root.standardizedFileURL.path
        return candidate == root || candidate.hasPrefix(root + "/")
    }

    /// Fail-closed gate for macOS: the seatbelt front-end must exist as an
    /// executable regular file (symlinks followed — the target is what gets
    /// exec'd). A missing path, a non-executable file, or a directory means
    /// NO spawn at all: a managed package never runs unsandboxed on macOS.
    /// Sends the `sandboxUnavailable` diagnostic, then throws the typed
    /// error.
    #if os(macOS)
    private func requireSandboxExecutable(
        _ url: URL?,
        command: String
    ) throws -> URL {
        func unusable(_ detail: String) -> ManagedExtractorProcessError {
            diagnostics.send(ManagedExtractorDiagnostics.Event.sandboxUnavailable(
                command: command,
                detail: detail).consoleLine)
            return ManagedExtractorProcessError.sandboxUnavailable
        }
        guard let url else {
            throw unusable("no sandbox executable was configured")
        }
        var status = stat()
        guard stat(url.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_mode & S_IXUSR != 0 else {
            throw unusable("\(url.path) is missing or not an executable regular file")
        }
        return url
    }
    #endif
}

/// One validated launch: the executable to spawn, its pinned identity, the
/// package entry point's pinned identity, and the entry-point rule that
/// applies at revalidation.
private struct ManagedLaunch: Sendable {
    /// The command name for diagnostics (runtime name or entry basename).
    let commandDescription: String
    /// The absolute executable URL to spawn.
    let executableURL: URL
    /// Fixed manifest arguments plus the entry-point path last.
    let arguments: [String]
    /// The pinned host-executable identity validated at launch construction.
    let executableIdentity: RuntimeExecutableIdentity
    /// The package entry point and its pinned identity.
    let entryPointURL: URL
    let entryPointIdentity: RuntimeExecutableIdentity
    let entryPointRequirement: ManagedExtractorProcessExecutor.EntryPointRequirement
    /// True when `executableURL` is a host tool (runtime launch) whose
    /// identity must be revalidated following symlinks. A direct launch
    /// spawns the package entry point itself.
    let launchesHostExecutable: Bool
}

// NSLock protects all mutable state (`handle`, `terminationRequested`,
// `terminationTask`); every read and write holds the lock, and the termination
// task body never re-enters the slot's state.
// swiftlint:disable:next unchecked_sendable
private final class ManagedProcessCancellationSlot: @unchecked Sendable {
    private let lock = NSLock()
    private let gracePeriod: Duration
    private var handle: RaceFreeProcessGroupHandle?
    private var terminationRequested = false
    private var terminationTask: Task<Void, Never>?

    init(gracePeriod: Duration) {
        self.gracePeriod = gracePeriod
    }

    func install(_ handle: RaceFreeProcessGroupHandle) {
        lock.withLock { self.handle = handle }
        startTerminationIfReady()
    }

    func requestTermination() {
        lock.withLock { terminationRequested = true }
        startTerminationIfReady()
    }

    private func startTerminationIfReady() {
        lock.withLock {
            guard terminationRequested,
                  terminationTask == nil,
                  let handle else { return }
            terminationTask = Task {
                do {
                    try await handle.terminateVerifiedGroup(gracePeriod: gracePeriod)
                } catch {
                    DebugLog.extraction("Managed extractor protocol failure cleanup was refused")
                }
            }
        }
    }

    deinit {
        terminationTask?.cancel()
    }
}

// NSLock protects all mutable state (`decoder`, `sequence`, `failure`);
// every access holds the lock, and callbacks fire outside the lock.
// swiftlint:disable:next unchecked_sendable
private final class ManagedProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var decoder = ExtractorJSONLinesDecoder()
    private var sequence: ExtractorProtocolSequence
    private var failure: Error?
    private var completionSignaled = false
    private let onFrame: @Sendable (ExtractorProtocolFrame) -> Void
    private let onFailure: @Sendable () -> Void
    private let onCompletion: @Sendable () -> Void

    init(
        requestID: ExtractorRequestID,
        outputPath: ExtractorRelativePath,
        maximumProgressEventCount: Int,
        onFrame: @escaping @Sendable (ExtractorProtocolFrame) -> Void,
        onFailure: @escaping @Sendable () -> Void,
        onCompletion: @escaping @Sendable () -> Void
    ) {
        sequence = ExtractorProtocolSequence(
            requestID: requestID,
            expectedOutputPath: outputPath,
            maximumProgressEventCount: maximumProgressEventCount)
        self.onFrame = onFrame
        self.onFailure = onFailure
        self.onCompletion = onCompletion
    }

    var hasFailure: Bool { lock.withLock { failure != nil } }

    /// True once the package's terminal frame has been decoded. The package
    /// contract makes that frame the operation's completion, even if the
    /// wrapper process that spawned the package never exits.
    var hasTerminalFrame: Bool { lock.withLock { sequence.terminalFrame != nil } }

    func consume(_ data: Data) {
        struct Outcome {
            let frames: [ExtractorProtocolFrame]
            let failed: Bool
            let completed: Bool
        }
        let outcome: Outcome = lock.withLock {
            guard failure == nil else { return Outcome(frames: [], failed: false, completed: false) }
            do {
                let frames = try decoder.append(data)
                for frame in frames { try sequence.consume(frame) }
                var completed = false
                if sequence.terminalFrame != nil, !completionSignaled {
                    completionSignaled = true
                    completed = true
                }
                return Outcome(frames: frames, failed: false, completed: completed)
            } catch {
                failure = error
                return Outcome(frames: [], failed: true, completed: false)
            }
        }
        for frame in outcome.frames { onFrame(frame) }
        if outcome.failed { onFailure() }
        if outcome.completed { onCompletion() }
    }

    func finish() throws -> (terminalFrame: ExtractorProtocolFrame, progressEventCount: Int) {
        try lock.withLock {
            if let failure { throw failure }
            try decoder.finish()
            return (try sequence.finish(), sequence.progressEventCount)
        }
    }
}

/// Thread-safe record of the most recent progress line and when it arrived,
/// feeding the timeout detail (which phase hung, and for how long).
/// Sendability invariant: `entry` is only read/written under `lock`, and the
/// recorded Duration value types are themselves Sendable.
// swiftlint:disable:next unchecked_sendable
final class LastProgressBox: @unchecked Sendable {
    struct Entry: Sendable {
        let message: String
        let offset: Duration
    }

    private let lock = NSLock()
    private var entry: Entry?

    func record(_ message: String, at instant: ContinuousClock.Instant, since start: ContinuousClock.Instant) {
        lock.withLock { entry = Entry(message: message, offset: instant - start) }
    }

    var value: Entry? { lock.withLock { entry } }
}

extension ManagedExtractorProcessError {
    /// Human-readable timeout diagnosis: how long the extractor ran against
    /// its limit, and what it last reported (with the silence length).
    static func timeoutDetail(
        limit: Duration,
        elapsed: Duration,
        lastProgress: LastProgressBox.Entry?
    ) -> String {
        func seconds(_ duration: Duration) -> String {
            let value = Double(duration.components.seconds)
                + Double(duration.components.attoseconds) / 1e18
            return String(format: "%.1f s", value)
        }
        var detail = "The extractor did not finish in time. It ran \(seconds(elapsed)) of the "
            + "\(seconds(limit)) limit."
        if let lastProgress {
            let silence = elapsed - lastProgress.offset
            detail += " Last progress: \"\(lastProgress.message)\" at "
                + "\(seconds(lastProgress.offset)) (silent for the last \(seconds(silence)))."
        } else {
            detail += " No progress was reported — the extractor likely never completed startup."
        }
        return detail
    }
}
