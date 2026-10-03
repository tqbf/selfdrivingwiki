import Foundation
import Testing
@testable import WikiCtlCore
@testable import WikiFSCore

/// `wikictl strategy read|save|reset` — the CLI face of the per-wiki
/// editorial strategy singleton. Covers argument parsing (the REQUIRED CAS
/// expectation, `absent` vs a committed revision, the content/file body
/// rules), the read→save→read roundtrip, the Default/reset/tombstone paths,
/// the store's write-boundary limits (asserted by their named constants, not
/// magic numbers), and the conflict contract (nothing written on mismatch).
struct WikiCtlStrategyCommandTests {

    private func tempStore() throws -> GRDBWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-strategy-ctl-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }

    private let noEnv: (String) -> String? = { _ in nil }

    // MARK: - Argument parsing

    @Test func parsesReadTextAndJSON() throws {
        let text = try ArgumentParser.parse(
            ["--wiki", "W", "strategy", "read"], env: noEnv)
        #expect(text.command == .strategy(.read(json: false)))

        let json = try ArgumentParser.parse(
            ["--wiki", "W", "strategy", "read", "--json"], env: noEnv)
        #expect(json.command == .strategy(.read(json: true)))
    }

    @Test func parsesSaveWithInlineContentAndExpectation() throws {
        let absent = try ArgumentParser.parse(
            ["--wiki", "W", "strategy", "save",
             "--name", "Research", "--content", "# Plan",
             "--expect-revision", "absent"],
            env: noEnv)
        #expect(absent.command == .strategy(.save(
            name: "Research", content: .inline("# Plan"),
            expect: .absent, json: false)))

        let pinned = try ArgumentParser.parse(
            ["--wiki", "W", "strategy", "save",
             "--content", "# Plan", "--expect-revision", "3", "--json"],
            env: noEnv)
        #expect(pinned.command == .strategy(.save(
            name: nil, content: .inline("# Plan"),
            expect: .revision(WikiStrategyRevision(rawValue: 3)), json: true)))
    }

    @Test func parsesSaveWithFileBody() throws {
        let file = try ArgumentParser.parse(
            ["--wiki", "W", "strategy", "save",
             "--file", "-", "--expect-revision", "1"],
            env: noEnv)
        #expect(file.command == .strategy(.save(
            name: nil, content: .file("-"),
            expect: .revision(WikiStrategyRevision(rawValue: 1)), json: false)))
    }

    @Test func parsesReset() throws {
        let reset = try ArgumentParser.parse(
            ["--wiki", "W", "strategy", "reset", "--expect-revision", "2"],
            env: noEnv)
        #expect(reset.command == .strategy(.reset(
            expect: .revision(WikiStrategyRevision(rawValue: 2)), json: false)))
    }

    @Test func saveAndResetRequireExpectRevision() {
        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse(
                ["--wiki", "W", "strategy", "save", "--content", "x"], env: noEnv)
        }
        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse(
                ["--wiki", "W", "strategy", "reset"], env: noEnv)
        }
        // An empty value is as absent as a missing flag.
        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse(
                ["--wiki", "W", "strategy", "reset", "--expect-revision", " "], env: noEnv)
        }
    }

    @Test func saveRequiresExactlyOneBodySource() {
        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse(
                ["--wiki", "W", "strategy", "save",
                 "--content", "a", "--file", "b", "--expect-revision", "1"],
                env: noEnv)
        }
        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse(
                ["--wiki", "W", "strategy", "save", "--expect-revision", "1"],
                env: noEnv)
        }
    }

    @Test func rejectsInvalidExpectRevisionSpellings() {
        for bad in ["0", "-2", "abc", "1.5"] {
            #expect(throws: ArgumentParser.Failure.self) {
                try ArgumentParser.parse(
                    ["--wiki", "W", "strategy", "save",
                     "--content", "x", "--expect-revision", bad],
                    env: noEnv)
            }
        }
    }

    @Test func rejectsUnknownSubcommandAndUnlistedOption() {
        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse(
                ["--wiki", "W", "strategy", "bogus"], env: noEnv)
        }
        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse(
                ["--wiki", "W", "strategy", "read", "--create-only"], env: noEnv)
        }
    }

    // MARK: - read

    @Test func readOnNeverWrittenWikiReportsAbsentAndDefault() throws {
        let store = try tempStore()
        let text = try StrategyCommand.run(.read(json: false), in: store)
        #expect(text.output.contains("revision: absent"))
        #expect(text.output.contains("Default"))
        #expect(text.didCommit == false)

        let json = try StrategyCommand.run(.read(json: true), in: store)
        let object = try jsonObject(json.output)
        #expect(object["revision"] is NSNull)
        #expect(object["default"] as? Bool == true)
        #expect(object["instructions"] is NSNull)
    }

    // MARK: - save roundtrip

    @Test func saveFromAbsentRoundtrips() throws {
        let store = try tempStore()
        let saved = try StrategyCommand.run(
            .save(name: "Research", content: .inline("# Plan\n- rule one"),
                  expect: .absent, json: false),
            in: store)
        #expect(saved.didCommit)
        #expect(saved.output.contains("revision 1"))
        // The next CAS token echoes on stderr (text mode), like page add's
        // head_version_id echo — the next save needs no extra read.
        #expect(saved.stderrOutput == "next --expect-revision: 1")

        let read = try StrategyCommand.run(.read(json: false), in: store)
        #expect(read.output.contains("revision: 1"))
        #expect(read.output.contains("name: Research"))
        #expect(read.output.contains("# Plan"))
        #expect(read.output.contains("- rule one"))

        let committed = try store.getWikiStrategy()
        #expect(committed?.revision == WikiStrategyRevision(rawValue: 1))
        // Instructions are stored verbatim, surrounding whitespace preserved.
        #expect(committed?.instructions == "# Plan\n- rule one")
    }

    @Test func changedSaveAdvancesRevisionAndUnchangedSaveDoesNot() throws {
        let store = try tempStore()
        _ = try StrategyCommand.run(
            .save(name: "S", content: .inline("one"), expect: .absent, json: false),
            in: store)

        // Identical save: no write, no revision advance, no commit signal.
        let unchanged = try StrategyCommand.run(
            .save(name: "S", content: .inline("one"), expect: .revision(.init(rawValue: 1)), json: false),
            in: store)
        #expect(unchanged.didCommit == false)
        #expect(unchanged.output.contains("unchanged"))
        #expect(try store.wikiStrategyRevision() == WikiStrategyRevision(rawValue: 1))

        // Changed save: exactly one advance.
        let changed = try StrategyCommand.run(
            .save(name: "S", content: .inline("two"), expect: .revision(.init(rawValue: 1)), json: false),
            in: store)
        #expect(changed.didCommit)
        #expect(changed.stderrOutput == "next --expect-revision: 2")
        #expect(try store.wikiStrategyRevision() == WikiStrategyRevision(rawValue: 2))
    }

    @Test func saveWithStaleExpectationThrowsConflictAndWritesNothing() throws {
        let store = try tempStore()
        _ = try StrategyCommand.run(
            .save(name: "S", content: .inline("one"), expect: .absent, json: false),
            in: store)

        // `absent` no longer matches: a row exists at revision 1.
        do {
            _ = try StrategyCommand.run(
                .save(name: "T", content: .inline("clobber"), expect: .absent, json: false),
                in: store)
            Issue.record("expected WikiStrategyConflictError")
        } catch let conflict as WikiStrategyConflictError {
            #expect(conflict.expectedRevision == nil)
            #expect(conflict.currentRevision == WikiStrategyRevision(rawValue: 1))
        }
        // Nothing was written: the committed strategy is the winner's.
        let winner = try store.getWikiStrategy()
        #expect(winner?.name == "S")
        #expect(winner?.instructions == "one")
        #expect(try store.wikiStrategyRevision() == WikiStrategyRevision(rawValue: 1))
    }

    // MARK: - reset / Default / tombstone

    @Test func resetAdvancesRevisionAndKeepsTombstone() throws {
        let store = try tempStore()
        _ = try StrategyCommand.run(
            .save(name: "S", content: .inline("one"), expect: .absent, json: false),
            in: store)

        let reset = try StrategyCommand.run(
            .reset(expect: .revision(.init(rawValue: 1)), json: false),
            in: store)
        #expect(reset.didCommit)
        #expect(reset.output.contains("Default"))
        #expect(reset.output.contains("revision 2"))

        // Default reads back as nil, but the revision survives (tombstone) —
        // the next save must expect 2, not `absent`.
        #expect(try store.getWikiStrategy() == nil)
        #expect(try store.wikiStrategyRevision() == WikiStrategyRevision(rawValue: 2))

        let read = try StrategyCommand.run(.read(json: true), in: store)
        let object = try jsonObject(read.output)
        #expect(object["revision"] as? Int64 == 2)
        #expect(object["default"] as? Bool == true)

        // And that expectation is exactly what a post-reset save needs.
        let resaved = try StrategyCommand.run(
            .save(name: "Back", content: .inline("two"), expect: .revision(.init(rawValue: 2)), json: false),
            in: store)
        #expect(resaved.didCommit)
        #expect(try store.wikiStrategyRevision() == WikiStrategyRevision(rawValue: 3))
    }

    @Test func resetOnNeverWrittenWikiIsUnchanged() throws {
        let store = try tempStore()
        let reset = try StrategyCommand.run(.reset(expect: .absent, json: false), in: store)
        #expect(reset.didCommit == false)
        #expect(reset.output.contains("unchanged"))
        #expect(try store.wikiStrategyRevision() == nil)
    }

    @Test func whitespaceOnlySaveResetsToDefault() throws {
        let store = try tempStore()
        _ = try StrategyCommand.run(
            .save(name: "S", content: .inline("one"), expect: .absent, json: false),
            in: store)
        // Whitespace-only instructions are the store's documented reset path.
        let reset = try StrategyCommand.run(
            .save(name: "S", content: .inline(" \n\t "), expect: .revision(.init(rawValue: 1)), json: false),
            in: store)
        #expect(reset.didCommit)
        #expect(try store.getWikiStrategy() == nil)
        #expect(try store.wikiStrategyRevision() == WikiStrategyRevision(rawValue: 2))
    }

    // MARK: - write-boundary limits (named constants, never magic numbers)

    @Test func nameOverTheNamedLimitIsRejectedNotTruncated() throws {
        let store = try tempStore()
        let longName = String(repeating: "n", count: WikiStrategy.nameCharacterLimit + 1)
        do {
            _ = try StrategyCommand.run(
                .save(name: longName, content: .inline("x"), expect: .absent, json: false),
                in: store)
            Issue.record("expected WikiStrategyTextError.nameTooLong")
        } catch let error as WikiStrategyTextError {
            guard case let .nameTooLong(characterCount, limit) = error else {
                Issue.record("expected nameTooLong, got \(error)")
                return
            }
            #expect(limit == WikiStrategy.nameCharacterLimit)
            #expect(characterCount == WikiStrategy.nameCharacterLimit + 1)
        }
        #expect(try store.wikiStrategyRevision() == nil)
    }

    @Test func instructionsOverTheNamedByteLimitAreRejected() throws {
        let store = try tempStore()
        let oversized = String(
            repeating: "a", count: WikiStrategy.instructionsUTF8ByteLimit + 1)
        do {
            _ = try StrategyCommand.run(
                .save(name: "S", content: .inline(oversized), expect: .absent, json: false),
                in: store)
            Issue.record("expected WikiStrategyTextError.instructionsTooLarge")
        } catch let error as WikiStrategyTextError {
            guard case let .instructionsTooLarge(byteCount, limit) = error else {
                Issue.record("expected instructionsTooLarge, got \(error)")
                return
            }
            #expect(limit == WikiStrategy.instructionsUTF8ByteLimit)
            #expect(byteCount > limit)
        }
        #expect(try store.wikiStrategyRevision() == nil)
    }

    @Test func oversizedWhitespaceOnlyInstructionsAreRejectedNotReset() throws {
        let store = try tempStore()
        // The byte limit is checked BEFORE the whitespace-reset rule, so an
        // oversized whitespace-only document is rejected visibly — it can
        // never smuggle a reset past the limit.
        let oversizedWhitespace = String(
            repeating: " ", count: WikiStrategy.instructionsUTF8ByteLimit + 1)
        #expect(throws: WikiStrategyTextError.self) {
            _ = try StrategyCommand.run(
                .save(name: "S", content: .inline(oversizedWhitespace), expect: .absent, json: false),
                in: store)
        }
        #expect(try store.wikiStrategyRevision() == nil)
    }

    // MARK: - JSON output shape

    @Test func saveJSONOutputsParseWithOutcomeAndRevision() throws {
        let store = try tempStore()
        let saved = try StrategyCommand.run(
            .save(name: "S", content: .inline("one"), expect: .absent, json: true),
            in: store)
        let savedObject = try jsonObject(saved.output)
        #expect(savedObject["outcome"] as? String == "saved")
        #expect(savedObject["revision"] as? Int64 == 1)
        #expect(savedObject["default"] as? Bool == false)
        #expect(saved.stderrOutput == nil)

        let unchanged = try StrategyCommand.run(
            .save(name: "S", content: .inline("one"), expect: .revision(.init(rawValue: 1)), json: true),
            in: store)
        let unchangedObject = try jsonObject(unchanged.output)
        #expect(unchangedObject["outcome"] as? String == "unchanged")
        #expect(unchangedObject["revision"] as? Int64 == 1)
        #expect(unchangedObject["default"] as? Bool == false)
    }

    // MARK: - helpers

    /// Parse one JSON object from a command's stdout line.
    private func jsonObject(_ output: String) throws -> [String: Any] {
        let data = Data(output.utf8)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return object
    }
}
