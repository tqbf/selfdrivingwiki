import Foundation
import Testing
@testable import WikiCtlCore
@testable import WikiFSCore

/// Phase B `wikictl` seams: argument parsing / dispatch for `log append` and
/// `index set`, plus `LogIndexCommand` execution against a temp DB.
struct WikiCtlLogIndexTests {

    private func tempStore() throws -> GRDBWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-ctl-logindex-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }

    private let noEnv: (String) -> String? = { _ in nil }

    // MARK: - log append parsing

    @Test func parsesLogAppendWithNote() throws {
        let invocation = try ArgumentParser.parse(
            ["--wiki", "W", "log", "append", "--kind", "ingest", "--title", "T", "--note", "N"],
            env: noEnv)
        #expect(invocation.command == .logAppend(kind: .ingest, title: "T", note: "N", source: nil))
    }

    @Test func parsesLogAppendWithoutNote() throws {
        let invocation = try ArgumentParser.parse(
            ["--wiki", "W", "log", "append", "--kind", "query", "--title", "T"],
            env: noEnv)
        #expect(invocation.command == .logAppend(kind: .query, title: "T", note: nil, source: nil))
    }

    @Test func parsesLogAppendWithSource() throws {
        let invocation = try ArgumentParser.parse(
            ["--wiki", "W", "log", "append", "--kind", "ingest", "--title", "T", "--source", "FILE123"],
            env: noEnv)
        #expect(invocation.command
            == .logAppend(kind: .ingest, title: "T", note: nil, source: PageID(rawValue: "FILE123")))
    }

    @Test func logAppendRejectsBadKind() {
        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse(
                ["--wiki", "W", "log", "append", "--kind", "bogus", "--title", "T"], env: noEnv)
        }
    }

    @Test func logAppendRequiresKindAndTitle() {
        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse(
                ["--wiki", "W", "log", "append", "--title", "T"], env: noEnv)
        }
        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse(
                ["--wiki", "W", "log", "append", "--kind", "lint"], env: noEnv)
        }
    }

    @Test func rejectsUnknownLogSubcommand() {
        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse(["--wiki", "W", "log", "bogus"], env: noEnv)
        }
    }

    // MARK: - index set parsing

    @Test func parsesIndexSetBodyFile() throws {
        let stdin = try ArgumentParser.parse(
            ["--wiki", "W", "index", "set", "--body-file", "-"], env: noEnv)
        #expect(stdin.command == .indexSet(bodyFile: "-"))

        let path = try ArgumentParser.parse(
            ["--wiki", "W", "index", "set", "--body-file", "catalog.md"], env: noEnv)
        #expect(path.command == .indexSet(bodyFile: "catalog.md"))
    }

    @Test func indexSetRequiresBodyFile() {
        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse(["--wiki", "W", "index", "set"], env: noEnv)
        }
    }

    @Test func rejectsUnknownIndexSubcommand() {
        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse(["--wiki", "W", "index", "bogus"], env: noEnv)
        }
    }

    // MARK: - Command dispatch (against a temp DB)

    @Test func logAppendCommitsAndReturnsID() throws {
        let store = try tempStore()
        let result = try LogIndexCommand.run(
            .logAppend(kind: .ingest, title: "Ingested X", note: "note", source: nil), in: store)
        #expect(result.didCommit)
        let all = try store.listAllLogEntriesOrderedByID()
        #expect(all.count == 1)
        #expect(all[0].id.rawValue == result.output)  // echoed id matches the row
        #expect(all[0].title == "Ingested X")
        #expect(all[0].note == "note")
    }

    @Test func logAppendWithSourceMarksFileIngested() throws {
        let store = try tempStore()
        let file = try store.addSource(filename: "paper.pdf", data: Data("%PDF".utf8))
        #expect(try store.markedSourceIDs().isEmpty)

        _ = try LogIndexCommand.run(
            .logAppend(kind: .ingest, title: "Anything", note: nil, source: file.id), in: store)

        #expect(try store.markedSourceIDs() == [file.id.rawValue])
    }

    @Test func logAppendWithoutSourceLeavesFileUnmarked() throws {
        let store = try tempStore()
        let file = try store.addSource(filename: "paper.pdf", data: Data("%PDF".utf8))

        _ = try LogIndexCommand.run(
            .logAppend(kind: .ingest, title: "Ingested paper.pdf", note: nil, source: nil), in: store)

        #expect(try store.markedSourceIDs().isEmpty)
        _ = file
    }

    @Test func indexSetCommitsAndPersistsBody() throws {
        let store = try tempStore()
        let result = try LogIndexCommand.run(.indexSet(body: "# Catalog"), in: store)
        #expect(result.didCommit)
        #expect(result.output.isEmpty)
        let index = try store.getWikiIndex()
        #expect(index.body == "# Catalog")
        #expect(index.version == 2)  // seed 1, +1
    }

    // MARK: - Empty-body refusal at the CLI boundary

    @Test func testIndexSetRefusesEmptyBody() throws {
        let store = try tempStore()
        // Empty body is refused.
        do {
            _ = try LogIndexCommand.run(.indexSet(body: ""), in: store)
            Issue.record("expected empty-body indexSet to throw")
        } catch let PageCommand.Failure.message(text) {
            #expect(text.contains("empty index body"))
        }
        // Whitespace-only body is also refused.
        do {
            _ = try LogIndexCommand.run(.indexSet(body: "  \n\t "), in: store)
            Issue.record("expected whitespace-only indexSet to throw")
        } catch let PageCommand.Failure.message(text) {
            #expect(text.contains("empty index body"))
        }
    }
}
