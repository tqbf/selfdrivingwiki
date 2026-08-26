import Foundation
import Testing
@testable import WikiFSCore
import WikiFSTypes

@Suite("Race-free process group runner", .serialized, .timeLimit(.minutes(1)))
struct RaceFreeProcessGroupRunnerTests {
    @Test func protocolExchangeClosesInputAndReturnsOneResult() async throws {
        let executable = try fixtureExecutable()
        let input = Data("{\"version\":1,\"requestID\":\"success\",\"mode\":\"success\"}\n".utf8)
        let handle = try RaceFreeProcessGroupRunner.launch(.init(
            executableURL: executable,
            environment: ["LANG": "C.UTF-8", "LC_ALL": "C.UTF-8"],
            standardInput: input,
            stdoutLimit: 16 * 1024,
            stderrLimit: 4 * 1024))
        let result = try await handle.result(timeout: .seconds(5))
        #expect(result.terminationCause == .exited(code: 0))
        #expect(result.terminationStatus == 0)
        let frames = result.stdout.split(separator: 0x0A)
        #expect(frames.count == 2)
        #expect(String(decoding: frames[0], as: UTF8.self).contains(#""kind":"progress""#))
        #expect(String(decoding: frames[1], as: UTF8.self).contains(#""kind":"result""#))
    }

    @Test func verifiedGroupTerminationKillsFixtureChild() async throws {
        let executable = try fixtureExecutable()
        let input = Data("{\"version\":1,\"requestID\":\"hold\",\"mode\":\"holdWithChild\"}\n".utf8)
        let handle = try RaceFreeProcessGroupRunner.launch(.init(
            executableURL: executable,
            environment: ["LANG": "C.UTF-8", "LC_ALL": "C.UTF-8"],
            standardInput: input,
            stdoutLimit: 16 * 1024,
            stderrLimit: 4 * 1024))
        let childPID = try await childPID(from: handle.stdoutChunks)
        try await handle.terminateVerifiedGroup(gracePeriod: .milliseconds(50))
        let result = try await handle.result(timeout: .seconds(5))
        #expect(result.terminationCause == .signaled(signal: SIGKILL))
        #expect(await processIsGone(handle.processID))
        #expect(await processIsGone(childPID))
    }

    @Test func immediateResultCancellationNeverLeavesARegisteredWaiter() async throws {
        for index in 0 ..< 20 {
            let executable = try fixtureExecutable()
            let input = Data("{\"version\":1,\"requestID\":\"cancel-\(index)\",\"mode\":\"holdWithChild\"}\n".utf8)
            let handle = try RaceFreeProcessGroupRunner.launch(.init(
                executableURL: executable,
                environment: ["LANG": "C.UTF-8", "LC_ALL": "C.UTF-8"],
                standardInput: input,
                stdoutLimit: 16 * 1024,
                stderrLimit: 4 * 1024))
            let wait = Task { try await handle.result(timeout: .seconds(5)) }
            wait.cancel()
            await #expect(throws: CancellationError.self) { _ = try await wait.value }
            #expect(await processIsGone(handle.processID))
        }
    }

    @Test func resultTimeoutKillsFixtureGroup() async throws {
        let executable = try fixtureExecutable()
        let input = Data("{\"version\":1,\"requestID\":\"timeout\",\"mode\":\"holdWithChild\"}\n".utf8)
        let handle = try RaceFreeProcessGroupRunner.launch(.init(
            executableURL: executable,
            environment: ["LANG": "C.UTF-8", "LC_ALL": "C.UTF-8"],
            standardInput: input,
            stdoutLimit: 16 * 1024,
            stderrLimit: 4 * 1024))
        let childPID = try await childPID(from: handle.stdoutChunks)
        await #expect(throws: RaceFreeProcessGroupError.timedOut) {
            _ = try await handle.result(timeout: .milliseconds(50))
        }
        #expect(await processIsGone(handle.processID))
        #expect(await processIsGone(childPID))
    }

    private func fixtureExecutable() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let buildRoot = root.appendingPathComponent(".build", isDirectory: true)
        let candidates = try FileManager.default.contentsOfDirectory(
            at: buildRoot,
            includingPropertiesForKeys: [.isDirectoryKey])
            .map { $0.appendingPathComponent("debug/ExtractorProcessFixture") }
        guard let executable = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else {
            throw TestFailure("fixture executable is missing below \(buildRoot.path)")
        }
        return executable
    }

    private func childPID(from stream: AsyncStream<Data>) async throws -> Int32 {
        try await withThrowingTaskGroup(of: Int32.self) { group in
            group.addTask {
                var data = Data()
                for await chunk in stream {
                    data.append(chunk)
                    guard let newline = data.firstIndex(of: 0x0A),
                          let object = try? JSONSerialization.jsonObject(with: Data(data[..<newline])) as? [String: Any],
                          let number = object["childPID"] as? NSNumber else { continue }
                    return number.int32Value
                }
                throw TestFailure("child PID frame was missing")
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw TestFailure("child PID frame timed out")
            }
            let result = try await group.next()
            group.cancelAll()
            guard let result else { throw TestFailure("child PID frame was missing") }
            return result
        }
    }

    private func processIsGone(_ rawPID: Int32) async -> Bool {
        guard let pid = ProcessSignalSafety.PositivePID(rawValue: rawPID) else { return true }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if ProcessIdentityObservation.observe(processID: pid) == nil { return true }
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return false }
        }
        return ProcessIdentityObservation.observe(processID: pid) == nil
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
