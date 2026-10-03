import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiCtlCore

/// Tests for Phase 1: Agent CAS writes (`#multi-writer-hardening`).
///
/// Covers:
/// - `page add --expect-head <current>` succeeds and appends a version.
/// - `page add --expect-head <stale>` exits with code 3, reports current head,
///   leaves page byte-identical.
/// - `page get` (text and `--json`) includes `head_version_id`.
/// - Blind `page add` (no flag) preserves today's behavior.
@MainActor
@Suite
struct AgentCASTests {

    private func tempStore() throws -> GRDBWikiStore {
        try TestStoreFactory.inMemory()
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
            .add(id: page.id, title: "CAS Page", body: .inline("v2 body"),
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
                .add(id: page.id, title: "Stale Page", body: .inline("v2 body (original)"),
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
            #expect(result.output.contains(head.rawValue))
        }
    }

    // MARK: - AC1.4: blind upsert preserves behavior

    @Test func blindUpsertPreservesBehavior() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Blind Page")

        // No --expect-head flag → blind write (no CAS check, succeeds unconditionally).
        let result = try PageCommand.run(
            .add(id: page.id, title: "Blind Page", body: .inline("blind body"),
                     expectHead: nil),
            in: store)
        #expect(result.didCommit == true)

        let readBack = try store.getPage(id: page.id)
        #expect(readBack.bodyMarkdown == "blind body")
    }

    // MARK: - ArgumentParser: --expect-head and --json parsing

    @Test func parserParsesExpectHead() throws {
        let invocation = try ArgumentParser.parse(
            ["--wiki", "test", "page", "add", "--title", "Test",
             "--body-file", "-", "--expect-head", "01ABC123"],
            env: { _ in nil })
        guard case .page(.add(_, let title, _, let expectHead, _, _, _, _)) = invocation.command else {
            Issue.record("expected .page(.add)")
            return
        }
        #expect(title == "Test")
        #expect(expectHead == PageVersionID(rawValue: "01ABC123"))
    }

    @Test func parserParsesGetJson() throws {
        let invocation = try ArgumentParser.parse(
            ["--wiki", "test", "page", "get", "--title", "Test", "--json"],
            env: { _ in nil })
        guard case .page(.get(_, let json, _)) = invocation.command else {
            Issue.record("expected .page(.get)")
            return
        }
        #expect(json == true)
    }

    @Test func parserGetWithoutJsonDefaultsToFalse() throws {
        let invocation = try ArgumentParser.parse(
            ["--wiki", "test", "page", "get", "--title", "Test"],
            env: { _ in nil })
        guard case .page(.get(_, let json, _)) = invocation.command else {
            Issue.record("expected .page(.get)")
            return
        }
        #expect(json == false)
    }

    @Test func parserUpsertWithoutExpectHeadDefaultsToNil() throws {
        let invocation = try ArgumentParser.parse(
            ["--wiki", "test", "page", "add", "--title", "Test",
             "--body-file", "-"],
            env: { _ in nil })
        guard case .page(.add(_, _, _, let expectHead, _, _, _, _)) = invocation.command else {
            Issue.record("expected .page(.add)")
            return
        }
        #expect(expectHead == nil)
    }

    @Test func wikictlAddDecodesSourceRoles() throws {
        let invocation = try ArgumentParser.parse(
            ["--wiki", "test", "page", "add", "--title", "Test", "--body-file", "-",
             "--source", "source-a", "--source", "source-b:quoted"],
            env: { _ in nil })

        guard case .page(.add(_, _, _, _, _, _, _, let provenance)) = invocation.command else {
            Issue.record("expected .page(.add)")
            return
        }
        #expect(provenance == [
            .init(sourceID: SourceID(rawValue: "source-a"), role: .primary),
            .init(sourceID: SourceID(rawValue: "source-b"), role: .quoted),
        ])
    }

    @Test func wikictlRejectsEmptySourceRole() {
        #expect(throws: PageVersionProvenanceWriteError.invalidRole(rawValue: "")) {
            _ = try ArgumentParser.parse(
                ["--wiki", "test", "page", "add", "--title", "Test", "--body-file", "-",
                 "--source", "source-a:"],
                env: { _ in nil })
        }
    }

    // MARK: - Create-only writes (cumulative ingestion, phase 4 §4)

    /// `page add --create-only` on an absent title creates the page (the
    /// create-versus-create race's happy path).
    @Test func createOnlyCreatesAbsentPage() throws {
        let store = try tempStore()
        #expect(try store.resolveTitleToID("Fresh Page") == nil)

        let result = try PageCommand.run(
            .add(id: nil, title: "Fresh Page", body: .inline("first body"),
                 createOnly: true),
            in: store)
        #expect(result.didCommit == true)

        let readBack = try store.getPage(id: PageID(rawValue: result.output))
        #expect(readBack.bodyMarkdown == "first body")
        #expect(try store.resolveTitleToID("Fresh Page") != nil)
    }

    /// `page add --create-only` on an EXISTING title conflicts (exit 3 at the
    /// process layer via `PageCreateConflictError`) and must not overwrite the
    /// existing page's body, links, or add a version.
    @Test func createOnlyConflictDoesNotOverwrite() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Existing Page", body: "original body")
        let headBefore = try store.pageHeadVersionID(pageID: page.id)

        do {
            _ = try PageCommand.run(
                .add(id: nil, title: "Existing Page", body: .inline("intruder body"),
                     createOnly: true),
                in: store)
            Issue.record("expected PageCreateConflictError")
        } catch let error as PageCreateConflictError {
            #expect(error.pageID == page.id)
            #expect(error.actualVersionID == headBefore)
        }

        // Byte-identical page, same head, no second version.
        let readBack = try store.getPage(id: page.id)
        #expect(readBack.bodyMarkdown == "original body")
        #expect(try store.pageHeadVersionID(pageID: page.id) == headBefore)
        #expect(try store.pageVersionHistory(pageID: page.id).count == 1)
    }

    /// `--create-only` and `--expect-head` state contradictory preconditions;
    /// the parser rejects them together as a usage error (and `--create-only`
    /// cannot combine with `--id` or `--workspace` either).
    @Test func mutuallyExclusiveExpectationsRejected() throws {
        func firstUsageMessage(_ arguments: [String]) throws -> String {
            do {
                _ = try ArgumentParser.parse(["--wiki", "test"] + arguments, env: { _ in nil })
                throw ArgumentParser.Failure.usage("expected a usage failure")
            } catch let failure as ArgumentParser.Failure {
                return failure.description
            }
        }
        #expect(try firstUsageMessage(
            ["page", "add", "--title", "Test", "--body-file", "-",
             "--create-only", "--expect-head", "01ABC123"]
        ).contains("mutually exclusive"))
        #expect(try firstUsageMessage(
            ["page", "add", "--title", "Test", "--body-file", "-",
             "--create-only", "--id", "01ABC"]
        ).contains("cannot be combined with --id"))
        #expect(try firstUsageMessage(
            ["page", "add", "--title", "Test", "--body-file", "-",
             "--create-only", "--workspace", "ws"]
        ).contains("cannot be combined with --workspace"))
    }

    /// The parser binds `--create-only` onto the action (the flag survives
    /// env application, not just the parse).
    @Test func parserParsesCreateOnly() throws {
        let invocation = try ArgumentParser.parse(
            ["--wiki", "test", "page", "add", "--title", "Test",
             "--body-file", "-", "--create-only"],
            env: { _ in nil })
        guard case .page(.add(_, _, _, let expectHead, let createOnly, _, _, _)) = invocation.command else {
            Issue.record("expected .page(.add)")
            return
        }
        #expect(createOnly == true)
        #expect(expectHead == nil)
    }
}
