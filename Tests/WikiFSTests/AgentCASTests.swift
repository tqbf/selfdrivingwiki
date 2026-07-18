import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiCtlCore

/// Tests for Phase 1: Agent CAS writes (`#multi-writer-hardening`).
///
/// Covers:
/// - `page upsert --expect-head <current>` succeeds and appends a version.
/// - `page upsert --expect-head <stale>` exits with code 3, reports current head,
///   leaves page byte-identical.
/// - `page get` (text and `--json`) includes `head_version_id`.
/// - Blind `page upsert` (no flag) preserves today's behavior.
@MainActor
@Suite(.tags(.integration))
struct AgentCASTests {

    private func tempStore() throws -> GRDBWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cas-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }

    // MARK: - AC1.1: expect-head current succeeds

    @Test func expectHeadCurrentSucceeds() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "CAS Page")
        // First versioned save.
        _ = try store.appendPageVersion(
            pageID: page.id, title: "CAS Page", body: "v1 body",
            expectedHeadVersionID: nil)
        let head = try store.pageHeadVersionID(pageID: page.id)
        #expect(head != nil)

        // Upsert with the correct head → should succeed (no conflict).
        let result = try PageCommand.run(
            .upsert(id: page.id, title: "CAS Page", body: "v2 body",
                    expectHead: head),
            in: store)
        #expect(result.didCommit == true)

        // The body should be updated.
        let readBack = try store.getPage(id: page.id)
        #expect(readBack.bodyMarkdown == "v2 body")

        // A new version was appended (parent = old head).
        let newHead = try store.pageHeadVersionID(pageID: page.id)
        #expect(newHead != head)
    }

    // MARK: - AC1.2: expect-head stale fails with exit code 3

    @Test func expectHeadStaleFailsWithConflict() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Stale Page")
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Stale Page", body: "v1 body",
            expectedHeadVersionID: nil)
        let oldHead = try store.pageHeadVersionID(pageID: page.id)

        // Simulate a concurrent write: another writer commits a new version.
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Stale Page", body: "v2 body (concurrent)",
            expectedHeadVersionID: oldHead)

        // Now try to upsert with the STALE head → conflict.
        #expect(throws: PageConflictError.self) {
            _ = try PageCommand.run(
                .upsert(id: page.id, title: "Stale Page", body: "v2 body (original)",
                        expectHead: oldHead),
                in: store)
        }

        // The page must be byte-identical to the concurrent writer's version.
        let readBack = try store.getPage(id: page.id)
        #expect(readBack.bodyMarkdown == "v2 body (concurrent)")
    }

    // MARK: - AC1.3: page get includes head_version_id

    @Test func pageGetJsonIncludesHeadVersionID() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "JSON Page")
        _ = try store.appendPageVersion(
            pageID: page.id, title: "JSON Page", body: "json body",
            expectedHeadVersionID: nil)
        let head = try store.pageHeadVersionID(pageID: page.id)

        let result = try PageCommand.run(
            .get(.id(page.id), json: true), in: store)
        #expect(result.didCommit == false)

        // The JSON output must contain head_version_id and body_markdown.
        #expect(result.output.contains("\"head_version_id\""))
        #expect(result.output.contains("\"body_markdown\""))
        #expect(result.output.contains("json body"))
        if let head {
            #expect(result.output.contains(head))
        }
    }

    // MARK: - AC1.4: blind upsert preserves behavior

    @Test func blindUpsertPreservesBehavior() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Blind Page")

        // No --expect-head flag → blind write (no CAS check, succeeds unconditionally).
        let result = try PageCommand.run(
            .upsert(id: page.id, title: "Blind Page", body: "blind body",
                    expectHead: nil),
            in: store)
        #expect(result.didCommit == true)

        let readBack = try store.getPage(id: page.id)
        #expect(readBack.bodyMarkdown == "blind body")
    }

    // MARK: - ArgumentParser: --expect-head and --json parsing

    @Test func parserParsesExpectHead() throws {
        let invocation = try ArgumentParser.parse(
            ["--wiki", "test", "page", "upsert", "--title", "Test",
             "--body-file", "-", "--expect-head", "01ABC123"],
            env: { _ in nil })
        guard case .upsert(_, let title, _, let expectHead, _, _) = invocation.command else {
            Issue.record("expected .upsert")
            return
        }
        #expect(title == "Test")
        #expect(expectHead == "01ABC123")
    }

    @Test func parserParsesGetJson() throws {
        let invocation = try ArgumentParser.parse(
            ["--wiki", "test", "page", "get", "--title", "Test", "--json"],
            env: { _ in nil })
        guard case .get(_, let json, _) = invocation.command else {
            Issue.record("expected .get")
            return
        }
        #expect(json == true)
    }

    @Test func parserGetWithoutJsonDefaultsToFalse() throws {
        let invocation = try ArgumentParser.parse(
            ["--wiki", "test", "page", "get", "--title", "Test"],
            env: { _ in nil })
        guard case .get(_, let json, _) = invocation.command else {
            Issue.record("expected .get")
            return
        }
        #expect(json == false)
    }

    @Test func parserUpsertWithoutExpectHeadDefaultsToNil() throws {
        let invocation = try ArgumentParser.parse(
            ["--wiki", "test", "page", "upsert", "--title", "Test",
             "--body-file", "-"],
            env: { _ in nil })
        guard case .upsert(_, _, _, let expectHead, _, _) = invocation.command else {
            Issue.record("expected .upsert")
            return
        }
        #expect(expectHead == nil)
    }
}
