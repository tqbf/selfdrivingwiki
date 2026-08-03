#if os(macOS)
import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#endif
@testable import WikiFSCore

@Suite(.serialized, .timeLimit(.minutes(2)))
struct AsyncProcessRunnerTests {
    /// `@unchecked Sendable` is correct because `lock` serializes the single
    /// mutable `value` flag across the test task and hook callbacks.
    // swiftlint:disable:next unchecked_sendable
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }

        func get() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    /// `@unchecked Sendable` is correct because `lock` serializes the single
    /// mutable counter across the test task and hook callbacks.
    // swiftlint:disable:next unchecked_sendable
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        func get() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private actor LaunchGate {
        private var started = false
        private var startedContinuation: CheckedContinuation<Void, Never>?
        private var cancellationRequested = false
        private var cancellationContinuation: CheckedContinuation<Void, Never>?
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            started = true
            startedContinuation?.resume()
            startedContinuation = nil
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { continuation in
                startedContinuation = continuation
            }
        }

        func open() {
            continuation?.resume()
            continuation = nil
        }

        func cancellationDidRequest() {
            cancellationRequested = true
            cancellationContinuation?.resume()
            cancellationContinuation = nil
        }

        func waitUntilCancellationRequested() async {
            if cancellationRequested { return }
            await withCheckedContinuation { continuation in
                cancellationContinuation = continuation
            }
        }
    }

    @Test func capturesSeparateOutputAndStatus() async throws {
        let request = AsyncProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'out-head\\nout-tail'; printf 'err-head\\nerr-tail' >&2; exit 7"])

        let result = try await AsyncProcessRunner.run(request)

        #expect(result.terminationStatus == 7)
        #expect(String(decoding: result.stdoutData, as: UTF8.self).contains("out-tail"))
        #expect(String(decoding: result.stderrData, as: UTF8.self).contains("err-tail"))
    }

    @Test func capturesOutputLargerThanPipeCapacity() async throws {
        let request = AsyncProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "perl -e 'print \"A\" x 1024 for 1..256; print STDERR \"B\" x 1024 for 1..128'"])

        for _ in 0..<3 {
            let result = try await AsyncProcessRunner.run(request)
            #expect(result.terminationStatus == 0)
            #expect(result.stdoutData.count == 256 * 1024)
            #expect(result.stderrData.count == 128 * 1024)
        }
    }

    @Test func launchFailureReturnsOnce() async {
        let request = AsyncProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"))

        do {
            _ = try await AsyncProcessRunner.run(
                request,
                hooks: .init(runProcess: { _ in
                    throw NSError(
                        domain: "AsyncProcessRunnerTests",
                        code: 42,
                        userInfo: [NSLocalizedDescriptionKey: "simulated launch failure"])
                }))
            Issue.record("Expected launch failure")
        } catch let error as AsyncProcessRunnerError {
            switch error {
            case .launchFailed(let message):
                #expect(message.contains("simulated launch failure"))
                break
            case .cancelled, .pipeSetupFailed:
                Issue.record("Unexpected error: \(error.localizedDescription)")
            }
        } catch {
            Issue.record("Unexpected error: \(error.localizedDescription)")
        }
    }

    @Test func cancellationBeforeLaunchDoesNotSpawnChild() async throws {
        let gate = LaunchGate()
        let launched = Flag()
        let request = AsyncProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 0"])

        let task = Task {
            try await AsyncProcessRunner.run(
                request,
                hooks: .init(
                    beforeLaunch: { await gate.wait() },
                    didLaunch: { _ in launched.set() },
                    didRequestCancellation: { Task { await gate.cancellationDidRequest() } }))
        }

        await gate.waitUntilStarted()
        task.cancel()
        await gate.waitUntilCancellationRequested()
        await gate.open()
        await #expect(throws: AsyncProcessRunnerError.cancelled) {
            _ = try await task.value
        }
        #expect(launched.get() == false)
    }

    @Test func cancellationEscalatesWhenChildIgnoresTermination() async throws {
        let readyFile = try makeMarkerFile()
        let request = AsyncProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "ready=\"$1\"; echo started > \"$ready\"; trap '' TERM; while :; do sleep 1; done", "sh", readyFile.path],
            cancellationGracePeriod: .milliseconds(100))

        let task = Task {
            try await AsyncProcessRunner.run(request)
        }

        try await waitForFile(readyFile)
        task.cancel()
        await #expect(throws: AsyncProcessRunnerError.cancelled) {
            _ = try await task.value
        }
    }

    @Test func cancellationReturnsWhenDescendantKeepsPipeOpen() async throws {
        let readyFile = try makeMarkerFile()
        let holdFile = try makeMarkerFile()
        if FileManager.default.fileExists(atPath: holdFile.path) {
            try FileManager.default.removeItem(at: holdFile)
        }

        let launchedProcessID = Counter()
        let request = AsyncProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                """
                ready="$1"
                hold="$2"
                /usr/bin/perl -MPOSIX=setsid -e 'setsid() or die "setsid: $!"; open my $fh, ">", $ARGV[0] or die "open: $!"; print {$fh} $$; close $fh or die "close: $!"; exec "sleep", "60" or die "exec: $!";' "$ready" &
                trap '' TERM
                while [ ! -f "$hold" ]; do sleep 0.05; done
                """,
                "sh",
                readyFile.path,
                holdFile.path,
            ],
            cancellationGracePeriod: .milliseconds(100))

        let task = Task {
            try await AsyncProcessRunner.run(
                request,
                hooks: .init(didLaunch: { pid in
                    launchedProcessID.increment()
                    _ = pid
                }))
        }

        let descendantPID = try await waitForPIDFile(readyFile)
        #expect(kill(descendantPID, 0) == 0)

        task.cancel()
        await #expect(throws: AsyncProcessRunnerError.cancelled) {
            _ = try await task.value
        }
        #expect(kill(descendantPID, 0) == 0)
        _ = kill(descendantPID, SIGKILL)
        #expect(launchedProcessID.get() == 1)
    }

    @Test func cancellationDuringOutputCleansUpOnce() async throws {
        let readyFile = try makeMarkerFile()
        let terminations = Counter()
        let request = AsyncProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                """
                ready="$1"
                echo started > "$ready"
                trap '' TERM
                while :; do
                  printf 'streaming-line\\n'
                  sleep 0.05
                done
                """,
                "sh",
                readyFile.path,
            ],
            cancellationGracePeriod: .milliseconds(100))

        let task = Task {
            try await AsyncProcessRunner.run(
                request,
                hooks: .init(didTerminate: { _, _ in
                    terminations.increment()
                }))
        }

        try await waitForFile(readyFile)
        task.cancel()
        await #expect(throws: AsyncProcessRunnerError.cancelled) {
            _ = try await task.value
        }
        #expect(terminations.get() == 1)
    }

    @Test func loginShellPathUsesAsyncRunner() async {
        let path = await PathPreflight.loginShellPATH(using: { _ in
            AsyncProcessResult(
                terminationStatus: 0,
                output: .separate(stdout: Data("/opt/homebrew/bin:/usr/local/bin".utf8), stderr: Data()))
        })

        #expect(path == "/opt/homebrew/bin:/usr/local/bin")
    }

    @Test func resolveOnLoginShellFallsBackAfterRunnerFailure() async {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        } catch {
            Issue.record("Failed to create temp directory: \(error.localizedDescription)")
            return
        }
        let executable = temporaryDirectory.appendingPathComponent("phase1-test-exe", isDirectory: false)
        _ = FileManager.default.createFile(
            atPath: executable.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o755])
        defer {
            do {
                try FileManager.default.removeItem(at: temporaryDirectory)
            } catch {
                Issue.record("Failed to remove temp directory: \(error.localizedDescription)")
            }
        }

        let result = await PathPreflight.resolveOnLoginShell(
            executable: "phase1-test-exe",
            runProcess: { _ in throw AsyncProcessRunnerError.launchFailed("boom") },
            fallbackPath: temporaryDirectory.path)

        #expect(result == .found(path: executable.path))
    }

    @Test func asyncProductionDiscoveryAwaitsResolver() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Issue.record("Failed to create temp directory: \(error.localizedDescription)")
            return
        }
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("Failed to remove temp directory: \(error.localizedDescription)")
            }
        }
        let one = directory.appendingPathComponent("one")
        let two = directory.appendingPathComponent("two")
        _ = FileManager.default.createFile(atPath: one.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        _ = FileManager.default.createFile(atPath: two.path, contents: Data(), attributes: [.posixPermissions: 0o755])

        let catalog = [
            KnownACPAgent(
                id: ProviderID(rawValue: "one"),
                label: "One",
                summary: "",
                detectExecutable: "one",
                command: ["one", "--acp"]),
            KnownACPAgent(
                id: ProviderID(rawValue: "two"),
                label: "Two",
                summary: "",
                detectExecutable: "two",
                command: ["two", "--acp"]),
        ]

        let found = await ACPProviderDiscovery.discoverOnLoginShell(
            in: catalog,
            runProcess: { _ in
                AsyncProcessResult(
                    terminationStatus: 0,
                    output: .separate(stdout: Data(directory.path.utf8), stderr: Data()))
            })

        #expect(found.map(\.agent.id) == [ProviderID(rawValue: "one"), ProviderID(rawValue: "two")])
    }

    private func makeMarkerFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("async-process-runner-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString, isDirectory: false)
    }

    private func waitForFile(_ url: URL, timeout: Duration = .seconds(15)) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "AsyncProcessRunnerTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Timed out waiting for file at \(url.path)"
        ])
    }

    private func waitForPIDFile(_ url: URL, timeout: Duration = .seconds(5)) async throws -> Int32 {
        try await waitForFile(url, timeout: timeout)
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Int32(text) ?? -1
    }
}
#endif
