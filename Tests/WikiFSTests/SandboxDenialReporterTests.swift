#if os(macOS)
import Testing
import Foundation
import Synchronization
import WikiFSCore
@testable import WikiFSEngine

/// #1409 — the unified-log sandbox-denial reporter. Covered layers:
///
/// 1. PURE parser (`parseDenials`): the real pi-acp denial line from the
///    issue, the ubiquitous `file-write-data /dev/dtracehelper` noise,
///    unrelated processes' denials, duplicates, malformed lines, and the
///    cap — pinned so the failure messages carry exactly the relevant
///    denied operations.
/// 2. PURE inputs (`sandboxDenialTokens`, `logShowArguments`,
///    `logShowPredicate`, `appending`): the token derivation from spawn
///    argv + `providerHomeSubpaths`, the bounded `log show` window, and
///    predicate escaping.
/// 3. `recentDenials` through the injected `runLogShow` seam — the tests
///    never spawn `/usr/bin/log`; the seam captures the argv and returns
///    canned output. The hard bound is exercised with a short injected
///    bound (never the production 8s).
///
/// The suite is `.serialized`: the tests share nothing, but under a loaded
/// `swift test` run every unstructured task here competes for the same
/// cooperative pool the process-spawning suites depend on (AGENTS.md #1051),
/// so the suite keeps its own footprint serial and small.
@Suite("SandboxDenialReporter", .serialized)
struct SandboxDenialReporterTests {

    // MARK: - Fixtures

    /// The origin-case line (issue #1409 evidence), in the shape
    /// `log show --style compact` emits: timestamp/process prefixes before
    /// the kernel message.
    private static let piDenialCompact =
        "2026-10-12 08:43:13.921308-0700  localhost  kernel[0]: (Sandbox) Sandbox: node(34070) deny(1) file-write-create /Users/wsargent/.pi/agent/settings.json.lock"
    /// The same denial as a bare eventMessage (no prefixes).
    private static let piDenialBare =
        "Sandbox: node(34071) deny(1) file-write-create /Users/wsargent/.pi/agent/settings.json.lock"
    /// Ubiquitous per-process Seatbelt noise: matches the `node` token but
    /// is not the failure being diagnosed.
    private static let dtracehelperNoise =
        "2026-10-12 08:43:13.902114-0700  localhost  kernel[0]: (Sandbox) Sandbox: node(34070) deny(1) file-write-data /dev/dtracehelper"
    /// A denial from an unrelated process the tokens must not match.
    private static let unrelatedDenial =
        "2026-10-12 08:43:12.000000-0700  localhost  kernel[0]: (Sandbox) Sandbox: python3(500) deny(1) file-read-data /Users/wsargent/secret.txt"
    /// The word "deny" without a deny(...) marker — not a seatbelt line.
    private static let proseDeny =
        "2026-10-12 08:43:13.5 app[1]: the server will deny requests without a token"
    /// A malformed marker: the parenthesized result is not numeric.
    private static let malformedDenial =
        "Sandbox: sh(9) deny(x) file-write-create /tmp/x"

    private static let sampleLogOutput = [
        piDenialCompact,
        dtracehelperNoise,
        unrelatedDenial,
        proseDeny,
        piDenialBare,
        malformedDenial,
    ].joined(separator: "\n")

    // MARK: - PURE: parseDenials

    /// Token-matched selection: the pi denial survives (twice in the input,
    /// once out — dedupe), the dtracehelper/prose/malformed lines drop under
    /// path tokens, and prefixes are normalized away.
    @Test func parseDenialsKeepsTokenMatchedPiDenialOnly() {
        let denials = SandboxDenialReporter.parseDenials(
            fromLogOutput: Self.sampleLogOutput,
            tokens: [".pi", "pi-acp"])
        #expect(denials == [
            "deny file-write-create /Users/wsargent/.pi/agent/settings.json.lock",
        ])
    }

    /// v1 window+token matching (documented on the type): a runtime token
    /// like `node` also matches the ubiquitous dtracehelper line. Pinned so
    /// the noise tradeoff is a documented decision, not an accident.
    @Test func parseDenialsRuntimeTokenIncludesDtracehelperNoise() {
        let denials = SandboxDenialReporter.parseDenials(
            fromLogOutput: Self.sampleLogOutput,
            tokens: ["node"])
        #expect(denials == [
            "deny file-write-create /Users/wsargent/.pi/agent/settings.json.lock",
            "deny file-write-data /dev/dtracehelper",
        ])
    }

    /// Token matching is case-insensitive; prefixes (timestamp, host,
    /// process, pid) are dropped by the normalization.
    @Test func parseDenialsTokenMatchIsCaseInsensitive() {
        let denials = SandboxDenialReporter.parseDenials(
            fromLogOutput: Self.piDenialCompact,
            tokens: ["PI"])
        #expect(denials == [
            "deny file-write-create /Users/wsargent/.pi/agent/settings.json.lock",
        ])
    }

    /// The result is capped at `limit` preserving first occurrences.
    @Test func parseDenialsCapsPreservingFirstOccurrences() {
        var lines: [String] = []
        for index in 0..<12 {
            lines.append(
                "Sandbox: node(\(700 + index)) deny(1) file-write-create /tmp/denied-\(index)")
        }
        let denials = SandboxDenialReporter.parseDenials(
            fromLogOutput: lines.joined(separator: "\n"),
            tokens: ["denied-"],
            limit: 8)
        #expect(denials.count == 8)
        #expect(denials.first == "deny file-write-create /tmp/denied-0")
        #expect(denials.last == "deny file-write-create /tmp/denied-7")
    }

    /// Duplicates collapse on the NORMALIZED line, not the raw line — the
    /// same denial from two pids/timestamps counts once.
    @Test func parseDenialsDedupesOnNormalizedLine() {
        let twoPids = [Self.piDenialCompact, Self.piDenialBare].joined(separator: "\n")
        let denials = SandboxDenialReporter.parseDenials(
            fromLogOutput: twoPids,
            tokens: [".pi"])
        #expect(denials.count == 1)
    }

    /// Guards: empty tokens, non-matching tokens, and a non-positive limit
    /// all yield [].
    @Test func parseDenialsGuardYieldsEmpty() {
        #expect(SandboxDenialReporter.parseDenials(fromLogOutput: Self.sampleLogOutput, tokens: [], limit: 8).isEmpty)
        #expect(SandboxDenialReporter.parseDenials(fromLogOutput: Self.sampleLogOutput, tokens: ["claude"], limit: 8).isEmpty)
        #expect(SandboxDenialReporter.parseDenials(fromLogOutput: Self.sampleLogOutput, tokens: [".pi"], limit: 0).isEmpty)
        #expect(SandboxDenialReporter.parseDenials(fromLogOutput: "", tokens: [".pi"], limit: 8).isEmpty)
    }

    // MARK: - PURE: sandboxDenialTokens

    /// Tokens are the lowercase basenames of the spawn argv plus the
    /// provider-home subpaths `ACPBackend.providerHomeSubpaths` derives
    /// (codex → ".codex"), deduplicated and order-stable.
    @Test func sandboxDenialTokensFromArgvBasenamesAndSubpaths() {
        let tokens = SandboxDenialReporter.sandboxDenialTokens(
            executablePath: "/usr/local/bin/Codex-ACP",
            arguments: ["--profile", "extra"])
        #expect(tokens.contains("codex-acp"))
        #expect(tokens.contains("--profile"))
        #expect(tokens.contains("extra"))
        #expect(tokens.contains(".codex"))
        // Lowercased throughout.
        #expect(tokens.allSatisfy { $0 == $0.lowercased() })
        // Deduplicated.
        #expect(Set(tokens).count == tokens.count)
    }

    /// A `bun x` adapter shape: the runner basename, the package spec, and
    /// the bun home subpaths all become tokens.
    @Test func sandboxDenialTokensForBunAdapterShape() {
        let tokens = SandboxDenialReporter.sandboxDenialTokens(
            executablePath: "/Users/dev/.bun/bin/bun",
            arguments: ["x", "@agentclientprotocol/pi-acp"])
        #expect(tokens.contains("bun"))
        #expect(tokens.contains("x"))
        // The package spec's basename carries the adapter name.
        #expect(tokens.contains("pi-acp"))
        #expect(tokens.contains(".bun"))
        #expect(tokens.contains(".cache/.bun"))
    }

    // MARK: - PURE: logShowArguments / predicate

    /// The window starts one second before `since` (no clamp when recent)
    /// and the predicate carries the deny marker plus every token.
    @Test func logShowArgumentsWindowAndTokens() throws {
        let since = Date(timeIntervalSince1970: 750_000_000)
        let now = since.addingTimeInterval(5)
        let argv = SandboxDenialReporter.logShowArguments(
            since: since,
            tokens: [".pi", "node"],
            now: now)
        #expect(argv.first == "/usr/bin/log")
        #expect(argv.count == 8)
        #expect(argv[1] == "show")
        #expect(argv[2] == "--style")
        #expect(argv[3] == "compact")
        let expectedStart = Self.formatForLogShow(since.addingTimeInterval(-1))
        #expect(argv[4] == "--start")
        #expect(argv[5] == expectedStart)
        #expect(argv[6] == "--predicate")
        // The predicate rides as the last element — assert it from the tail.
        let predicate = try #require(argv.last)
        #expect(predicate.contains("eventMessage CONTAINS \"deny\""))
        #expect(predicate.contains(#"eventMessage CONTAINS[c] ".pi""#))
        #expect(predicate.contains(#"eventMessage CONTAINS[c] "node""#))
    }

    /// A stale `since` is clamped to `maximumLookback` before `now` so the
    /// store scan stays bounded.
    @Test func logShowArgumentsClampsStaleWindow() throws {
        let now = Date(timeIntervalSince1970: 750_000_000)
        let staleSince = now.addingTimeInterval(-3_600)
        let argv = SandboxDenialReporter.logShowArguments(
            since: staleSince,
            tokens: ["node"],
            now: now)
        let expectedStart = Self.formatForLogShow(now.addingTimeInterval(-SandboxDenialReporter.maximumLookback))
        #expect(argv[5] == expectedStart)
    }

    /// Predicate tokens are escaped for the double-quoted literal (backslash
    /// first, then quotes).
    @Test func logShowPredicateEscapesTokens() {
        let predicate = SandboxDenialReporter.logShowPredicate(tokens: [#"we"ird\path"#])
        #expect(predicate.contains(#"eventMessage CONTAINS[c] "we\"ird\\path""#))
    }

    // MARK: - PURE: appending

    @Test func appendingEmptyDenialsReturnsMessageUnchanged() {
        #expect(SandboxDenialReporter.appending("boom", denials: []) == "boom")
    }

    @Test func appendingRendersCappedSection() {
        let rendered = SandboxDenialReporter.appending(
            "boom",
            denials: ["deny file-write-create /Users/wsargent/.pi/agent/settings.json.lock"])
        #expect(rendered.contains("boom"))
        #expect(rendered.contains("\nSandbox denials:\n"))
        #expect(rendered.contains("- deny file-write-create /Users/wsargent/.pi/agent/settings.json.lock"))
    }

    // MARK: - recentDenials via the injected seam

    /// A thread-safe capture for the seam's argv.
    private final class ArgvCapture: Sendable {
        private let storage = Mutex<[String]?>(nil)
        var argv: [String]? { storage.withLock { $0 } }
        func set(_ value: [String]) { storage.withLock { $0 = value } }
    }

    /// The production shape: the seam receives the full `log show` argv
    /// (window + tokens) and its combined output is parsed into normalized
    /// denials.
    @Test func recentDenialsPassesWindowAndTokensToLogShow() async throws {
        let capture = ArgvCapture()
        let since = Date(timeIntervalSince1970: 750_000_000)
        let now = since.addingTimeInterval(5)
        let denials = await SandboxDenialReporter.recentDenials(
            since: since,
            tokens: [".pi"],
            now: now,
            runLogShow: { argv in
                capture.set(argv)
                return Self.sampleLogOutput
            })
        #expect(denials == [
            "deny file-write-create /Users/wsargent/.pi/agent/settings.json.lock",
        ])
        let argv = try #require(capture.argv)
        #expect(argv.first == "/usr/bin/log")
        #expect(argv[4] == "--start")
        #expect(argv[5] == Self.formatForLogShow(since.addingTimeInterval(-1)))
        let predicate = try #require(argv.last)
        #expect(predicate.contains(#"CONTAINS[c] ".pi""#))
    }

    /// A failed invocation (nil) yields no denials — a diagnostic failure
    /// must not mask the launch failure it annotates.
    @Test func recentDenialsNilOutputYieldsEmpty() async {
        let denials = await SandboxDenialReporter.recentDenials(
            since: Date(),
            tokens: ["node"],
            runLogShow: { _ in nil })
        #expect(denials.isEmpty)
    }

    /// Empty tokens never reach the seam — the query is skipped entirely.
    @Test func recentDenialsSkipsQueryWithoutTokens() async {
        let seamRuns = Mutex<Bool>(false)
        let denials = await SandboxDenialReporter.recentDenials(
            since: Date(),
            tokens: [],
            runLogShow: { _ in
                seamRuns.withLock { $0 = true }
                return nil
            })
        #expect(denials.isEmpty)
        #expect(seamRuns.withLock { $0 } == false)
    }

    /// The hard bound: a seam that outlives the bound loses the race, the
    /// result is [], and the caller is unblocked (the injected bound is
    /// short — never the production 8s). The latency ceiling is generous:
    /// under a starved cooperative pool even continuation resumption can
    /// lag (#1051); the CONTRACT under assertion is the empty result and
    /// the race winning over the 2s seam sleep, not wall-clock precision.
    @Test func recentDenialsBoundUnblocksCaller() async {
        let clock = ContinuousClock()
        let start = clock.now
        let denials = await SandboxDenialReporter.recentDenials(
            since: Date(),
            tokens: ["node"],
            bound: .milliseconds(100),
            runLogShow: { _ in
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return nil // cancelled when the bound wins
                }
                return Self.sampleLogOutput
            })
        let elapsed = clock.now - start
        #expect(denials.isEmpty)
        #expect(elapsed < .seconds(20),
                "the bound must unblock the caller, took \(elapsed)")
    }

    /// The limit flows through the query to the parser.
    @Test func recentDenialsRespectsLimit() async {
        var builder: [String] = []
        for index in 0..<12 {
            builder.append("Sandbox: node(\(800 + index)) deny(1) file-write-create /tmp/d-\(index)")
        }
        let output = builder.joined(separator: "\n")
        let denials = await SandboxDenialReporter.recentDenials(
            since: Date(),
            tokens: ["d-"],
            limit: 3,
            runLogShow: { _ in output })
        #expect(denials == [
            "deny file-write-create /tmp/d-0",
            "deny file-write-create /tmp/d-1",
            "deny file-write-create /tmp/d-2",
        ])
    }

    // MARK: - Chat-path error rendering (#1409)

    /// The chat launch failure carries the denials on the typed error and
    /// renders them into `errorDescription` (what the launcher surfaces).
    /// `ACPBackend.startProcess` itself needs a live subprocess + SDK client
    /// to reach its catch, so the chat path is covered at the error seam —
    /// the startProcess catch (1) queries through the same
    /// `recentSandboxDenials` seam and (2) builds the message through the
    /// same `appending` formatter this pins.
    @Test func chatLaunchFailedRendersSandboxDenials() {
        let error = ACPBackendError.launchFailed(
            executable: "/Users/dev/.bun/bin/bun",
            stderr: nil,
            hint: nil,
            sandboxDenials: [
                "deny file-write-create /Users/wsargent/.pi/agent/settings.json.lock",
            ])
        let rendered = error.errorDescription ?? ""
        #expect(rendered.contains("Failed to launch /Users/dev/.bun/bin/bun."))
        #expect(rendered.contains("\nSandbox denials:\n"))
        #expect(rendered.contains("deny file-write-create /Users/wsargent/.pi/agent/settings.json.lock"))
    }

    /// Without denials the chat launch failure renders exactly as before
    /// (#733/#737 shape) — no dangling section.
    @Test func chatLaunchFailedWithoutDenialsRendersLegacyShape() {
        let error = ACPBackendError.launchFailed(
            executable: "/usr/local/bin/claude",
            stderr: "env: node: No such file or directory",
            hint: ProviderEnvHint(envVar: "CLAUDE_CODE_EXECUTABLE", description: "Claude Code (claude)"),
            sandboxDenials: [])
        let rendered = error.errorDescription ?? ""
        #expect(rendered.contains("Failed to launch /usr/local/bin/claude."))
        #expect(rendered.contains("env: node: No such file or directory"))
        #expect(rendered.contains("Hint: set CLAUDE_CODE_EXECUTABLE"))
        #expect(rendered.contains("Sandbox denials:") == false)
    }

    // MARK: - Helpers

    /// The exact `--start` serialization spec the reporter uses
    /// (local-time `yyyy-MM-dd HH:mm:ss`, POSIX digits).
    private static func formatForLogShow(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
#endif
