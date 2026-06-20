import Foundation
import Testing
@testable import WikiCtlCore
@testable import WikiFSCore

/// Tests for `wikictl`'s deterministic seams: argument parsing / command dispatch
/// and the `PageCommand` execution against a temp DB.
struct WikiCtlCommandTests {

    private func tempStore() throws -> SQLiteWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-ctl-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try SQLiteWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }

    private let noEnv: (String) -> String? = { _ in nil }

    // MARK: - Argument parsing

    @Test func parsesWikiFromFlag() throws {
        let invocation = try ArgumentParser.parse(["--wiki", "WIKI1", "page", "list"], env: noEnv)
        #expect(invocation.wikiSelector == "WIKI1")
        #expect(invocation.command == .list(json: false))
    }

    @Test func parsesWikiFromEnvWhenFlagAbsent() throws {
        let invocation = try ArgumentParser.parse(
            ["page", "list", "--json"],
            env: { $0 == "WIKI_DB" ? "ENVWIKI" : nil }
        )
        #expect(invocation.wikiSelector == "ENVWIKI")
        #expect(invocation.command == .list(json: true))
    }

    @Test func flagBeatsEnvForWikiSelector() throws {
        let invocation = try ArgumentParser.parse(
            ["--wiki", "FLAG", "page", "list"],
            env: { $0 == "WIKI_DB" ? "ENV" : nil }
        )
        #expect(invocation.wikiSelector == "FLAG")
    }

    @Test func missingWikiSelectorIsUsageError() {
        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse(["page", "list"], env: noEnv)
        }
    }

    @Test func parsesGetByTitleAndByID() throws {
        let byTitle = try ArgumentParser.parse(
            ["--wiki", "W", "page", "get", "--title", "Home"], env: noEnv)
        #expect(byTitle.command == .get(.title("Home")))

        let byID = try ArgumentParser.parse(
            ["--wiki", "W", "page", "get", "--id", "01ABC"], env: noEnv)
        #expect(byID.command == .get(.id(PageID(rawValue: "01ABC"))))
    }

    @Test func getRequiresExactlyOneSelector() {
        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse(["--wiki", "W", "page", "get"], env: noEnv)
        }
        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse(
                ["--wiki", "W", "page", "get", "--id", "x", "--title", "y"], env: noEnv)
        }
    }

    @Test func parsesUpsertWithAndWithoutID() throws {
        let create = try ArgumentParser.parse(
            ["--wiki", "W", "page", "upsert", "--title", "T", "--body-file", "-"], env: noEnv)
        #expect(create.command == .upsert(id: nil, title: "T", bodyFile: "-"))

        let update = try ArgumentParser.parse(
            ["--wiki", "W", "page", "upsert", "--title", "T", "--id", "01X", "--body-file", "body.md"],
            env: noEnv)
        #expect(update.command == .upsert(id: PageID(rawValue: "01X"), title: "T", bodyFile: "body.md"))
    }

    @Test func upsertRequiresTitleAndBodyFile() {
        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse(
                ["--wiki", "W", "page", "upsert", "--body-file", "-"], env: noEnv)
        }
        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse(
                ["--wiki", "W", "page", "upsert", "--title", "T"], env: noEnv)
        }
    }

    @Test func parsesDelete() throws {
        let invocation = try ArgumentParser.parse(
            ["--wiki", "W", "page", "delete", "--id", "01Z"], env: noEnv)
        #expect(invocation.command == .delete(id: PageID(rawValue: "01Z")))
    }

    @Test func rejectsUnknownCommand() {
        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse(["--wiki", "W", "bogus"], env: noEnv)
        }
    }

    // MARK: - Search parsing

    @Test func parsesSearchWithQueryAndDefaultLimit() throws {
        let invocation = try ArgumentParser.parse(
            ["--wiki", "W", "search", "--query", "electric cars"], env: noEnv)
        #expect(invocation.command == .search(query: "electric cars", limit: 10))
    }

    @Test func parsesSearchWithCustomLimit() throws {
        let invocation = try ArgumentParser.parse(
            ["search", "--query", "ai", "--limit", "5"],
            env: { _ in "W" })
        #expect(invocation.command == .search(query: "ai", limit: 5))
    }

    @Test func searchRequiresQuery() {
        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse(["--wiki", "W", "search", "--limit", "10"], env: noEnv)
        }
    }

    @Test func searchRejectsLimitZero() {
        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse(["--wiki", "W", "search", "--query", "x", "--limit", "0"], env: noEnv)
        }
    }

    @Test func searchRejectsLimitOver100() {
        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse(["--wiki", "W", "search", "--query", "x", "--limit", "101"], env: noEnv)
        }
    }

    // MARK: - Command dispatch (against a temp DB)

    @Test func upsertCommitsAndReturnsID() throws {
        let store = try tempStore()
        let result = try PageCommand.run(
            .upsert(id: nil, title: "Created", body: "hello"), in: store)
        #expect(result.didCommit)
        let resolvedID = try store.resolveTitleToID("Created")?.rawValue
        #expect(result.output == resolvedID)
        #expect(try store.getPage(id: PageID(rawValue: result.output)).bodyMarkdown == "hello")
    }

    @Test func getReturnsBodyAndDoesNotCommit() throws {
        let store = try tempStore()
        _ = try PageCommand.run(.upsert(id: nil, title: "Doc", body: "the body"), in: store)
        let result = try PageCommand.run(.get(.title("Doc")), in: store)
        #expect(result.output == "the body")
        #expect(!result.didCommit)
    }

    @Test func getByMissingTitleThrows() throws {
        let store = try tempStore()
        #expect(throws: PageCommand.Failure.self) {
            try PageCommand.run(.get(.title("Nope")), in: store)
        }
    }

    @Test func listTSVHasIDTitlePathPerLine() throws {
        let store = try tempStore()
        _ = try PageCommand.run(.upsert(id: nil, title: "Alpha", body: ""), in: store)
        let result = try PageCommand.run(.list(json: false), in: store)
        #expect(!result.didCommit)
        let columns = result.output.split(separator: "\t")
        #expect(columns.count == 3)
        #expect(columns[1] == "Alpha")
        #expect(columns[2].hasPrefix("pages/by-title/Alpha--"))
    }

    @Test func listJSONIsOneObjectPerLine() throws {
        let store = try tempStore()
        _ = try PageCommand.run(.upsert(id: nil, title: "One", body: ""), in: store)
        _ = try PageCommand.run(.upsert(id: nil, title: "Two", body: ""), in: store)
        let result = try PageCommand.run(.list(json: true), in: store)
        let lines = result.output.split(separator: "\n")
        #expect(lines.count == 2)
        for line in lines {
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            #expect(object?["id"] != nil)
            #expect(object?["title"] != nil)
            #expect(object?["path"] != nil)
        }
    }

    @Test func deleteCommitsAndRemovesPage() throws {
        let store = try tempStore()
        let created = try PageCommand.run(.upsert(id: nil, title: "Doomed", body: ""), in: store)
        let id = PageID(rawValue: created.output)
        let result = try PageCommand.run(.delete(id: id), in: store)
        #expect(result.didCommit)
        #expect(try store.listPages(sortBy: .lastUpdated).isEmpty)
    }

    // MARK: - Search dispatch

    @Test func searchReturnsTSVAndDoesNotCommit() throws {
        let store = try tempStore()
        _ = try PageCommand.run(.upsert(id: nil, title: "Cars", body: "electric vehicles"), in: store)
        _ = try PageCommand.run(.upsert(id: nil, title: "Recipes", body: "baking bread"), in: store)
        let result = try PageCommand.run(.search(query: "car", limit: 10), in: store)
        #expect(!result.didCommit)
        let lines = result.output.split(separator: "\n")
        #expect(!lines.isEmpty)
        // Each line is "id\ttitle"
        for line in lines {
            let cols = line.split(separator: "\t")
            #expect(cols.count == 2)
            #expect(!cols[0].isEmpty)
            #expect(!cols[1].isEmpty)
        }
    }

    // MARK: - File command parsing

    @Test func parsesFileList() throws {
        let invocation = try ArgumentParser.parse(
            ["--wiki", "W", "file", "list"], env: noEnv)
        #expect(invocation.command == .file(.list(json: false)))
    }

    @Test func parsesFileListJSON() throws {
        let invocation = try ArgumentParser.parse(
            ["--wiki", "W", "file", "list", "--json"], env: noEnv)
        #expect(invocation.command == .file(.list(json: true)))
    }

    @Test func parsesFileCatByID() throws {
        let invocation = try ArgumentParser.parse(
            ["--wiki", "W", "file", "cat", "--id", "01ABC"], env: noEnv)
        #expect(invocation.command == .file(.cat(.id(PageID(rawValue: "01ABC")))))
    }

    @Test func parsesFileCatByName() throws {
        let invocation = try ArgumentParser.parse(
            ["--wiki", "W", "file", "cat", "--name", "report.pdf"], env: noEnv)
        #expect(invocation.command == .file(.cat(.name("report.pdf"))))
    }

    @Test func parsesFileExportByID() throws {
        let invocation = try ArgumentParser.parse(
            ["--wiki", "W", "file", "export", "--id", "01Z"], env: noEnv)
        #expect(invocation.command == .file(.export(.id(PageID(rawValue: "01Z")), out: nil)))
    }

    @Test func parsesFileExportWithOut() throws {
        let invocation = try ArgumentParser.parse(
            ["--wiki", "W", "file", "export", "--id", "01Z", "--out", "/tmp/out.pdf"], env: noEnv)
        #expect(invocation.command == .file(.export(.id(PageID(rawValue: "01Z")), out: "/tmp/out.pdf")))
    }

    @Test func fileRequiresSubcommand() {
        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse(["--wiki", "W", "file"], env: noEnv)
        }
    }

    @Test func fileCatRequiresSelector() {
        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse(["--wiki", "W", "file", "cat"], env: noEnv)
        }
    }

    @Test func fileCatRejectsBothSelectors() {
        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse(
                ["--wiki", "W", "file", "cat", "--id", "x", "--name", "y"], env: noEnv)
        }
    }

    @Test func fileRejectsUnknownSubcommand() {
        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse(["--wiki", "W", "file", "bogus"], env: noEnv)
        }
    }

    // MARK: - File command dispatch (against a temp DB)

    @Test func fileListTSV() throws {
        let store = try tempStore()
        _ = try store.ingestFile(filename: "alpha.txt", data: Data("hello".utf8))
        _ = try store.ingestFile(filename: "beta.pdf", data: Data([0x00, 0xFF, 0x42]))
        let result = try FileCommand.run(.list(json: false), in: store, cwd: "/tmp")
        #expect(!result.didCommit)
        guard case .text(let output) = result.payload else {
            #expect(Bool(false), "expected .text payload"); return
        }
        let lines = output.split(separator: "\n")
        #expect(lines.count == 2)
        for line in lines {
            let cols = line.split(separator: "\t")
            #expect(cols.count == 4) // id, name, size, mime
            #expect(!cols[0].isEmpty)
            #expect(!cols[1].isEmpty)
        }
        // alpha.txt = 5 bytes, beta.pdf = 3 bytes; most-recent-first so beta then alpha
        #expect(lines[0].contains("beta.pdf"))
        #expect(lines[1].contains("alpha.txt"))
    }

    @Test func fileListJSONMatchesFilesJSONL() throws {
        let store = try tempStore()
        _ = try store.ingestFile(filename: "one.txt", data: Data("aaa".utf8))
        _ = try store.ingestFile(filename: "two.bin", data: Data([0x00, 0x01]))
        let result = try FileCommand.run(.list(json: true), in: store, cwd: "/tmp")
        guard case .text(let output) = result.payload else {
            #expect(Bool(false), "expected .text payload"); return
        }

        // Build the expected JSONL the same way the command does.
        let summaries = try store.listIngestedFiles().sorted { $0.id.rawValue < $1.id.rawValue }
        let rows = summaries.map { s in
            IndexGenerators.FileRow(
                id: s.id.rawValue, filename: s.filename, ext: s.ext,
                mime: s.mimeType, byteSize: s.byteSize,
                createdAt: s.createdAt, updatedAt: s.updatedAt, version: s.version
            )
        }
        let expected = String(decoding: IndexGenerators.filesJSONL(files: rows), as: UTF8.self)
        #expect(output == expected)

        // Verify each line is valid JSON with the expected keys.
        for line in output.split(separator: "\n") {
            let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            #expect(obj?["id"] != nil)
            #expect(obj?["name"] != nil)
            #expect(obj?["path"] != nil)
            #expect(obj?["size"] != nil)
            // mime key always present (null for unknown types)
            #expect(obj?.keys.contains("mime") ?? false)
        }
    }

    @Test func fileCatReturnsExactBytes() throws {
        let store = try tempStore()
        // Binary fixture with non-UTF-8 bytes to prove the byte path works.
        let binary = Data([0x00, 0xFF, 0x89, 0x50, 0x4E, 0x47]) // includes PNG magic
        let ingested = try store.ingestFile(filename: "icon.png", data: binary)
        let result = try FileCommand.run(.cat(.id(ingested.id)), in: store, cwd: "/tmp")
        #expect(!result.didCommit)
        #expect(result.payload == .bytes(binary))
    }

    @Test func fileCatWithUnknownIDFails() throws {
        let store = try tempStore()
        #expect(throws: FileCommand.Failure.self) {
            try FileCommand.run(.cat(.id(PageID(rawValue: "01NOPE"))), in: store, cwd: "/tmp")
        }
    }

    @Test func fileExportWritesToDefaultPath() throws {
        let store = try tempStore()
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-export-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let data = Data("pdf content".utf8)
        let ingested = try store.ingestFile(filename: "doc.pdf", data: data)
        let result = try FileCommand.run(.export(.id(ingested.id), out: nil), in: store, cwd: tmpDir.path)
        #expect(!result.didCommit)
        guard case .text(let path) = result.payload else {
            #expect(Bool(false), "expected .text payload"); return
        }
        // Default path: <cwd>/file-<id>.pdf
        #expect(path.hasPrefix(tmpDir.path))
        #expect(path.contains(ingested.id.rawValue))
        #expect(path.hasSuffix(".pdf"))
        let written = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(written == data)
    }

    @Test func fileExportWritesToCustomOutPath() throws {
        let store = try tempStore()
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-export-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let data = Data("hello".utf8)
        let ingested = try store.ingestFile(filename: "notes.txt", data: data)
        let customPath = tmpDir.appendingPathComponent("custom-out.txt").path
        let result = try FileCommand.run(
            .export(.id(ingested.id), out: customPath), in: store, cwd: tmpDir.path)
        guard case .text(let path) = result.payload else {
            #expect(Bool(false), "expected .text payload"); return
        }
        #expect(path == customPath)
        let written = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(written == data)
    }

    @Test func fileExportWithUnknownIDFails() throws {
        let store = try tempStore()
        #expect(throws: FileCommand.Failure.self) {
            try FileCommand.run(
                .export(.id(PageID(rawValue: "01NOPE")), out: nil), in: store, cwd: "/tmp")
        }
    }

    @Test func fileNameResolutionResolvesUnambiguous() throws {
        let store = try tempStore()
        let ingested = try store.ingestFile(filename: "unique.md", data: Data("text".utf8))
        let result = try FileCommand.run(.cat(.name("unique.md")), in: store, cwd: "/tmp")
        #expect(result.payload == .bytes(Data("text".utf8)))
        _ = ingested
    }

    @Test func fileNameResolutionFailsWhenMissing() throws {
        let store = try tempStore()
        #expect(throws: FileCommand.Failure.self) {
            try FileCommand.run(.cat(.name("ghost.pdf")), in: store, cwd: "/tmp")
        }
    }

    @Test func fileNameResolutionFailsWhenAmbiguous() throws {
        let store = try tempStore()
        _ = try store.ingestFile(filename: "same.txt", data: Data("v1".utf8))
        _ = try store.ingestFile(filename: "same.txt", data: Data("v2".utf8))
        #expect(throws: FileCommand.Failure.self) {
            try FileCommand.run(.cat(.name("same.txt")), in: store, cwd: "/tmp")
        }
    }

    // MARK: - Darwin notification naming

    @Test func darwinNotificationNameCarriesWikiID() {
        let name = WikiChangeNotification.name(forWikiID: "01ABCDEF")
        #expect(name == "org.sockpuppet.wiki.changed.01ABCDEF")
        #expect(name.hasPrefix(WikiChangeNotification.baseName))
    }
}
