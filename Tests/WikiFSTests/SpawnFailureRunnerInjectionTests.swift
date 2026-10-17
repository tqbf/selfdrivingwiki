#if os(macOS)
import Foundation
import Testing
import WikiFSCore
@testable import WikiFSCore

/// Fault-injection at the process-runner spawn seam (#1409): a forced launch
/// failure must surface the OS status and the failing executable, not a bare
/// localized phrase. This is the layer every extractor probe, preflight, and
/// discovery flow spawns through (`AsyncProcessRunner.run`).
@Suite(.serialized, .timeLimit(.minutes(2)))
struct SpawnFailureRunnerInjectionTests {

    /// The nested-sandbox-exec denial signature (#1417): macOS denies the
    /// spawn of `sandbox-exec` with EPERM. The surfaced `.launchFailed` must
    /// name the failing executable AND carry the errno — pre-fix, the message
    /// was only `error.localizedDescription` ("Operation not permitted."),
    /// with no operation and no status.
    @Test func injectedEPERMCarriesOperationAndErrno() async throws {
        do {
            _ = try await AsyncProcessRunner.run(
                AsyncProcessRequest(executableURL: URL(fileURLWithPath: "/usr/bin/sandbox-exec")),
                hooks: .init(runProcess: { _ in
                    throw NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(SpawnFailureDetail.eperm),
                        userInfo: [NSFilePathErrorKey: "/usr/bin/sandbox-exec"])
                }))
            Issue.record("expected the injected EPERM launch failure to surface")
        } catch let error as AsyncProcessRunnerError {
            guard case .launchFailed(let message) = error else {
                Issue.record("expected .launchFailed, got \(error)")
                return
            }
            #expect(message.contains("spawn /usr/bin/sandbox-exec"), "got: \(message)")
            #expect(message.contains("POSIX errno 1"), "got: \(message)")
        }
    }

    /// A generic spawn failure (missing executable) keeps its structural OS
    /// status. Foundation's own error is used here — no stub — so the test
    /// pins the REAL error shape Foundation produces at `Process.run()`.
    @Test func missingExecutableKeepsStructuralStatus() async throws {
        let bogus = "/nonexistent/spawn-denial-\(UUID().uuidString)"
        do {
            _ = try await AsyncProcessRunner.run(
                AsyncProcessRequest(executableURL: URL(fileURLWithPath: bogus)))
            Issue.record("expected the missing-executable launch to fail")
        } catch let error as AsyncProcessRunnerError {
            guard case .launchFailed(let message) = error else {
                Issue.record("expected .launchFailed, got \(error)")
                return
            }
            #expect(message.contains("spawn \(bogus)"), "got: \(message)")
            #expect(message.contains("domain") || message.contains("errno"),
                    "the OS status (domain/code or errno) must ride the message: \(message)")
        }
    }
}
#endif
