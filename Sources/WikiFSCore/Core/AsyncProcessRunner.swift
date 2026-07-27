// pattern: Imperative Shell

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct AsyncProcessRequest: Sendable {
    public enum OutputMode: Sendable {
        case separate
        case combined
    }

    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]?
    public let currentDirectoryURL: URL?
    public let outputMode: OutputMode
    public let cancellationGracePeriod: Duration

    public init(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil,
        outputMode: OutputMode = .separate,
        cancellationGracePeriod: Duration = .seconds(1)
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL
        self.outputMode = outputMode
        self.cancellationGracePeriod = cancellationGracePeriod
    }
}

public enum AsyncProcessOutput: Sendable {
    case separate(stdout: Data, stderr: Data)
    case combined(Data)
}

public struct AsyncProcessResult: Sendable {
    public let terminationStatus: Int32
    public let output: AsyncProcessOutput

    public init(terminationStatus: Int32, output: AsyncProcessOutput) {
        self.terminationStatus = terminationStatus
        self.output = output
    }

    public var stdoutData: Data {
        switch output {
        case .separate(let stdout, _): return stdout
        case .combined(let data): return data
        }
    }

    public var stderrData: Data {
        switch output {
        case .separate(_, let stderr): return stderr
        case .combined(let data): return data
        }
    }

    public var combinedData: Data {
        switch output {
        case .separate(let stdout, let stderr):
            var merged = stdout
            merged.append(stderr)
            return merged
        case .combined(let data):
            return data
        }
    }
}

public enum AsyncProcessRunnerError: Error, LocalizedError, Sendable, Equatable {
    case cancelled
    case launchFailed(String)
    case pipeSetupFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "process execution cancelled"
        case .launchFailed(let message):
            return "failed to launch process: \(message)"
        case .pipeSetupFailed(let message):
            return "failed to set up process pipes: \(message)"
        }
    }
}

public enum AsyncProcessRunner {
    public static func run(_ request: AsyncProcessRequest) async throws -> AsyncProcessResult {
        try await run(request, hooks: .none)
    }

    struct Hooks: Sendable {
        var beforeLaunch: (@Sendable () async -> Void)?
        var didLaunch: (@Sendable (Int32) -> Void)?
        var didTerminate: (@Sendable (Int32, Int32) -> Void)?
        var didRequestCancellation: (@Sendable () -> Void)?
        var runProcess: (@Sendable (Process) throws -> Void)?

        static let none = Hooks()
    }

    static func run(_ request: AsyncProcessRequest, hooks: Hooks) async throws -> AsyncProcessResult {
        let process = Process()
        process.executableURL = request.executableURL
        process.arguments = request.arguments
        process.environment = request.environment
        process.currentDirectoryURL = request.currentDirectoryURL

        let state = ExecutionState(
            expectedShutdowns: request.outputMode == .separate ? 2 : 1)
        let completionSignal = CompletionSignal()

        let stdoutPipe = Pipe()
        let stderrPipe = request.outputMode == .separate ? Pipe() : stdoutPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutDrainer: StreamDrainer
        let stderrDrainer: StreamDrainer?
        do {
            stdoutDrainer = try StreamDrainer(
                fileHandle: stdoutPipe.fileHandleForReading,
                label: "stdout",
                onShutdown: {
                    state.recordStreamShutdown()
                    completionSignal.signal()
                })
            if request.outputMode == .separate {
                stderrDrainer = try StreamDrainer(
                    fileHandle: stderrPipe.fileHandleForReading,
                    label: "stderr",
                    onShutdown: {
                        state.recordStreamShutdown()
                        completionSignal.signal()
                    })
            } else {
                stderrDrainer = nil
            }
        } catch let error as AsyncProcessRunnerError {
            throw error
        } catch {
            throw AsyncProcessRunnerError.pipeSetupFailed(error.localizedDescription)
        }

        let finish: @Sendable (CheckedContinuation<AsyncProcessResult, Error>) -> Void = { continuation in
            guard let outcome = state.takeCompletion() else { return }

            switch outcome {
            case .cancelled:
                continuation.resume(throwing: AsyncProcessRunnerError.cancelled)
            case .launchFailed(let message):
                continuation.resume(throwing: AsyncProcessRunnerError.launchFailed(message))
            case .success:
                let result = buildResult(
                    outputMode: request.outputMode,
                    status: state.terminationStatus,
                    stdoutDrainer: stdoutDrainer,
                    stderrDrainer: stderrDrainer)
                continuation.resume(returning: result)
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AsyncProcessResult, Error>) in
                let attemptCompletion: @Sendable () -> Void = {
                    finish(continuation)
                }
                completionSignal.install(attemptCompletion)

                process.terminationHandler = { proc in
                    hooks.didTerminate?(proc.processIdentifier, proc.terminationStatus)
                    state.recordTermination(status: proc.terminationStatus)
                    state.cancelEscalationTask()
                    stdoutDrainer.shutdown()
                    stderrDrainer?.shutdown()
                    completionSignal.signal()
                }

                Task {
                    if let beforeLaunch = hooks.beforeLaunch {
                        await beforeLaunch()
                    }

                    guard state.beginLaunchAttempt() else {
                        stdoutDrainer.abortBeforeLaunch()
                        stderrDrainer?.abortBeforeLaunch()
                        completionSignal.signal()
                        return
                    }

                    do {
                        if let runProcess = hooks.runProcess {
                            try runProcess(process)
                        } else {
                            try process.run()
                        }
                        hooks.didLaunch?(process.processIdentifier)
                        if let pid = state.recordLaunch(processID: process.processIdentifier) {
                            requestCancellation(
                                of: process,
                                processID: pid,
                                gracePeriod: request.cancellationGracePeriod,
                                state: state)
                        }
                    } catch {
                        if state.recordLaunchFailure(error.localizedDescription) {
                            stdoutDrainer.abortBeforeLaunch()
                            stderrDrainer?.abortBeforeLaunch()
                            completionSignal.signal()
                        }
                    }
                }
            }
        } onCancel: {
            let pid = state.requestCancellation()
            hooks.didRequestCancellation?()
            if let pid {
                requestCancellation(
                    of: process,
                    processID: pid,
                    gracePeriod: request.cancellationGracePeriod,
                    state: state)
            }
        }
    }

    private static func buildResult(
        outputMode: AsyncProcessRequest.OutputMode,
        status: Int32?,
        stdoutDrainer: StreamDrainer,
        stderrDrainer: StreamDrainer?
    ) -> AsyncProcessResult {
        let terminationStatus = status ?? 0
        let output: AsyncProcessOutput
        switch outputMode {
        case .separate:
            output = .separate(
                stdout: stdoutDrainer.dataSnapshot(),
                stderr: stderrDrainer?.dataSnapshot() ?? Data())
        case .combined:
            output = .combined(stdoutDrainer.dataSnapshot())
        }

        return AsyncProcessResult(
            terminationStatus: terminationStatus,
            output: output)
    }

    private static func requestCancellation(
        of process: Process,
        processID: Int32,
        gracePeriod: Duration,
        state: ExecutionState
    ) {
        if process.isRunning {
            process.terminate()
        }

        state.installEscalationTask(Task {
            do {
                try await Task.sleep(for: gracePeriod)
            } catch {
                return
            }
            guard state.shouldEscalateKill(for: processID) else { return }
            _ = kill(processID, SIGKILL)
        })
    }
}

/// `@unchecked Sendable` is correct because `lock` serializes all access to
/// `remainingShutdowns`, `phase`, `launchFailedMessage`, `terminationStatus`,
/// `cancelRequested`, `didResume`, and `escalationTask`.
// swiftlint:disable:next unchecked_sendable
private final class ExecutionState: @unchecked Sendable {
    enum Phase {
        case preparing
        case launching
        case running(processID: Int32)
        case cancelling(processID: Int32?)
        case terminated(status: Int32)
        case completed
    }

    enum Completion {
        case success
        case cancelled
        case launchFailed(String)
    }

    private let lock = NSLock()
    private var remainingShutdowns: Int
    private var phase: Phase = .preparing
    private var launchFailedMessage: String?
    private(set) var terminationStatus: Int32?
    private var cancelRequested = false
    private var didResume = false
    private var escalationTask: Task<Void, Never>?

    init(expectedShutdowns: Int) {
        self.remainingShutdowns = expectedShutdowns
    }

    func beginLaunchAttempt() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .preparing = phase else { return false }
        guard !cancelRequested else {
            phase = .cancelling(processID: nil)
            return false
        }
        phase = .launching
        return true
    }

    func recordLaunch(processID: Int32) -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        switch phase {
        case .launching where cancelRequested:
            phase = .cancelling(processID: processID)
            return processID
        case .launching:
            phase = .running(processID: processID)
            return nil
        case .cancelling:
            phase = .cancelling(processID: processID)
            return processID
        case .running, .terminated, .completed:
            return nil
        case .preparing:
            phase = .running(processID: processID)
            return nil
        }
    }

    func recordLaunchFailure(_ message: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return false }
        launchFailedMessage = message
        phase = cancelRequested ? .cancelling(processID: nil) : .preparing
        return true
    }

    func requestCancellation() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        cancelRequested = true
        switch phase {
        case .preparing:
            phase = .cancelling(processID: nil)
            return nil
        case .launching:
            phase = .cancelling(processID: nil)
            return nil
        case .running(let processID):
            phase = .cancelling(processID: processID)
            return processID
        case .cancelling, .terminated, .completed:
            return nil
        }
    }

    func recordTermination(status: Int32) {
        lock.lock()
        terminationStatus = status
        phase = .terminated(status: status)
        lock.unlock()
    }

    func recordStreamShutdown() {
        lock.lock()
        if remainingShutdowns > 0 {
            remainingShutdowns -= 1
        }
        lock.unlock()
    }

    func takeCompletion() -> Completion? {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return nil }
        guard remainingShutdowns == 0 else { return nil }

        if cancelRequested {
            guard terminationStatus != nil || !hasLaunchedProcess else { return nil }
            didResume = true
            phase = .completed
            return .cancelled
        }

        if let launchFailedMessage {
            didResume = true
            phase = .completed
            return .launchFailed(launchFailedMessage)
        }

        guard terminationStatus != nil else { return nil }
        didResume = true
        phase = .completed
        return .success
    }

    func installEscalationTask(_ task: Task<Void, Never>) {
        lock.lock()
        escalationTask?.cancel()
        escalationTask = task
        lock.unlock()
    }

    func cancelEscalationTask() {
        lock.lock()
        escalationTask?.cancel()
        escalationTask = nil
        lock.unlock()
    }

    func shouldEscalateKill(for processID: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        switch phase {
        case .cancelling(let currentProcessID):
            return currentProcessID == processID && terminationStatus == nil
        default:
            return false
        }
    }

    private var hasLaunchedProcess: Bool {
        switch phase {
        case .launching:
            return false
        case .running:
            return true
        case .cancelling(let processID):
            return processID != nil
        case .terminated:
            return true
        case .preparing, .completed:
            return false
        }
    }
}

/// `@unchecked Sendable` is correct because `lock` serializes all access to
/// `callback`, and `signal()` copies the callback while holding the lock before
/// enqueueing it onto `deliveryQueue`, which keeps completion delivery off the
/// drainer queues that may have triggered the signal.
// swiftlint:disable:next unchecked_sendable
private final class CompletionSignal: @unchecked Sendable {
    private let lock = NSLock()
    private let deliveryQueue = DispatchQueue(label: "AsyncProcessRunner.completion")
    private var callback: (@Sendable () -> Void)?

    func install(_ callback: @escaping @Sendable () -> Void) {
        lock.lock()
        self.callback = callback
        lock.unlock()
    }

    func signal() {
        lock.lock()
        let callback = self.callback
        lock.unlock()
        guard let callback else { return }
        deliveryQueue.async {
            callback()
        }
    }
}

/// `@unchecked Sendable` is correct because `buffer` and `isShutdown` are
/// confined to `queue`, while `fileHandle.readabilityHandler` only enqueues
/// work onto that same serial queue and never mutates shared state directly.
// swiftlint:disable:next unchecked_sendable
private final class StreamDrainer: @unchecked Sendable {
    private let queue: DispatchQueue
    private let fileHandle: FileHandle
    private let fileDescriptor: Int32
    private let onShutdown: @Sendable () -> Void
    private var buffer = Data()
    private var isShutdown = false

    init(
        fileHandle: FileHandle,
        label: String,
        onShutdown: @escaping @Sendable () -> Void
    ) throws {
        self.queue = DispatchQueue(label: "AsyncProcessRunner.\(label)")
        self.fileHandle = fileHandle
        self.fileDescriptor = fileHandle.fileDescriptor
        self.onShutdown = onShutdown
        try Self.enableNonBlocking(fileDescriptor: fileDescriptor)
        installHandler()
    }

    func shutdown() {
        queue.async { [self] in
            performShutdown()
        }
    }

    func abortBeforeLaunch() {
        queue.async { [self] in
            guard !isShutdown else { return }
            fileHandle.readabilityHandler = nil
            markShutdown()
        }
    }
    func dataSnapshot() -> Data {
        queue.sync { buffer }
    }

    private func installHandler() {
        fileHandle.readabilityHandler = { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.drainAvailableBytes()
            }
        }
    }

    private func performShutdown() {
        guard !isShutdown else { return }
        fileHandle.readabilityHandler = nil
        drainAvailableBytes()
        markShutdown()
    }

    private func drainAvailableBytes() {
        guard !isShutdown else { return }

        while true {
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            let count = chunk.withUnsafeMutableBytes { bytes in
                read(fileDescriptor, bytes.baseAddress, bytes.count)
            }

            if count > 0 {
                buffer.append(contentsOf: chunk.prefix(Int(count)))
                continue
            }

            if count == 0 {
                markShutdown()
                return
            }

            let errorNumber = errno
            if errorNumber == EINTR {
                continue
            }
            if errorNumber == EAGAIN || errorNumber == EWOULDBLOCK {
                return
            }

            DebugLog.agent("AsyncProcessRunner.StreamDrainer: read failed fd=\(fileDescriptor) errno=\(errorNumber)")
            markShutdown()
            return
        }
    }

    private func markShutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        fileHandle.readabilityHandler = nil
        do {
            try fileHandle.close()
        } catch {
            DebugLog.agent("AsyncProcessRunner.StreamDrainer: close failed fd=\(fileDescriptor): \(error.localizedDescription)")
        }
        onShutdown()
    }

    private static func enableNonBlocking(fileDescriptor: Int32) throws {
        let currentFlags = fcntl(fileDescriptor, F_GETFL)
        guard currentFlags >= 0 else {
            throw AsyncProcessRunnerError.pipeSetupFailed(
                "fcntl(F_GETFL) failed for fd \(fileDescriptor): errno \(errno)")
        }
        guard fcntl(fileDescriptor, F_SETFL, currentFlags | O_NONBLOCK) == 0 else {
            throw AsyncProcessRunnerError.pipeSetupFailed(
                "fcntl(F_SETFL) failed for fd \(fileDescriptor): errno \(errno)")
        }
    }
}
