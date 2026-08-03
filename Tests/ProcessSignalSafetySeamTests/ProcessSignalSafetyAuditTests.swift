import Foundation
import Testing

/// Inventories every process-control call site in the repository's executable
/// sources and requires an explicit, rationale-bearing disposition for each one.
///
/// Why this guard exists (#1051): a broad `pkill -f "[s]wiftpm-testing-helper…"`
/// sweep in `make test` selected processes by command-line appearance rather
/// than by ownership, and was credited with terminating 125 PIDs when one hung
/// child was the intended target. Nothing in the build would have objected to
/// that line being added, or to it being added back. This test objects.
///
/// It is deliberately shaped like `StoreEmissionExhaustivenessTests`: a
/// discovered set is compared against a reviewed inventory, so a NEW call site
/// fails the build until someone writes down why it is safe.
///
/// The inventory is keyed by (path, primitive) with an expected count rather
/// than by line number. Line numbers would make this test fail on every
/// unrelated edit above a call site, which trains reviewers to update the table
/// without reading it. Counts still force review when a call site is added.
struct ProcessSignalSafetyAuditTests {
    /// A kind of process-control operation, not a specific API.
    private enum Primitive: String, Hashable, CaseIterable {
        /// `pkill` / `killall` — selects targets by command-line appearance.
        case broadMatcher
        /// `kill(pid, sig)` — POSIX signal to a numeric PID.
        case posixSignal
        /// `Process.terminate()` / client `terminate()`.
        case processTermination
        /// `kill -SIG` / `builtin kill` in shell.
        case shellSignal

        var pattern: String {
            switch self {
            case .broadMatcher: #"\b(pkill|killall)\b"#
            case .posixSignal: #"(?<![-\w])kill\s*\("#
            case .processTermination: #"\.terminate\s*\(\s*\)"#
            // Shell quotes its signal argument (`kill "-$sig"`) as often as it
            // writes it bare (`kill -0`), so both forms must be detected.
            case .shellSignal: #"(\bbuiltin\s+kill\b|\bkill\s+["'-])"#
            }
        }
    }

    private struct Site: Hashable, CustomStringConvertible {
        let path: String
        let primitive: Primitive

        var description: String { "\(path) [\(primitive.rawValue)]" }
    }

    /// Every process-control call site in the repository, with the number of
    /// occurrences and the reason it is acceptable.
    ///
    /// Adding a process-control call anywhere under `Sources/`, `scripts/`, or
    /// in the `Makefile` will fail `everyProcessControlCallSiteIsReviewed`
    /// until it is recorded here with a rationale.
    private var reviewed: [Site: (count: Int, rationale: String)] {
        [
            // --- The verified-signal boundary itself -------------------------
            .init(path: "Sources/WikiFSCore/Core/AsyncProcessRunner.swift",
                  primitive: .processTermination):
                (1, "guarded: ProcessSignalSafety.verify confirms PID, parent PID, "
                    + "and kernel start time against a fresh observation before TERM"),
            .init(path: "Sources/WikiFSCore/Core/AsyncProcessRunner.swift",
                  primitive: .posixSignal):
                (1, "guarded: injected sendSignal seam, reached only via "
                    + "ProcessSignalSafety.signal on a re-verified direct child"),
            .init(path: "scripts/lib/test-watchdog-process-control.sh",
                  primitive: .shellSignal):
                (1, "guarded: builtin kill is addressed by jobspec (%N), never by a "
                    + "number. Bash resolves ownership and signals in one step, so "
                    + "there is no interval in which the PID could be reaped and "
                    + "recycled. A separately captured jobs snapshot cannot authorise "
                    + "a signal, because it only proves ownership at snapshot time"),

            // --- Owner-terminates-its-own-child, no numeric PID -------------
            // These call terminate() on a Process/client object the same code
            // created and still holds. The object identity is the authority,
            // so there is no PID-reuse window to close.
            .init(path: "Sources/WikiFSEngine/PdfExtractionService.swift",
                  primitive: .processTermination):
                (3, "owns the Process object it terminates; no numeric PID involved"),
            .init(path: "Sources/WikiFS/Sources/DefuddleExtractionService.swift",
                  primitive: .processTermination):
                (2, "owns the Process object it terminates; no numeric PID involved"),
            .init(path: "Sources/WikiFSEngine/ACPBackend.swift",
                  primitive: .processTermination):
                (3, "terminates a held ACP client object, not a PID"),
            .init(path: "Sources/WikiFSEngine/ACPProviderModelProbe.swift",
                  primitive: .processTermination):
                (1, "terminates a held ACP client object, not a PID"),

            // --- Liveness probe only ----------------------------------------
            .init(path: "Sources/WikiFSEngine/ACPBackend.swift",
                  primitive: .posixSignal):
                (1, "kill(pid, 0) is a liveness probe and delivers no signal"),

            // --- Known-weak, pre-existing, tracked --------------------------
            // NOT a safety approval. Recorded so it is visible and cannot be
            // mistaken for a reviewed-safe pattern.
            .init(path: "Sources/WikiFSCore/Integrations/TranscriptSubprocess.swift",
                  primitive: .posixSignal):
                (2, "WEAK, pre-existing: kill(pid, 0) then kill(pid, SIGTERM) on a "
                    + "PID from a stored snapshot. This is a check-then-signal race "
                    + "of the same class as #1051 and should migrate to "
                    + "ProcessSignalSafety; out of scope for this change"),

            .init(path: "scripts/paseo-archive-cleanup.sh", primitive: .shellSignal):
                (2, "WEAK, pre-existing: operator-run agent-archive cleanup. Selects "
                    + "PIDs by matching a ps snapshot, then does pid_is_alive followed "
                    + "by kill — check-then-signal, same class as #1051. It does skip "
                    + "self, PPID, and PID 1. Not on any build or test path; out of "
                    + "scope for this change"),

            // --- Developer app lifecycle, not test helpers -------------------
            // NOT a safety approval. These match by absolute installed-app path
            // to stop the developer's own app before reinstalling it.
            .init(path: "Makefile", primitive: .broadMatcher):
                (4, "WEAK, pre-existing: pkill -f against the absolute installed "
                    + "app/appex path in run/install targets. Appearance-based, but "
                    + "scoped to this developer's install path and never used to "
                    + "reap test helpers. The test-helper sweep was removed in #1051"),
        ]
    }

    /// Files whose text talks about process-control tools by name rather than
    /// invoking them. Excluded for the same reason `DebugLog.swift` is excluded
    /// from mutation testing: the match is the subject, not a call.
    private let excludedPaths: Set<String> = [
        // Asserts that pkill/killall/kill -0 do NOT appear in the watchdog.
        "scripts/tests/test-test-with-watchdog-process-control.sh",
    ]

    @Test func everyProcessControlCallSiteIsReviewed() throws {
        let discovered = try discoveredSites()
        let reviewed = self.reviewed

        let undocumented = discovered.keys.filter { reviewed[$0] == nil }.sorted { "\($0)" < "\($1)" }
        #expect(
            undocumented.isEmpty,
            """
            Unreviewed process-control call site(s):
            \(undocumented.map { "  - \($0) x\(discovered[$0] ?? 0)" }.joined(separator: "\n"))

            A numeric PID is never sufficient authority to signal (#1051). Either
            route this through ProcessSignalSafety / the watchdog verified-child
            boundary, or add it to `reviewed` with a rationale explaining why the
            target's identity is already proven.
            """)

        let stale = reviewed.keys.filter { discovered[$0] == nil }.sorted { "\($0)" < "\($1)" }
        #expect(
            stale.isEmpty,
            """
            Reviewed call site(s) no longer found — remove them from `reviewed`:
            \(stale.map { "  - \($0)" }.joined(separator: "\n"))
            """)

        for (site, expected) in reviewed {
            guard let actual = discovered[site] else { continue }
            #expect(
                actual == expected.count,
                """
                \(site): expected \(expected.count) occurrence(s), found \(actual).
                A process-control call was added or removed here. Re-read the
                rationale and update the count deliberately:
                  \(expected.rationale)
                """)
        }

        #expect(
            reviewed.values.allSatisfy { $0.rationale.isEmpty == false },
            "every reviewed call site needs a non-empty rationale")
    }

    /// The specific line that caused the #1051 incident must never come back.
    @Test func noSweepReapsTestHelpersByCommandLine() throws {
        let root = repositoryRoot()
        for relativePath in ["Makefile", "scripts/test-with-watchdog.sh",
                             "scripts/lib/test-watchdog-process-control.sh"] {
            let source = try String(
                contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
            let executable = strippingCommentsAndLiterals(source, path: relativePath)
            // Match on "testing-helper", not "swiftpm-testing-helper": the
            // original sweep wrote the pattern as `[s]wiftpm-testing-helper`
            // (the bracket trick that stops pkill matching its own command
            // line), which contains no "swiftpm-testing-helper" substring at
            // all. A naive check passes straight through the exact line that
            // caused the incident.
            #expect(
                executable.contains("testing-helper") == false,
                "\(relativePath) must not select the SwiftPM test helper by command line (#1051)")
        }
    }

    /// The watchdog must still be able to run a suite. The first attempt at this
    /// fix shipped a production observer that always failed, so the script hit
    /// its own refusal branch and exited 78 without running a single test.
    @Test func watchdogRemainsOperableAndVerifiesBeforeSignalling() throws {
        let root = repositoryRoot()
        let watchdog = try String(
            contentsOf: root.appendingPathComponent("scripts/test-with-watchdog.sh"),
            encoding: .utf8)

        #expect(watchdog.contains("swift test -v"), "watchdog must still launch the suite")
        #expect(
            watchdog.contains("watchdog_signal_job"),
            "watchdog must signal only through the jobspec boundary")
        // Comments stripped: this script documents the `kill -0` it removed.
        #expect(
            strippingCommentsAndLiterals(watchdog, path: "scripts/test-with-watchdog.sh")
                .contains("kill -0") == false,
            "kill -0 cannot distinguish a reused PID; use the job table instead")

        let boundary = try String(
            contentsOf: root.appendingPathComponent(
                "scripts/lib/test-watchdog-process-control.sh"),
            encoding: .utf8)
        let executableBoundary = strippingCommentsAndLiterals(
            boundary, path: "scripts/lib/test-watchdog-process-control.sh")

        // The signal must be addressed by jobspec. A `jobs -pr` snapshot proves
        // ownership only at snapshot time: bash can reap the job between the
        // check and a later numeric `kill`, after which the kernel may recycle
        // the number. Signalling `%N` makes the lookup and the signal one step.
        #expect(
            executableBoundary.contains("builtin kill \"-$signal_name\" \"$jobspec\""),
            "the only kill must be addressed by jobspec, not by PID")
        #expect(
            executableBoundary.contains("^%[0-9]+$"),
            "the jobspec must be validated so a numeric PID cannot reach kill")
        // No `kill` anywhere in the boundary may take a PID variable.
        for pidAddressedKill in ["kill \"-$signal_name\" \"$pid\"",
                                 "kill \"-$signal_name\" \"$processID\"",
                                 "kill -TERM \"$pid\"",
                                 "kill -KILL \"$pid\""] {
            #expect(
                executableBoundary.contains(pidAddressedKill) == false,
                "signalling a numeric PID reintroduces the check-then-signal race")
        }
    }

    @Test func scannerIgnoresProcessControlTextInCommentsAndLiterals() {
        let swiftSource = """
        /// the watchdog kill(pgid) a stuck agent after cancel fails
        // process.terminate()
        DebugLog.agent("client.terminate()")
        client.terminate()
        """
        let counts = counted(swiftSource, path: "Fake.swift")
        #expect(counts[.processTermination] == 1)
        #expect(counts[.posixSignal] == nil)

        let shellSource = """
        # pkill -f something
        builtin kill -TERM "$pid"
        """
        let shellCounts = counted(shellSource, path: "fake.sh")
        #expect(shellCounts[.broadMatcher] == nil)
        #expect(shellCounts[.shellSignal] == 1)
    }

    @Test func scannerDoesNotMistakeSimilarIdentifiersForSignals() {
        let source = """
        overkill(value)
        self.killCount(3)
        kill(pid, SIGTERM)
        """
        let counts = counted(source, path: "Fake.swift")
        #expect(counts[.posixSignal] == 1)
    }

    // MARK: - Scanning

    private func discoveredSites() throws -> [Site: Int] {
        let root = repositoryRoot()
        var result: [Site: Int] = [:]

        for relativePath in try scannedSourceFiles(root: root) {
            let source = try String(
                contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
            for (primitive, count) in counted(source, path: relativePath) {
                result[Site(path: relativePath, primitive: primitive), default: 0] += count
            }
        }
        return result
    }

    private func counted(_ source: String, path: String) -> [Primitive: Int] {
        let executable = strippingCommentsAndLiterals(source, path: path)
        var counts: [Primitive: Int] = [:]
        for primitive in Primitive.allCases {
            let matches = regex(primitive.pattern).numberOfMatches(
                in: executable,
                range: NSRange(executable.startIndex..., in: executable))
            if matches > 0 { counts[primitive] = matches }
        }
        return counts
    }

    /// Blanks out comments so that documentation mentioning `kill` is not
    /// counted as a call site.
    ///
    /// Quoted spans are stripped for Swift/Obj-C only, where a `kill` mention is
    /// almost always a log message. Shell keeps its quotes, because shell passes
    /// real arguments in them — `kill "-$signal_name" "$pid"` is an invocation,
    /// not prose, and stripping quotes would hide it.
    private func strippingCommentsAndLiterals(_ source: String, path: String) -> String {
        let usesHashComments = path.hasSuffix(".sh") || path.hasSuffix("Makefile")
        var output: [String] = []

        for rawLine in source.components(separatedBy: .newlines) {
            var line = rawLine

            if usesHashComments {
                if let hash = line.firstIndex(of: "#") {
                    line = String(line[line.startIndex..<hash])
                }
                output.append(line)
                continue
            }

            if let slashes = line.range(of: "//") {
                line = String(line[line.startIndex..<slashes.lowerBound])
            }
            output.append(removingQuotedSpans(line))
        }
        return output.joined(separator: "\n")
    }

    private func removingQuotedSpans(_ line: String) -> String {
        var result = ""
        var insideQuotes = false
        var previous: Character?

        for character in line {
            if character == "\"", previous != "\\" {
                insideQuotes.toggle()
                previous = character
                continue
            }
            if insideQuotes == false { result.append(character) }
            previous = character
        }
        return result
    }

    private func scannedSourceFiles(root: URL) throws -> [String] {
        var paths: [String] = ["Makefile"]

        for directory in ["Sources", "scripts"] {
            let base = root.appendingPathComponent(directory)
            guard let enumerator = FileManager.default.enumerator(
                at: base,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])
            else { continue }

            for case let url as URL in enumerator {
                let isRegularFile = try url.resourceValues(
                    forKeys: [.isRegularFileKey]).isRegularFile ?? false
                guard isRegularFile else { continue }
                guard ["swift", "m", "mm", "sh"].contains(url.pathExtension) else { continue }

                let relativePath = url.path.replacingOccurrences(
                    of: root.path + "/", with: "")
                guard excludedPaths.contains(relativePath) == false else { continue }
                // Build products, vendored dependencies, and checkouts are not ours.
                guard relativePath.contains("/.build/") == false else { continue }
                paths.append(relativePath)
            }
        }
        return paths.sorted()
    }

    private func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are compile-time constants in this file.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern)
    }

    private func repositoryRoot() -> URL {
        // This file lives at Tests/ProcessSignalSafetySeamTests/<file>.swift.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
