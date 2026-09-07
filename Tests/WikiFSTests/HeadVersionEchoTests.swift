import Foundation
import Testing
@testable import WikiCtlCore
@testable import WikiFSCore

/// #1228: committing writes echo the new version head on stderr —
/// `head_version_id: <id>`, the same convention as `page get` — so an agent's
/// CAS loop can chain the next `--expect-head` write without a separate read.
/// stdout stays byte-identical in every case.
struct HeadVersionEchoTests {

    private func tempStore() throws -> GRDBWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikictl-head-echo-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }

    private func headLine(_ id: String?) -> String {
        "head_version_id: \(id ?? "")\n"
    }

    // MARK: - page add

    @Test func pageAddCreateEchoesHeadOnStderrAndKeepsStdout() throws {
        let store = try tempStore()
        let result = try PageCommand.run(.add(id: nil, title: "CAS Doc", body: .inline("v1")), in: store)
        let head = try store.pageHeadVersionID(pageID: PageID(rawValue: result.output))
        #expect(result.didCommit)
        #expect(result.stderrOutput == headLine(head?.rawValue))
        // stdout is still just the page id (compatibility contract).
        let resolvedID = try store.resolveTitleToID("CAS Doc")?.rawValue
        #expect(result.output == resolvedID)
        #expect(!result.output.contains("head_version_id"))
    }

    @Test func pageAddUpdateEchoesTheNewHead() throws {
        let store = try tempStore()
        let create = try PageCommand.run(.add(id: nil, title: "CAS Doc", body: .inline("v1")), in: store)
        let pageID = PageID(rawValue: create.output)
        let update = try PageCommand.run(
            .add(id: pageID, title: "CAS Doc", body: .inline("v2")), in: store)
        let head = try store.pageHeadVersionID(pageID: pageID)
        #expect(update.stderrOutput == headLine(head?.rawValue))
        #expect(update.stderrOutput != create.stderrOutput, "the update reports the NEW head")
    }

    @Test func workspacePageAddEchoesTheStagedHead() throws {
        let store = try tempStore()
        // The page must exist on main for a version to stage against.
        let create = try PageCommand.run(.add(id: nil, title: "WS Doc", body: .inline("main v1")), in: store)
        let pageID = PageID(rawValue: create.output)
        let wsID = try store.createWorkspace(name: nil, activityID: nil)
        let result = try PageCommand.run(
            .add(id: pageID, title: "WS Doc", body: .inline("staged v2"), workspace: wsID.rawValue), in: store)
        let staged = try store.workspacePageVersion(workspaceID: wsID, pageID: pageID)
        #expect(staged != nil, "a staged update records a workspace version")
        #expect(result.stderrOutput == headLine(staged?.rawValue))
        // stdout still prints the staged version id (existing contract).
        #expect(result.output == staged?.rawValue)
    }

    @Test func workspaceCreatedPageEchoesNoHead() throws {
        let store = try tempStore()
        let wsID = try store.createWorkspace(name: nil, activityID: nil)
        // A workspace-CREATED page has no version row until merge, so there
        // is no head to echo — stderr stays empty rather than lying.
        let result = try PageCommand.run(
            .add(id: PageID(rawValue: ULID.generate()), title: "Fresh WS", body: .inline("v1"),
                 workspace: wsID.rawValue), in: store)
        #expect(result.didCommit)
        #expect(result.stderrOutput == nil)
    }

    @Test func casConflictProducesNoHeadLine() throws {
        let store = try tempStore()
        _ = try PageCommand.run(.add(id: nil, title: "C", body: .inline("v1")), in: store)
        // A stale --expect-head throws before any Result exists, so no stderr
        // head line can leak from a failed write.
        #expect(throws: PageConflictError.self) {
            try PageCommand.run(
                .add(id: nil, title: "C", body: .inline("v2"),
                     expectHead: PageVersionID(rawValue: "01STALEVERSIONID")), in: store)
        }
    }

    // MARK: - page revert

    @Test func pageRevertEchoesTheRepointedHead() throws {
        let store = try tempStore()
        let create = try PageCommand.run(.add(id: nil, title: "R", body: .inline("v1")), in: store)
        let pageID = PageID(rawValue: create.output)
        let v1 = try #require(try store.pageVersionHistory(pageID: pageID).first)
        _ = try PageCommand.run(.add(id: pageID, title: "R", body: .inline("v2")), in: store)

        let revert = try PageCommand.run(
            .revert(.id(pageID), versionID: PageVersionID(rawValue: v1.id.rawValue)), in: store)
        #expect(revert.stderrOutput == headLine(v1.id.rawValue))
        #expect(revert.output == "reverted \(pageID.rawValue) to \(v1.id.rawValue)")
        let head = try store.pageHeadVersionID(pageID: pageID)
        #expect(head?.rawValue == v1.id.rawValue, "the echo matches the store's actual head")
    }

    // MARK: - source edit-markdown / set-active

    @Test func sourceEditMarkdownEchoesHeadOnStderr() throws {
        let store = try tempStore()
        let src = try store.addSource(filename: "doc.md", data: Data("bytes".utf8))
        _ = try store.appendProcessedMarkdown(sourceID: src.id, content: "# v1", origin: .extraction, note: nil)

        let result = try SourceCommand.run(
            .editMarkdown(.id(src.id), content: .inline("# v2")), in: store, cwd: "/tmp")
        let head = try store.processedMarkdownHead(sourceID: src.id)
        #expect(result.didCommit)
        #expect(result.stderrOutput == headLine(head?.id.rawValue))
    }

    @Test func sourceSetActiveEchoesTheNominatedHead() throws {
        let store = try tempStore()
        let src = try store.addSource(filename: "doc2.md", data: Data("bytes".utf8))
        let v1 = try store.appendProcessedMarkdown(sourceID: src.id, content: "# v1", origin: .extraction, note: nil)
        _ = try store.appendProcessedMarkdown(sourceID: src.id, content: "# v2", origin: .user, note: nil)

        // Nominate the OLDER version; the echo must report it, not the latest.
        let result = try SourceCommand.run(
            .setActive(.id(src.id), versionID: v1.id), in: store, cwd: "/tmp")
        let head = try store.processedMarkdownHead(sourceID: src.id)
        #expect(head?.id == v1.id)
        #expect(result.stderrOutput == headLine(v1.id.rawValue))
    }
}
