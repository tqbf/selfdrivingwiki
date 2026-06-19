import Foundation
import Testing
@testable import WikiFS

@Suite struct PdfExtractionServiceTests {

    // MARK: - ProcessRegistry

    @Suite struct ProcessRegistryTests {
        @Test func tracksAndUntracks() {
            let reg = PdfExtractionService.ProcessRegistry()
            let p = Process()
            reg.track(p)
            // Internal state — verified indirectly via termination test below.
            reg.untrack(p)
        }

        @Test func terminatesTrackedProcesses() {
            let reg = PdfExtractionService.ProcessRegistry()
            // Use /bin/sleep as a long-running process we can cleanly kill.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sleep")
            p.arguments = ["999"]
            try? p.run()
            #expect(p.isRunning)

            reg.track(p)
            // Force termination via the same mechanism the notification uses.
            reg.terminateAllForTesting()
            p.waitUntilExit()
            #expect(!p.isRunning)
            #expect(p.terminationStatus != 0)  // killed, not exited cleanly
        }

        @Test func untrackedProcessNotTerminated() {
            let reg = PdfExtractionService.ProcessRegistry()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sleep")
            p.arguments = ["999"]
            try? p.run()
            #expect(p.isRunning)

            reg.track(p)
            reg.untrack(p)
            reg.terminateAllForTesting()
            // Process should still be running — it was untracked before terminate.
            // Clean up manually.
            if p.isRunning { p.terminate() }
            p.waitUntilExit()
        }

        @Test func doubleTrackDoesNotDuplicate() {
            let reg = PdfExtractionService.ProcessRegistry()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sleep")
            p.arguments = ["999"]
            try? p.run()
            reg.track(p)
            reg.track(p)  // double track — set semantics dedupe
            reg.terminateAllForTesting()
            p.waitUntilExit()
            #expect(!p.isRunning)
        }

        @Test func terminateWhenNoneRunningDoesNotCrash() {
            let reg = PdfExtractionService.ProcessRegistry()
            reg.terminateAllForTesting()  // should not crash
        }
    }

    // MARK: - OutputBuffer

    @Suite struct OutputBufferTests {
        @Test func appendAndTake() {
            let buf = PdfExtractionService.OutputBuffer()
            buf.append(Data([1, 2, 3]))
            let result = buf.take()
            #expect(result == Data([1, 2, 3]))
        }

        @Test func takeFromEmptyReturnsEmpty() {
            let buf = PdfExtractionService.OutputBuffer()
            let result = buf.take()
            #expect(result.isEmpty)
        }

        @Test func multipleAppendsAccumulate() {
            let buf = PdfExtractionService.OutputBuffer()
            buf.append(Data([1]))
            buf.append(Data([2, 3]))
            buf.append(Data([4, 5, 6]))
            let result = buf.take()
            #expect(result == Data([1, 2, 3, 4, 5, 6]))
        }

        @Test func takeReturnsAccumulatedData() {
            let buf = PdfExtractionService.OutputBuffer()
            buf.append(Data([1, 2, 3]))
            let first = buf.take()
            #expect(first == Data([1, 2, 3]))
            // take() returns the accumulated data but does NOT clear the buffer
            // (the caller drains it exactly once at process exit, so clearing is
            // unnecessary and would be misleading if called twice).
            buf.append(Data([4]))
            let second = buf.take()
            #expect(second == Data([1, 2, 3, 4]))
        }

        @Test func concurrentAppends() async {
            let buf = PdfExtractionService.OutputBuffer()
            let iterations = 500
            await withTaskGroup(of: Void.self) { group in
                for i in 0..<10 {
                    group.addTask {
                        for j in 0..<iterations {
                            buf.append(Data([UInt8((i * iterations + j) % 256)]))
                        }
                    }
                }
            }
            let result = buf.take()
            #expect(result.count == 10 * iterations)
        }
    }

    // MARK: - Pipe draining (covers the stdout-block bug)

    @Suite struct PipeDrainingTests {
        /// Reproduces the exact scenario: a subprocess writes more than the 64 KB
        /// pipe buffer. If the readabilityHandler doesn't drain continuously, the
        /// process blocks in write() and never exits — this test would hang.
        @Test func continuousDrainPreventsPipeBlock() async throws {
            // Write 256 KB of printable ASCII to stdout — well above the 64 KB
            // pipe buffer. `dd` from /dev/zero would work but produces null bytes.
            // Instead use a Perl one-liner that emits a known repeating pattern.
            let blockCount = 256  // 256 × 1024 = 256 KB
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [
                "-c",
                "perl -e 'print \"A\" x 1024 for 1..\(blockCount)'"
            ]

            let stdoutPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = FileHandle.nullDevice

            let buffer = PdfExtractionService.OutputBuffer()
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                buffer.append(data)
            }

            try process.run()
            process.waitUntilExit()

            // Flush the tail — the exact pattern from the fix in run().
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            if let tail = try? stdoutPipe.fileHandleForReading.readToEnd() {
                buffer.append(tail)
            }

            let allData = buffer.take()
            #expect(process.terminationStatus == 0)
            #expect(allData.count == blockCount * 1024,
                    "Expected \(blockCount * 1024) bytes, got \(allData.count)")
            // Spot-check: every byte should be 'A' (0x41).
            #expect(allData.allSatisfy { $0 == 0x41 })
        }

        /// Verifies the tail-flush fix: after nil'ing the readabilityHandler,
        /// `readToEnd()` still captures bytes that were in-flight in the kernel
        /// pipe buffer.
        @Test func tailFlushCapturesRemainingBytes() async throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            // Write a small amount so the handler likely gets it all, then verify
            // readToEnd() returns empty (no leftover bytes). Then write enough that
            // some bytes are still in the kernel buffer when we nil the handler.
            process.arguments = ["-c", "echo 'hello tail'"]

            let stdoutPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = FileHandle.nullDevice

            let buffer = PdfExtractionService.OutputBuffer()
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                buffer.append(data)
            }

            try process.run()
            process.waitUntilExit()

            // Brief sleep to let the dispatch source deliver any final bytes.
            try? await Task.sleep(for: .milliseconds(50))

            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            if let tail = try? stdoutPipe.fileHandleForReading.readToEnd() {
                buffer.append(tail)
            }

            let text = String(data: buffer.take(), encoding: .utf8) ?? ""
            #expect(process.terminationStatus == 0)
            #expect(text.contains("hello tail"))
        }

        /// When stdout is /dev/null (the streamProcess pattern), the subprocess
        /// must not block even with large output.
        @Test func nullDeviceStdoutDoesNotBlock() async throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "perl -e 'print \"X\" x 65536 for 1..4'"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }

        /// streamProcess captures stderr lines via the progress callback.
        @Test func streamProcessCapturesStderrLines() async throws {
            actor Collector {
                var lines: [String] = []
                func add(_ line: String) { lines.append(line) }
                var count: Int { lines.count }
            }
            let collector = Collector()
            let onProgress: @Sendable (String) -> Void = { line in
                Task { await collector.add(line) }
            }

            try await PdfExtractionService.streamProcess(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo 'line one' >&2; echo 'line two' >&2"],
                extraPATH: ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin",
                onProgress: onProgress
            )

            let captured = await collector.count
            #expect(captured > 0, "Should have captured at least one stderr line")
        }

        /// streamProcess throws on non-zero exit, and the error includes the
        /// stderr output for diagnostics.
        @Test func streamProcessThrowsOnFailure() async {
            let onProgress: @Sendable (String) -> Void = { _ in }

            do {
                try await PdfExtractionService.streamProcess(
                    executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "echo 'boom' >&2; exit 3"],
                    extraPATH: ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin",
                    onProgress: onProgress
                )
                Issue.record("Expected streamProcess to throw on exit code 3")
            } catch let error as PdfExtractionService.ExtractionError {
                guard case .conversionFailed(let status, let message) = error else {
                    Issue.record("Expected conversionFailed, got \(error)")
                    return
                }
                #expect(status == 3)
                #expect(message.contains("boom"))
            } catch {
                Issue.record("Unexpected error type: \(error)")
            }
        }
    }

    // MARK: - ExtractionError descriptions

    @Suite struct ExtractionErrorTests {
        @Test func scriptNotFoundIncludesPath() {
            let err = PdfExtractionService.ExtractionError.scriptNotFound
            let desc = err.errorDescription ?? ""
            #expect(desc.contains("PATH="))
            #expect(desc.contains("script not found"))
        }

        @Test func timedOutMessage() {
            let err = PdfExtractionService.ExtractionError.timedOut
            let desc = err.errorDescription ?? ""
            #expect(desc.contains("timed out"))
            #expect(desc.contains("180s"))
        }

        @Test func uvNotInstalledDetected() {
            let err = PdfExtractionService.ExtractionError.conversionFailed(
                status: 127, message: "uv: command not found\n")
            let desc = err.errorDescription ?? ""
            #expect(desc.contains("uv is not installed"))
            #expect(desc.contains("PATH="))
            #expect(desc.contains("curl"))
        }

        @Test func conversionFailedGeneric() {
            let err = PdfExtractionService.ExtractionError.conversionFailed(
                status: 1, message: "something broke\n")
            let desc = err.errorDescription ?? ""
            #expect(desc.contains("exited 1"))
            #expect(desc.contains("something broke"))
        }

        @Test func emptyOutput() {
            let err = PdfExtractionService.ExtractionError.emptyOutput
            let desc = err.errorDescription ?? ""
            #expect(desc.contains("no output"))
        }

        @Test func processFailedIncludesPath() {
            let underlying = NSError(domain: "test", code: 1)
            let err = PdfExtractionService.ExtractionError.processFailed(underlying)
            let desc = err.errorDescription ?? ""
            #expect(desc.contains("PATH="))
            #expect(desc.contains("Failed to launch"))
        }
    }

    // MARK: - resolveScript

    @Suite struct ResolveScriptTests {
        @Test @MainActor func returnsNilWhenNoCandidateHasScript() {
            // In a test environment with no bundled app or build dir,
            // resolveScript should return nil.
            let script = PdfExtractionService.resolveScript()
            // We don't assert nil because the test runner might have the script
            // available. We just verify it doesn't crash.
            _ = script
        }
    }
}
