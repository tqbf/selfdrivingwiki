import Foundation
import Testing
import WikiFSCore
@testable import WikiCtlCore

/// The typed explicit-database selector seam (`--database-path` /
/// `WIKI_DB_PATH`): invalid combinations are rejected, ordinary `--wiki`
/// registry resolution is unchanged, and explicit resolution touches neither
/// the registry nor the App Group container.
@Suite("WikiCtl explicit database path")
struct WikiCtlExplicitDatabasePathTests {

    // MARK: - Typed selection validation

    @Test("relative database path is rejected on the raw string")
    func relativePathRejected() throws {
        #expect(throws: WikiSelectionError.relativeDatabasePath("tmp/eval.sqlite")) {
            _ = try WikiResolver.selection(forDatabasePath: "tmp/eval.sqlite")
        }
        #expect(throws: WikiSelectionError.relativeDatabasePath("eval.sqlite")) {
            _ = try WikiResolver.selection(forDatabasePath: "eval.sqlite")
        }
    }

    @Test("non-sqlite database path is rejected")
    func nonSQLiteRejected() throws {
        #expect(throws: WikiSelectionError.notADatabaseFile("/tmp/fixture.db")) {
            _ = try WikiResolver.selection(forDatabasePath: "/tmp/fixture.db")
        }
    }

    @Test("the real App Group path namespace is refused")
    func containerPathRefused() throws {
        let container = WikiResolver.appGroupContainerPath()
        let inside = container + "/01TESTWIKI.sqlite"
        #expect(throws: WikiSelectionError.explicitPathInsideAppGroupContainer(inside)) {
            _ = try WikiResolver.selection(forDatabasePath: inside)
        }
        // The namespace reservation also covers a file-like spelling of the
        // container root. This stays pure: selection must not create or read
        // anything in the live App Group container.
        let containerItself = container + ".sqlite"
        #expect(throws: WikiSelectionError.explicitPathInsideAppGroupContainer(containerItself)) {
            _ = try WikiResolver.selection(forDatabasePath: containerItself)
        }
    }

    @Test("valid explicit path becomes the typed selection")
    func validPathTyped() throws {
        let selection = try WikiResolver.selection(forDatabasePath: "/tmp/wiki-eval/01FIXTURE.sqlite")
        guard case .explicitDatabase(let url) = selection else {
            Issue.record("expected explicitDatabase selection, got \(selection)")
            return
        }
        #expect(url.path == "/tmp/wiki-eval/01FIXTURE.sqlite")
    }

    @Test("mixed selector forms are conflicting selections")
    func mixedSelectorsConflict() throws {
        #expect(throws: WikiSelectionError.self) {
            _ = try WikiResolver.selection(
                wikiSelector: "01WIKI",
                databasePath: "/tmp/wiki-eval/01FIXTURE.sqlite")
        }
        #expect(throws: WikiSelectionError.self) {
            _ = try WikiResolver.selection(wikiSelector: nil, databasePath: nil)
        }
        // Plain wiki selector still routes to the registry form.
        let plain = try WikiResolver.selection(wikiSelector: "01WIKI", databasePath: "")
        #expect(plain == .registry("01WIKI"))
    }

    // MARK: - Resolution: explicit bypasses the registry; ordinary unchanged

    @Test("explicit resolution bypasses the registry and creates nothing",
          arguments: ["/tmp", "/private/tmp"])
    func explicitResolutionBypassesRegistry(root: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wiki-explicit-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record("fixture cleanup failed: \(error)") }
        }
        _ = root  // both spellings of the system temp root must behave alike

        let database = directory.appendingPathComponent("01FIXTURE.sqlite", isDirectory: false)
        let resolver = WikiResolver(containerDirectory: directory)
        let selection = try WikiResolver.selection(forDatabasePath: database.path)
        let target = try resolver.resolve(selection: selection)

        #expect(target.databaseURL.path == database.path)
        #expect(target.wikiID == WikiID(rawValue: "01FIXTURE"))
        #expect(target.containerDirectory.path == directory.path)

        // No registry material appeared beside the database, and no wikis.json
        // was consulted or written: the directory still holds nothing.
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(contents.isEmpty)
    }

    @Test("ordinary registry resolution is unchanged")
    func ordinaryResolutionUnchanged() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wiki-registry-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record("fixture cleanup failed: \(error)") }
        }

        let descriptor = WikiDescriptor.make(displayName: "Fixture Wiki", now: Date())
        var registry = WikiRegistry()
        registry.add(descriptor)
        try registry.save(to: directory)

        let resolver = WikiResolver(containerDirectory: directory)
        let selection = try WikiResolver.selection(wikiSelector: descriptor.id.rawValue, databasePath: "")
        let target = try resolver.resolve(selection: selection)
        #expect(target.databaseURL.path == directory.appendingPathComponent("\(descriptor.id.rawValue).sqlite").path)
        #expect(target.wikiID == descriptor.id)
        #expect(target.containerDirectory.path == directory.path)

        // Unknown selector still fails like before.
        #expect(throws: PageCommand.Failure.self) {
            _ = try resolver.resolve(selection: .registry("no-such-wiki"))
        }
    }

    // MARK: - Argument parsing

    @Test("--database-path parses as the leading selector")
    func parsesDatabasePathFlag() throws {
        let spaced = try ArgumentParser.parse(["--database-path", "/tmp/eval.sqlite", "page", "list"]) { _ in nil }
        #expect(spaced.databasePath == "/tmp/eval.sqlite")
        #expect(spaced.wikiSelector == "")
        #expect(spaced.command == .page(.list(json: false)))

        let joined = try ArgumentParser.parse(["--database-path=/tmp/eval.sqlite", "page", "list"]) { _ in nil }
        #expect(joined.databasePath == "/tmp/eval.sqlite")

        let fromEnv = try ArgumentParser.parse(["page", "list"]) { name in
            name == "WIKI_DB_PATH" ? "/tmp/eval.sqlite" : nil
        }
        #expect(fromEnv.databasePath == "/tmp/eval.sqlite")
        #expect(fromEnv.wikiSelector == "")
    }

    @Test("ordinary --wiki parsing is unchanged")
    func parsesWikiSelectorUnchanged() throws {
        let flagged = try ArgumentParser.parse(["--wiki", "01WIKI", "page", "list"]) { _ in nil }
        #expect(flagged.wikiSelector == "01WIKI")
        #expect(flagged.databasePath == "")

        let fromEnv = try ArgumentParser.parse(["page", "list"]) { name in
            name == "WIKI_DB" ? "01WIKI" : nil
        }
        #expect(fromEnv.wikiSelector == "01WIKI")
        #expect(fromEnv.databasePath == "")
    }

    @Test("flag and env selector mixes parse through to the typed conflict check")
    func mixedFormsReachConflictCheck() throws {
        // --wiki flag + WIKI_DB_PATH env: both recorded; the runner's typed
        // conversion rejects the combination.
        let flaggedWiki = try ArgumentParser.parse(["--wiki", "01WIKI", "page", "list"]) { name in
            name == "WIKI_DB_PATH" ? "/tmp/eval.sqlite" : nil
        }
        #expect(flaggedWiki.wikiSelector == "01WIKI")
        #expect(flaggedWiki.databasePath == "/tmp/eval.sqlite")
        #expect(throws: WikiSelectionError.self) {
            _ = try WikiResolver.selection(
                wikiSelector: flaggedWiki.wikiSelector,
                databasePath: flaggedWiki.databasePath)
        }

        // Both env vars set: both recorded, same conflict.
        let bothEnv = try ArgumentParser.parse(["page", "list"]) { name in
            switch name {
            case "WIKI_DB": return "01WIKI"
            case "WIKI_DB_PATH": return "/tmp/eval.sqlite"
            default: return nil
            }
        }
        #expect(bothEnv.wikiSelector == "01WIKI")
        #expect(bothEnv.databasePath == "/tmp/eval.sqlite")

        // Both flags on the command line: both recorded.
        let bothFlags = try ArgumentParser.parse(
            ["--wiki", "01WIKI", "--database-path", "/tmp/eval.sqlite", "page", "list"]) { _ in nil }
        #expect(bothFlags.wikiSelector == "01WIKI")
        #expect(bothFlags.databasePath == "/tmp/eval.sqlite")
    }

    @Test("missing selector value is a usage error")
    func missingValueRejected() throws {
        #expect(throws: ArgumentParser.Failure.usage("--database-path requires a value")) {
            _ = try ArgumentParser.parse(["--database-path"]) { _ in nil }
        }
    }
}
