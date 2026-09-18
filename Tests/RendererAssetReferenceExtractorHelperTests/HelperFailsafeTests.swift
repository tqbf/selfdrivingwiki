import Foundation
import Testing
@testable import WikiFSCore
import WikiFSTypes

// Acceptance tests for the helper failsafes added for #1259: a parent that
// dies without killing the helper's process group must not leave a
// non-terminating extractor spinning a full core forever.
//
// These tests spawn the real helper binary and deliberately withhold the
// supervision the production client normally provides:
//
//   1. Self-deadline: a never-terminating extractor with NO further parent
//      interaction must be ended by the helper's own ceiling (exit 3).
//   2. Orphan detection: a helper whose parent process dies (simulated by
//      the ExtractorProcessFixture `spawnChildAndExit` middleman) must exit
//      itself within one orphan-poll interval (exit 4).
//   3. Legitimate extractions are unaffected: a real extraction under
//      shortened-but-generous failsafe timings still exits 0 with a valid
//      frame.
@Suite("Helper failsafes", .serialized, .timeLimit(.minutes(4)))
struct HelperFailsafeTests {
    private static let neverTerminatingExtractor = Data(
        "__sdw_extract = function (input) { while (true) {} };".utf8)

    @Test("self-deadline exits a never-terminating extractor with no parent interaction")
    func selfDeadlineExitsNeverTerminatingExtractor() async throws {
        let helper = try locateHelper()
        let frame = try frame(Self.neverTerminatingExtractor, primaryInput: Data("{}".utf8))

        // Spawn with a shortened ceiling. The handle is only OBSERVED: no
        // terminateVerifiedGroup call, and the 30 s runner timeout is an
        // order of magnitude above the 2 s ceiling — exit code 3 can only
        // come from the helper's own failsafe.
        let handle = try RaceFreeProcessGroupRunner.launch(.init(
            executableURL: helper,
            arguments: ["--self-deadline-seconds=2"],
            environment: [:],
            currentDirectoryURL: URL(fileURLWithPath: "/"),
            standardInput: frame,
            stdoutLimit: 4096,
            stderrLimit: 4096))
        let started = ContinuousClock.now
        let result = try await handle.result(timeout: .seconds(30))
        let elapsed = ContinuousClock.now - started

        #expect(result.terminationCause == .exited(code: 3))
        #expect(elapsed < .seconds(10))
        #expect(Self.stderrText(result).contains("self-deadline"))
    }

    @Test(
        "orphaned helper exits within one orphan-poll interval",
        .disabled(
            "Load-flaky under parallel build/test load: the child PID frame can miss its read window (.childPIDFrameMissing) and the 3s exit bound assumes an idle machine — same class as the #1296 graceful-shutdown disable. Re-enable with a deterministic parent-death signal or a load-scaled bound"))
    func orphanedHelperExitsItself() async throws {
        let helper = try locateHelper()
        let fixture = try fixtureExecutable()
        let frame = try frame(Self.neverTerminatingExtractor, primaryInput: Data("{}".utf8))

        // The middleman spawns the helper as ITS child, seeds the
        // never-terminating frame into the helper's stdin, lingers 700 ms
        // (so the helper's main arms its failsafes against a live parent),
        // then exits — orphaning the helper with zero signals sent.
        let request = OrphanFixtureRequest(
            version: 1,
            requestID: "orphan-\(UInt64.random(in: 0 ..< .max))",
            mode: "spawnChildAndExit",
            childPath: helper.path,
            childArguments: [
                // Well above the observed window: only the orphan failsafe
                // can end the helper inside the assertion bound.
                "--self-deadline-seconds=600",
                "--orphan-poll-milliseconds=100",
            ],
            childStandardInput: frame,
            preExitDelayMilliseconds: 700)
        let fixtureInput = try JSONEncoder().encode(request) + Data([0x0A])

        let handle = try RaceFreeProcessGroupRunner.launch(.init(
            executableURL: fixture,
            environment: ["LANG": "C.UTF-8", "LC_ALL": "C.UTF-8"],
            standardInput: fixtureInput,
            stdoutLimit: 16 * 1024,
            stderrLimit: 4096))
        let orphaned = try await childPIDFrame(from: handle.stdoutChunks)
        // The helper is NOT this test's child (its parent was the fixture),
        // so `result` reaps the fixture and returns the moment every pipe
        // writer is gone — which happens exactly when the orphaned helper
        // exits itself. The middleman never signals the helper's group.
        let result = try await handle.result(timeout: .seconds(15))
        let elapsed = ContinuousClock.now - orphaned.instant

        #expect(result.terminationCause == .exited(code: 0))
        #expect(elapsed < .seconds(3))
        #expect(await Self.processIsGone(orphaned.childPID))
        let stderrText = Self.stderrText(result)
        #expect(stderrText.contains("orphaned") || stderrText.contains("supervisor"))
    }

    @Test("legitimate extraction completes under shortened failsafe timings")
    func legitimateExtractionUnaffected() async throws {
        let helper = try locateHelper()
        let extractor = Data("""
        __sdw_extract = function (input) {
          var data = JSON.parse(input);
          var records = [];
          (data.nodes || []).forEach(function (node) {
            if (node.type === "file" && node.file) {
              records.push({ role: "imageNode", reference: node.file });
            }
          });
          return { records: records };
        };
        """.utf8)
        let frame = try frame(extractor, primaryInput: Data(#"{"nodes":[{"type":"file","file":"diagram.png"}]}"#.utf8))

        let handle = try RaceFreeProcessGroupRunner.launch(.init(
            executableURL: helper,
            arguments: ["--self-deadline-seconds=30", "--orphan-poll-milliseconds=100"],
            environment: [:],
            currentDirectoryURL: URL(fileURLWithPath: "/"),
            standardInput: frame,
            stdoutLimit: 4096,
            stderrLimit: 4096))
        let result = try await handle.result(timeout: .seconds(30))

        #expect(result.terminationCause == .exited(code: 0))
        let response = try JSONSerialization.jsonObject(
            with: try Self.payloadFrame(result.stdout)) as? [String: Any]
        #expect(response?["ok"] as? Bool == true)
        let records = response?["records"] as? [[String: Any]]
        #expect(records?.count == 1)
        #expect(records?.first?["reference"] as? String == "diagram.png")
        #expect(Self.stderrText(result).isEmpty)
    }

    @Test("unrecognized arguments fail fast with a usage error")
    func unrecognizedArgumentFailsFast() async throws {
        let helper = try locateHelper()
        let frame = try frame(
            Data("__sdw_extract = function (input) { return { records: [] }; };".utf8),
            primaryInput: Data("{}".utf8))
        let handle = try RaceFreeProcessGroupRunner.launch(.init(
            executableURL: helper,
            arguments: ["--totally-unknown-flag"],
            environment: [:],
            currentDirectoryURL: URL(fileURLWithPath: "/"),
            standardInput: frame,
            stdoutLimit: 4096,
            stderrLimit: 4096))
        let result = try await handle.result(timeout: .seconds(10))
        #expect(result.terminationCause == .exited(code: 64))
        #expect(Self.stderrText(result).contains("unrecognized argument"))
    }

    // MARK: - Fixtures/helpers

    private struct OrphanFixtureRequest: Codable {
        let version: Int
        let requestID: String
        let mode: String
        let childPath: String
        let childArguments: [String]
        let childStandardInput: Data
        let preExitDelayMilliseconds: Int
    }

    private func locateHelper() throws -> URL {
        guard let resolved = RendererAssetExtractorHelperLocation.locate(
            mainBundle: Bundle.main,
            processInfo: .init()) else {
            throw HelperFailsafeTestsError.missingHelper
        }
        return resolved
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
            throw HelperFailsafeTestsError.missingFixture
        }
        return executable
    }

    private func frame(_ extractor: Data, primaryInput: Data) throws -> Data {
        try RendererAssetReferenceExtractorClient.frameRequest(.init(
            helperURL: try locateHelper(),
            extractorBytes: extractor,
            entryFunction: "__sdw_extract",
            primaryInput: primaryInput,
            maxExtractorInputBytes: 256 * 1_024,
            maxExtractorOutputBytes: 256 * 1_024,
            maxReferenceCount: 256,
            // Irrelevant here: these tests never route through Client.run,
            // so the parent-side deadline never applies.
            maxExecutionSeconds: 3_600,
            stdoutLimit: 4096,
            stderrLimit: 4096))
    }

    /// The fixture's `child spawned` frame: the orphaned helper's PID plus
    /// the instant just after arrival (the fixture exits within
    /// milliseconds of writing it).
    private func childPIDFrame(
        from stream: AsyncStream<Data>
    ) async throws -> (childPID: Int32, instant: ContinuousClock.Instant) {
        try await withThrowingTaskGroup(
            of: (childPID: Int32, instant: ContinuousClock.Instant).self) { group in
            group.addTask {
                var data = Data()
                for await chunk in stream {
                    data.append(chunk)
                    guard let newline = data.firstIndex(of: 0x0A),
                          let object = try? JSONSerialization.jsonObject(
                              with: Data(data[..<newline])) as? [String: Any],
                          let number = object["childPID"] as? NSNumber else { continue }
                    return (number.int32Value, ContinuousClock.now)
                }
                throw HelperFailsafeTestsError.childPIDFrameMissing
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw HelperFailsafeTestsError.childPIDFrameMissing
            }
            let result = try await group.next()
            group.cancelAll()
            guard let result else { throw HelperFailsafeTestsError.childPIDFrameMissing }
            return result
        }
    }

    private static func stderrText(_ result: ProcessGroupExecutionResult) -> String {
        String(decoding: result.stderr, as: UTF8.self)
    }

    /// Strip the helper's 4-byte frame prefix, mirroring the client decoder.
    private static func payloadFrame(_ stdout: Data) throws -> Data {
        guard stdout.count >= 4 else { throw HelperFailsafeTestsError.malformedFrame }
        let length = stdout.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
        let payload = stdout.dropFirst(4)
        guard payload.count == Int(length) else { throw HelperFailsafeTestsError.malformedFrame }
        return Data(payload)
    }

    private static func processIsGone(_ rawPID: Int32) async -> Bool {
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

private enum HelperFailsafeTestsError: Error {
    case missingHelper
    case missingFixture
    case childPIDFrameMissing
    case malformedFrame
}
