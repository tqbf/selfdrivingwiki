import Foundation
import Testing
@testable import WikiFSCore
import WikiFSTypes

/// Pure formatting checks for the safe diagnostic surface: every line is
/// bounded, one-line, control-free, and home-redacted (AC.7, AC.8).
@Suite("Managed extractor diagnostics")
struct ManagedExtractorDiagnosticsTests {
    /// AC.7: each execution failure category produces a distinguishable
    /// Console line.
    @Test func executionFailureCategoriesAreDistinct() {
        let lines = [
            ManagedExtractorDiagnostics.Event.executableChanged(
                command: "bun", identity: "dev:1-ino:2").consoleLine,
            ManagedExtractorDiagnostics.Event.spawnFailure(
                command: "bun", detail: "posix_spawn failed").consoleLine,
            ManagedExtractorDiagnostics.Event.nonzeroExit(
                command: "bun", termination: "exited(17)", stderrTail: "boom").consoleLine,
            ManagedExtractorDiagnostics.Event.protocolFailure(
                command: "bun", detail: "invalid sequence").consoleLine,
        ]
        #expect(lines[0].hasPrefix("executable changed before spawn:"))
        #expect(lines[1].hasPrefix("spawn failure:"))
        #expect(lines[2].hasPrefix("nonzero extractor exit:"))
        #expect(lines[3].hasPrefix("protocol failure:"))
        #expect(Set(lines).count == lines.count)
        for line in lines {
            #expect(line.contains("command=bun"))
            #expect(line.contains("\n") == false)
        }
    }

    /// AC.8: home-directory prefixes are redacted; non-home paths stay
    /// lexical; length is bounded; control characters cannot survive.
    @Test func redactsAndBoundsRuntimeDiagnostics() {
        let home = URL(fileURLWithPath: "/Users/testuser", isDirectory: true)
        let underHome = home.appendingPathComponent(".local/bin/bun")
        let described = ManagedExtractorDiagnostics.redactedPath(for: underHome, home: home)
        #expect(described == "~/.local/bin/bun")
        #expect(described.contains("testuser") == false)

        let outsideHome = ManagedExtractorDiagnostics.redactedPath(
            for: URL(fileURLWithPath: "/opt/homebrew/bin/bun"), home: home)
        #expect(outsideHome == "/opt/homebrew/bin/bun")

        // Control characters and line breaks cannot bypass the redaction.
        let hostile = ManagedExtractorDiagnostics.redactedPath(
            for: URL(fileURLWithPath: "/Users/testuser/a\u{07}b\nc"), home: home)
        #expect(hostile.contains("\n") == false)
        #expect(hostile.contains("\u{07}") == false)

        // A very long path is bounded.
        let longPath = "/" + String(repeating: "x", count: 4_096)
        let bounded = ManagedExtractorDiagnostics.redactedPath(
            for: URL(fileURLWithPath: longPath), home: home)
        #expect(bounded.count <= ManagedExtractorDiagnostics.maximumPathDescriptionLength)

        // A successful resolution event carries the redacted path and an
        // identity fingerprint, never a username.
        let event = ManagedExtractorDiagnostics.Event.runtimeResolved(
            command: "bun",
            source: "login-shell",
            path: described,
            identity: ManagedExtractorDiagnostics.identityFingerprint(
                for: RuntimeExecutableIdentity(
                    device: 7, inode: 9, mode: 0o100755, size: 10))).consoleLine
        #expect(event == "runtime resolved: command=bun source=login-shell path=~/.local/bin/bun identity=dev:7-ino:9")
        #expect(event.contains("testuser") == false)
    }

    /// Stderr tails are bounded to the display limit, one line, and keep
    /// only the final lines.
    @Test func stderrTailsAreBoundedToOneLine() {
        let long = String(repeating: "line of stderr\n", count: 500)
        let tail = ManagedExtractorDiagnostics.singleLineTail(
            Data(long.utf8),
            displayLimit: ManagedExtractorDiagnostics.maximumStderrTailDisplayLength)
        #expect(tail.contains("\n") == false)
        #expect(tail.count <= ManagedExtractorDiagnostics.maximumStderrTailDisplayLength)
        // Only the final lines survive.
        #expect(tail.contains(" | "))
        #expect(tail.hasPrefix("line of stderr | line of stderr"))

        let empty = ManagedExtractorDiagnostics.singleLineTail(Data(), displayLimit: 100)
        #expect(empty.isEmpty)

        // Control characters inside stderr cannot smuggle a newline or
        // control byte into the log line.
        let hostile = ManagedExtractorDiagnostics.singleLineTail(
            Data("a\u{1b}[31mb\nc\u{0b}".utf8), displayLimit: 100)
        #expect(hostile.contains("\n") == false)
        #expect(hostile.contains("\u{1b}") == false)
        #expect(hostile.contains("\u{0b}") == false)
    }

    /// The sanitize helper collapses whitespace and caps length.
    @Test func sanitizeCollapsesAndCaps() {
        let sanitized = ManagedExtractorDiagnostics.sanitize(
            "  a\tb\n c  d  ",
            limit: 100)
        #expect(sanitized == "a b c d")

        let capped = ManagedExtractorDiagnostics.sanitize(
            String(repeating: "z", count: 1_000),
            limit: 10)
        #expect(capped.count == 10)
    }

    /// The production sink writes lines to the extraction channel; the
    /// in-memory sink used by tests records them unchanged. Neither ever
    /// receives a multi-line payload from the formatter.
    @Test func eventsNeverCarryRawNewlines() {
        let hostileCases: [ManagedExtractorDiagnostics.Event] = [
            .runtimeResolutionFailed(command: "bun", category: "absent", detail: "line1\nline2\r\nline3"),
            .spawnFailure(command: "bun", detail: "a\u{0a}b"),
            .nonzeroExit(command: "bun", termination: "exited(1)", stderrTail: "x\ny"),
        ]
        for event in hostileCases {
            #expect(event.consoleLine.contains("\n") == false)
            #expect(event.consoleLine.contains("\r") == false)
        }
    }
}
