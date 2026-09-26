import Foundation
import Testing

/// Pins the #1330 quit-backstop wiring call sites.
///
/// The wiring is three-line closures, and it is compile-verified only: no
/// behavioral test can run the real daemon or app quit path. If an edit
/// silently drops or reorders the backstop call, orphaned `uv run` wrappers
/// survive process death again (#1330) with no build failure. These source
/// audits fail legibly instead, naming the file and what went missing.
@Suite("Quit backstop wiring audit")
struct QuitBackstopWiringAuditTests {
    /// The daemon's clean-quit closure must sweep every owned process group
    /// BEFORE the process exits: after `Darwin.exit` no Swift code runs
    /// again, and worker-task cancellation may never get scheduled.
    @Test func daemonDidShutdownRunsBackstopBeforeProcessExit() throws {
        let source = try repositoryFile("Sources/wikid/main.swift")

        let didShutdown = try #require(
            source.range(of: "didShutdown:"),
            """
                Sources/wikid/main.swift: the DaemonProcessLifetimeCoordinator \
                didShutdown closure is gone — the #1330 quit backstop has no \
                daemon wiring
                """)
        let afterClosure = source[didShutdown.upperBound...]
        let exit = try #require(
            afterClosure.range(of: "Darwin.exit(EXIT_SUCCESS)"),
            """
                Sources/wikid/main.swift: Darwin.exit(EXIT_SUCCESS) not found \
                after didShutdown — cannot verify the backstop's ordering \
                against the exit
                """)
        let closureBody = executableText(afterClosure[..<exit.lowerBound])

        #expect(
            closureBody.contains(Self.backstopCall),
            """
            Sources/wikid/main.swift: the didShutdown closure no longer calls \
            OwnedProcessGroupRegistry.terminateAllOwnedGroups() before \
            Darwin.exit(EXIT_SUCCESS) — the #1330 daemon quit backstop was \
            dropped or moved after the exit
            """)
    }

    /// The app's termination cleanup must sweep owned groups BEFORE the
    /// session directories are removed. A still-running group whose
    /// operation root is deleted underneath it is exactly the orphaned
    /// wrapper shape #1330 fixed.
    @Test func appTerminationRunsBackstopBeforeSessionCleanup() throws {
        let source = try repositoryFile("Sources/WikiFS/Window/WikiFSApp.swift")

        let closureStart = try #require(
            source.range(of: "shutdownForTermination = {"),
            """
                Sources/WikiFS/Window/WikiFSApp.swift: the \
                shutdownForTermination wiring closure is gone — the #1330 \
                quit backstop has no app wiring
                """)
        let afterClosure = source[closureStart.upperBound...]
        let cleanup = try #require(
            afterClosure.range(of: "cleanupOperationSessions"),
            """
                Sources/WikiFS/Window/WikiFSApp.swift: \
                cleanupOperationSessions not found after \
                shutdownForTermination — cannot verify the backstop's \
                ordering against session cleanup
                """)
        let closureBody = executableText(afterClosure[..<cleanup.lowerBound])

        #expect(
            closureBody.contains(Self.backstopCall),
            """
            Sources/WikiFS/Window/WikiFSApp.swift: the shutdownForTermination \
            closure no longer calls OwnedProcessGroupRegistry.\
            terminateAllOwnedGroups() before cleanupOperationSessions — the \
            #1330 app quit backstop was dropped or moved after the session \
            directories are removed
            """)
    }

    /// The exact call both quit closures must make.
    private static let backstopCall = "OwnedProcessGroupRegistry.terminateAllOwnedGroups()"

    /// Comment-stripped, whitespace-normalized text. A commented-out call
    /// is not wiring, and a reformatted line wrap must not defeat the
    /// check (same comment discipline as ProcessSignalSafetyAuditTests).
    private func executableText(_ region: Substring) -> String {
        region
            .components(separatedBy: .newlines)
            .map { line in
                guard let slashes = line.range(of: "//") else { return line }
                return String(line[line.startIndex..<slashes.lowerBound])
            }
            .joined(separator: "\n")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
    }

    // MARK: - Files

    private func repositoryFile(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot().appendingPathComponent(relativePath),
            encoding: .utf8)
    }

    /// Walks up from this file until `Package.swift` appears. Never assumes
    /// the process CWD.
    private func repositoryRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            if FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("Package.swift").path) {
                return directory
            }
            directory.deleteLastPathComponent()
        }
        struct RepositoryRootNotFound: Error, CustomStringConvertible {
            var description: String { "no Package.swift found above #filePath" }
        }
        throw RepositoryRootNotFound()
    }
}
