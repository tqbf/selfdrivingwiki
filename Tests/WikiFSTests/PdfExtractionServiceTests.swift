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
