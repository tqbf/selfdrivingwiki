#if os(macOS)
import Foundation
import Testing
import WikiFSCore
@testable import WikiFSEngine

/// Deterministic fixture-runtime tests (AC.3, deterministic half): a fake
/// `bun` / `python3` executable placed on an injected user PATH is discovered
/// through the same PATH-search the run context enables and is directly
/// executable in scratch. No real developer-installed runtime is required —
/// the stubs are plain `/bin/sh` scripts, so the test proves the DISCOVERY +
/// DIRECT-EXEC contract, not any specific runtime's behavior. The real-
/// runtime smokes live in `AgentSandboxProcessTests` (capability-gated).
@Suite(.timeLimit(.minutes(2)))
struct AgentRuntimePathTests {

    /// A fixture bin directory with one executable stub per runtime. Each stub
    /// prints a deterministic marker so the test can pin the executed argv.
    private func makeFixtureRuntimes() throws -> (binDirectory: URL, bunMarker: String, pythonMarker: String) {
        let bin = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-fixture-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let bunMarker = "BUN-MARKER-\(UUID().uuidString)"
        let pythonMarker = "PY-MARKER-\(UUID().uuidString)"
        try Self.writeExecutable(
            at: bin.appendingPathComponent("bun"),
            body: "#!/bin/sh\necho \(bunMarker)\n")
        try Self.writeExecutable(
            at: bin.appendingPathComponent("python3"),
            body: "#!/bin/sh\necho \(pythonMarker)\n")
        return (bin, bunMarker, pythonMarker)
    }

    private static func writeExecutable(at url: URL, body: String) throws {
        try Data(body.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    @Test func injectedBunIsDiscoveredAndExecuted() async throws {
        let fixture = try makeFixtureRuntimes()
        defer { try? FileManager.default.removeItem(at: fixture.binDirectory.deletingLastPathComponent()) }

        // The run context assembles the effective PATH from the injected user
        // environment PATH (which contains the fixture bin).
        let context = AgentRunContext(
            scratchDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("runtime-scratch-\(UUID().uuidString)", isDirectory: true),
            wikiID: WikiID(rawValue: "01RUNTIME"),
            wikictlDirectory: "/nonexistent-helpers",
            userPATH: fixture.binDirectory.path + ":/usr/bin:/bin")

        // Bare `bun` resolves on the effective PATH — the contract that makes
        // `command -v bun` / direct `bun …` work inside the run.
        let resolved = PathPreflight.resolve(executable: "bun", usingSearchPath: context.effectivePATH)
        guard case .found(let bunPath) = resolved else {
            Issue.record("bun was not discovered on the assembled effective PATH")
            return
        }
        #expect(bunPath == fixture.binDirectory.appendingPathComponent("bun").path)

        // And it is DIRECTLY executable (exec a process on the resolved path).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bunPath)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let status = try await Self.waitNonblocking(process, timeout: .seconds(15))
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(status == 0)
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == fixture.bunMarker)
    }

    @Test func injectedPythonIsDiscoveredAndExecuted() async throws {
        let fixture = try makeFixtureRuntimes()
        defer { try? FileManager.default.removeItem(at: fixture.binDirectory.deletingLastPathComponent()) }

        let context = AgentRunContext(
            scratchDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("runtime-scratch-\(UUID().uuidString)", isDirectory: true),
            wikiID: WikiID(rawValue: "01RUNTIME"),
            wikictlDirectory: "/nonexistent-helpers",
            userPATH: fixture.binDirectory.path + ":/usr/bin:/bin")

        let resolved = PathPreflight.resolve(executable: "python3", usingSearchPath: context.effectivePATH)
        guard case .found(let pythonPath) = resolved else {
            Issue.record("python3 was not discovered on the assembled effective PATH")
            return
        }
        #expect(pythonPath == fixture.binDirectory.appendingPathComponent("python3").path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let status = try await Self.waitNonblocking(process, timeout: .seconds(15))
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(status == 0)
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == fixture.pythonMarker)
    }

    /// Nonblocking subprocess wait (repository policy): a cooperative
    /// `Task.sleep` poll loop with a hard deadline — never `waitUntilExit`,
    /// never a parked thread, and no continuation that a starved pool could
    /// strand (an abandoned continuation survives `.timeLimit` cancellation
    /// and hangs the whole run). The 10ms poll yields the cooperative thread
    /// on every iteration, so `--parallel` stays healthy.
    static func waitNonblocking(_ process: Process, timeout: Duration) async throws -> Int32 {
        let deadline = ContinuousClock.now + timeout
        while process.isRunning {
            if ContinuousClock.now >= deadline {
                // Diagnose, don't hang: kill the child so `--parallel` runs
                // downstream suites aren't contending with a zombie.
                if process.isRunning { process.terminate() }
                throw SubprocessTimeout()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return process.terminationStatus
    }

    struct SubprocessTimeout: Error {}
}
#endif
