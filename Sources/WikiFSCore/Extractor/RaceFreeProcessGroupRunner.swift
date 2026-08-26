import Foundation
import WikiFSTypes
#if canImport(Darwin)
import Darwin
#endif

public struct ProcessGroupExecutionResult: Sendable, Equatable {
    public let terminationStatus: Int32
    public let stdout: Data
    public let stderr: Data

    public init(terminationStatus: Int32, stdout: Data, stderr: Data) {
        self.terminationStatus = terminationStatus
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum RaceFreeProcessGroupError: Error, LocalizedError, Sendable, Equatable {
    case unavailable
    case invalidExecutable
    case pipeFailure(Int32)
    case spawnFailure(Int32)
    case identityUnavailable
    case identityMismatch
    case outputLimitExceeded
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .unavailable: "race-free process groups are unavailable on this platform"
        case .invalidExecutable: "the executable path is not absolute"
        case .pipeFailure(let code): "process pipe setup failed with errno \(code)"
        case .spawnFailure(let code): "posix_spawn failed with errno \(code)"
        case .identityUnavailable: "the child process identity is unavailable"
        case .identityMismatch: "the child process identity changed"
        case .outputLimitExceeded: "the process exceeded an output limit"
        case .timedOut: "the process did not terminate before the deadline"
        }
    }
}

/// Starts an executable in a new process group before its first instruction.
/// The handle verifies the group leader identity before each group signal.
public enum RaceFreeProcessGroupRunner {
    public struct Request: Sendable {
        public let executableURL: URL
        public let arguments: [String]
        public let environment: [String: String]
        public let currentDirectoryURL: URL?
        public let standardInput: Data
        public let stdoutLimit: Int
        public let stderrLimit: Int

        public init(
            executableURL: URL,
            arguments: [String] = [],
            environment: [String: String] = [:],
            currentDirectoryURL: URL? = nil,
            standardInput: Data,
            stdoutLimit: Int,
            stderrLimit: Int
        ) {
            self.executableURL = executableURL
            self.arguments = arguments
            self.environment = environment
            self.currentDirectoryURL = currentDirectoryURL
            self.standardInput = standardInput
            self.stdoutLimit = stdoutLimit
            self.stderrLimit = stderrLimit
        }
    }

    public static func launch(_ request: Request) throws -> RaceFreeProcessGroupHandle {
        #if os(macOS)
        try RaceFreeProcessGroupHandle(request: request)
        #else
        throw RaceFreeProcessGroupError.unavailable
        #endif
    }
}

// Stored process identity is immutable. Locked state objects protect all shared mutable state.
// swiftlint:disable:next unchecked_sendable
public final class RaceFreeProcessGroupHandle: @unchecked Sendable {
    public let processID: Int32
    public let stdoutChunks: AsyncStream<Data>

    private let expectedIdentity: ProcessSignalSafety.Identity
    private let parentProcessID: ProcessSignalSafety.PositivePID
    private let standardInput: FileHandle
    private let stdoutReader: FileHandle
    private let stderrReader: FileHandle
    private let stdoutAccumulator: BoundedProcessAccumulator
    private let stderrAccumulator: BoundedProcessAccumulator
    private let stdoutDrainState = ProcessPipeDrainState()
    private let stderrDrainState = ProcessPipeDrainState()
    private let exitState = ProcessGroupExitState()
    private let processSource: DispatchSourceProcess

    #if os(macOS)
    fileprivate init(request: RaceFreeProcessGroupRunner.Request) throws {
        guard request.executableURL.isFileURL,
              request.executableURL.path.hasPrefix("/") else {
            throw RaceFreeProcessGroupError.invalidExecutable
        }
        guard let parentProcessID = ProcessSignalSafety.PositivePID(rawValue: getpid()) else {
            throw RaceFreeProcessGroupError.identityUnavailable
        }
        self.parentProcessID = parentProcessID
        stdoutAccumulator = BoundedProcessAccumulator(limit: request.stdoutLimit)
        stderrAccumulator = BoundedProcessAccumulator(limit: request.stderrLimit)

        var stdinFDs = [Int32](repeating: -1, count: 2)
        var stdoutFDs = [Int32](repeating: -1, count: 2)
        var stderrFDs = [Int32](repeating: -1, count: 2)
        guard pipe(&stdinFDs) == 0 else { throw RaceFreeProcessGroupError.pipeFailure(errno) }
        guard pipe(&stdoutFDs) == 0 else {
            close(stdinFDs[0]); close(stdinFDs[1])
            throw RaceFreeProcessGroupError.pipeFailure(errno)
        }
        guard pipe(&stderrFDs) == 0 else {
            close(stdinFDs[0]); close(stdinFDs[1])
            close(stdoutFDs[0]); close(stdoutFDs[1])
            throw RaceFreeProcessGroupError.pipeFailure(errno)
        }

        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        posix_spawnattr_init(&attributes)
        posix_spawn_file_actions_init(&actions)
        defer {
            posix_spawnattr_destroy(&attributes)
            posix_spawn_file_actions_destroy(&actions)
        }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawn_file_actions_adddup2(&actions, stdinFDs[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stdoutFDs[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderrFDs[1], STDERR_FILENO)
        for descriptor in [stdinFDs[1], stdoutFDs[0], stderrFDs[0]] {
            posix_spawn_file_actions_addclose(&actions, descriptor)
        }
        if let directory = request.currentDirectoryURL {
            posix_spawn_file_actions_addchdir(&actions, directory.path)
        }

        var spawnedPID: pid_t = 0
        let argv = CStringArray([request.executableURL.path] + request.arguments)
        let environment = CStringArray(
            request.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
        let spawnResult = posix_spawn(
            &spawnedPID,
            request.executableURL.path,
            &actions,
            &attributes,
            argv.pointer,
            environment.pointer)
        close(stdinFDs[0]); close(stdoutFDs[1]); close(stderrFDs[1])
        guard spawnResult == 0 else {
            close(stdinFDs[1]); close(stdoutFDs[0]); close(stderrFDs[0])
            throw RaceFreeProcessGroupError.spawnFailure(spawnResult)
        }
        processID = spawnedPID
        standardInput = FileHandle(fileDescriptor: stdinFDs[1], closeOnDealloc: true)
        stdoutReader = FileHandle(fileDescriptor: stdoutFDs[0], closeOnDealloc: true)
        stderrReader = FileHandle(fileDescriptor: stderrFDs[0], closeOnDealloc: true)

        guard let positivePID = ProcessSignalSafety.PositivePID(rawValue: spawnedPID),
              let identity = ProcessIdentityObservation.observe(processID: positivePID),
              identity.parentProcessID == parentProcessID else {
            kill(-spawnedPID, SIGKILL)
            throw RaceFreeProcessGroupError.identityUnavailable
        }
        expectedIdentity = identity

        let stdoutPair = AsyncStream<Data>.makeStream(
            bufferingPolicy: .bufferingNewest(64))
        stdoutChunks = stdoutPair.stream
        stdoutReader.readabilityHandler = { [stdoutAccumulator, stdoutDrainState] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                stdoutPair.continuation.finish()
                stdoutDrainState.finish()
            } else {
                stdoutAccumulator.append(data)
                stdoutPair.continuation.yield(data)
            }
        }
        stderrReader.readabilityHandler = { [stderrAccumulator, stderrDrainState] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                stderrDrainState.finish()
            } else {
                stderrAccumulator.append(data)
            }
        }

        processSource = DispatchSource.makeProcessSource(
            identifier: spawnedPID,
            eventMask: .exit,
            queue: DispatchQueue(label: "RaceFreeProcessGroupRunner.exit"))
        processSource.setEventHandler { [exitState] in
            var status: Int32 = 0
            var result: Int32
            repeat {
                result = waitpid(spawnedPID, &status, 0)
            } while result < 0 && errno == EINTR
            guard result == spawnedPID else { return }
            exitState.finish(status: Self.decodeWaitStatus(status))
        }
        processSource.resume()

        do {
            try standardInput.write(contentsOf: request.standardInput)
            try standardInput.close()
        } catch {
            kill(-spawnedPID, SIGKILL)
            throw RaceFreeProcessGroupError.pipeFailure(errno)
        }
    }
    #endif

    deinit {
        processSource.cancel()
        stdoutReader.readabilityHandler = nil
        stderrReader.readabilityHandler = nil
    }

    public func terminateVerifiedGroup(gracePeriod: Duration = .milliseconds(250)) async throws {
        try signalVerifiedGroup(SIGTERM)
        do {
            try await Task.sleep(for: gracePeriod)
        } catch is CancellationError {
            try signalRemainingVerifiedGroup(SIGKILL)
            throw CancellationError()
        }
        try signalRemainingVerifiedGroup(SIGKILL)
    }

    public func result(timeout: Duration) async throws -> ProcessGroupExecutionResult {
        do {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            let status = try await exitState.wait(timeout: timeout)
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else { throw RaceFreeProcessGroupError.timedOut }
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.stdoutDrainState.wait(timeout: remaining) }
                group.addTask { try await self.stderrDrainState.wait(timeout: remaining) }
                try await group.waitForAll()
            }
            if stdoutAccumulator.exceededLimit || stderrAccumulator.exceededLimit {
                throw RaceFreeProcessGroupError.outputLimitExceeded
            }
            return ProcessGroupExecutionResult(
                terminationStatus: status,
                stdout: stdoutAccumulator.snapshot,
                stderr: stderrAccumulator.snapshot)
        } catch {
            terminateAfterFailure()
            throw error
        }
    }

    private func signalVerifiedGroup(_ signal: Int32) throws {
        try verifyLeader()
        guard kill(-processID, signal) == 0 || errno == ESRCH else {
            throw RaceFreeProcessGroupError.identityMismatch
        }
    }

    private func signalRemainingVerifiedGroup(_ signal: Int32) throws {
        if let positivePID = ProcessSignalSafety.PositivePID(rawValue: processID),
           let observed = ProcessIdentityObservation.observe(processID: positivePID) {
            guard ProcessSignalSafety.verify(
                processID: positivePID,
                expectedIdentity: expectedIdentity,
                expectedParentProcessID: parentProcessID,
                observedIdentity: observed) == .verified else {
                throw RaceFreeProcessGroupError.identityMismatch
            }
        }
        guard kill(-processID, signal) == 0 || errno == ESRCH else {
            throw RaceFreeProcessGroupError.identityMismatch
        }
    }

    private func terminateAfterFailure() {
        do {
            try signalRemainingVerifiedGroup(SIGKILL)
        } catch {
            DebugLog.extraction("RaceFreeProcessGroupRunner refused failure cleanup for PID \(processID): \(error)")
        }
    }

    private func verifyLeader() throws {
        guard let positivePID = ProcessSignalSafety.PositivePID(rawValue: processID),
              ProcessSignalSafety.verify(
                processID: positivePID,
                expectedIdentity: expectedIdentity,
                expectedParentProcessID: parentProcessID,
                observedIdentity: ProcessIdentityObservation.observe(processID: positivePID)) == .verified
        else {
            throw RaceFreeProcessGroupError.identityMismatch
        }
    }

    private static func decodeWaitStatus(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        if signal == 0 { return (status >> 8) & 0xff }
        return -signal
    }
}

private final class CStringArray {
    let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ values: [String]) {
        count = values.count
        pointer = .allocate(capacity: count + 1)
        for (index, value) in values.enumerated() {
            pointer[index] = strdup(value)
        }
        pointer[count] = nil
    }

    deinit {
        for index in 0..<count { free(pointer[index]) }
        pointer.deallocate()
    }
}

// NSLock protects the bounded data buffer and limit flag.
// swiftlint:disable:next unchecked_sendable
private final class BoundedProcessAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var limitWasExceeded = false

    init(limit: Int) { self.limit = max(limit, 0) }

    func append(_ newData: Data) {
        lock.withLock {
            let remaining = max(limit - data.count, 0)
            data.append(newData.prefix(remaining))
            if newData.count > remaining { limitWasExceeded = true }
        }
    }

    var snapshot: Data { lock.withLock { data } }
    var exceededLimit: Bool { lock.withLock { limitWasExceeded } }
}

// NSLock protects completion state and continuation ownership.
// swiftlint:disable:next unchecked_sendable
private final class ProcessPipeDrainState: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var continuations: [UUID: CheckedContinuation<Void, Error>] = [:]

    func finish() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            guard !finished else { return [] }
            finished = true
            defer { continuations.removeAll() }
            return Array(continuations.values)
        }
        waiting.forEach { $0.resume() }
    }

    func wait(timeout: Duration) async throws {
        if lock.withLock({ finished }) { return }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [self] in try await waitForFinish() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw RaceFreeProcessGroupError.timedOut
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    private func waitForFinish() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                let completed = lock.withLock { () -> Bool in
                    if finished { return true }
                    continuations[id] = continuation
                    return false
                }
                if completed { continuation.resume() }
            }
        } onCancel: {
            let continuation = self.lock.withLock { self.continuations.removeValue(forKey: id) }
            continuation?.resume(throwing: CancellationError())
        }
    }
}

// NSLock protects exit status and continuation ownership.
// swiftlint:disable:next unchecked_sendable
private final class ProcessGroupExitState: @unchecked Sendable {
    private let lock = NSLock()
    private var innerStatus: Int32?
    private var continuations: [UUID: CheckedContinuation<Int32, Error>] = [:]

    var status: Int32? { lock.withLock { innerStatus } }

    func finish(status: Int32) {
        let waiting = lock.withLock { () -> [CheckedContinuation<Int32, Error>] in
            guard innerStatus == nil else { return [] }
            innerStatus = status
            defer { continuations.removeAll() }
            return Array(continuations.values)
        }
        waiting.forEach { $0.resume(returning: status) }
    }

    func wait(timeout: Duration) async throws -> Int32 {
        if let status { return status }
        return try await withThrowingTaskGroup(of: Int32.self) { group in
            group.addTask { [self] in try await waitForExit() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw RaceFreeProcessGroupError.timedOut
            }
            let first = try await group.next()
            group.cancelAll()
            return try first ?? { throw RaceFreeProcessGroupError.timedOut }()
        }
    }

    private func waitForExit() async throws -> Int32 {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Int32, Error>) in
                let immediate = lock.withLock { () -> Int32? in
                    if let innerStatus { return innerStatus }
                    continuations[id] = continuation
                    return nil
                }
                if let immediate { continuation.resume(returning: immediate) }
            }
        } onCancel: {
            let continuation = self.lock.withLock { self.continuations.removeValue(forKey: id) }
            continuation?.resume(throwing: CancellationError())
        }
    }
}
