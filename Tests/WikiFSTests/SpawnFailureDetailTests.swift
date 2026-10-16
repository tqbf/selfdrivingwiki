import Foundation
import Testing
import WikiFSCore
import WikiFSEngine

/// Diagnostics for failed subprocess spawns (#1409) and their sandbox-denial
/// classification (#1417's signature at the spawn boundary).
///
/// Two pure layers are pinned here:
///
/// 1. `SpawnFailureDetail.render` — a spawn failure's surfaced text must carry
///    the OS status (errno, domain, failing path) instead of the flattened
///    `localizedDescription` phrase. The pre-fix behavior — a bare phrase for
///    `NSError`s and the generic Foundation sentence for any other error — is
///    what left operators diagnosing spawn failures from a unified-log dig.
/// 2. `ACPToolFailureClassification.classifySpawn` / `.annotatedSpawnCause` —
///    the synchronously available denial signatures (`sandbox-exec` spawn
///    EPERM; a child's nested `sandbox_apply` stderr line) must annotate the
///    surfaced cause. Seatbelt denial records reach the unified log
///    asynchronously (#1279), so classification is intentionally limited to
///    what the failing process itself reported.
@Suite("SpawnFailureDetail")
struct SpawnFailureDetailTests {

    // MARK: - SpawnFailureDetail.render

    /// A POSIX `EPERM` spawn failure renders with its numeric errno — the
    /// status `localizedDescription` drops (it keeps only the phrase).
    @Test func posixEPERRendersErrno() {
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(SpawnFailureDetail.eperm))
        let rendered = SpawnFailureDetail.render(error)
        #expect(rendered.contains("POSIX errno 1"), "got: \(rendered)")
        #expect(SpawnFailureDetail.posixErrno(of: error) == SpawnFailureDetail.eperm)
        #expect(SpawnFailureDetail.isPosixError(error, code: SpawnFailureDetail.eperm))
    }

    /// A POSIX error carrying the failing file path keeps it — the failing
    /// operation is part of the denial context.
    @Test func posixErrorWithFilePathKeepsPath() {
        let error = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(SpawnFailureDetail.eperm),
            userInfo: [NSFilePathErrorKey: "/usr/bin/sandbox-exec"])
        let rendered = SpawnFailureDetail.render(error, operation: "spawn")
        #expect(rendered.contains("POSIX errno 1"))
        #expect(rendered.contains("/usr/bin/sandbox-exec"))
        #expect(rendered.hasPrefix("spawn: "))
    }

    /// A Mach-domain error keeps its numeric status.
    @Test func machErrorRendersCode() {
        let error = NSError(domain: NSMachErrorDomain, code: 44)
        #expect(SpawnFailureDetail.render(error).contains("(Mach error 44)"))
    }

    /// A Cocoa error with an underlying POSIX error renders BOTH statuses, so
    /// e.g. a wrapped `ENOENT` stays diagnosable.
    @Test func cocoaErrorIncludesUnderlyingPosixStatus() {
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: 4,
            userInfo: [
                NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 2),
            ])
        let rendered = SpawnFailureDetail.render(error)
        #expect(rendered.contains("domain NSCocoaErrorDomain, code 4"))
        #expect(rendered.contains("underlying:"))
        #expect(rendered.contains("POSIX errno 2"))
    }

    /// A non-`NSError` Swift error renders its case payload. This is the
    /// kernel-diagnostics shape from #1417 (`exited(code=71)` + a stderr
    /// tail): `localizedDescription` would collapse it to Foundation's
    /// generic sentence and lose the payload entirely.
    @Test func nonNSErrorCarriesCasePayload() {
        struct StubKernelError: Error, Equatable {
            let kernelStatus: String
            let stderrTail: String
        }
        let error = StubKernelError(
            kernelStatus: "exited(code=71)",
            stderrTail: "sandbox-exec: sandbox_apply: Operation not permitted")
        let rendered = SpawnFailureDetail.render(error)
        #expect(rendered.contains("exited(code=71)"))
        #expect(rendered.contains("sandbox_apply"))
        #expect(!rendered.contains("The operation could not be completed"),
                "the generic Foundation sentence must not replace the payload: \(rendered)")
    }

    /// A `LocalizedError` description leads the text; the structural rendering
    /// rides behind it so the numeric status is never lost.
    @Test func localizedErrorLeadsWithDescriptionAndKeepsStructure() {
        struct DescribedSpawnError: LocalizedError, Error {
            var errorDescription: String? { "sandbox-exec exited immediately" }
        }
        let rendered = SpawnFailureDetail.render(DescribedSpawnError())
        #expect(rendered.contains("sandbox-exec exited immediately"))
        #expect(rendered.contains("DescribedSpawnError"), "structural payload must follow: \(rendered)")
    }

    /// Cause text is bounded so a pathological error chain cannot bloat a
    /// user-visible error, with an explicit truncation marker.
    @Test func boundedTruncationMarksTheCut() {
        struct LongPayloadError: Error { let payload: String }
        let long = LongPayloadError(
            payload: String(repeating: "x", count: SpawnFailureDetail.maxTextLength + 500))
        let rendered = SpawnFailureDetail.render(long)
        #expect(rendered.contains("[truncated at \(SpawnFailureDetail.maxTextLength) characters]"))
        #expect(rendered.count < SpawnFailureDetail.maxTextLength + 100)
    }

    // MARK: - ACPToolFailureClassification.classifySpawn

    private let eperm = NSError(domain: NSPOSIXErrorDomain, code: Int(SpawnFailureDetail.eperm))
    private let enoent = NSError(domain: NSPOSIXErrorDomain, code: 2)
    private let nestedApplyStderr = "sandbox-exec: sandbox_apply: Operation not permitted"

    /// EPERM while spawning the seatbelt front-end itself → the launch was
    /// denied before any child code ran.
    @Test func epermOnSandboxExecClassifiesLaunchDenied() {
        #expect(
            ACPToolFailureClassification.classifySpawn(
                error: eperm,
                causeText: "launch /usr/bin/sandbox-exec: Operation not permitted (POSIX errno 1)",
                stderr: nil,
                executablePath: "/usr/bin/sandbox-exec") == .sandboxExecLaunchDenied)
    }

    /// EPERM on some other binary is not a sandbox denial — it classifies as
    /// nothing rather than mislabeling a plain permission problem.
    @Test func epermOnAnotherBinaryDoesNotClassify() {
        #expect(
            ACPToolFailureClassification.classifySpawn(
                error: eperm,
                causeText: "launch /usr/local/bin/claude (POSIX errno 1)",
                stderr: nil,
                executablePath: "/usr/local/bin/claude") == nil)
    }

    /// A missing or non-executable front-end is the `.sandboxUnavailable`
    /// fail-closed gate's territory, not a denial.
    @Test func enoentOnSandboxExecDoesNotClassify() {
        #expect(
            ACPToolFailureClassification.classifySpawn(
                error: enoent,
                causeText: "launch /usr/bin/sandbox-exec (POSIX errno 2)",
                stderr: nil,
                executablePath: "/usr/bin/sandbox-exec") == nil)
    }

    /// The nested `sandbox_apply` signature in the child's stderr — #1417's
    /// failure, arriving at the spawn boundary — classifies as a nested
    /// denial regardless of which binary was spawned.
    @Test func nestedApplyStderrClassifiesNestedDenial() {
        #expect(
            ACPToolFailureClassification.classifySpawn(
                error: eperm,
                causeText: "launch /usr/local/bin/claude",
                stderr: "node: " + nestedApplyStderr,
                executablePath: "/usr/local/bin/claude") == .sandboxExecNestedDenial)
        #expect(
            ACPToolFailureClassification.classifySpawn(
                error: enoent,
                causeText: nestedApplyStderr,
                stderr: nil,
                executablePath: "/usr/local/bin/claude") == .sandboxExecNestedDenial)
    }

    /// The annotated cause leads with the actionable reason (which documents
    /// that unified-log denial records arrive asynchronously — the #1279
    /// limitation) and still carries the OS status.
    @Test func annotatedSpawnCausePrefixesReasonAndKeepsStatus() {
        let cause = ACPToolFailureClassification.annotatedSpawnCause(
            error: eperm,
            stderr: nil,
            executablePath: "/usr/bin/sandbox-exec",
            operation: "launch /usr/bin/sandbox-exec")
        #expect(cause.contains("Launch denied"))
        #expect(cause.contains("asynchronously"), "the async-denial-record limitation must be documented in the error itself")
        #expect(cause.contains("POSIX errno 1"))

        let generic = ACPToolFailureClassification.annotatedSpawnCause(
            error: enoent,
            stderr: nil,
            executablePath: "/usr/local/bin/claude",
            operation: "launch /usr/local/bin/claude")
        #expect(generic.hasPrefix("launch /usr/local/bin/claude: "))
        #expect(generic.contains("POSIX errno 2"))
        #expect(!generic.contains("denied"), "a non-denial failure must not be annotated as one")
    }
}
