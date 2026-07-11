import Foundation
import WikiFSCore

/// The `wikictl page …` subcommands, executed against an already-opened
/// `WikiStore`. Deliberately split from process concerns (arg parsing, stdin,
/// the Darwin post, opening the DB) so the whole command surface is unit-testable
/// against a temp DB: a test builds a `SQLiteWikiStore`, runs a `PageCommand`,
/// and asserts on the returned `Result`.
public enum PageCommand {

    /// What a command produced: text to print and whether it COMMITTED a write
    /// (so the caller knows to post the change notification — `wikictl` posts
    /// only after a committing call, never on a pure read).
    public struct Result: Equatable {
        public var output: String
        public var didCommit: Bool

        public init(output: String, didCommit: Bool) {
            self.output = output
            self.didCommit = didCommit
        }
    }

    /// How a page is selected for `get`/`upsert`/`delete`.
    public enum Selector: Equatable {
        case id(PageID)
        case title(String)
    }

    public enum Action: Equatable {
        case list(json: Bool)
        case get(Selector)
        /// `upsert` always carries the body (read from `--body-file`); the
        /// optional id forces updating a specific page, otherwise the title
        /// resolves create-or-update.
        case upsert(id: PageID?, title: String, body: String)
        case delete(id: PageID)
        /// Semantic search: find pages by meaning (cosine similarity via
        /// sqlite-vec), falling back to LIKE title match.
        case search(query: String, limit: Int)
        /// Show the page's version history (W0, PR #312). One line per version:
        /// `seq  versionID  saved_at  title  blob_hash  parent_id`.
        case history(Selector)
        /// Revert a page to a specific version (W0, PR #312). Repoints the
        /// page-content ref to `versionID` and updates the body mirror.
        case revert(Selector, versionID: String)
    }

    public enum Failure: Error, CustomStringConvertible {
        case message(String)

        public var description: String {
            switch self {
            case .message(let text): text
            }
        }
    }

    /// Run one action against `store`. Read actions never commit; `upsert` /
    /// `delete` do. Output mirrors the doc's command surface (TSV or JSON for
    /// `list`; the raw body for `get`; the resulting id for `upsert`).
    ///
    /// `validator` injects the Mermaid validator (defaults to the bundled one) so
    /// the abort-before-write path is end-to-end testable without a bundle.
    /// `linter` injects the Markdown linter (defaults to the bundled one) so the
    /// auto-fix-before-write path is testable without a bundle.
    public static func run(
        _ action: Action,
        in store: WikiStore,
        validator: MermaidValidator? = MermaidValidator.loadDefault(),
        linter: MarkdownLinter? = MarkdownLinter.loadDefault()
    ) throws -> Result {
        switch action {
        case .list(let json):
            return try list(in: store, json: json)
        case .get(let selector):
            return try get(selector, in: store)
        case .upsert(let id, let title, let body):
            return try upsert(id: id, title: title, body: body, in: store, validator: validator, linter: linter)
        case .delete(let id):
            return try delete(id: id, in: store)
        case .search(let query, let limit):
            return try search(query: query, limit: limit, in: store)
        case .history(let selector):
            return try history(selector, in: store)
        case .revert(let selector, let versionID):
            return try revert(selector, versionID: versionID, in: store)
        }
    }

    // MARK: - list

    private static func list(in store: WikiStore, json: Bool) throws -> Result {
        let summaries = try store.listPages(sortBy: .lastUpdated)
        if json {
            let rows = summaries.map { summary in
                JSONRow(
                    id: summary.id.rawValue,
                    title: summary.title,
                    path: pagePath(for: summary)
                )
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let lines = try rows.map { row -> String in
                let data = try encoder.encode(row)
                return String(decoding: data, as: UTF8.self)
            }
            return Result(output: lines.joined(separator: "\n"), didCommit: false)
        }
        // TSV: id <tab> title <tab> path, one page per line.
        let lines = summaries.map { summary in
            [summary.id.rawValue, summary.title, pagePath(for: summary)]
                .joined(separator: "\t")
        }
        return Result(output: lines.joined(separator: "\n"), didCommit: false)
    }

    /// One JSON line for `page list --json`.
    private struct JSONRow: Encodable {
        let id: String
        let title: String
        let path: String
    }

    /// The mount-relative `pages/by-title/<escaped>--<id8>.md` path, matching the
    /// File Provider projection's by-title leaf so the agent can `cat` it. Built
    /// from the SAME `FilenameEscaping` the projection uses, so the two can't
    /// drift.
    private static func pagePath(for summary: WikiPageSummary) -> String {
        let filename = FilenameEscaping.byTitleFilename(
            title: summary.title,
            pageID: summary.id.rawValue
        )
        return "pages/by-title/\(filename)"
    }

    // MARK: - get

    private static func get(_ selector: Selector, in store: WikiStore) throws -> Result {
        let id = try resolve(selector, in: store)
        let page = try store.getPage(id: id)
        // Print the body verbatim — this is the instant SoT read that bypasses
        // the ~5 s mount lag.
        return Result(output: page.bodyMarkdown, didCommit: false)
    }

    // MARK: - upsert

    private static func upsert(
        id: PageID?,
        title: String,
        body: String,
        in store: WikiStore,
        validator: MermaidValidator?,
        linter: MarkdownLinter?
    ) throws -> Result {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.message(
                "refusing to upsert an empty body for \(title.debugDescription) — nothing "
                + "was delivered. Under the sandbox a piped or heredoc'd body can arrive "
                + "empty; write the body to a file in your cwd and pass --body-file <path>."
            )
        }
        // 1. Auto-fix cosmetic markdown issues BEFORE the write (trailing
        //    whitespace, hard tabs, blank-line spacing, etc.). Skipped silently
        //    when the linter is nil (no bundle → dev / swift test). If any
        //    finding can't be auto-fixed, abort (inert under the cosmetic-only
        //    config — every enabled rule is auto-fixable).
        let fixed = try autoFixMarkdown(body, linter: linter)
        // 2. Validate ```mermaid blocks in the FIXED text (so the linter's
        //    whitespace fixes don't disturb a fence boundary). Skipped silently
        //    when the validator is nil.
        try abortOnInvalidMermaid(fixed, validator: validator)
        // 3. The SHARED seam: identical create-or-update + `[[link]]` reparse as
        //    the in-app editor, so the link graph stays consistent across both
        //    writers.
        let outcome = try PageUpsert.upsert(in: store, id: id, title: title, body: fixed)
        return Result(output: outcome.id.rawValue, didCommit: true)
    }

    /// Apply `MarkdownLinter.fix` to `body`, returning the normalized text. When
    /// `linter` is nil (unbundled / dev / `swift test`), returns `body` unchanged
    /// (no-op pass-through — the save proceeds unmodified). If `fix` returns
    /// unfixable findings, throws a `.message` with a report the agent can act on.
    static func autoFixMarkdown(_ body: String, linter: MarkdownLinter?) throws -> String {
        guard let linter else { return body }
        let outcome = linter.fix(markdown: body)
        if !outcome.unfixable.isEmpty {
            throw Failure.message(MarkdownLinter.describe(outcome.unfixable))
        }
        return outcome.fixed
    }

    /// Abort the save when `body` contains any invalid ```mermaid block, throwing
    /// a `.message` with a multi-line report the agent can act on. Pure over the
    /// injected validator (testable): pass `nil` to skip (the unbundled path).
    static func abortOnInvalidMermaid(_ body: String, validator: MermaidValidator?) throws {
        guard let validator else { return }
        let bad = validator.invalidBlocks(markdown: body)
        if !bad.isEmpty {
            throw Failure.message(MermaidValidator.describe(bad))
        }
    }

    // MARK: - delete

    private static func delete(id: PageID, in store: WikiStore) throws -> Result {
        try store.deletePage(id: id)
        return Result(output: id.rawValue, didCommit: true)
    }

    // MARK: - search

    private static func search(
        query: String, limit: Int, in store: WikiStore
    ) throws -> Result {
        let results = try store.searchSimilar(query: query, limit: limit)
        let output = results.map { summary in
            let title = summary.title.replacingOccurrences(of: "\t", with: " ")
            return "\(summary.id.rawValue)\t\(title)"
        }.joined(separator: "\n")
        return Result(output: output, didCommit: false)
    }

    // MARK: - history (W0, PR #312)

    private static func history(_ selector: Selector, in store: WikiStore) throws -> Result {
        let id = try resolve(selector, in: store)
        let versions = try store.pageVersionHistory(pageID: id)
        if versions.isEmpty {
            return Result(output: "(no version history)", didCommit: false)
        }
        let lines = versions.enumerated().map { (i, v) in
            let parent = v.parentID ?? "—"
            let date = ISO8601DateFormatter().string(from: v.savedAt)
            return "\(i)\t\(v.id)\t\(date)\t\(v.title)\t\(v.blobHash.prefix(12))\t\(parent.prefix(12))"
        }
        return Result(output: lines.joined(separator: "\n"), didCommit: false)
    }

    // MARK: - revert (W0, PR #312)

    private static func revert(
        _ selector: Selector, versionID: String, in store: WikiStore
    ) throws -> Result {
        let id = try resolve(selector, in: store)
        try store.revertPage(pageID: id, to: versionID)
        return Result(output: "reverted \(id.rawValue) to \(versionID)", didCommit: true)
    }

    // MARK: - Selector resolution

    private static func resolve(_ selector: Selector, in store: WikiStore) throws -> PageID {
        switch selector {
        case .id(let id):
            return id
        case .title(let title):
            guard let id = try store.resolveTitleToID(title) else {
                throw Failure.message("no page titled \(title.debugDescription)")
            }
            return id
        }
    }
}
