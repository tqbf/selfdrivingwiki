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
            == .logAppend(kind: .ingest, title: "T", note: nil, source: SourceID(rawValue: "FILE123")))
    }

    /// `--source` is the completed-ingest switch; on any other kind it must
    /// fail loudly instead of silently taking no effect. The message is the
    /// agent-facing deliverable, so pin it too.
    @Test func logAppendRejectsSourceOnNonIngestKind() throws {
        for kind in ["query", "lint"] {
            do {
                _ = try ArgumentParser.parse(
                    ["--wiki", "W", "log", "append", "--kind", kind, "--title", "T", "--source", "FILE123"],
                    env: noEnv)
                Issue.record("expected usage failure for --kind \(kind)")
            } catch let failure as ArgumentParser.Failure {
                #expect(
                    String(describing: failure).contains("--source is only valid with --kind ingest"))
            }
        }
    }

    @Test func logAppendRejectsEmptySource() {
        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse(
                ["--wiki", "W", "log", "append", "--kind", "ingest", "--title", "T", "--source", ""],
                env: noEnv)
        }
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

    /// #1344: the first stamp wins — `markSourceIngested` only touches rows
    /// whose `ingested_at` is NULL, so a host re-drain or a late agent
    /// `--source` ritual stamp never rewrites the timestamp. `ingested_at`
    /// is not exposed on `SourceSummary`; `updatedAt` is the public-API
    /// observable for "no rewrite" (the old unconditional UPDATE always
    /// wrote a later `updated_at`).
    @Test func markSourceIngestedKeepsFirstTimestamp() async throws {
        let store = try tempStore()
        let file = try store.addSource(filename: "paper.pdf", data: Data("%PDF".utf8))
        try store.markSourceIngested(id: file.id)
        let firstStamp = try #require(try store.listSources().first { $0.id == file.id })

        // Guarantee the wall clock advances so a rewrite would be observable
        // (cooperative sleep — never Thread.sleep).
        try await Task.sleep(for: .milliseconds(20))
        try store.markSourceIngested(id: file.id)

        let secondStamp = try #require(try store.listSources().first { $0.id == file.id })
        #expect(try store.markedSourceIDs() == [file.id.rawValue])
        #expect(secondStamp.updatedAt.timeIntervalSince1970
            == firstStamp.updatedAt.timeIntervalSince1970)
    }

    @Test func logAppendWithoutSourceLeavesFileUnmarked() throws {
        let store = try tempStore()
        let file = try store.addSource(filename: "paper.pdf", data: Data("%PDF".utf8))

        _ = try LogIndexCommand.run(
            .logAppend(kind: .ingest, title: "Ingested paper.pdf", note: nil, source: nil), in: store)

        #expect(try store.markedSourceIDs().isEmpty)
        _ = file
    }

    /// Defense-in-depth for the command-level gate (the parser rejects this
    /// shape first): a non-ingest entry that names a source must never flip
    /// its ingest state — the Ingested badge is the completed-ingest switch.
    /// The gate suppresses the STAMP, not the entry: the log row still lands.
    @Test func logAppendWithSourceOnNonIngestKindDoesNotMark() throws {
        let store = try tempStore()
        let file = try store.addSource(filename: "paper.pdf", data: Data("%PDF".utf8))

        _ = try LogIndexCommand.run(
            .logAppend(kind: .query, title: "Cited paper.pdf", note: nil, source: file.id), in: store)

        #expect(try store.markedSourceIDs().isEmpty)
        #expect(try store.listAllLogEntriesOrderedByID().count == 1)
    }

    /// A typo'd or unknown --source must fail loudly BEFORE anything commits:
    /// markSourceIngested is a no-op UPDATE on a missing id, so accepting it
    /// would append the row, exit 0, and leave the file unmarked.
    @Test func logAppendWithUnknownSourceFailsLoudlyAndCommitsNothing() throws {
        let store = try tempStore()
        let ghost = SourceID(rawValue: "DOESNOTEXIST")

        #expect(throws: PageCommand.Failure.self) {
            _ = try LogIndexCommand.run(
                .logAppend(kind: .ingest, title: "Anything", note: nil, source: ghost), in: store)
        }
        #expect(try store.listAllLogEntriesOrderedByID().isEmpty)
        #expect(try store.markedSourceIDs().isEmpty)
    }

    // MARK: - Author-gated stamp refusal (#1367)

    /// A queued pipeline agent runs with `WIKI_AUTHOR=agent:<kind>`. Its
    /// mid-run `--source` stamps survived job failures (issue #1367: 62
    /// stamps seconds before a failed job), so the stamp is refused for
    /// agent-authored runs. Refusal does NOT fail the command: the log row
    /// still lands and one stdout notice names the rule.
    @Test func logAppendAgentAuthorRefusesStampButCommitsRow() throws {
        let store = try tempStore()
        let file = try store.addSource(filename: "paper.pdf", data: Data("%PDF".utf8))

        let result = try LogIndexCommand.run(
            .logAppend(kind: .ingest, title: "Ingested paper.pdf", note: nil,
                       source: file.id, author: .agent("ingest")),
            in: store)

        #expect(result.didCommit)
        #expect(try store.markedSourceIDs().isEmpty)
        let all = try store.listAllLogEntriesOrderedByID()
        #expect(all.count == 1)
        #expect(all[0].title == "Ingested paper.pdf")
        // Two output lines: the echoed entry id, then the refusal notice.
        #expect(result.output.hasPrefix(all[0].id.rawValue + "\n"))
        #expect(result.output.contains(LogIndexCommand.agentStampRefusalNotice(source: file.id)))
    }

    /// The refusal path also skips the unknown-`--source` existence check:
    /// that check protects the STAMP (a typo'd id must not look like it
    /// worked), and an agent-authored run never stamps — the notice already
    /// says so. The row must still land and the command must still succeed.
    @Test func logAppendAgentAuthorWithUnknownSourceStillCommitsRow() throws {
        let store = try tempStore()
        let ghost = SourceID(rawValue: "DOESNOTEXIST")

        let result = try LogIndexCommand.run(
            .logAppend(kind: .ingest, title: "Anything", note: nil,
                       source: ghost, author: .agent("ingest")),
            in: store)

        #expect(result.didCommit)
        #expect(try store.listAllLogEntriesOrderedByID().count == 1)
        #expect(result.output.contains(LogIndexCommand.agentStampRefusalNotice(source: ghost)))
    }

    /// An agent-authored run that passes NO `--source` is not attempting a
    /// stamp, so there is nothing to refuse and nothing to notice — the row
    /// lands exactly as before.
    @Test func logAppendAgentAuthorWithoutSourceIsQuiet() throws {
        let store = try tempStore()

        let result = try LogIndexCommand.run(
            .logAppend(kind: .ingest, title: "Ingested paper.pdf", note: nil,
                       source: nil, author: .agent("ingest")),
            in: store)

        #expect(result.didCommit)
        #expect(try store.listAllLogEntriesOrderedByID().count == 1)
        #expect(!result.output.contains("\n"), "no notice line when no stamp was attempted")
    }

    /// `chat:` authors keep the ad-hoc path exactly: the stamp applies.
    @Test func logAppendChatAuthorStillStamps() throws {
        let store = try tempStore()
        let file = try store.addSource(filename: "paper.pdf", data: Data("%PDF".utf8))

        let result = try LogIndexCommand.run(
            .logAppend(kind: .ingest, title: "Anything", note: nil,
                       source: file.id, author: .chat("01CHAT")),
            in: store)

        #expect(result.didCommit)
        #expect(try store.markedSourceIDs() == [file.id.rawValue])
        #expect(!result.output.contains("note:"), "no refusal notice on the ad-hoc path")
    }

    /// Unset author (shell use / programmatic default) keeps today's
    /// behavior: the stamp applies and no notice prints.
    @Test func logAppendUnsetAuthorStillStamps() throws {
        let store = try tempStore()
        let file = try store.addSource(filename: "paper.pdf", data: Data("%PDF".utf8))

        let result = try LogIndexCommand.run(
            .logAppend(kind: .ingest, title: "Anything", note: nil, source: file.id),
            in: store)

        #expect(result.didCommit)
        #expect(try store.markedSourceIDs() == [file.id.rawValue])
        #expect(!result.output.contains("note:"))
    }

    /// The typed parse drives the gate: an author value that merely STARTS
    /// with "agent" (`.other`, not `.agent`) must not trip the refusal —
    /// this pins the modeling rule that the gate never string-matches.
    @Test func logAppendAgentLookalikeAuthorStillStamps() throws {
        let store = try tempStore()
        let file = try store.addSource(filename: "paper.pdf", data: Data("%PDF".utf8))

        _ = try LogIndexCommand.run(
            .logAppend(kind: .ingest, title: "Anything", note: nil,
                       source: file.id, author: .other("agent-lookalike")),
            in: store)

        #expect(try store.markedSourceIDs() == [file.id.rawValue])
    }

#if os(macOS)
    /// End to end through the scripted production pipeline (parse → applyEnv
    /// → `LogIndexCommand`): an agent-authored `--source` stamp attempt exits
    /// 0, lands the log row, refuses the stamp, and prints the notice on
    /// stdout — the same resolved-author path the real CLI takes.
    @Test func scriptedAgentAuthoredStampAttemptSucceedsWithoutStamping() throws {
        let store = try tempStore()
        let file = try store.addSource(filename: "paper.pdf", data: Data("%PDF".utf8))

        let outcome = ScriptedWikiCtl.dispatch(
            ["--wiki", ScriptedWikiCtl.wikiSelector,
             "log", "append", "--kind", "ingest", "--title", "Ingested paper.pdf",
             "--source", file.id.rawValue],
            in: store,
            env: ["WIKI_AUTHOR": "agent:ingest"])

        #expect(outcome.exitCode == ScriptedCLIOutcome.Code.success)
        #expect(outcome.stdout.contains(LogIndexCommand.agentStampRefusalNotice(source: file.id)))
        #expect(try store.listAllLogEntriesOrderedByID().count == 1)
        #expect(try store.markedSourceIDs().isEmpty)
    }
#endif

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
