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

/// One page assignment: the planner's decision that this page should exist,
/// backed by a specific section of a staged source file.
public struct ACPIngestPageAssignment: Codable, Equatable, Sendable {
    /// The wiki page title to create or update (upserting an existing title
    /// updates it — the planner checks `wikictl page list` for dedup).
    public let title: String
    /// The staged source filename in the scratch directory (e.g. `"source-1.md"`).
    public let sourceFile: String
    /// Human-readable description of where in the source file the content for
    /// this page is (e.g. `"lines 1-80"`, `"section 'Intro'"`, `"entire file"`).
    public let sourceRanges: String
    /// A 1-3 sentence description of what the page covers. Helps the executor
    /// know what to write without re-reading the entire source.
    public let outline: String

    public init(title: String, sourceFile: String, sourceRanges: String, outline: String) {
        self.title = title
        self.sourceFile = sourceFile
        self.sourceRanges = sourceRanges
        self.outline = outline
    }
}

/// The full plan: all page assignments + the source IDs (for `wikictl log append
/// --source`).
public struct ACPIngestPlan: Codable, Equatable, Sendable {
    /// All page assignments. Executors are grouped by `sourceFile` and each
    /// executor receives its subset.
    public let pages: [ACPIngestPageAssignment]
    /// The source IDs (ULIDs) for `wikictl log append --kind ingest --source <id>`.
    /// Echoed from the planner prompt; copied verbatim to `plan.json`.
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
        return try? JSONDecoder().decode(ACPIngestPlan.self, from: jsonData)
    }

    /// Read `plan.json` from the given directory and extract the plan.
    /// Returns `nil` if the file is missing or invalid.
    public static func load(from directory: URL) -> ACPIngestPlan? {
        let planURL = directory.appendingPathComponent("plan.json")
        guard let data = try? Data(contentsOf: planURL) else { return nil }
        return extract(from: data)
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
        sourceIDs: [String]
    ) -> String {
        let sourceFiles = stagedSourcePaths
            .map { path -> String in
                // Show the filename (the agent's cwd is the scratch dir) + the
                // absolute path so the agent knows where it is.
                let name = (path as NSString).lastPathComponent
                return "- \(name)  (absolute: \(path))"
            }
            .joined(separator: "\n")

        return PromptTemplate.fill(GeneratedPrompts.ingestPlanner, [
            "STATE_FILE_PATH": stateFilePath,
            "SOURCE_FILES": sourceFiles,
            "SOURCE_IDS": sourceIDs.joined(separator: ", "),
        ])
    }

    /// The executor task prompt. Instructs Sonnet to read its assigned source
    /// section and write each page via `wikictl page add`. Cross-references
    /// all page titles for linking.
    public static func executorPrompt(
        stateFilePath: String,
        assignments: [ACPIngestPageAssignment],
        allPageTitles: [String],
        sourceIDs: [String]
    ) -> String {
        let assignedPages = assignments.map { a -> String in
            """
            ### \(a.title)
            - Source: \(a.sourceFile), \(a.sourceRanges)
            - Outline: \(a.outline)
            """
        }.joined(separator: "\n\n")

        let primarySourceFile = assignments.first?.sourceFile ?? "source-1.md"

        return PromptTemplate.fill(GeneratedPrompts.ingestExecutor, [
            "STATE_FILE_PATH": stateFilePath,
            "ASSIGNED_PAGES": assignedPages,
            "ALL_PAGE_TITLES": allPageTitles.map { "- \($0)" }.joined(separator: "\n"),
            "SOURCE_IDS": sourceIDs.joined(separator: ", "),
            "PRIMARY_SOURCE_FILE": primarySourceFile,
        ])
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
