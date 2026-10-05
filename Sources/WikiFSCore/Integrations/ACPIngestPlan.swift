import Foundation

/// The `Codable` contract between the **planner** and **executor** phases of
/// multi-phase ACP ingestion (`runACPIngestPlannerExecutors`).
///
/// The planner (Opus) reads staged sources, decides the page set, and writes a
/// `plan.json` in the scratch directory. Executors (Sonnet) each read the plan +
/// their assigned source section and write wiki pages via `wikictl`.
///
/// This is the pure, unit-tested schema + extraction + prompt builders — no I/O,
/// no ACP session management. The orchestration lives in `AgentLauncher`.
///
/// See `plans/acp-multi-phase-ingestion.md` for the architecture.

// MARK: - Plan schema

/// An OPTIONAL supporting staged-source reference on a page assignment
/// (wiki strategies phase 4): other staged material the assigned writer
/// should READ as reconciliation context — e.g. a later chapter that
/// corrects or extends the primary source's account, or the source behind
/// a citation the page must keep. Supporting sources are reading material
/// for the one assigned writer, never co-writers: the primary `sourceFile`
/// stays the responsibility marker.
public struct ACPIngestSupportingSource: Codable, Equatable, Sendable {
    /// The staged source filename — the same shell-safe, provenance-carrying
    /// leaf form as `ACPIngestPageAssignment.sourceFile`, copied verbatim
    /// from the planner's source list. Validated against the staged source
    /// list before executors launch.
    public let sourceFile: String
    /// Human-readable range within the supporting source (e.g. `"lines 40-60"`
    /// or `"section 'Handshake'"`) — where the relevant material STARTS. The
    /// writer may read beyond it when assessing a retained, disputed, or
    /// superseded claim requires it.
    public let sourceRanges: String

    public init(sourceFile: String, sourceRanges: String) {
        self.sourceFile = sourceFile
        self.sourceRanges = sourceRanges
    }
}

/// One page assignment: the planner's decision that this page should exist,
/// backed by a specific section of a staged source file.
public struct ACPIngestPageAssignment: Codable, Equatable, Sendable {
    /// The wiki page title to create or update (upserting an existing title
    /// updates it — the planner checks `wikictl page list` for dedup).
    public let title: String
    /// The staged source filename in the scratch directory — a shell-safe,
    /// provenance-carrying leaf of the form
    /// `<shellSafeStem>--<full-ULID>.<ext>`
    /// (e.g. `"Neuralwatt-Cloud-Platform--01KXYMP7J6HZ3E34ZZX02HKS1F.html"`).
    /// The planner copies this verbatim from the source list in its prompt;
    /// the executor dispatch keys on it via `distinctSourceFiles` /
    /// `assignments(forSource:)` (exact string match). This is the page's
    /// PRIMARY source — it names the one executor responsible for writing
    /// the page.
    public let sourceFile: String
    /// Human-readable description of where in the source file the content for
    /// this page is (e.g. `"lines 1-80"`, `"section 'Intro'"`, `"entire file"`).
    public let sourceRanges: String
    /// A 1-3 sentence description of what the page covers. Helps the executor
    /// know what to write without re-reading the entire source.
    public let outline: String
    /// OPTIONAL supporting staged sources for the assigned writer (see
    /// `ACPIngestSupportingSource`). `nil` — the default — is what a plan
    /// written before this field decodes to, so old `plan.json` files load
    /// unchanged; `[]` is a planner that explicitly assigned none. Both
    /// render the same executor prompt; the distinction is preserved so plan
    /// round-trips stay exact.
    public let supportingSources: [ACPIngestSupportingSource]?

    public init(
        title: String,
        sourceFile: String,
        sourceRanges: String,
        outline: String,
        supportingSources: [ACPIngestSupportingSource]? = nil
    ) {
        self.title = title
        self.sourceFile = sourceFile
        self.sourceRanges = sourceRanges
        self.outline = outline
        self.supportingSources = supportingSources
    }
}

/// The full plan: all page assignments + the source IDs of the queued payload.
public struct ACPIngestPlan: Codable, Equatable, Sendable {
    /// All page assignments. Executors are grouped by `sourceFile` and each
    /// executor receives its subset.
    public let pages: [ACPIngestPageAssignment]
    /// The source IDs (ULIDs) of the queued payload, echoed to the phase
    /// prompts so each phase knows the payload's source identity. The agent
    /// does NOT use them to mark sources Ingested: pipeline prompts dropped
    /// the `log append --source` ritual (#1347) and `wikictl` refuses it for
    /// agent-authored runs (#1367) — the host marks sources Ingested at
    /// validated-successful job completion. Echoed from the planner prompt;
    /// copied verbatim to `plan.json`.
    public let sourceIDs: [String]

    public init(pages: [ACPIngestPageAssignment], sourceIDs: [String]) {
        self.pages = pages
        self.sourceIDs = sourceIDs
    }

    /// Group pages by source file — each executor gets one source file's pages.
    /// Returns assignments for the given source filename only.
    public func assignments(forSource file: String) -> [ACPIngestPageAssignment] {
        pages.filter { $0.sourceFile == file }
    }

    /// The distinct source files referenced by the plan, in first-occurrence
    /// order. Used to assign executors (one executor per source file).
    public var distinctSourceFiles: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for page in pages where !seen.contains(page.sourceFile) {
            seen.insert(page.sourceFile)
            result.append(page.sourceFile)
        }
        return result
    }

    /// All page titles (for cross-linking in the executor prompt).
    public var allPageTitles: [String] {
        pages.map(\.title)
    }

    // MARK: - Tolerant JSON extraction

    /// Extract an `ACPIngestPlan` from raw bytes that may be wrapped in prose or
    /// ```json fences. Claude routinely wraps JSON in markdown or surrounding
    /// text. The extraction:
    /// 1. Strips leading/trailing whitespace.
    /// 2. Strips ```json or ``` fences if present.
    /// 3. Substrings from the first `{` to the last `}`.
    /// 4. Decodes via `JSONDecoder`.
    ///
    /// Returns `nil` if the bytes contain no valid plan JSON.
    public static func extract(from data: Data) -> ACPIngestPlan? {
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        return extract(from: raw)
    }

    /// String-based extraction (testable without `Data` round-trip).
    public static func extract(from raw: String) -> ACPIngestPlan? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip ```json … ``` fences if present.
        if s.hasPrefix("```") {
            // Remove opening fence (```json or ```).
            if let firstNewline = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: firstNewline)...])
            }
            // Remove closing fence.
            if let closingRange = s.range(of: "```", options: .backwards) {
                s = String(s[..<closingRange.lowerBound])
            }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Substring from first `{` to last `}`.
        guard let firstBrace = s.firstIndex(of: "{"),
              let lastBrace = s.lastIndex(of: "}"),
              firstBrace <= lastBrace else {
            return nil
        }
        let jsonSubstring = String(s[firstBrace...lastBrace])

        guard let jsonData = jsonSubstring.data(using: .utf8) else { return nil }
        return DebugLog.trying("extract", operation: { try JSONDecoder().decode(ACPIngestPlan.self, from: jsonData) })
    }

    /// Read `plan.json` from the given directory and extract the plan.
    /// Returns `nil` if the file is missing or invalid.
    public static func load(from directory: URL) -> ACPIngestPlan? {
        let planURL = directory.appendingPathComponent("plan.json")
        guard let data = DebugLog.trying("load", operation: { try Data(contentsOf: planURL) }) else { return nil }
        return extract(from: data)
    }
}

// MARK: - Pre-launch validation

/// Pre-launch validation of a planner-written plan (wiki strategies phase 4).
///
/// Two classes of defect are rejected BEFORE any executor session launches:
/// - source references — the primary `sourceFile` AND every supporting
///   source — that do not name a staged source file (the writer would be
///   sent to read a file that does not exist);
/// - duplicate resolved page targets — two assignments that would write the
///   same page. Target resolution uses the SAME semantics `PageUpsert`
///   applies when it writes: `WikiNameRules.sanitized(title)` first, then
///   the store's title resolution (`resolveTitleToID` — SQLite
///   `COLLATE NOCASE`, lowest id on a stored duplicate-title collision).
///   Assignments that resolve to no existing page are compared as new
///   titles under the same ASCII-only case fold, so Unicode case pairs
///   (Ä/ä) stay distinct titles exactly as SQLite treats them.
///
/// The launcher reports the problems as an actionable failure and launches
/// no executors — it never silently selects a winning writer, and the
/// pre-existing protection between concurrent INDEPENDENT runs remains CAS
/// at write time, not a global lock here.
public enum ACPIngestPlanValidation {

    /// One actionable plan defect. `description` is written for the run
    /// transcript: it names the offending assignment and what to fix.
    public enum Problem: Error, Equatable, Sendable, CustomStringConvertible {
        /// An assignment's primary `sourceFile` is not a staged source file.
        case unknownPrimarySource(pageTitle: String, sourceFile: String)
        /// A supporting source reference is not a staged source file.
        case unknownSupportingSource(pageTitle: String, sourceFile: String)
        /// Two or more assignments write the same page — either the same
        /// existing page (`existingPageID` set) or the same title that no
        /// page holds yet (`existingPageID` nil).
        case duplicateResolvedTarget(resolvedTitle: String, pageTitles: [String], existingPageID: PageID?)
        /// The injected title resolver FAILED for one assignment (store
        /// unreadable, database missing, I/O error). Never silently degraded
        /// to new-title folding: with a resolver in place, existing-page
        /// duplicate detection is load-bearing, so the plan is rejected with
        /// the underlying reason.
        case titleResolutionFailed(pageTitle: String, reason: String)

        public var description: String {
            switch self {
            case let .unknownPrimarySource(pageTitle, sourceFile):
                return "plan page \"\(pageTitle)\" names primary source \"\(sourceFile)\", which is not one of the staged source files"
            case let .unknownSupportingSource(pageTitle, sourceFile):
                return "plan page \"\(pageTitle)\" names supporting source \"\(sourceFile)\", which is not one of the staged source files"
            case let .duplicateResolvedTarget(resolvedTitle, pageTitles, existingPageID):
                let whereTo = existingPageID
                    .map { "the existing page (id \($0.rawValue))" }
                    ?? "the same not-yet-existing page"
                let titles = pageTitles.map { "\"\($0)\"" }.joined(separator: ", ")
                return "plan pages \(titles) all resolve to \(whereTo) via title \"\(resolvedTitle)\" — one topic needs exactly one assigned writer"
            case let .titleResolutionFailed(pageTitle, reason):
                return "title resolution failed for plan page \"\(pageTitle)\": \(reason) — the plan cannot be validated against the wiki; check the wiki store and retry"
            }
        }
    }

    /// One-line summary of a rejected plan, for a queue-visible failure string.
    ///
    /// The queue error is short, so this names the FIRST problem verbatim and
    /// counts the rest. The full multi-line detail stays in the run log and
    /// the transcript event. Returns `nil` for an empty list — a plan with no
    /// problems is not a rejection.
    public static func failureSummary(_ problems: [Problem]) -> String? {
        guard let first = problems.first else { return nil }
        let summary = "Ingest plan rejected before executor launch: \(first.description)"
        guard problems.count > 1 else { return summary }
        return "\(summary) (+\(problems.count - 1) more)"
    }

    /// All problems found in `plan`, in first-occurrence order. An empty
    /// result means the plan may launch.
    ///
    /// - Parameters:
    ///   - stagedSourceFiles: the staged source LEAF names in the scratch
    ///     directory; every `sourceFile` (primary and supporting) must match
    ///     one verbatim.
    ///   - resolveTitleToPageID: resolves a SANITIZED title to an existing
    ///     page using the store's `resolveTitleToID` semantics. Production
    ///     hosts inject a store-backed closure (the shared LauncherFactory
    ///     over the wiki's store; the pipeline tests over an in-memory
    ///     store; the live evaluation harness over its disposable database);
    ///     the launcher never derives a database path itself. A resolver
    ///     that THROWS is an actionable `titleResolutionFailed` problem —
    ///     with a resolver in place, existing-page duplicate detection is
    ///     load-bearing and is never silently skipped. Only an ABSENT
    ///     resolver (`nil` seam, e.g. an uninjected test harness) falls
    ///     back to new-title ASCII folding.
    public static func problems(
        in plan: ACPIngestPlan,
        stagedSourceFiles: [String],
        resolveTitleToPageID: (String) throws -> PageID?
    ) -> [Problem] {
        var problems: [Problem] = []
        let staged = Set(stagedSourceFiles)

        for page in plan.pages {
            if !staged.contains(page.sourceFile) {
                problems.append(.unknownPrimarySource(pageTitle: page.title, sourceFile: page.sourceFile))
            }
            for supporting in (page.supportingSources ?? []) where !staged.contains(supporting.sourceFile) {
                problems.append(.unknownSupportingSource(pageTitle: page.title, sourceFile: supporting.sourceFile))
            }
        }

        // Duplicate resolved targets, keyed exactly as PageUpsert writes:
        // sanitized title → the existing page id when one resolves, else the
        // sanitized title under SQLite's ASCII-only NOCASE fold.
        struct ResolvedTarget {
            let resolvedTitle: String
            let existingPageID: PageID?
            var titles: [String]
        }
        var ordered: [ResolvedTarget] = []
        var indexOfKey: [String: Int] = [:]
        for page in plan.pages {
            let sanitized = WikiNameRules.sanitized(page.title)
            let existing: PageID?
            do {
                existing = try resolveTitleToPageID(sanitized)
            } catch {
                // Actionable failure, not a silent degrade: an injected
                // resolver that cannot read the wiki makes the plan
                // unvalidatable, so reject it with the underlying reason.
                DebugLog.agent("ACPIngestPlanValidation: title resolver FAILED for \"\(sanitized)\" — \(error.localizedDescription)")
                problems.append(.titleResolutionFailed(pageTitle: page.title, reason: error.localizedDescription))
                existing = nil
            }
            let key: String
            if let existing {
                key = "page:\(existing.rawValue)"
            } else {
                key = "title:\(nocaseFoldKey(sanitized))"
            }
            if let index = indexOfKey[key] {
                ordered[index].titles.append(page.title)
            } else {
                indexOfKey[key] = ordered.count
                ordered.append(ResolvedTarget(resolvedTitle: sanitized, existingPageID: existing, titles: [page.title]))
            }
        }
        for target in ordered where target.titles.count > 1 {
            problems.append(.duplicateResolvedTarget(
                resolvedTitle: target.resolvedTitle,
                pageTitles: target.titles,
                existingPageID: target.existingPageID))
        }
        return problems
    }

    /// SQLite `COLLATE NOCASE` folds ASCII `A`–`Z` only; Unicode case pairs
    /// (Ä/ä) compare DISTINCT. Mirror that exactly — a Swift `lowercased()`
    /// key would wrongly flag distinct new titles as duplicates.
    static func nocaseFoldKey(_ title: String) -> String {
        String(title.map { character in
            guard let ascii = character.asciiValue, (65...90).contains(ascii) else { return character }
            return Character(UnicodeScalar(ascii + 32))
        })
    }
}

// MARK: - Pure prompt builders

/// Pure (no I/O) prompt builders for the three phases of multi-phase ACP
/// ingestion. Each fills a `GeneratedPrompts` template via `PromptTemplate.fill`.
/// Unit-tested directly — no ACP session required.
public enum ACPIngestPrompts {

    /// The planner task prompt. Instructs Opus to read staged sources, decide
    /// the page set, and write `plan.json` — without writing any wiki pages.
    public static func plannerPrompt(
        stateFilePath: String,
        stagedSourcePaths: [String],
        sourceIDs: [String],
        retryAdvisory: String? = nil
    ) -> String {
        let sourceFiles = stagedSourcePaths
            .map { path -> String in
                // Show the filename (the agent's cwd is the scratch dir) + the
                // absolute path so the agent knows where it is.
                let name = (path as NSString).lastPathComponent
                return "- \(name)  (absolute: \(path))"
            }
            .joined(separator: "\n")

        let prompt = PromptTemplate.fill(GeneratedPrompts.ingestPlanner, [
            "STATE_FILE_PATH": stateFilePath,
            "SOURCE_FILES": sourceFiles,
            "SOURCE_IDS": sourceIDs.joined(separator: ", "),
        ])
        return appendRetryAdvisory(retryAdvisory, to: prompt)
    }

    /// The executor task prompt. Instructs Sonnet to read its assigned source
    /// section and write each page via `wikictl page add`. Cross-references
    /// all page titles for linking.
    public static func executorPrompt(
        stateFilePath: String,
        assignments: [ACPIngestPageAssignment],
        allPageTitles: [String],
        sourceIDs: [String],
        retryAdvisory: String? = nil
    ) -> String {
        let assignedPages = assignments.map { a -> String in
            var lines = [
                "### \(a.title)",
                "- Source: \(a.sourceFile), \(a.sourceRanges)",
            ]
            // Supporting staged sources (wiki strategies phase 4): reading
            // context for the assigned writer, rendered only when present so
            // prompts for plans without them stay byte-identical to before.
            for supporting in a.supportingSources ?? [] {
                lines.append("- Supporting: \(supporting.sourceFile), \(supporting.sourceRanges)")
            }
            lines.append("- Outline: \(a.outline)")
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")

        // The fallback is only reached when `assignments` is empty — an
        // executor always has ≥1 page in practice (the launcher skips an
        // empty-assignment source). `source.md` is an obviously-placeholder
        // leaf (no `--<ulid>` suffix, no provenance) so a missing assignment
        // is visible at a glance rather than masquerading as a real source.
        let primarySourceFile = assignments.first?.sourceFile ?? "source.md"

        let prompt = PromptTemplate.fill(GeneratedPrompts.ingestExecutor, [
            "STATE_FILE_PATH": stateFilePath,
            "ASSIGNED_PAGES": assignedPages,
            "ALL_PAGE_TITLES": allPageTitles.map { "- \($0)" }.joined(separator: "\n"),
            "SOURCE_IDS": sourceIDs.joined(separator: ", "),
            "PRIMARY_SOURCE_FILE": primarySourceFile,
        ])
        return appendRetryAdvisory(retryAdvisory, to: prompt)
    }

    private static func appendRetryAdvisory(_ advisory: String?, to prompt: String) -> String {
        guard let advisory, !advisory.isEmpty else { return prompt }
        return "\(prompt)\n\n## Prior ceiling-kill context\n\(advisory)"
    }

    /// The finalizer task prompt. Instructs Opus to write `index.md` and record
    /// log entries for each source.
    public static func finalizerPrompt(
        stateFilePath: String,
        sourceFileNames: [String],
        sourceIDs: [String]
    ) -> String {
        // Pair source file names with IDs for the log entries.
        let pairs = zip(sourceFileNames, sourceIDs).map { name, id -> String in
            "- \(name) → \(id)"
        }.joined(separator: "\n")

        return PromptTemplate.fill(GeneratedPrompts.ingestFinalizer, [
            "STATE_FILE_PATH": stateFilePath,
            "SOURCE_FILES_AND_IDS": pairs,
        ])
    }
}
