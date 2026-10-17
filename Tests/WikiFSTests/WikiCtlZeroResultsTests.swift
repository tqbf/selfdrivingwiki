import Foundation
import Testing
@testable import WikiCtlCore
@testable import WikiFSCore

/// #1230: zero-result list/search runs print an explicit notice on stderr
/// (axi.md principle 5, definitive empty states) while stdout stays
/// byte-identical — empty TSV, an empty JSON-lines stream for `--json` — and
/// the exit contract stays success (empty is a success, not an error).
/// Non-empty runs print no notice.
///
/// `wiki list` and `job list` render in `wikictl`'s executable target
/// (`main.swift`), which is not importable from tests; their notice wiring is
/// covered by the end-to-end CLI run recorded in the PR.
@Suite("Wikictl zero-results stderr notices")
struct WikiCtlZeroResultsTests {

    private func tempStore() throws -> GRDBWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikictl-zero-results-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }

    /// `SourceCommand.Result` carries a `.text`/`.bytes` payload; the list and
    /// search paths under test here are all `.text`.
    private func payloadText(_ result: SourceCommand.Result) -> String {
        if case .text(let text) = result.payload { return text }
        return "<bytes>"
    }

    // MARK: - page list / page search

    @Test func pageListEmptySaysSoOnStderrWithByteIdenticalStdout() throws {
        let store = try tempStore()
        let tsv = try PageCommand.run(.list(json: false), in: store)
        #expect(tsv.output == "")
        #expect(tsv.stderrOutput == "wikictl: 0 results for page list\n")
        let json = try PageCommand.run(.list(json: true), in: store)
        #expect(json.output == "", "an empty --json run is still an empty JSON-lines stream")
        #expect(json.stderrOutput == "wikictl: 0 results for page list\n")
    }

    @Test func pageListNonEmptyPrintsNoNotice() throws {
        let store = try tempStore()
        _ = try PageCommand.run(.add(id: nil, title: "Solo", body: .inline("the only page")), in: store)
        let tsv = try PageCommand.run(.list(json: false), in: store)
        #expect(!tsv.output.isEmpty)
        #expect(tsv.stderrOutput == nil)
        let json = try PageCommand.run(.list(json: true), in: store)
        #expect(!json.output.isEmpty)
        #expect(json.stderrOutput == nil)
    }

    @Test func pageSearchEmptyNamesTheQueryOnStderr() throws {
        let store = try tempStore()
        let result = try PageCommand.run(.search(query: "electric cars", limit: 10), in: store)
        #expect(result.output == "")
        #expect(result.stderrOutput == "wikictl: 0 results for page search \"electric cars\"\n")
    }

    @Test func pageSearchNonEmptyPrintsNoNotice() throws {
        let store = try tempStore()
        let cars = try PageCommand.run(
            .add(id: nil, title: "Cars", body: .inline("electric vehicles")), in: store)
        // Post-#634 a fabricated BM25 leg is the documented way a test
        // produces non-empty search output (the store has no FTS5 fallback);
        // same pattern as WikiCtlCommandTests.searchReturnsTSVAndDoesNotCommit.
        let leg = WikiPageSummary(
            id: PageID(rawValue: cars.output), title: "Cars",
            updatedAt: Date(timeIntervalSince1970: 0),
            createdAt: Date(timeIntervalSince1970: 0))
        let result = try PageCommand.run(
            .search(query: "car", limit: 10), in: store, bm25Leg: [leg])
        #expect(!result.output.isEmpty)
        #expect(result.stderrOutput == nil)
    }

    // MARK: - source list / source search

    @Test func sourceListEmptySaysSoOnStderrWithByteIdenticalStdout() throws {
        let store = try tempStore()
        let tsv = try SourceCommand.run(.list(json: false), in: store, cwd: "/tmp")
        #expect(payloadText(tsv) == "")
        #expect(tsv.stderrOutput == "wikictl: 0 results for source list\n")
        let json = try SourceCommand.run(.list(json: true), in: store, cwd: "/tmp")
        #expect(payloadText(json) == "", "an empty --json run is still an empty JSON-lines stream")
        #expect(json.stderrOutput == "wikictl: 0 results for source list\n")
    }

    @Test func sourceListNonEmptyPrintsNoNotice() throws {
        let store = try tempStore()
        _ = try store.addSource(filename: "notes.md", data: Data("bytes".utf8))
        let tsv = try SourceCommand.run(.list(json: false), in: store, cwd: "/tmp")
        #expect(!payloadText(tsv).isEmpty)
        #expect(tsv.stderrOutput == nil)
        let json = try SourceCommand.run(.list(json: true), in: store, cwd: "/tmp")
        #expect(!payloadText(json).isEmpty)
        #expect(json.stderrOutput == nil)
    }

    @Test func sourceSearchEmptyNamesTheQueryOnStderr() throws {
        let store = try tempStore()
        let result = try SourceCommand.run(
            .search(query: "zotero attachments", limit: 10), in: store, cwd: "/tmp")
        #expect(payloadText(result) == "")
        #expect(result.stderrOutput == "wikictl: 0 results for source search \"zotero attachments\"\n")
    }

    @Test func sourceSearchNonEmptyPrintsNoNotice() throws {
        let store = try tempStore()
        let src = try store.addSource(filename: "notes.md", data: Data("bytes".utf8))
        // Fabricated BM25 leg targeting the seeded source — the same
        // pre-ranked-leg pattern the page-search control uses.
        let leg = SourceSummary(
            id: src.id, filename: src.filename, ext: "md", mimeType: "text/markdown",
            byteSize: 5, createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0), version: 1)
        let result = try SourceCommand.run(
            .search(query: "notes", limit: 10), in: store, cwd: "/tmp", bm25Leg: [leg])
        #expect(!payloadText(result).isEmpty)
        #expect(result.stderrOutput == nil)
    }

    // MARK: - chat list / chat search

    @Test func chatListEmptySaysSoOnStderrWithByteIdenticalStdout() throws {
        let store = try tempStore()
        let tsv = try ChatCommand.run(.list(json: false), in: store)
        #expect(tsv.output == "")
        #expect(tsv.stderrOutput == "wikictl: 0 results for chat list\n")
        let json = try ChatCommand.run(.list(json: true), in: store)
        #expect(json.output == "", "an empty --json run is still an empty JSON-lines stream")
        #expect(json.stderrOutput == "wikictl: 0 results for chat list\n")
    }

    @Test func chatListNonEmptyPrintsNoNotice() throws {
        let store = try tempStore()
        let chat = try store.createChat(kind: .edit, title: "Queue review")
        let tsv = try ChatCommand.run(.list(json: false), in: store)
        #expect(tsv.output.contains(chat.id.rawValue))
        #expect(tsv.stderrOutput == nil)
        let json = try ChatCommand.run(.list(json: true), in: store)
        #expect(!json.output.isEmpty)
        #expect(json.stderrOutput == nil)
    }

    @Test func chatSearchEmptyNamesTheQueryOnStderr() throws {
        let store = try tempStore()
        let result = try ChatCommand.run(.search(query: "queue review", limit: 10), in: store)
        #expect(result.output == "")
        #expect(result.stderrOutput == "wikictl: 0 results for chat search \"queue review\"\n")
    }

    @Test func chatSearchNonEmptyPrintsNoNotice() throws {
        let store = try tempStore()
        let chat = try store.createChat(kind: .edit, title: "Queue review")
        let leg = ChatSummary(
            id: chat.id, kind: .edit, title: "Queue review",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0), messageCount: 0)
        let result = try ChatCommand.run(
            .search(query: "queue", limit: 10), in: store, bm25Leg: [leg])
        #expect(!result.output.isEmpty)
        #expect(result.stderrOutput == nil)
    }

    // MARK: - bookmark list

    @Test func bookmarkListEmptySaysSoOnStderrWithByteIdenticalStdout() throws {
        let store = try tempStore()
        let tsv = try BookmarkCommand.run(.list(json: false), in: store)
        #expect(tsv.output == "")
        #expect(tsv.stderrOutput == "wikictl: 0 results for bookmark list\n")
        let json = try BookmarkCommand.run(.list(json: true), in: store)
        #expect(json.output == "", "an empty --json run is still an empty JSON-lines stream")
        #expect(json.stderrOutput == "wikictl: 0 results for bookmark list\n")
    }

    @Test func bookmarkListNonEmptyPrintsNoNotice() throws {
        let store = try tempStore()
        _ = try BookmarkCommand.run(.createFolder(parentID: nil, name: "Research"), in: store)
        let tsv = try BookmarkCommand.run(.list(json: false), in: store)
        #expect(!tsv.output.isEmpty)
        #expect(tsv.stderrOutput == nil)
        let json = try BookmarkCommand.run(.list(json: true), in: store)
        #expect(!json.output.isEmpty)
        #expect(json.stderrOutput == nil)
    }

    // MARK: - workspace conflicts

    @Test func workspaceConflictsEmptyKeepsTheStdoutMarkerAndAddsTheNotice() throws {
        let store = try tempStore()
        let wsID = try store.createWorkspace(name: nil, activityID: nil)
        let result = try WorkspaceCommand.run(.conflicts(id: wsID), in: store)
        // stdout byte-identical: the "(no conflicts)" marker predates #1230.
        #expect(result.output == "(no conflicts)")
        #expect(
            result.stderrOutput == "wikictl: 0 results for workspace conflicts \(wsID.rawValue)\n")
    }

    @Test func workspaceConflictsNonEmptyPrintsNoNotice() throws {
        let store = try tempStore()
        // A real conflict: the workspace stages an edit against the page's
        // base version, then main moves on — the merge parks a conflict row
        // in `workspace_conflicts`, which `workspace conflicts` renders.
        let create = try PageCommand.run(.add(id: nil, title: "Shared", body: .inline("main v1")), in: store)
        let pageID = PageID(rawValue: create.output)
        let wsID = try store.createWorkspace(name: nil, activityID: nil)
        _ = try PageCommand.run(
            .add(id: pageID, title: "Shared", body: .inline("ws edit"), workspace: wsID.rawValue),
            in: store)
        _ = try PageCommand.run(
            .add(id: pageID, title: "Shared", body: .inline("main v2")), in: store)
        _ = try store.workspaceMerge(workspaceID: wsID)

        let result = try WorkspaceCommand.run(.conflicts(id: wsID), in: store)
        #expect(!result.output.isEmpty)
        #expect(!result.output.contains("(no conflicts)"))
        #expect(result.stderrOutput == nil)
    }

    // MARK: - the process-layer seam

    @Test func runnerSeamKeepsEmptyStdoutAndWritesTheNoticeToStderr() {
        // `WikiCtlRunner.output` is where `SourceCommand.Result` becomes the
        // process's stdout/stderr bytes: the notice must ride stderr while
        // stdout is ZERO bytes — the piping contract.
        let output = WikiCtlRunner.output(
            for: SourceCommand.Result(
                payload: .text(""), didCommit: false,
                stderrOutput: ZeroResults.note("page list")),
            command: .page(.list(json: true)))
        #expect(output.stdout.isEmpty)
        #expect(String(decoding: output.stderr, as: UTF8.self) == "wikictl: 0 results for page list\n")
    }
}
