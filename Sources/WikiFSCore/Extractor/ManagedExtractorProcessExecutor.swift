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

public struct ExtractorRuntimeSearchPolicy: Sendable {
    public let searchDirectories: [URL]

    public init(searchDirectories: [URL]) {
        self.searchDirectories = searchDirectories.map(\.standardizedFileURL)
    }

    public static var standard: Self {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return Self(searchDirectories: [
            home.appendingPathComponent(".local/share/mise/shims", isDirectory: true),
            home.appendingPathComponent(".bun/bin", isDirectory: true),
            home.appendingPathComponent(".local/bin", isDirectory: true),
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/bin", isDirectory: true),
            URL(fileURLWithPath: "/bin", isDirectory: true),
        ])
    }
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
    public let runtimeSearchPolicy: ExtractorRuntimeSearchPolicy
    public let cancellationGracePeriod: Duration

    public init(
        revision: ExtractorPackageRevisionID,
        manifest: ExtractorManifest,
        protocolRequest: ExtractorProtocolRequest,
        paths: ManagedExtractorProcessPaths,
        runtimeSearchPolicy: ExtractorRuntimeSearchPolicy = .standard,
        cancellationGracePeriod: Duration = .seconds(1)
    ) {
        self.revision = revision
        self.manifest = manifest
        self.protocolRequest = protocolRequest
        self.paths = paths
        self.runtimeSearchPolicy = runtimeSearchPolicy
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
    case missingRuntime(ExtractorRuntimeName)
    case executableChanged
    case launch(RaceFreeProcessGroupError)
    case malformedProtocol
    case protocolSequence(ExtractorProtocolSequenceError)
    case timeout
    case cancellation
    case outputLimit
    case processTermination(ProcessTerminationCause)
}

public struct ManagedExtractorProcessExecutor: ManagedProcessExecuting, Sendable {
    public init() {}

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
        let protocolState = ManagedProtocolState(
            requestID: operation.protocolRequest.requestID,
            outputPath: operation.protocolRequest.outputPath,
            maximumProgressEventCount: operation.manifest.limits.maximumProgressEventCount,
            onFrame: onFrame,
            onFailure: { cancellationSlot.requestTermination() })
        let stdoutLimit = managedStandardOutputLimit(operation.manifest.limits)
        let handle: RaceFreeProcessGroupHandle
        do {
            try verifyIdentity(
                launch.identity,
                at: launch.executableURL,
                requireExecutable: true,
                followingSymlinks: launch.followsSymlinks)
            handle = try RaceFreeProcessGroupRunner.launch(.init(
                executableURL: launch.executableURL,
                arguments: launch.arguments,
                environment: environment,
                currentDirectoryURL: operation.paths.operationRoot,
                standardInput: input,
                stdoutLimit: stdoutLimit,
                stderrLimit: ExtractorHostLimits.maximumStandardErrorByteCount,
                observeStdout: { protocolState.consume($0) }))
            cancellationSlot.install(handle)
        } catch let error as RaceFreeProcessGroupError {
            throw ManagedExtractorProcessError.launch(error)
        }

        let timeout = effectiveTimeout(operation)
        let execution: ProcessGroupExecutionResult
        do {
            execution = try await handle.result(timeout: timeout)
        } catch is CancellationError {
            throw ManagedExtractorProcessError.cancellation
        } catch RaceFreeProcessGroupError.timedOut {
            throw ManagedExtractorProcessError.timeout
        } catch RaceFreeProcessGroupError.outputLimitExceeded {
            throw ManagedExtractorProcessError.outputLimit
        } catch let error as RaceFreeProcessGroupError {
            throw ManagedExtractorProcessError.launch(error)
        }

        if protocolState.hasFailure {
            throw ManagedExtractorProcessError.malformedProtocol
        }
        switch execution.terminationCause {
        case .exited(code: 0):
            break
        case .exited, .signaled:
            // A bounded, single-line stderr tail makes non-protocol exits
            // diagnosable (a bare exit code says nothing). Bounded by the
            // runner's stderr limit; never the package's stdout.
            let tail = execution.stderr
                .split(separator: "\n").suffix(3)
                .joined(separator: " | ")
            let bounded = String(tail.prefix(512))
            DebugLog.extraction(
                "Managed extractor exited nonzero: \(execution.terminationCause); stderr tail: \(bounded.isEmpty ? "<empty>" : bounded)")
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
            throw ManagedExtractorProcessError.protocolSequence(error)
        } catch {
            throw ManagedExtractorProcessError.malformedProtocol
        }
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

    private func resolveLaunch(_ operation: ManagedExtractorProcessRequest) throws -> ManagedLaunch {
        let entryPoint = operation.paths.packageRoot
            .appendingPathComponent(operation.manifest.entryPoint.rawValue)
            .standardizedFileURL
        guard isContained(entryPoint, in: operation.paths.packageRoot) else {
            throw ManagedExtractorProcessError.invalidOperationLayout
        }
        switch operation.manifest.launch {
        case .direct:
            let identity = try executableIdentity(entryPoint, requireExecutable: true)
            return ManagedLaunch(
                executableURL: entryPoint,
                arguments: [],
                identity: identity)
        case .runtime(let command, let arguments):
            _ = try executableIdentity(entryPoint, requireExecutable: false)
            for directory in operation.runtimeSearchPolicy.searchDirectories {
                let candidate = directory.appendingPathComponent(command.rawValue).standardizedFileURL
                guard isContained(candidate, in: directory) else { continue }
                // mise-style shims are SYMLINKS to the runtime selector binary
                // (shims/bun -> /opt/homebrew/bin/mise) and dispatch on
                // argv[0] — so the shim path itself is what launches. The
                // identity probe therefore FOLLOWS the link (stat): the
                // pinned identity names the real binary, and the spawn-time
                // re-verification follows the same link, keeping the TOCTOU
                // window closed. Search directories are host PATH policy,
                // not package payload — the strict no-symlink lstat rule
                // stays on the package entry point above.
                let identity: ManagedExecutableIdentity
                do {
                    // A search-directory entry that is absent, not an
                    // executable regular file behind the link, or a broken
                    // symlink simply ends the probe of that candidate.
                    identity = try executableIdentity(
                        candidate,
                        requireExecutable: true,
                        followingSymlinks: true)
                } catch {
                    continue
                }
                return ManagedLaunch(
                    executableURL: candidate,
                    arguments: arguments + [entryPoint.path],
                    identity: identity,
                    followsSymlinks: true)
            }
            throw ManagedExtractorProcessError.missingRuntime(command)
        }
    }

    private func makeEnvironment(_ operation: ManagedExtractorProcessRequest) throws -> [String: String] {
        var environment = [
            "HOME": operation.paths.homeRoot.path,
            "TMPDIR": operation.paths.temporaryRoot.path,
            "XDG_CACHE_HOME": operation.paths.privateCacheRoot.path,
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "WIKI_EXTRACTOR_REQUEST_ID": operation.protocolRequest.requestID.rawValue.uuidString.lowercased(),
            "WIKI_EXTRACTOR_PROTOCOL_REVISION": String(operation.manifest.protocolRevision.rawValue),
        ]
        // Runtime selectors dispatch through mise-style shims, which locate
        // already-installed tools via the mise data dir. Under the sandboxed
        // HOME they would otherwise re-download the tool (or fail); point the
        // selector at the user's real mise data dir. Deliberate, narrow hole:
        // only the selector reads it, and only to find the runtime the user
        // installed.
        let realHome = FileManager.default.homeDirectoryForCurrentUser
        let miseDataDir = realHome.appendingPathComponent(".local/share/mise", isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: miseDataDir.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            environment["MISE_DATA_DIR"] = miseDataDir.path
        }
        if operation.manifest.capabilities.contains(.sharedRuntimeCache),
           let shared = operation.paths.sharedRuntimeCacheRoot {
            environment["WIKI_EXTRACTOR_SHARED_RUNTIME_CACHE"] = shared.path
        }
        if operation.manifest.capabilities.contains(.modelDownload),
           let shared = operation.paths.sharedModelCacheRoot {
            environment["WIKI_EXTRACTOR_SHARED_MODEL_CACHE"] = shared.path
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

    private func executableIdentity(
        _ url: URL,
        requireExecutable: Bool,
        followingSymlinks: Bool = false
    ) throws -> ManagedExecutableIdentity {
        var status = stat()
        // lstat keeps the strict no-symlink package-payload rule; stat()
        // follows symlinks for host PATH candidates (mise-style shims are
        // links to the real binary).
        let probe = followingSymlinks
            ? stat(url.path, &status)
            : lstat(url.path, &status)
        guard probe == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_nlink == 1,
              requireExecutable == false || status.st_mode & S_IXUSR != 0 else {
            throw ManagedExtractorProcessError.executableChanged
        }
        return ManagedExecutableIdentity(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            mode: UInt32(status.st_mode),
            size: Int64(status.st_size))
    }

    private func verifyIdentity(
        _ expected: ManagedExecutableIdentity,
        at url: URL,
        requireExecutable: Bool,
        followingSymlinks: Bool = false
    ) throws {
        guard try executableIdentity(
            url,
            requireExecutable: requireExecutable,
            followingSymlinks: followingSymlinks) == expected else {
            throw ManagedExtractorProcessError.executableChanged
        }
    }

    private func isContained(_ candidate: URL, in root: URL) -> Bool {
        let candidate = candidate.standardizedFileURL.path
        let root = root.standardizedFileURL.path
        return candidate == root || candidate.hasPrefix(root + "/")
    }
}

private struct ManagedLaunch: Sendable {
    let executableURL: URL
    let arguments: [String]
    let identity: ManagedExecutableIdentity
    /// True when `executableURL` is a symlink that must stay unresolved at
    /// spawn (mise-style shims dispatch on argv[0]) and identity checks must
    /// follow the link with stat().
    let followsSymlinks: Bool

    init(
        executableURL: URL,
        arguments: [String],
        identity: ManagedExecutableIdentity,
        followsSymlinks: Bool = false
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.identity = identity
        self.followsSymlinks = followsSymlinks
    }
}

private struct ManagedExecutableIdentity: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt32
    let size: Int64
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
    private let onFrame: @Sendable (ExtractorProtocolFrame) -> Void
    private let onFailure: @Sendable () -> Void

    init(
        requestID: ExtractorRequestID,
        outputPath: ExtractorRelativePath,
        maximumProgressEventCount: Int,
        onFrame: @escaping @Sendable (ExtractorProtocolFrame) -> Void,
        onFailure: @escaping @Sendable () -> Void
    ) {
        sequence = ExtractorProtocolSequence(
            requestID: requestID,
            expectedOutputPath: outputPath,
            maximumProgressEventCount: maximumProgressEventCount)
        self.onFrame = onFrame
        self.onFailure = onFailure
    }

    var hasFailure: Bool { lock.withLock { failure != nil } }

    func consume(_ data: Data) {
        let outcome: (frames: [ExtractorProtocolFrame], failed: Bool) = lock.withLock {
            guard failure == nil else { return ([], false) }
            do {
                let frames = try decoder.append(data)
                for frame in frames { try sequence.consume(frame) }
                return (frames, false)
            } catch {
                failure = error
                return ([], true)
            }
        }
        for frame in outcome.frames { onFrame(frame) }
        if outcome.failed { onFailure() }
    }

    func finish() throws -> (terminalFrame: ExtractorProtocolFrame, progressEventCount: Int) {
        try lock.withLock {
            if let failure { throw failure }
            try decoder.finish()
            return (try sequence.finish(), sequence.progressEventCount)
        }
    }
}
