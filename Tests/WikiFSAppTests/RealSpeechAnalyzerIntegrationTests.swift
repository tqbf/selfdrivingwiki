#if os(macOS)
import AVFoundation
import Foundation
import os
import Testing
@testable import WikiFSEngine

/// AC.6 — the gated REAL-engine suite. On a supported macOS 26 machine with
/// the local speech model installed, this transcribes a synthetic spoken
/// AIFF produced by `say`. The gate is deliberate: deterministic injected-
/// engine tests remain the CI gate; this suite runs only when the operator
/// opts in with `WIKIFS_REAL_SPEECH=1`. A model/locale SETUP FAILURE here is
/// a typed failure — never a passing transcription check.
@Suite("Real speech analyzer integration", .serialized, .timeLimit(.minutes(10)))
struct RealSpeechAnalyzerIntegrationTests {

    /// The fixture sentence: distinctive words the transcript must contain.
    private static let fixtureSentence =
        "The self driving wiki speech fixture is speaking now."

    /// Generates the `say` AIFF fixture with the repository's non-blocking,
    /// timeout-bounded subprocess pattern (never `waitUntilExit()` on the
    /// cooperative pool).
    private static func makeFixture() async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-fixture-\(UUID().uuidString).aiff")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", url.path, fixtureSentence]
        let stdin = Pipe(); let stdout = Pipe(); let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // Race termination against a bounded timeout (AGENTS.md rule).
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    if !process.isRunning { cont.resume(); return }
                    process.terminationHandler = { process in
                        if process.terminationStatus == 0 { cont.resume() }
                        else {
                            cont.resume(throwing: SpeechTranscriptionError.unreadableAudio)
                        }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                if !process.isRunning { return }
                process.terminate()
                throw SpeechTranscriptionError.unreadableAudio
            }
            _ = try await group.next()
            group.cancelAll()
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size > 1_000 else {
            throw SpeechTranscriptionError.unreadableAudio
        }
        return url
    }

    @Test func sayFixtureTranscribes() async throws {
        guard ProcessInfo.processInfo.environment["WIKIFS_REAL_SPEECH"] == "1" else {
            // Ungated runs SKIP with a visible marker: the CI gate stays on
            // the deterministic injected-engine suites.
            throw SkipTest()
        }
        let engine = SystemSpeechTranscriber()
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        // Readiness: a missing model asset is a typed SETUP FAILURE, never
        // a pass.
        let readiness = await engine.readiness(localeID: "en-US")
        guard case .ready = readiness else {
            Issue.record("REAL-ENGINE SETUP FAILURE: \(readiness) — install the en-US speech model, then re-run with WIKIFS_REAL_SPEECH=1")
            return
        }

        let transcription = try await engine.transcribeFile(
            at: fixture,
            localeID: "en-US",
            deadline: ContinuousClock.now.advanced(by: .seconds(120)),
            onProgress: nil)
        #expect(transcription.text.isEmpty == false)
        #expect(transcription.engine == SpeechTranscribers.systemEngineIdentifier)
        // The transcript must actually contain the fixture's words (lower-
        // cased containment tolerates punctuation/casing differences).
        let lowered = transcription.text.lowercased()
        #expect(lowered.contains("fixture"))
        #expect(lowered.contains("speaking"))
    }
}

/// Swift Testing's skip signal for the ungated run.
private struct SkipTest: Error {}
#endif
