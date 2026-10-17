#if os(macOS)
import Foundation
import WikiFSCore

/// Unified-log reporter for macOS Seatbelt (sandbox) denials (issue #1409).
///
/// When a sandboxed adapter spawn fails, the cryptic surface error (e.g.
/// "Cannot call write after a stream was destroyed") hides the real cause:
/// a kernel denial such as
/// `Sandbox: node(34070) deny(1) file-write-create /Users/wsargent/.pi/agent/settings.json.lock`,
/// logged by the unified log milliseconds before the adapter's own error.
/// This reporter turns that window+token query into one bounded `log show`
/// invocation and a set of normalized denial lines that the launch-failure
/// paths (`ACPProviderModelProbe.runProbe`, `ACPBackend.startProcess`)
/// append to their typed errors.
///
/// **Bounded by construction.** One query per failure, a hard wall-clock
/// bound (`queryTimeBound`) raced unstructured (so a caller that is itself
/// being cancelled — the probe losing its timeout race — cannot take the
/// query down with it), a clamped lookback window (`maximumLookback`), and
/// a capped, deduplicated result (`defaultDenialLimit`).
///
/// **v1 attribution is window+token, NOT pid-perfect.** The ACP SDK client
/// does not expose the child pid to us, so denials are matched by the launch
/// window plus lowercase tokens derived from the spawn argv basenames and
/// the `ACPBackend.providerHomeSubpaths` values. A same-window denial from
/// an unrelated process sharing a token (e.g. the ubiquitous
/// `file-write-data /dev/dtracehelper` line under a `node` token) can
/// appear; the cap and the dedupe keep that readable. Pid-perfect
/// attribution is a future refinement if the SDK ever surfaces child pids.
enum SandboxDenialReporter {

    /// One bounded `log show` invocation. Takes the FULL argv (executable
    /// path first), returns the combined output, or nil when the invocation
    /// failed. Injectable so tests never spawn `/usr/bin/log`.
    typealias LogShowInvocation = @Sendable ([String]) async -> String?

    /// A denial query bound to a launch window. Returns the normalized,
    /// deduplicated, capped denial lines (empty when none). Injectable so the
    /// probe and backend tests can return canned denials.
    typealias DenialQuery = @Sendable (Date, [String]) async -> [String]

    /// Maximum normalized denial lines returned (and rendered).
    static let defaultDenialLimit = 8

    /// Token floor: shorter tokens (the 1-character `x` runner argument in
    /// `bun x …`) are substrings of common words ("sandbox") and would
    /// over-match every denial line in the window, evicting the real
    /// diagnosis from the capped result. `.pi` (3) survives.
    static let minimumTokenLength = 3

    /// Hard wall-clock bound for the whole `log show` invocation. `log show`
    /// scans the whole store from `--start`, so an unbounded query could run
    /// for minutes; past this bound the reporter gives up (returns []).
    static let queryTimeBound: Duration = .seconds(8)

    /// The lookback clamp: `--start` never goes further back than this many
    /// seconds before `now`, no matter how stale the caller's `since` is. A
    /// launch failure is diagnosed within seconds of the launch, so a long
    /// scan only adds noise and runtime.
    static let maximumLookback: TimeInterval = 300

    /// Slack subtracted from `since` so denials logged a beat BEFORE the
    /// recorded launch instant (clock skew, early child output) are inside
    /// the window.
    static let windowSlackSeconds: TimeInterval = 1

    /// The unified-log front-end used by the production invocation.
    static let logShowExecutable = "/usr/bin/log"

    // MARK: - PURE: parsing

    /// PURE. From raw `log show` output, keep the lines that carry a Seatbelt
    /// deny marker AND (case-insensitively) any token, normalize each to
    /// `deny <operation> <path-or-argument>` (dropping timestamps, pids, and
    /// every other prefix), deduplicate preserving first occurrence, and cap
    /// at `limit`. Empty/absent tokens or a non-positive limit yield [].
    static func parseDenials(
        fromLogOutput output: String,
        tokens: [String],
        limit: Int = defaultDenialLimit
    ) -> [String] {
        guard limit > 0 else { return [] }
        let loweredTokens = tokens.map { $0.lowercased() }.filter { !$0.isEmpty }
        guard !loweredTokens.isEmpty else { return [] }
        var seen = Set<String>()
        var denials: [String] = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard let markerRange = line.range(of: "deny(") else { continue }
            let lowered = line.lowercased()
            guard loweredTokens.contains(where: { lowered.contains($0) }) else { continue }
            guard let normalized = normalizedDenial(line, afterMarker: markerRange) else { continue }
            if seen.insert(normalized).inserted {
                denials.append(normalized)
                if denials.count == limit { break }
            }
        }
        return denials
    }

    /// PURE. Normalize one already-token-matched log line into
    /// `deny <operation> <path-or-argument>`. The seatbelt form after the
    /// marker is `deny(<result>) <operation> <argument…>`; anything else is
    /// skipped as not-a-denial.
    private static func normalizedDenial(
        _ line: String,
        afterMarker markerRange: Range<String.Index>
    ) -> String? {
        var cursor = markerRange.upperBound
        // Skip the parenthesized result, e.g. "1)".
        guard let digitEnd = line[cursor...].firstIndex(where: { !$0.isNumber }) else {
            return nil
        }
        guard line[digitEnd] == ")" else { return nil }
        cursor = line.index(after: digitEnd)
        // Skip whitespace between ")" and the operation.
        while cursor < line.endIndex, line[cursor].isWhitespace {
            cursor = line.index(after: cursor)
        }
        let operationStart = cursor
        guard let operationEnd = line[operationStart...].firstIndex(where: \.isWhitespace) else {
            // "deny(1) mach-lookup" with the operation as the last token.
            let operation = String(line[operationStart...]).trimmingCharacters(in: .whitespaces)
            return operation.isEmpty ? nil : "deny \(operation)"
        }
        let operation = String(line[operationStart..<operationEnd])
        let argument = String(line[line.index(after: operationEnd)...])
            .trimmingCharacters(in: .whitespaces)
        guard !operation.isEmpty else { return nil }
        return argument.isEmpty ? "deny \(operation)" : "deny \(operation) \(argument)"
    }

    // MARK: - PURE: inputs

    /// PURE. The case-insensitive match tokens for one launch: lowercase
    /// basenames of the spawn argv (the adapter runs under a runtime whose
    /// name — node, bun, python3 — heads the kernel denial lines) plus the
    /// `providerHomeSubpaths` values (".npm", ".bun", ".codex", …) whose
    /// denied config-home writes are exactly what this reporter exists to
    /// surface. Deduplicated, order-stable. See the v1-attribution comment
    /// on this type for the matching tradeoff.
    static func sandboxDenialTokens(executablePath: String, arguments: [String]) -> [String] {
        var tokens: [String] = []
        func insert(_ raw: String) {
            let lowered = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            // The floor keeps `bun x`'s 1-character runner argument ("x")
            // out of the token set: "x" is a substring of "sandbox", so it
            // would match effectively every denial line in the window and
            // evict the real diagnosis from the capped result.
            guard lowered.count >= minimumTokenLength,
                  !tokens.contains(lowered) else { return }
            tokens.append(lowered)
        }
        // Basename each argv element: the executable is a path; arguments may
        // carry package specs (the adapter name usually lives in an argument,
        // e.g. `bun x @agentclientprotocol/pi-acp`).
        for element in [executablePath] + arguments {
            insert((element as NSString).lastPathComponent)
        }
        for subpath in ACPBackend.providerHomeSubpaths(
            executablePath: executablePath,
            arguments: arguments) {
            insert(subpath)
        }
        return tokens
    }

    /// PURE. The exact `log` argv for one denial query: a compact-style show
    /// over the clamped launch window with a deny+token predicate. The window
    /// starts `windowSlackSeconds` before `since`, never further back than
    /// `maximumLookback` before `now` (a stale `since` must not turn into a
    /// minutes-long store scan).
    static func logShowArguments(since: Date, tokens: [String], now: Date = Date()) -> [String] {
        let windowStart = max(
            since.addingTimeInterval(-windowSlackSeconds),
            now.addingTimeInterval(-maximumLookback))
        return [
            logShowExecutable,
            "show",
            "--style", "compact",
            "--start", timestampText(windowStart),
            "--predicate", logShowPredicate(tokens: tokens),
        ]
    }

    /// PURE. The predicate string: kernel/agent eventMessages that mention a
    /// deny AND any token. Tokens are escaped for the predicate's double
    /// quoted literals (backslash first, then quotes). With no tokens the
    /// predicate degrades to deny-only matching — the parser's empty-token
    /// guard still returns [], and `recentDenials` never reaches the query
    /// in that case anyway.
    static func logShowPredicate(tokens: [String]) -> String {
        let clauses = tokens
            .filter { !$0.isEmpty }
            .map { token -> String in
                let escaped = token
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                return "eventMessage CONTAINS[c] \"\(escaped)\""
            }
        if clauses.isEmpty {
            return #"eventMessage CONTAINS "deny""#
        }
        return "eventMessage CONTAINS \"deny\" AND (\(clauses.joined(separator: " OR ")))"
    }

    /// PURE. Append the rendered denial section to a failure message. Empty
    /// denials return the message unchanged.
    static func appending(_ message: String, denials: [String]) -> String {
        guard !denials.isEmpty else { return message }
        return message + "\n\nSandbox denials:\n"
            + denials.map { "- \($0)" }.joined(separator: "\n")
    }

    /// `log show --start` parses `YYYY-MM-DD HH:mm:ss` in the local time
    /// zone; en_US_POSIX pins the digits. Built per call — DateFormatter is
    /// a non-Sendable class and this query is rare enough that allocation
    /// costs nothing.
    private static func timestampText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    // MARK: - Production query

    /// One bounded unified-log query for the denials of a failed launch.
    /// `since` is the recorded launch instant; `bound` races the query so a
    /// slow store scan cannot hold the failure path hostage. The race is
    /// UNSTRUCTURED (mirroring `ACPProviderModelProbe.boundedRace`): the
    /// caller may already be cancelled (the probe losing its timeout race),
    /// and a structured task group would cancel this query with it — exactly
    /// the failure being diagnosed. When the bound wins, the query task is
    /// cancelled, which the production `AsyncProcessRunner` answers by
    /// terminating the `log` subprocess; the abandoned task then unwinds
    /// harmlessly.
    static func recentDenials(
        since: Date,
        tokens: [String],
        limit: Int = defaultDenialLimit,
        now: Date = Date(),
        bound: Duration = queryTimeBound,
        runLogShow: @escaping LogShowInvocation = SandboxDenialReporter.defaultLogShowInvocation
    ) async -> [String] {
        let sanitizedTokens = tokens
            .map { $0.lowercased() }
            .filter { $0.count >= minimumTokenLength }
        guard !sanitizedTokens.isEmpty, limit > 0 else { return [] }
        // A caller cancelled while unwinding (probe timeout, user cancel)
        // should not wait out the bounded race — the denial section would
        // be discarded anyway.
        guard !Task.isCancelled else { return [] }
        // logd delivery can lag the kernel's denial by a beat; the query's
        // open-ended end (now) plus the 8s bound absorb typical flush
        // latency. A denial missing from an immediate query is possible —
        // the raw adapter error still surfaces.
        let argv = logShowArguments(since: since, tokens: sanitizedTokens, now: now)

        let box = RaceBox()
        let query = Task {
            await box.resume(.output(await runLogShow(argv)))
        }
        let deadline = Task {
            do {
                try await Task.sleep(for: bound)
            } catch {
                return // the query already won — nothing to settle
            }
            await box.resume(.timedOut)
        }
        let outcome = await box.wait()
        deadline.cancel()
        // No-op when the query won; on a bound win it stops the `log`
        // subprocess via the runner's cancellation handling.
        query.cancel()
        switch outcome {
        case .output(let text):
            return parseDenials(
                fromLogOutput: text ?? "",
                tokens: sanitizedTokens,
                limit: limit)
        case .timedOut:
            DebugLog.agent(
                "SandboxDenialReporter: log show exceeded \(bound) — no denials attached")
            return []
        }
    }

    /// The production invocation: one `AsyncProcessRunner` run of `log show`
    /// with combined output. The runner is non-blocking (readability pumps +
    /// termination continuations) and answers cancellation by terminating
    /// the subprocess after a grace period — the properties the bound above
    /// relies on. Any failure (missing front-end, non-zero exit, spawn
    /// error) surfaces as nil; a failed diagnostic query must never mask the
    /// launch failure it is annotating, so the error is only logged.
    static let defaultLogShowInvocation: LogShowInvocation = { argv in
        guard let executable = argv.first else { return nil }
        let request = AsyncProcessRequest(
            executableURL: URL(fileURLWithPath: executable),
            arguments: Array(argv.dropFirst()),
            outputMode: .combined,
            cancellationGracePeriod: .seconds(2))
        do {
            let result = try await AsyncProcessRunner.run(request)
            return String(data: result.combinedData, encoding: .utf8)
        } catch {
            DebugLog.agent("SandboxDenialReporter: log show failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Bounded race plumbing

    private enum RaceOutcome: Sendable {
        case output(String?)
        case timedOut
    }

    /// Resume-once box (actor isolation serializes the once-check) — the
    /// same primitive shape as `ACPProviderModelProbe.BoundedRaceBox`.
    private actor RaceBox {
        private var outcome: RaceOutcome?
        private var continuation: CheckedContinuation<RaceOutcome, Never>?

        func resume(_ value: RaceOutcome) {
            guard outcome == nil else { return }
            outcome = value
            continuation?.resume(returning: value)
            continuation = nil
        }

        func wait() async -> RaceOutcome {
            if let outcome { return outcome }
            return await withCheckedContinuation { continuation = $0 }
        }
    }
}
#endif
