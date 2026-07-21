import Foundation
import WikiFSCore

/// The `wikictl page …` subcommands, executed against an already-opened
/// `WikiStore`. Deliberately split from process concerns (arg parsing, stdin,
/// the Darwin post, opening the DB) so the whole command surface is unit-testable
/// against a temp DB: a test builds a `GRDBWikiStore`, runs a `PageCommand`,
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
        case get(Selector, json: Bool = false, workspace: String? = nil)
        /// `add` (formerly `upsert`) always carries the body source (read
        /// inline or from `--body-file`); the optional id forces updating a
        /// specific page, otherwise the title resolves create-or-update.
        /// `expectHead` carries the CAS expectation (the `head_version_id` the
        /// caller read before editing); when non-nil, the upsert routes through
        /// `appendPageVersion` and a mismatch throws `PageConflictError`
        /// (Phase 1: agent CAS writes).
        case add(id: PageID?, title: String, body: BodySource, expectHead: String? = nil, workspace: String? = nil, author: String? = nil)
        case delete(id: PageID)
        /// Semantic search: find pages by meaning (cosine similarity via
        /// Swift-side `VectorCosine`), falling back to LIKE title match.
        case search(query: String, limit: Int)
        /// Show the page's version history (W0, PR #312). One line per version:
        /// `seq  versionID  saved_at  title  blob_hash  parent_id`.
        case history(Selector)
        /// Revert a page to a specific version (W0, PR #312). Repoints the
        /// page-content ref to `versionID` and updates the body mirror.
        case revert(Selector, versionID: String)
        /// Print identity (id, title, slug, created/updated, version count) +
        /// origin provenance (HEAD's agent + activity, edit history) for a
        /// page. Mirrors `source info` (`SourceCommand.info`) — a read-side
        /// diagnostic for agents + debugging. Read-only.
        case info(Selector)
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
    /// `linter` injects the Markdown linter (defaults to the bundled one) so
    /// the auto-fix-before-write path is testable without a bundle.
    ///
    /// `bm25Leg` is the pre-resolved Tantivy BM25 leg for the `.search` action
    /// (#637). Post-#634 this is the SOLE BM25 leg (FTS5 was dropped); `nil`
    /// (the default) means no BM25 results — only the cosine semantic leg runs.
    /// Caller-resolved via `CLITantivyLegResolver.resolvePageLeg(...)` in
    /// `wikictl`'s `execute()`.
    public static func run(
        _ action: Action,
        in store: WikiStore,
        validator: MermaidValidator? = MermaidValidator.loadDefault(),
        linter: MarkdownLinter? = MarkdownLinter.loadDefault(),
        bm25Leg: [WikiPageSummary]? = nil
    ) throws -> Result {
        switch action {
        case .list(let json):
            return try list(in: store, json: json)
        case .get(let selector, let json, let workspace):
            return try get(selector, in: store, json: json, workspace: workspace)
        case .add(let id, let title, let bodySource, let expectHead, let workspace, let author):
            let body = try resolveBodySource(bodySource)
            return try upsert(id: id, title: title, body: body, expectHead: expectHead, workspace: workspace, author: author, in: store, validator: validator, linter: linter)
        case .delete(let id):
            return try delete(id: id, in: store)
        case .search(let query, let limit):
            return try search(query: query, limit: limit, bm25Leg: bm25Leg, in: store)
        case .history(let selector):
            return try history(selector, in: store)
        case .revert(let selector, let versionID):
            return try revert(selector, versionID: versionID, in: store)
        case .info(let selector):
            return try info(selector, in: store)
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

    /// The JSON object emitted by `page get --json`.
    private struct PageGetJSON: Encodable {
        let body_markdown: String
        let head_version_id: String?
    }

    private static func get(_ selector: Selector, in store: WikiStore, json: Bool = false, workspace: String? = nil) throws -> Result {
        // Phase 7: workspace overlay read. When --workspace is set, check
        // the workspace's staged version FIRST. A created page (staged as
        // blob_hash) has no `pages` row on main, so `getPage` would throw.
        // We resolve the selector to an ID — for a created page, the agent
        // must pass --id (there's no title row on main to resolve).
        if let workspace {
            // Try to resolve the ID without throwing (created pages may not
            // resolve via title on main).
            let id: PageID?
            switch selector {
            case .id(let pageID):
                id = pageID
            case .title:
                id = try? resolve(selector, in: store)
            }
            if let id, let stagedBody = try store.workspacePageBody(workspaceID: workspace, pageID: id) {
                var headVersionID = try? store.workspacePageVersion(workspaceID: workspace, pageID: id)
                if headVersionID == nil {
                    headVersionID = try? store.pageHeadVersionID(pageID: id)
                }
                if json {
                    let row = PageGetJSON(body_markdown: stagedBody, head_version_id: headVersionID)
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys]
                    let data = try encoder.encode(row)
                    return Result(output: String(decoding: data, as: UTF8.self), didCommit: false)
                }
                if let headVersionID {
                    FileHandle.standardError.write(Data("head_version_id: \(headVersionID)\n".utf8))
                }
                return Result(output: stagedBody, didCommit: false)
            }
            // Not staged in workspace, or no ID — fall through to main read.
        }

        let id = try resolve(selector, in: store)
        let page = try store.getPage(id: id)
        let headVersionID = try store.pageHeadVersionID(pageID: id)

        if json {
            // JSON mode: emit body_markdown + head_version_id as one JSON object.
            let row = PageGetJSON(body_markdown: page.bodyMarkdown, head_version_id: headVersionID)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(row)
            return Result(output: String(decoding: data, as: UTF8.self), didCommit: false)
        }

        // Text mode: print the body verbatim — this is the instant SoT read
        // that bypasses the ~5 s mount lag. The head_version_id goes to
        // stderr so stdout stays clean for body piping (agents read it from
        // stderr for CAS threading).
        if let headVersionID {
            FileHandle.standardError.write(Data("head_version_id: \(headVersionID)\n".utf8))
        }
        return Result(output: page.bodyMarkdown, didCommit: false)
    }

    // MARK: - upsert

    private static func upsert(
        id: PageID?,
        title: String,
        body: String,
        expectHead: String? = nil,
        workspace: String? = nil,
        author: String? = nil,
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

        // Phase 7: workspace routing. When --workspace is set, route to
        // workspaceWritePage (main is untouched until merge). The page ID is
        // resolved the same way — title resolves to an existing page or creates
        // a new one (staged as a created page if it doesn't exist on main).
        if let workspace {
            let pageID: PageID
            if let id {
                pageID = id
            } else {
                // Resolve by title: if the page exists on main, use its ID;
                // otherwise generate a new ULID (the workspace will stage it
                // as a created page).
                if let existingID = try store.resolveTitleToID(title) {
                    pageID = existingID
                } else {
                    pageID = PageID(rawValue: ULID.generate())
                }
            }
            let resultID = try store.workspaceWritePage(
                workspaceID: workspace, pageID: pageID, title: title, body: fixed,
                author: author)
            return Result(output: resultID, didCommit: true)
        }

        // 3. The SHARED seam: identical create-or-update + `[[link]]` reparse as
        //    the in-app editor, so the link graph stays consistent across both
        //    writers.
        let outcome = try PageUpsert.upsert(in: store, id: id, title: title, body: fixed,
                                             expectedHeadVersionID: expectHead, author: author)
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
        query: String, limit: Int, bm25Leg: [WikiPageSummary]?, in store: WikiStore
    ) throws -> Result {
        let results = try store.searchSimilar(query: query, limit: limit, bm25Leg: bm25Leg)
        let output: String = results.map { summary in
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

    // MARK: - info (page provenance, #page-provenance)

    /// Print identity (id, title, slug, head version id, version count,
    /// created/updated) + origin provenance for the page's HEAD + every prior
    /// version. Mirrors `SourceCommand.info`. Read-only. The HEAD's
    /// `agentName` reflects the writer — for a chat edit, `"chat:<id>"`;
    /// for an ingestion executor, `"agent:<kind>"`; for a manual app edit,
    /// `"user"`; for pre-v39 rows, `"legacy-import"`.
    private static func info(_ selector: Selector, in store: WikiStore) throws -> Result {
        let id = try resolve(selector, in: store)
        let page = try store.getPage(id: id)
        let headVersionID = try store.pageHeadVersionID(pageID: id)
        let history = try store.pageVersionHistory(pageID: id)

        var lines: [String] = []
        lines.append("id\t\(page.id.rawValue)")
        lines.append("title\t\(page.title)")
        lines.append("slug\t\(page.slug)")
        if let createdBy = page.createdBy { lines.append("created_by\t\(createdBy)") }
        if let lastEditedBy = page.lastEditedBy { lines.append("last_edited_by\t\(lastEditedBy)") }
        lines.append("version\t\(page.version)")
        let created = ISO8601DateFormatter().string(from: page.createdAt)
        let updated = ISO8601DateFormatter().string(from: page.updatedAt)
        lines.append("created_at\t\(created)")
        lines.append("updated_at\t\(updated)")
        lines.append("version_count\t\(history.count)")
        if let headVersionID {
            lines.append("head_version_id\t\(headVersionID)")
        }

        // HEAD origin (the active page-content ref → version → activity → agent).
        if let origin = try store.pageOrigin(pageID: id) {
            lines.append("")
            lines.append("# origin (HEAD)")
            lines.append("activity\t\(origin.activityKind)")
            lines.append("agent\t\(origin.agentName)")
            lines.append("agent_kind\t\(origin.agentKind)")
            if let plan = origin.plan { lines.append("plan\t\(plan)") }
            if let extRef = origin.externalRef { lines.append("external_ref\t\(extRef)") }
            let savedAt = ISO8601DateFormatter().string(from: origin.savedAt)
            lines.append("saved_at\t\(savedAt)")
            if let hash = origin.blobHash { lines.append("blob_hash\t\(hash)") }
        }

        // Full edit history (every page_versions row joined to activity + agent).
        let editHistory = try store.pageEditHistory(pageID: id)
        if !editHistory.isEmpty {
            lines.append("")
            lines.append("# edit history (oldest-first)")
            for (i, entry) in editHistory.enumerated() {
                let savedAt = ISO8601DateFormatter().string(from: entry.savedAt)
                // seq<TAB>activity<TAB>agent<TAB>agent_kind<TAB>date<TAB>title<TAB>version_id<TAB>blob_hash
                let hash = entry.blobHash?.prefix(12) ?? "—"
                let parent = history[i].parentID?.prefix(12) ?? "—"
                lines.append("\(i)\t\(entry.activityKind)\t\(entry.agentName)\t\(entry.agentKind)\t\(savedAt)\t\(entry.title)\t\(entry.versionID.prefix(12))\t\(hash)\t\(parent)")
            }
        }

        return Result(output: lines.joined(separator: "\n"), didCommit: false)
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
