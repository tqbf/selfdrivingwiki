import Foundation
import Testing
@testable import WikiCtlCore
@testable import WikiFSCore

/// Tests for `wikictl`'s deterministic seams: argument parsing / command dispatch
/// and the `PageCommand` execution against a temp DB.
struct WikiCtlCommandTests {

    private func tempStore() throws -> GRDBWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-ctl-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
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
        #expect(byTitle.command == .get(.title("Home"), json: false))

        let byID = try ArgumentParser.parse(
            ["--wiki", "W", "page", "get", "--id", "01ABC"], env: noEnv)
        #expect(byID.command == .get(.id(PageID(rawValue: "01ABC")), json: false))
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
        #expect(create.command == .upsert(id: nil, title: "T", bodyFile: "-", author: nil))

        let update = try ArgumentParser.parse(
            ["--wiki", "W", "page", "upsert", "--title", "T", "--id", "01X", "--body-file", "body.md"],
            env: noEnv)
        #expect(update.command == .upsert(id: PageID(rawValue: "01X"), title: "T", bodyFile: "body.md", author: nil))
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

    @Test func parsesUpsertAuthorFlag() throws {
        let inv = try ArgumentParser.parse(
            ["--wiki", "W", "page", "upsert", "--title", "T", "--body-file", "-",
             "--author", "chat:01ABC"],
            env: noEnv)
        guard case .upsert(_, _, _, _, _, let author) = inv.command else {
            Issue.record("expected .upsert")
            return
        }
        #expect(author == "chat:01ABC")
    }

    // MARK: - WIKI_AUTHOR env var routing (#397)

    @Test func wikiAuthorEnvStampsProvenanceWhenFlagAbsent() throws {
        let inv = try ArgumentParser.parse(
            ["--wiki", "W", "page", "upsert", "--title", "T", "--body-file", "-"],
            env: { _ in nil })
        let applied = ArgumentParser.applyEnv(
            inv.command, env: ["WIKI_AUTHOR": "chat:01DEF"])
        guard case .upsert(_, _, _, _, _, let author) = applied else {
            Issue.record("expected .upsert")
            return
        }
        #expect(author == "chat:01DEF")
    }

    @Test func explicitAuthorFlagWinsOverEnv() throws {
        let inv = try ArgumentParser.parse(
            ["--wiki", "W", "page", "upsert", "--title", "T", "--body-file", "-",
             "--author", "agent:ingest"],
            env: { _ in nil })
        let applied = ArgumentParser.applyEnv(
            inv.command, env: ["WIKI_AUTHOR": "chat:01DEF"])
        guard case .upsert(_, _, _, _, _, let author) = applied else {
            Issue.record("expected .upsert")
            return
        }
        #expect(author == "agent:ingest")
    }

    @Test func wikiAuthorEnvIgnoredWhenAbsent() throws {
        let inv = try ArgumentParser.parse(
            ["--wiki", "W", "page", "upsert", "--title", "T", "--body-file", "-"],
            env: { _ in nil })
        let applied = ArgumentParser.applyEnv(inv.command, env: [:])
        guard case .upsert(_, _, _, _, _, let author) = applied else {
            Issue.record("expected .upsert")
            return
        }
        #expect(author == nil)
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

    @Test func upsertWithoutAuthorLeavesProvenanceNil() throws {
        let store = try tempStore()
        let result = try PageCommand.run(
            .upsert(id: nil, title: "NoProv", body: "hi"), in: store)
        let page = try store.getPage(id: PageID(rawValue: result.output))
        #expect(page.createdBy == nil)
        #expect(page.lastEditedBy == nil)
    }

    @Test func upsertWithAuthorStampsCreatedAndLastEditedBy() throws {
        let store = try tempStore()
        let result = try PageCommand.run(
            .upsert(id: nil, title: "Prov", body: "v1",
                    author: "chat:01ABC"), in: store)
        let page = try store.getPage(id: PageID(rawValue: result.output))
        #expect(page.createdBy == "chat:01ABC")
        #expect(page.lastEditedBy == "chat:01ABC")
    }

    @Test func upsertWithAuthorOnUpdateSetsLastEditedByOnly() throws {
        let store = try tempStore()
        let created = try PageCommand.run(
            .upsert(id: nil, title: "Edit", body: "v1",
                    author: "user"), in: store)
        _ = try PageCommand.run(
            .upsert(id: PageID(rawValue: created.output), title: "Edit",
                    body: "v2", author: "chat:01DEF"), in: store)
        let page = try store.getPage(id: PageID(rawValue: created.output))
        #expect(page.createdBy == "user")
        #expect(page.lastEditedBy == "chat:01DEF")
    }

    @Test func getReturnsBodyAndDoesNotCommit() throws {
        let store = try tempStore()
        _ = try PageCommand.run(.upsert(id: nil, title: "Doc", body: "the body"), in: store)
        let result = try PageCommand.run(.get(.title("Doc"), json: false), in: store)
        #expect(result.output == "the body")
        #expect(!result.didCommit)
    }

    @Test func getByMissingTitleThrows() throws {
        let store = try tempStore()
        #expect(throws: PageCommand.Failure.self) {
            try PageCommand.run(.get(.title("Nope"), json: false), in: store)
        }
    }

    @Test func listTSVHasIDTitlePathPerLine() throws {
        let store = try tempStore()
        _ = try PageCommand.run(.upsert(id: nil, title: "Alpha", body: "stub"), in: store)
        let result = try PageCommand.run(.list(json: false), in: store)
        #expect(!result.didCommit)
        let columns = result.output.split(separator: "\t")
        #expect(columns.count == 3)
        #expect(columns[1] == "Alpha")
        #expect(columns[2].hasPrefix("pages/by-title/Alpha--"))
    }

    @Test func listJSONIsOneObjectPerLine() throws {
        let store = try tempStore()
        _ = try PageCommand.run(.upsert(id: nil, title: "One", body: "stub"), in: store)
        _ = try PageCommand.run(.upsert(id: nil, title: "Two", body: "stub"), in: store)
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
        let created = try PageCommand.run(.upsert(id: nil, title: "Doomed", body: "stub"), in: store)
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
            ["--wiki", "W", "source", "list"], env: noEnv)
        #expect(invocation.command == .source(.list(json: false)))
    }

    @Test func parsesFileListJSON() throws {
        let invocation = try ArgumentParser.parse(
            ["--wiki", "W", "source", "list", "--json"], env: noEnv)
        #expect(invocation.command == .source(.list(json: true)))
    }

    @Test func parsesFileCatByID() throws {
        let invocation = try ArgumentParser.parse(
            ["--wiki", "W", "source", "cat", "--id", "01ABC"], env: noEnv)
        #expect(invocation.command == .source(.cat(.id(PageID(rawValue: "01ABC")), markdown: false)))
    }

    @Test func parsesFileCatByName() throws {
        let invocation = try ArgumentParser.parse(
            ["--wiki", "W", "source", "cat", "--name", "report.pdf"], env: noEnv)
        #expect(invocation.command == .source(.cat(.name("report.pdf"), markdown: false)))
    }

    @Test func parsesFileExportByID() throws {
        let invocation = try ArgumentParser.parse(
            ["--wiki", "W", "source", "export", "--id", "01Z"], env: noEnv)
        #expect(invocation.command == .source(.export(.id(PageID(rawValue: "01Z")), out: nil, markdown: false)))
    }

    @Test func parsesFileExportWithOut() throws {
        let invocation = try ArgumentParser.parse(
            ["--wiki", "W", "source", "export", "--id", "01Z", "--out", "/tmp/out.pdf"], env: noEnv)
        #expect(invocation.command == .source(.export(.id(PageID(rawValue: "01Z")), out: "/tmp/out.pdf", markdown: false)))
    }

    @Test func fileRequiresSubcommand() {
        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse(["--wiki", "W", "source"], env: noEnv)
        }
    }

    @Test func fileCatRequiresSelector() {
        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse(["--wiki", "W", "source", "cat"], env: noEnv)
        }
    }

    @Test func fileCatRejectsBothSelectors() {
        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse(
                ["--wiki", "W", "source", "cat", "--id", "x", "--name", "y"], env: noEnv)
        }
    }

    @Test func fileRejectsUnknownSubcommand() {
        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse(["--wiki", "W", "source", "bogus"], env: noEnv)
        }
    }

    // MARK: - File command dispatch (against a temp DB)

    @Test func fileListTSV() throws {
        let store = try tempStore()
        _ = try store.addSource(filename: "alpha.txt", data: Data("hello".utf8))
        _ = try store.addSource(filename: "beta.pdf", data: Data([0x00, 0xFF, 0x42]))
        let result = try SourceCommand.run(.list(json: false), in: store, cwd: "/tmp")
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

    @Test func fileListShowsDisplayNameAfterRename() throws {
        let store = try tempStore()
        let src = try store.addSource(filename: "User Guide.md", data: Data("# Guide".utf8))
        try store.renameSource(id: src.id, to: "Self-Driving Wiki — User Guide")
        let result = try SourceCommand.run(.list(json: false), in: store, cwd: "/tmp")
        guard case .text(let output) = result.payload else {
            #expect(Bool(false), "expected .text payload"); return
        }
        // Text mode should show the display name, not the filename.
        #expect(output.contains("Self-Driving Wiki — User Guide"))
        #expect(!output.contains("User Guide.md"))
    }

    @Test func fileListJSONMatchesFilesJSONL() throws {
        let store = try tempStore()
        _ = try store.addSource(filename: "one.txt", data: Data("aaa".utf8))
        _ = try store.addSource(filename: "two.bin", data: Data([0x00, 0x01]))
        let result = try SourceCommand.run(.list(json: true), in: store, cwd: "/tmp")
        guard case .text(let output) = result.payload else {
            #expect(Bool(false), "expected .text payload"); return
        }

        // Build the expected JSONL the same way the command does.
        let summaries = try store.listSources().sorted { $0.id.rawValue < $1.id.rawValue }
        let rows = summaries.map { s in
            IndexGenerators.SourceIndexRow(
                id: s.id.rawValue, filename: s.filename, ext: s.ext,
                mime: s.mimeType, byteSize: s.byteSize,
                createdAt: s.createdAt, updatedAt: s.updatedAt, version: s.version,
                displayName: s.displayName
            )
        }
        let expected = String(decoding: IndexGenerators.sourcesJSONL(sources: rows), as: UTF8.self)
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
            #expect(obj?.keys.contains("has_markdown") ?? false)
        }
    }

    @Test func fileCatReturnsExactBytes() throws {
        let store = try tempStore()
        // Binary fixture with non-UTF-8 bytes to prove the byte path works.
        let binary = Data([0x00, 0xFF, 0x89, 0x50, 0x4E, 0x47]) // includes PNG magic
        let ingested = try store.addSource(filename: "icon.png", data: binary)
        let result = try SourceCommand.run(.cat(.id(ingested.id), markdown: false), in: store, cwd: "/tmp")
        #expect(!result.didCommit)
        #expect(result.payload == .bytes(binary))
    }

    @Test func fileCatWithUnknownIDFails() throws {
        let store = try tempStore()
        #expect(throws: SourceCommand.Failure.self) {
            try SourceCommand.run(.cat(.id(PageID(rawValue: "01NOPE")), markdown: false), in: store, cwd: "/tmp")
        }
    }

    @Test func fileExportWritesToDefaultPath() throws {
        let store = try tempStore()
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-export-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let data = Data("pdf content".utf8)
        let ingested = try store.addSource(filename: "doc.pdf", data: data)
        let result = try SourceCommand.run(.export(.id(ingested.id), out: nil, markdown: false), in: store, cwd: tmpDir.path)
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
        let ingested = try store.addSource(filename: "notes.txt", data: data)
        let customPath = tmpDir.appendingPathComponent("custom-out.txt").path
        let result = try SourceCommand.run(
            .export(.id(ingested.id), out: customPath, markdown: false), in: store, cwd: tmpDir.path)
        guard case .text(let path) = result.payload else {
            #expect(Bool(false), "expected .text payload"); return
        }
        #expect(path == customPath)
        let written = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(written == data)
    }

    @Test func fileExportWithUnknownIDFails() throws {
        let store = try tempStore()
        #expect(throws: SourceCommand.Failure.self) {
            try SourceCommand.run(
                .export(.id(PageID(rawValue: "01NOPE")), out: nil, markdown: false), in: store, cwd: "/tmp")
        }
    }

    @Test func fileNameResolutionResolvesUnambiguous() throws {
        let store = try tempStore()
        let ingested = try store.addSource(filename: "unique.md", data: Data("text".utf8))
        let result = try SourceCommand.run(.cat(.name("unique.md"), markdown: false), in: store, cwd: "/tmp")
        #expect(result.payload == .bytes(Data("text".utf8)))
        _ = ingested
    }

    @Test func fileNameResolutionFailsWhenMissing() throws {
        let store = try tempStore()
        #expect(throws: SourceCommand.Failure.self) {
            try SourceCommand.run(.cat(.name("ghost.pdf"), markdown: false), in: store, cwd: "/tmp")
        }
    }

    @Test func fileNameResolutionFailsWhenAmbiguous() throws {
        let store = try tempStore()
        _ = try store.addSource(filename: "same.txt", data: Data("v1".utf8))
        _ = try store.addSource(filename: "same.txt", data: Data("v2".utf8))
        #expect(throws: SourceCommand.Failure.self) {
            try SourceCommand.run(.cat(.name("same.txt"), markdown: false), in: store, cwd: "/tmp")
        }
    }

    // MARK: - cat --markdown (#553)

    @Test func parsesFileCatWithMarkdownFlag() throws {
        let invocation = try ArgumentParser.parse(
            ["--wiki", "W", "source", "cat", "--id", "01ABC", "--markdown"], env: noEnv)
        #expect(invocation.command == .source(.cat(.id(PageID(rawValue: "01ABC")), markdown: true)))
    }

    @Test func parsesFileCatByNameWithMarkdownFlag() throws {
        let invocation = try ArgumentParser.parse(
            ["--wiki", "W", "source", "cat", "--name", "report.pdf", "--markdown"], env: noEnv)
        #expect(invocation.command == .source(.cat(.name("report.pdf"), markdown: true)))
    }

    @Test func parsesFileExportWithMarkdownFlag() throws {
        let invocation = try ArgumentParser.parse(
            ["--wiki", "W", "source", "export", "--id", "01Z", "--markdown"], env: noEnv)
        #expect(invocation.command == .source(.export(.id(PageID(rawValue: "01Z")), out: nil, markdown: true)))
    }

    @Test func catMarkdownReturnsExtractedMarkdown() throws {
        let store = try tempStore()
        let ingested = try store.addSource(filename: "paper.pdf", data: Data("%PDF-1.4".utf8))
        _ = try store.appendProcessedMarkdown(
            sourceID: ingested.id, content: "# Extracted Title\n\nBody text.", origin: .extraction, note: nil)
        let result = try SourceCommand.run(.cat(.id(ingested.id), markdown: true), in: store, cwd: "/tmp")
        #expect(!result.didCommit)
        guard case .text(let output) = result.payload else {
            #expect(Bool(false), "expected .text payload for --markdown"); return
        }
        #expect(output == "# Extracted Title\n\nBody text.")
    }

    @Test func catMarkdownFallsBackToRawBytesWhenNoExtraction() throws {
        let store = try tempStore()
        let binary = Data([0x25, 0x50, 0x44, 0x46]) // %PDF
        let ingested = try store.addSource(filename: "raw.pdf", data: binary)
        // No appendProcessedMarkdown — no markdown chain exists.
        let result = try SourceCommand.run(.cat(.id(ingested.id), markdown: true), in: store, cwd: "/tmp")
        #expect(result.payload == .bytes(binary))
    }

    @Test func catMarkdownResolvesByName() throws {
        let store = try tempStore()
        let ingested = try store.addSource(filename: "doc.pdf", data: Data("%PDF".utf8))
        _ = try store.appendProcessedMarkdown(
            sourceID: ingested.id, content: "markdown body", origin: .extraction, note: nil)
        let result = try SourceCommand.run(.cat(.name("doc.pdf"), markdown: true), in: store, cwd: "/tmp")
        guard case .text(let output) = result.payload else {
            #expect(Bool(false), "expected .text payload"); return
        }
        #expect(output == "markdown body")
    }

    @Test func exportMarkdownWritesExtractedMarkdown() throws {
        let store = try tempStore()
        let ingested = try store.addSource(filename: "doc.pdf", data: Data("%PDF".utf8))
        _ = try store.appendProcessedMarkdown(
            sourceID: ingested.id, content: "# Title\n\nContent.", origin: .extraction, note: nil)
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-md-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let result = try SourceCommand.run(
            .export(.id(ingested.id), out: nil, markdown: true), in: store, cwd: tmpDir.path)
        guard case .text(let path) = result.payload else {
            #expect(Bool(false), "expected .text payload"); return
        }
        #expect(path.hasSuffix(".pdf.md"))
        let written = try String(contentsOfFile: path, encoding: .utf8)
        #expect(written == "# Title\n\nContent.")
    }

    @Test func exportMarkdownFallsBackToRawBytesWhenNoExtraction() throws {
        let store = try tempStore()
        let binary = Data("%PDF".utf8)
        let ingested = try store.addSource(filename: "raw.pdf", data: binary)
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-md-export-fb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let result = try SourceCommand.run(
            .export(.id(ingested.id), out: nil, markdown: true), in: store, cwd: tmpDir.path)
        guard case .text(let path) = result.payload else {
            #expect(Bool(false), "expected .text payload"); return
        }
        // Falls back to raw bytes path — default uses stored ext (.pdf).
        #expect(path.hasSuffix(".pdf"))
        let written = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(written == binary)
    }

    // MARK: - resolve by display name (#554)

    @Test func resolveByDisplayName() throws {
        let store = try tempStore()
        let ingested = try store.addSource(filename: "Matthews1999.pdf", data: Data("raw".utf8))
        try store.renameSource(id: ingested.id, to: "Ericksonian Hypnosis: A Review")
        // Agent sees display name in `source list`, should be able to use it.
        let result = try SourceCommand.run(
            .cat(.name("Ericksonian Hypnosis: A Review"), markdown: false), in: store, cwd: "/tmp")
        #expect(result.payload == .bytes(Data("raw".utf8)))
    }

    @Test func resolveFallsBackToFilenameWhenDisplayNameNotSet() throws {
        let store = try tempStore()
        _ = try store.addSource(filename: "plain.txt", data: Data("data".utf8))
        // No display name set — effectiveName falls back to filename.
        let result = try SourceCommand.run(
            .cat(.name("plain.txt"), markdown: false), in: store, cwd: "/tmp")
        #expect(result.payload == .bytes(Data("data".utf8)))
    }

    @Test func resolveByDisplayNameAmbiguityFails() throws {
        let store = try tempStore()
        let a = try store.addSource(filename: "a.pdf", data: Data("v1".utf8))
        let b = try store.addSource(filename: "b.pdf", data: Data("v2".utf8))
        try store.renameSource(id: a.id, to: "Same Display Name")
        try store.renameSource(id: b.id, to: "Same Display Name")
        #expect(throws: SourceCommand.Failure.self) {
            try SourceCommand.run(.cat(.name("Same Display Name"), markdown: false), in: store, cwd: "/tmp")
        }
    }

    // MARK: - edit-markdown parsing

    @Test func parsesEditMarkdownWithContent() throws {
        let invocation = try ArgumentParser.parse(
            ["--wiki", "W", "source", "edit-markdown", "--id", "01ABC", "--content", "new body"], env: noEnv)
        #expect(invocation.command == .sourceEditMarkdown(.id(PageID(rawValue: "01ABC")), contentOrFile: "new body", isFile: false))
    }

    @Test func parsesEditMarkdownWithFile() throws {
        let invocation = try ArgumentParser.parse(
            ["--wiki", "W", "source", "edit-markdown", "--id", "01ABC", "--file", "edit.md"], env: noEnv)
        #expect(invocation.command == .sourceEditMarkdown(.id(PageID(rawValue: "01ABC")), contentOrFile: "edit.md", isFile: true))
    }

    @Test func parsesEditMarkdownByName() throws {
        let invocation = try ArgumentParser.parse(
            ["--wiki", "W", "source", "edit-markdown", "--name", "report.md", "--content", "updated"], env: noEnv)
        #expect(invocation.command == .sourceEditMarkdown(.name("report.md"), contentOrFile: "updated", isFile: false))
    }

    @Test func editMarkdownRejectsBothContentAndFile() {
        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse(
                ["--wiki", "W", "source", "edit-markdown", "--id", "x", "--content", "a", "--file", "b.md"],
                env: noEnv)
        }
    }

    @Test func editMarkdownRequiresContentOrFile() {
        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse(
                ["--wiki", "W", "source", "edit-markdown", "--id", "x"], env: noEnv)
        }
    }

    @Test func editMarkdownRequiresSelector() {
        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse(
                ["--wiki", "W", "source", "edit-markdown", "--content", "x"], env: noEnv)
        }
    }

    // MARK: - edit-markdown dispatch

    @Test func editMarkdownAppendsUserVersion() throws {
        let store = try tempStore()
        let ingested = try store.addSource(filename: "doc.md", data: Data("hello".utf8))
        // Append first version (extraction).
        _ = try store.appendProcessedMarkdown(
            sourceID: ingested.id, content: "original", origin: .extraction, note: nil)
        // Small delay ensures the next ULID is strictly later.
        usleep(2000)
        // Run edit-markdown which appends a "user" version.
        let result = try SourceCommand.run(
            .editMarkdown(.id(ingested.id), content: "edited"), in: store, cwd: "/tmp")
        #expect(result.didCommit)

        // Verify the chain has 2 versions.
        let history = try store.processedMarkdownHistory(sourceID: ingested.id)
        #expect(history.count == 2)

        // Head (first, newest) is the user-edited version.
        #expect(history[0].content == "edited")
        #expect(history[0].origin == .user)
        #expect(history[0].parentID == history[1].id)

        // Second is the extraction baseline.
        #expect(history[1].content == "original")
        #expect(history[1].origin == .extraction)
        #expect(history[1].parentID == nil)
    }

    @Test func editMarkdownCommitsAndAppends() throws {
        let store = try tempStore()
        let ingested = try store.addSource(filename: "doc.md", data: Data("hello".utf8))
        _ = try store.appendProcessedMarkdown(
            sourceID: ingested.id, content: "original", origin: .extraction, note: nil)
        // Small delay ensures the next ULID is strictly later.
        usleep(2000)
        let result = try SourceCommand.run(
            .editMarkdown(.id(ingested.id), content: "edited"), in: store, cwd: "/tmp")
        #expect(result.didCommit)
        let head = try store.processedMarkdownHead(sourceID: ingested.id)
        #expect(head?.content == "edited")
        #expect(head?.origin == .user)
    }

    @Test func editMarkdownFailsWhenNoChainExists() throws {
        let store = try tempStore()
        let ingested = try store.addSource(filename: "doc.pdf", data: Data("%PDF".utf8))
        do {
            _ = try SourceCommand.run(
                .editMarkdown(.id(ingested.id), content: "edited"), in: store, cwd: "/tmp")
            Issue.record("expected SourceCommand.Failure")
        } catch let error as SourceCommand.Failure {
            #expect(error.description == "no processed markdown for this source")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func editMarkdownByNameResolvesAndCommits() throws {
        let store = try tempStore()
        let ingested = try store.addSource(filename: "unique.md", data: Data("hello".utf8))
        _ = try store.appendProcessedMarkdown(
            sourceID: ingested.id, content: "v1", origin: .extraction, note: nil)
        // Small delay ensures the next ULID is strictly later.
        usleep(2000)
        let result = try SourceCommand.run(
            .editMarkdown(.name("unique.md"), content: "v2"), in: store, cwd: "/tmp")
        #expect(result.didCommit)
        let head = try store.processedMarkdownHead(sourceID: ingested.id)
        #expect(head?.content == "v2")
    }

    // MARK: - Darwin notification naming

    @Test func darwinNotificationNameCarriesWikiID() {
        let name = WikiChangeNotification.name(forWikiID: "01ABCDEF")
        #expect(name == "org.sockpuppet.wiki.changed.01ABCDEF")
        #expect(name.hasPrefix(WikiChangeNotification.baseName))
    }

    // MARK: - Markdown auto-fix (wikictl page upsert)

    /// Resolve the committed bundles relative to this test file for injection.
    private func repoMarkdownLinter() throws -> MarkdownLinter {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../Resources/markdownlint.bundle.js")
        guard let src = try? String(contentsOf: url, encoding: .utf8), !src.isEmpty,
              let l = MarkdownLinter(jsSource: src) else {
            throw Failure("Resources/markdownlint.bundle.js unavailable")
        }
        return l
    }
    private func repoMermaidValidator() throws -> MermaidValidator {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../Resources/mermaid.min.js")
        guard let src = try? String(contentsOf: url, encoding: .utf8), !src.isEmpty,
              let v = MermaidValidator(jsSource: src) else {
            throw Failure("Resources/mermaid.min.js unavailable")
        }
        return v
    }
    private struct Failure: Error { let msg: String; init(_ s: String) { msg = s } }

    @Test func autoFixMarkdownPassesThroughWhenLinterIsNil() throws {
        // Nil linter = no-op pass-through (the unbundled / dev / swift test path).
        let body = "#No space\ntrailing   \n"
        let fixed = try PageCommand.autoFixMarkdown(body, linter: nil)
        #expect(fixed == body)
    }

    @Test func upsertAutoFixesMarkdownAndStoresNormalized() throws {
        let l = try repoMarkdownLinter()
        let store = try tempStore()
        let messy = "#No space\ntrailing   \n\n\n\ntext"
        let result = try PageCommand.run(
            .upsert(id: nil, title: "Messy", body: messy),
            in: store, linter: l)
        #expect(result.didCommit)
        // The stored body must be the NORMALIZED text.
        let stored = try store.getPage(id: PageID(rawValue: result.output)).bodyMarkdown
        #expect(stored.hasPrefix("# No space"))      // space after heading
        #expect(!stored.contains("   "))              // trailing whitespace stripped
        #expect(!stored.contains("\n\n\n"))           // blanks collapsed
        #expect(stored.hasSuffix("\n"))               // single trailing newline
    }

    @Test func upsertWithNilLinterStoresBodyUnchanged() throws {
        let store = try tempStore()
        let messy = "#No space\ntrailing   \n"
        _ = try PageCommand.run(
            .upsert(id: nil, title: "Raw", body: messy),
            in: store, linter: nil)
        let stored = try store.getPage(id: try store.resolveTitleToID("Raw")!).bodyMarkdown
        #expect(stored == messy)
    }

    @Test func compositionFixThenMermaidValidateThenUpsert() throws {
        // AC.2 proof: upsert a body with BOTH cosmetic issues AND a valid
        // ```mermaid block. Assert (a) stored body is normalized, (b) mermaid
        // content is byte-for-byte intact, (c) save succeeded (no abort).
        let l = try repoMarkdownLinter()
        let v = try repoMermaidValidator()
        let store = try tempStore()
        let fence = String(repeating: "`", count: 3)
        // Trailing spaces on the heading + no blank line before the fence.
        let body = "# Title   \n\(fence)mermaid\nflowchart LR\nA-->B\n\(fence)\nmore text"
        let result = try PageCommand.run(
            .upsert(id: nil, title: "Composition", body: body),
            in: store, validator: v, linter: l)
        #expect(result.didCommit)
        let stored = try store.getPage(id: PageID(rawValue: result.output)).bodyMarkdown
        // (a) Normalized: trailing space stripped, blank line before fence.
        #expect(stored.hasPrefix("# Title\n"))
        #expect(stored.contains("\n\n\(fence)mermaid"))
        // (b) Mermaid content byte-for-byte intact.
        #expect(stored.contains("flowchart LR"))
        #expect(stored.contains("A-->B"))
        // (c) Save succeeded (didCommit == true, already asserted).
    }

    @Test func upsertStillBlocksOnInvalidMermaidWithLinter() throws {
        // Regression: markdown fix runs first, but an invalid mermaid block
        // still hard-blocks the save.
        let l = try repoMarkdownLinter()
        let v = try repoMermaidValidator()
        let store = try tempStore()
        let fence = String(repeating: "`", count: 3)
        // `A B` is now VALID under mermaid v11; use a genuinely-invalid block.
        let body = "# Title\n\n\(fence)mermaid\nflowchart LR\nA[unclosed\n\(fence)\n"
        do {
            _ = try PageCommand.run(
                .upsert(id: nil, title: "Bad Mermaid", body: body),
                in: store, validator: v, linter: l)
            Issue.record("expected upsert to abort on invalid mermaid")
        } catch let PageCommand.Failure.message(text) {
            #expect(text.contains("PARSE_ERROR"))
        }
        // No page was written.
        #expect(try store.listPages(sortBy: .lastUpdated).isEmpty)
    }

    // MARK: - Empty-body refusal at the CLI boundary

    @Test func testPageUpssertRefusesEmptyBody() throws {
        let store = try tempStore()
        // 1. Empty body is refused at the CLI boundary.
        do {
            _ = try PageCommand.run(.upsert(id: nil, title: "X", body: ""), in: store)
            Issue.record("expected empty-body upsert to throw")
        } catch let PageCommand.Failure.message(text) {
            #expect(text.contains("empty body"))
        }
        // 2. Whitespace-only body is also refused.
        do {
            _ = try PageCommand.run(.upsert(id: nil, title: "X", body: "  \n\t "), in: store)
            Issue.record("expected whitespace-only upsert to throw")
        } catch let PageCommand.Failure.message(text) {
            #expect(text.contains("empty body"))
        }
        // 3. A non-empty body succeeds, commits, and returns a non-empty id.
        let result = try PageCommand.run(.upsert(id: nil, title: "Y", body: "hello"), in: store)
        #expect(result.didCommit)
        #expect(!result.output.isEmpty)
    }

    // MARK: - source set-active (Phase 2)

    /// AC.8 (wikictl) — `source set-active` nominates an existing markdown
    /// version as the active HEAD (repoints the `source-derived` ref), commits,
    /// and `processedMarkdownHead` follows it.
    @Test func sourceSetActiveRoundTrip() throws {
        let store = try tempStore()
        let pdf = try store.addSource(filename: "doc.pdf", data: Data("%PDF-1.4".utf8))
        let first = try store.recordMarkdownExtraction(
            sourceID: pdf.id, content: "first version",
            backend: .anthropic, sourceVersionID: nil, note: nil, modelVersion: nil)
        usleep(2000)
        _ = try store.recordMarkdownExtraction(
            sourceID: pdf.id, content: "second version",
            backend: .gemini, sourceVersionID: nil, note: nil, modelVersion: nil)
        // Default-active HEAD is the second (MAX id).
        #expect(try store.processedMarkdownHead(sourceID: pdf.id)?.content == "second version")

        let result = try SourceCommand.run(
            .setActive(.id(pdf.id), versionID: first.id), in: store, cwd: "/tmp")
        #expect(result.didCommit)
        #expect(try store.processedMarkdownHead(sourceID: pdf.id)?.id == first.id)
        #expect(try store.processedMarkdownHead(sourceID: pdf.id)?.content == "first version")
    }

    @Test func sourceSetActiveFailsWithoutMarkdown() throws {
        let store = try tempStore()
        let pdf = try store.addSource(filename: "doc.pdf", data: Data("%PDF-1.4".utf8))
        #expect(throws: SourceCommand.Failure.self) {
            try SourceCommand.run(
                .setActive(.id(pdf.id), versionID: PageID(rawValue: "01NOPE")),
                in: store, cwd: "/tmp")
        }
    }

    // MARK: - source info (Phase 3a)

    /// AC.7 — source info prints identity + origin provenance. A website source
    /// shows the provider, plan/URL, and external identity.
    @Test func sourceInfoPrintsWebsiteOrigin() async throws {
        let store = try tempStore()
        let prov = SourceProvenance(
            agentName: "website", activityKind: "fetch",
            plan: "https://example.com/article",
            externalRef: "https://example.com/article",
            externalIdentity: "https://example.com/article")
        let summary = try store.addSource(
            filename: "Article.md", data: Data("# Article".utf8),
            zoteroItemKey: nil, zoteroItemTitle: nil, mimeType: nil,
            provenance: prov)

        let byID = try SourceCommand.run(.info(.id(summary.id)), in: store, cwd: "/tmp")
        guard case .text(let textByID) = byID.payload else {
            Issue.record("expected text payload"); return
        }
        #expect(textByID.contains("provider\twebsite"))
        #expect(textByID.contains("plan\thttps://example.com/article"))
        #expect(textByID.contains("external_identity\thttps://example.com/article"))

        let byName = try SourceCommand.run(.info(.name("Article.md")), in: store, cwd: "/tmp")
        guard case .text(let textByName) = byName.payload else {
            Issue.record("expected text payload"); return
        }
        #expect(textByName.contains("filename\tArticle.md"))
        #expect(textByName.contains("provider\twebsite"))
    }

    /// AC.7 — a local (legacy) source shows the legacy-import provider.
    @Test func sourceInfoPrintsLegacyOrigin() throws {
        let store = try tempStore()
        let summary = try store.addSource(filename: "plain.txt", data: Data("hi".utf8))

        let result = try SourceCommand.run(.info(.id(summary.id)), in: store, cwd: "/tmp")
        guard case .text(let text) = result.payload else {
            Issue.record("expected text payload"); return
        }
        #expect(text.contains("provider\tlegacy-import"))
        #expect(text.contains("filename\tplain.txt"))
        #expect(text.contains("size\t2"))
    }

    @Test func parsesSourceRefresh() throws {
        let invocation = try ArgumentParser.parse(
            ["--wiki", "W", "source", "refresh", "--id", "01ABC"], env: noEnv)
        #expect(invocation.command == .sourceRefresh(.id(PageID(rawValue: "01ABC"))))
    }

    // MARK: - source refresh (Phase 3b)

    /// A fake fetcher returning a canned HTML response.
    struct RefreshFakeFetcher: URLFetchService.URLResourceFetcher {
        var response: URLFetchService.FetchResponse
        func fetch(_ url: URL) async throws -> URLFetchService.FetchResponse { response }
    }

    @Test func sourceRefreshAppendsVersionAndCommits() async throws {
        let store = try tempStore()
        // Seed a website source via a fake fetcher.
        let fetcher = RefreshFakeFetcher(response: URLFetchService.FetchResponse(
            data: Data("<html><body>v1</body></html>".utf8),
            contentType: "text/html", finalURL: URL(string: "https://example.com/p")!))
        let provider = WebsiteMaterializer(rawInput: "https://example.com/p", fetcher: fetcher)
        let source = try await provider.materialize()
        let summary = try store.addSource(
            filename: source.filename, data: source.data,
            zoteroItemKey: nil, zoteroItemTitle: nil, mimeType: nil,
            provenance: source.provenance)
        let historyBefore = try store.contentVersionHistory(sourceID: summary.id).count

        // Refresh via wikictl with updated content.
        let fetcher2 = RefreshFakeFetcher(response: URLFetchService.FetchResponse(
            data: Data("<html><body>v2</body></html>".utf8),
            contentType: "text/html", finalURL: URL(string: "https://example.com/p")!))
        let result = try await SourceCommand.runRefresh(
            .id(summary.id), in: store, fetcher: fetcher2)

        #expect(result.didCommit)
        let historyAfter = try store.contentVersionHistory(sourceID: summary.id).count
        #expect(historyAfter == historyBefore + 1)
    }

    @Test func sourceRefreshByNameNotFound() async throws {
        let store = try tempStore()
        let fetcher = RefreshFakeFetcher(response: URLFetchService.FetchResponse(
            data: Data("x".utf8), contentType: "text/plain",
            finalURL: URL(string: "https://x")!))
        await #expect(throws: SourceCommand.Failure.self) {
            _ = try await SourceCommand.runRefresh(
                .name("Nonexistent"), in: store, fetcher: fetcher)
        }
    }

    // MARK: - admin vacuum-blobs parsing (issue #253)

    @Test func adminVacuumBlobsDefaultsToDryRunNoJSON() throws {
        let invocation = try ArgumentParser.parse(
            ["--wiki", "W", "admin", "vacuum-blobs"], env: noEnv)
        #expect(invocation.command == .admin(.vacuumBlobs(dryRun: true, json: false)))
    }

    @Test func adminVacuumBlobsApplyOptsIntoDelete() throws {
        let invocation = try ArgumentParser.parse(
            ["--wiki", "W", "admin", "vacuum-blobs", "--apply"], env: noEnv)
        #expect(invocation.command == .admin(.vacuumBlobs(dryRun: false, json: false)))
    }

    @Test func adminVacuumBlobsJSONFlag() throws {
        let dry = try ArgumentParser.parse(
            ["--wiki", "W", "admin", "vacuum-blobs", "--json"], env: noEnv)
        #expect(dry.command == .admin(.vacuumBlobs(dryRun: true, json: true)))

        let applied = try ArgumentParser.parse(
            ["--wiki", "W", "admin", "vacuum-blobs", "--apply", "--json"], env: noEnv)
        #expect(applied.command == .admin(.vacuumBlobs(dryRun: false, json: true)))
    }

    // MARK: - admin vacuum-activities parsing (issue #257)

    @Test func adminVacuumActivitiesDefaultsToDryRunNoJSON() throws {
        let invocation = try ArgumentParser.parse(
            ["--wiki", "W", "admin", "vacuum-activities"], env: noEnv)
        #expect(invocation.command == .admin(.vacuumActivities(dryRun: true, json: false)))
    }

    @Test func adminVacuumActivitiesApplyAndJSON() throws {
        let applied = try ArgumentParser.parse(
            ["--wiki", "W", "admin", "vacuum-activities", "--apply"], env: noEnv)
        #expect(applied.command == .admin(.vacuumActivities(dryRun: false, json: false)))

        let json = try ArgumentParser.parse(
            ["--wiki", "W", "admin", "vacuum-activities", "--apply", "--json"], env: noEnv)
        #expect(json.command == .admin(.vacuumActivities(dryRun: false, json: true)))
    }

    // MARK: - admin vacuum-all parsing (issue #257)

    @Test func adminVacuumAllDefaultsToDryRunNoJSON() throws {
        let invocation = try ArgumentParser.parse(
            ["--wiki", "W", "admin", "vacuum-all"], env: noEnv)
        #expect(invocation.command == .admin(.vacuumAll(dryRun: true, json: false)))
    }

    @Test func adminVacuumAllApplyAndJSON() throws {
        let applied = try ArgumentParser.parse(
            ["--wiki", "W", "admin", "vacuum-all", "--apply"], env: noEnv)
        #expect(applied.command == .admin(.vacuumAll(dryRun: false, json: false)))

        let json = try ArgumentParser.parse(
            ["--wiki", "W", "admin", "vacuum-all", "--apply", "--json"], env: noEnv)
        #expect(json.command == .admin(.vacuumAll(dryRun: false, json: true)))
    }

    @Test func adminRequiresSubcommand() {
        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse(["--wiki", "W", "admin"], env: noEnv)
        }
    }

    @Test func adminRejectsUnknownSubcommand() {
        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse(["--wiki", "W", "admin", "frobnicate"], env: noEnv)
        }
    }

    // MARK: - blob GC (store vacuumBlobs, issue #253)

    /// `vacuumBlobs` reaches an orphan the realistic way: a source's bytes live in
    /// a blob reached through its v1 version; deleting the source cascades the
    /// version row but leaves the blob behind — exactly the leak the GC reclaims.
    /// No private table access needed: the report's own counts prove deletion, and
    /// `sourceContent` proves a referenced blob survives.
    @Test func vacuumDryRunReportsOrphanFromDeletedSource() throws {
        let store = try tempStore()
        let a = try store.addSource(filename: "a.bin", data: Data([0x41, 0x42, 0x43, 0x44, 0x45])) // 5 B
        _ = try store.addSource(filename: "b.bin", data: Data([0x01, 0x02, 0x03]))                // 3 B

        // Nothing orphaned while both sources exist.
        #expect(try store.vacuumBlobs(dryRun: true) == .init(orphanCount: 0, bytesReclaimed: 0, applied: false))

        try store.deleteSource(id: a.id)

        // Dry run reports the orphan (5 B) but does NOT delete it.
        let report1 = try store.vacuumBlobs(dryRun: true)
        #expect(report1 == .init(orphanCount: 1, bytesReclaimed: 5, applied: false))
        // Re-running the dry run still sees the same orphan → nothing was deleted.
        let report2 = try store.vacuumBlobs(dryRun: true)
        #expect(report2.orphanCount == 1)
    }

    @Test func vacuumApplyReclaimsOrphanAndPreservesReferencedBlob() throws {
        let store = try tempStore()
        let a = try store.addSource(filename: "a.bin", data: Data([0x41, 0x42, 0x43, 0x44, 0x45])) // 5 B
        let b = try store.addSource(filename: "b.bin", data: Data([0x01, 0x02, 0x03]))            // 3 B
        try store.deleteSource(id: a.id)

        let applied = try store.vacuumBlobs(dryRun: false)
        #expect(applied == .init(orphanCount: 1, bytesReclaimed: 5, applied: true))

        // The still-referenced blob survives and reads back intact.
        #expect(try store.sourceContent(id: b.id) == Data([0x01, 0x02, 0x03]))

        // The orphan is gone; a follow-up sweep is a no-op (idempotent).
        #expect(try store.vacuumBlobs(dryRun: false).orphanCount == 0)
        #expect(try store.vacuumBlobs(dryRun: true).orphanCount == 0)
    }

    @Test func vacuumIsNoOpWhenEverythingIsReferenced() throws {
        let store = try tempStore()
        let a = try store.addSource(filename: "a.bin", data: Data("hello".utf8))
        let b = try store.addSource(filename: "b.bin", data: Data("world!".utf8))

        let applied = try store.vacuumBlobs(dryRun: false)
        #expect(applied.orphanCount == 0)
        #expect(applied.bytesReclaimed == 0)
        // Both sources still fully readable.
        #expect(try store.sourceContent(id: a.id) == Data("hello".utf8))
        #expect(try store.sourceContent(id: b.id) == Data("world!".utf8))
    }

    // MARK: - admin vacuum-blobs dispatch (issue #253)

    @Test func adminVacuumBlobsDryRunDoesNotCommit() throws {
        let store = try tempStore()
        let a = try store.addSource(filename: "a.bin", data: Data([0x41, 0x42, 0x43, 0x44, 0x45]))
        try store.deleteSource(id: a.id)

        let result = try AdminCommand.run(.vacuumBlobs(dryRun: true, json: false), in: store)
        #expect(!result.didCommit)
        guard case .text(let text) = result.payload else {
            Issue.record("expected text payload"); return
        }
        #expect(text.contains("1 orphan blob"))
        #expect(text.contains("reclaimable"))
        #expect(text.contains("dry-run"))
        // Dry run left the orphan in place.
        #expect(try store.vacuumBlobs(dryRun: true).orphanCount == 1)
    }

    @Test func adminVacuumBlobsApplyCommits() throws {
        let store = try tempStore()
        let a = try store.addSource(filename: "a.bin", data: Data([0x41, 0x42, 0x43, 0x44, 0x45]))
        try store.deleteSource(id: a.id)

        let result = try AdminCommand.run(.vacuumBlobs(dryRun: false, json: false), in: store)
        #expect(result.didCommit)
        guard case .text(let text) = result.payload else {
            Issue.record("expected text payload"); return
        }
        #expect(text.contains("reclaimed"))
        #expect(!text.contains("dry-run"))
        // The apply actually deleted the orphan.
        #expect(try store.vacuumBlobs(dryRun: true).orphanCount == 0)
    }

    @Test func adminVacuumBlobsJSONPayloadMatchesReport() throws {
        let store = try tempStore()
        let a = try store.addSource(filename: "a.bin", data: Data([0x41, 0x42, 0x43, 0x44, 0x45]))
        try store.deleteSource(id: a.id)

        let result = try AdminCommand.run(.vacuumBlobs(dryRun: true, json: true), in: store)
        #expect(!result.didCommit)
        guard case .text(let text) = result.payload else {
            Issue.record("expected text payload"); return
        }
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        #expect(object?["orphanCount"] as? Int == 1)
        #expect(object?["bytesReclaimed"] as? Int == 5)
        #expect(object?["applied"] as? Bool == false)
    }

    // MARK: - activity GC (store vacuumActivities, issue #257)

    /// `vacuumActivities` reaches an orphan the same way `vacuumBlobs` does:
    /// a source's import activity lives in `activities`; deleting the source
    /// cascades the version row that referenced it but leaves the activity
    /// behind — exactly the leak the GC reclaims.
    @Test func activityVacuumDryRunReportsOrphanFromDeletedSource() throws {
        let store = try tempStore()
        let a = try store.addSource(filename: "a.bin", data: Data([0x41, 0x42, 0x43]))
        _ = try store.addSource(filename: "b.bin", data: Data([0x01, 0x02, 0x03]))

        // Nothing orphaned while both sources exist.
        #expect(try store.vacuumActivities(dryRun: true) == .init(orphanCount: 0, applied: false))

        try store.deleteSource(id: a.id)

        // Dry run reports the orphan but does NOT delete it.
        let report1 = try store.vacuumActivities(dryRun: true)
        #expect(report1 == .init(orphanCount: 1, applied: false))
        // Re-running the dry run still sees the same orphan.
        let report2 = try store.vacuumActivities(dryRun: true)
        #expect(report2.orphanCount == 1)
    }

    @Test func activityVacuumApplyReclaimsOrphanAndPreservesReferencedActivity() throws {
        let store = try tempStore()
        let a = try store.addSource(filename: "a.bin", data: Data([0x41, 0x42, 0x43]))
        let b = try store.addSource(filename: "b.bin", data: Data([0x01, 0x02, 0x03]))
        try store.deleteSource(id: a.id)

        let applied = try store.vacuumActivities(dryRun: false)
        #expect(applied == .init(orphanCount: 1, applied: true))

        // The still-referenced source reads back fine (its activity survived).
        #expect(try store.sourceContent(id: b.id) == Data([0x01, 0x02, 0x03]))

        // The orphan is gone; a follow-up sweep is a no-op (idempotent).
        #expect(try store.vacuumActivities(dryRun: false).orphanCount == 0)
        #expect(try store.vacuumActivities(dryRun: true).orphanCount == 0)
    }

    @Test func activityVacuumIsNoOpWhenEverythingIsReferenced() throws {
        let store = try tempStore()
        _ = try store.addSource(filename: "a.bin", data: Data("hello".utf8))
        _ = try store.addSource(filename: "b.bin", data: Data("world!".utf8))

        let applied = try store.vacuumActivities(dryRun: false)
        #expect(applied.orphanCount == 0)
    }

    // MARK: - admin vacuum-activities dispatch (issue #257)

    @Test func adminVacuumActivitiesDryRunDoesNotCommit() throws {
        let store = try tempStore()
        let a = try store.addSource(filename: "a.bin", data: Data([0x41, 0x42, 0x43]))
        try store.deleteSource(id: a.id)

        let result = try AdminCommand.run(.vacuumActivities(dryRun: true, json: false), in: store)
        #expect(!result.didCommit)
        guard case .text(let text) = result.payload else {
            Issue.record("expected text payload"); return
        }
        #expect(text.contains("1 orphaned activity"))
        #expect(text.contains("reclaimable"))
        // Dry run left the orphan in place.
        #expect(try store.vacuumActivities(dryRun: true).orphanCount == 1)
    }

    @Test func adminVacuumActivitiesApplyCommits() throws {
        let store = try tempStore()
        let a = try store.addSource(filename: "a.bin", data: Data([0x41, 0x42, 0x43]))
        try store.deleteSource(id: a.id)

        let result = try AdminCommand.run(.vacuumActivities(dryRun: false, json: false), in: store)
        #expect(result.didCommit)
        // The apply actually deleted the orphan.
        #expect(try store.vacuumActivities(dryRun: true).orphanCount == 0)
    }

    @Test func adminVacuumActivitiesJSONPayloadMatchesReport() throws {
        let store = try tempStore()
        let a = try store.addSource(filename: "a.bin", data: Data([0x41, 0x42, 0x43]))
        try store.deleteSource(id: a.id)

        let result = try AdminCommand.run(.vacuumActivities(dryRun: true, json: true), in: store)
        guard case .text(let text) = result.payload else {
            Issue.record("expected text payload"); return
        }
        let data = text.data(using: .utf8)!
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["orphanCount"] as? Int == 1)
        #expect(object?["applied"] as? Bool == false)
    }

    // MARK: - admin vacuum-all dispatch (issue #257)

    @Test func adminVacuumAllDryRunReportsBoth() throws {
        let store = try tempStore()
        let a = try store.addSource(filename: "a.bin", data: Data([0x41, 0x42, 0x43, 0x44, 0x45]))
        try store.deleteSource(id: a.id)

        let result = try AdminCommand.run(.vacuumAll(dryRun: true, json: false), in: store)
        #expect(!result.didCommit)
        guard case .text(let text) = result.payload else {
            Issue.record("expected text payload"); return
        }
        // Both blob and activity orphans are reported in the combined output.
        #expect(text.contains("1 orphan blob"))
        #expect(text.contains("1 orphaned activity"))
        // Dry run left both in place.
        #expect(try store.vacuumBlobs(dryRun: true).orphanCount == 1)
        #expect(try store.vacuumActivities(dryRun: true).orphanCount == 1)
    }

    @Test func adminVacuumAllApplyCommitsAndReclaimsBoth() throws {
        let store = try tempStore()
        let a = try store.addSource(filename: "a.bin", data: Data([0x41, 0x42, 0x43, 0x44, 0x45]))
        try store.deleteSource(id: a.id)

        let result = try AdminCommand.run(.vacuumAll(dryRun: false, json: false), in: store)
        #expect(result.didCommit)
        // Both orphans are gone.
        #expect(try store.vacuumBlobs(dryRun: true).orphanCount == 0)
        #expect(try store.vacuumActivities(dryRun: true).orphanCount == 0)
    }

    @Test func adminVacuumAllJSONPayloadHasBothSections() throws {
        let store = try tempStore()
        let a = try store.addSource(filename: "a.bin", data: Data([0x41, 0x42, 0x43, 0x44, 0x45]))
        try store.deleteSource(id: a.id)

        let result = try AdminCommand.run(.vacuumAll(dryRun: true, json: true), in: store)
        guard case .text(let text) = result.payload else {
            Issue.record("expected text payload"); return
        }
        let data = text.data(using: .utf8)!
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let blobs = object?["blobs"] as? [String: Any]
        let activities = object?["activities"] as? [String: Any]
        #expect(blobs?["orphanCount"] as? Int == 1)
        #expect(activities?["orphanCount"] as? Int == 1)
    }
}
