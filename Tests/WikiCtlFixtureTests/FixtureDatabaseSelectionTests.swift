import Foundation
import Testing
import WikiFSCore
@testable import WikiCtlCore
@testable import wikictl_fixture

/// The fixture binary's typed explicit-database selection
/// (`--database-path`/`WIKI_DB_PATH`): invalid paths are rejected, the real
/// App Group path namespace is refused, and resolution touches neither the
/// registry nor the live container. The selector-grammar twin of the suite
/// that lived in WikiFSTests before the fixture-binary split moved the
/// machinery into `wikictl-fixture`.
@Suite("wikictl-fixture database selection")
struct FixtureDatabaseSelectionTests {

    // MARK: - Typed selection validation

    @Test("relative database path is rejected on the raw string")
    func relativePathRejected() {
        #expect(throws: FixtureSelectionError.relativeDatabasePath("tmp/eval.sqlite")) {
            _ = try FixtureWikiResolver.validatedDatabasePath("tmp/eval.sqlite")
        }
        #expect(throws: FixtureSelectionError.relativeDatabasePath("eval.sqlite")) {
            _ = try FixtureWikiResolver.validatedDatabasePath("eval.sqlite")
        }
    }

    @Test("non-sqlite database path is rejected")
    func nonSQLiteRejected() {
        #expect(throws: FixtureSelectionError.notADatabaseFile("/tmp/fixture.db")) {
            _ = try FixtureWikiResolver.validatedDatabasePath("/tmp/fixture.db")
        }
    }

    @Test("the real App Group path namespace is refused")
    func containerPathRefused() throws {
        let container = FixtureWikiResolver.appGroupContainerPath()
        let inside = container + "/01TESTWIKI.sqlite"
        #expect(throws: FixtureSelectionError.explicitPathInsideAppGroupContainer(inside)) {
            _ = try FixtureWikiResolver.validatedDatabasePath(inside)
        }
        // The namespace reservation also covers a file-like spelling of the
        // container root. This stays pure: validation must not create or read
        // anything in the live App Group container.
        let containerItself = container + ".sqlite"
        #expect(throws: FixtureSelectionError.explicitPathInsideAppGroupContainer(containerItself)) {
            _ = try FixtureWikiResolver.validatedDatabasePath(containerItself)
        }
    }

    @Test("valid explicit path becomes the typed URL")
    func validPathTyped() throws {
        let url = try FixtureWikiResolver.validatedDatabasePath("/tmp/wiki-eval/01FIXTURE.sqlite")
        #expect(url.path == "/tmp/wiki-eval/01FIXTURE.sqlite")
    }

    // MARK: - Resolution: the file stem becomes the wiki id

    @Test("resolution derives the wiki id and roots sidecars at the file",
          arguments: ["/tmp", "/private/tmp"])
    func resolutionDerivesTarget(root: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wiki-fixture-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record("fixture cleanup failed: \(error)") }
        }
        _ = root  // both spellings of the system temp root must behave alike

        let database = directory.appendingPathComponent("01FIXTURE.sqlite", isDirectory: false)
        let target = try FixtureWikiResolver().resolve(databaseURL: database)

        #expect(target.databaseURL.path == database.path)
        #expect(target.wikiID == WikiID(rawValue: "01FIXTURE"))
        #expect(target.containerDirectory.path == directory.path)

        // No registry material appeared beside the database, and no wikis.json
        // was consulted or written: the directory still holds nothing.
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(contents.isEmpty)
    }

    // MARK: - Selector grammar

    @Test("--database-path parses as the leading selector")
    func parsesDatabasePathFlag() throws {
        let spaced = try FixtureArgumentParser.parse(
            ["--database-path", "/tmp/eval.sqlite", "page", "list"], env: { _ in nil })
        #expect(spaced.databasePath == "/tmp/eval.sqlite")
        #expect(spaced.arguments == ["page", "list"])

        let joined = try FixtureArgumentParser.parse(
            ["--database-path=/tmp/eval.sqlite", "page", "list"], env: { _ in nil })
        #expect(joined.databasePath == "/tmp/eval.sqlite")

        let fromEnv = try FixtureArgumentParser.parse(["page", "list"]) { name in
            name == "WIKI_DB_PATH" ? "/tmp/eval.sqlite" : nil
        }
        #expect(fromEnv.databasePath == "/tmp/eval.sqlite")
        #expect(fromEnv.arguments == ["page", "list"])
    }

    @Test("missing selector is a usage error")
    func missingSelectorRejected() {
        #expect(throws: ArgumentParser.Failure.self) {
            _ = try FixtureArgumentParser.parse(["page", "list"], env: { _ in nil })
        }
        #expect(throws: ArgumentParser.Failure.usage("--database-path requires a value")) {
            _ = try FixtureArgumentParser.parse(["--database-path"], env: { _ in nil })
        }
    }

    @Test("the registry selector is refused in both spellings and via WIKI_DB")
    func registrySelectorRejected() {
        for form in [["--wiki", "01WIKI", "page", "list"], ["--wiki=01WIKI", "page", "list"]] {
            #expect(throws: ArgumentParser.Failure.self) {
                _ = try FixtureArgumentParser.parse(form, env: { _ in nil })
            }
        }
        #expect(throws: ArgumentParser.Failure.self) {
            _ = try FixtureArgumentParser.parse(["page", "list"]) { name in
                name == "WIKI_DB" ? "01WIKI" : nil
            }
        }
    }
}
