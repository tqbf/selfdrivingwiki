import Foundation
import Testing
@testable import WikiFSCore

/// Verifies `WikiStoreModel.importFromMarkdownFolder` lands every `.md` file from a
/// real temp directory into `sources`, byte-identical, and correctly reports
/// errors. Uses a real `SQLiteWikiStore` + real temp directory fixtures — no external
/// dependencies.
@MainActor
struct WikiStoreModelMarkdownImportTests {

    private func tempStore() throws -> SQLiteWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-mdimport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try SQLiteWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }

    /// Creates a temp directory with the given file tree: `[relativePath: content]`.
    /// Subdirectories are created automatically from the path components.
    private func tempMarkdownDir(
        files: [String: String],
        alsoCreate extraDirs: [String] = []
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdimport-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (relPath, content) in files {
            let fileURL = root.appendingPathComponent(relPath)
            let parent = fileURL.deletingLastPathComponent()
            if parent.path != root.path {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            try Data(content.utf8).write(to: fileURL)
        }
        for dir in extraDirs {
            let dirURL = root.appendingPathComponent(dir)
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        }
        return root
    }

    @Test func importsAllDotMDFilesIntoSources() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let dir = try tempMarkdownDir(files: [
            "readme.md": "# Hello",
            "sub/notes.md": "## Section",
            "deep/nested/journal.md": "### Entry",
        ])

        let result = await model.importFromMarkdownFolder(directory: dir)
        model.reloadFromStore()
        #expect(result.imported == 3)
        #expect(result.errors.isEmpty)
        #expect(model.sources.count == 3)
    }

    @Test func filenamesMatchAfterImport() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let dir = try tempMarkdownDir(files: [
            "My Note.md": "# Body",
            "projects/Project Plan.md": "## Plan",
        ])

        _ = await model.importFromMarkdownFolder(directory: dir)
        model.reloadFromStore()
        let filenames = Set(model.sources.map(\.filename))
        #expect(filenames == ["My Note.md", "Project Plan.md"])
    }

    @Test func contentIsByteIdentical() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let body = "# Hello\n\nThis is a **test** with [[wikilinks]] and\nYAML frontmatter.\n"
        let dir = try tempMarkdownDir(files: ["note.md": body])

        _ = await model.importFromMarkdownFolder(directory: dir)
        model.reloadFromStore()
        #expect(model.sources.count == 1)
        let id = model.sources.first!.id
        let storedContent = try store.sourceContent(id: id)
        #expect(storedContent == Data(body.utf8))
    }

    @Test func ignoresUnsupportedFiles() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let dir = try tempMarkdownDir(files: [
            "note.md": "# md",
            "image.png": "png bytes",
            "video.mp4": "mp4",
            "data.txt": "text",
        ])

        let result = await model.importFromMarkdownFolder(directory: dir)
        model.reloadFromStore()
        #expect(result.imported == 1)
        #expect(model.sources.count == 1)
        #expect(model.sources.first?.filename == "note.md")
    }

    @Test func signalsOnPageDidChange() async throws {
        let store = try tempStore()
        store.eventBus = WikiEventBus(wikiID: "test")
        let model = WikiStoreModel(store: store)
        let recorder = SignalRecorder()
        store.eventBus?.subscribe(nil) { recorder.append($0) }
        let dir = try tempMarkdownDir(files: ["note.md": "# Test"])

        _ = await model.importFromMarkdownFolder(directory: dir)
        try await recorder.awaitNonEmpty()
        #expect(recorder.count > 0)
    }

    @Test func handlesEmptyDirectory() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let dir = try tempMarkdownDir(files: [:])

        let result = await model.importFromMarkdownFolder(directory: dir)
        model.reloadFromStore()
        #expect(result.imported == 0)
        #expect(result.errors.isEmpty)
        #expect(model.sources.isEmpty)
    }

    @Test func handlesDirectoryWithOnlyUnsupportedFiles() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let dir = try tempMarkdownDir(files: [
            "image.png": "png",
            "video.mp4": "mp4",
        ])

        let result = await model.importFromMarkdownFolder(directory: dir)
        model.reloadFromStore()
        #expect(result.imported == 0)
        #expect(model.sources.isEmpty)
    }

    @Test func deduplicatesFilenamesFromDifferentSubdirectories() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let dir = try tempMarkdownDir(files: [
            "projects/Note.md": "first note",
            "archive/Note.md": "second note",
            "shared/Note.md": "third note",
        ])

        let result = await model.importFromMarkdownFolder(directory: dir)
        model.reloadFromStore()
        #expect(result.imported == 3)
        #expect(result.errors.isEmpty)
        let filenames = Set(model.sources.map(\.filename))
        #expect(filenames.count == 3)
        #expect(filenames.contains("Note.md"))
        #expect(filenames.contains("Note-1.md"))
        #expect(filenames.contains("Note-2.md"))
    }

    @Test func preservesYAMLFrontmatterAndWikilinks() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let body = """
        ---
        title: My Note
        tags:
          - project
          - active
        created: 2024-01-15
        ---
        # My Note

        See also [[Other Note]] and [[Third|Third Note]].

        > [!warning] Careful
        > This is important.
        """
        let dir = try tempMarkdownDir(files: ["ObsidianNote.md": body])

        _ = await model.importFromMarkdownFolder(directory: dir)
        model.reloadFromStore()
        #expect(model.sources.count == 1)
        let id = model.sources.first!.id
        let stored = try store.sourceContent(id: id)
        let storedString = String(data: stored, encoding: .utf8)!
        #expect(storedString.contains("---"))
        #expect(storedString.contains("title: My Note"))
        #expect(storedString.contains("[[Other Note]]"))
        #expect(storedString.contains("[[Third|Third Note]]"))
        #expect(storedString.contains("> [!warning]"))
    }

    @Test func skipsHiddenDirectoriesLikeObsidianAndGit() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        // Create a directory structure mimicking an Obsidian vault with hidden dirs.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdimport-obsidian-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Visible note
        try Data("# Visible".utf8).write(to: root.appendingPathComponent("visible.md"))

        // Hidden directories (simulating .obsidian, .git, .trash)
        let obsidianDir = root.appendingPathComponent(".obsidian", isDirectory: true)
        try FileManager.default.createDirectory(at: obsidianDir, withIntermediateDirectories: true)
        try Data("# Config".utf8).write(to: obsidianDir.appendingPathComponent("config.md"))

        let gitDir = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)

        let result = await model.importFromMarkdownFolder(directory: root)
        model.reloadFromStore()
        #expect(result.imported == 1)
        #expect(model.sources.first?.filename == "visible.md")
    }

    @Test func importToExistingStoreDoesNotClobberExistingFiles() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)

        // First import
        let dir1 = try tempMarkdownDir(files: ["one.md": "# One"])
        let r1 = await model.importFromMarkdownFolder(directory: dir1)
        model.reloadFromStore()
        #expect(r1.imported == 1)
        let countAfterFirst = model.sources.count

        // Second import
        let dir2 = try tempMarkdownDir(files: ["two.md": "# Two"])
        let r2 = await model.importFromMarkdownFolder(directory: dir2)
        model.reloadFromStore()
        #expect(r2.imported == 1)
        #expect(model.sources.count == countAfterFirst + 1)
    }

    @Test func dotMarkdownExtensionIsAlsoImported() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let dir = try tempMarkdownDir(files: [
            "readme.markdown": "# Readme",
            "notes.MARKDOWN": "# Notes",
        ])

        let result = await model.importFromMarkdownFolder(directory: dir)
        #expect(result.imported == 2)
    }

    // MARK: - Self-seed (MIME-keyed)

    /// processedMarkdownHead(for:) on a markdown-native source self-seeds v1 from
    /// the verbatim bytes (origin "source"). Every source has a chain: PDFs are
    /// seeded from extraction, markdown-native sources self-seed. The seed means
    /// headVersion is never nil — the original content is always available as v1.
    @Test func processedMarkdownHeadOnMdSourceSelfSeedsV1() throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)

        model.addSource(filename: "note.md", data: Data("# Hello".utf8))
        model.reloadFromStore()
        #expect(model.sources.count == 1)
        let source = model.sources[0]

        // Self-seeds: the verbatim bytes become v1 (origin "source").
        let head = model.processedMarkdownHead(for: source)
        #expect(head != nil)
        #expect(head?.content == "# Hello")
        #expect(head?.origin == .source)

        // Chain row was created.
        #expect(try store.hasProcessedMarkdown(sourceID: source.id))
        #expect(try store.processedMarkdownHistory(sourceID: source.id).count == 1)

        // Second call returns the same head — no double-seed.
        let head2 = model.processedMarkdownHead(for: source)
        #expect(head2?.id == head?.id)
        #expect(try store.processedMarkdownHistory(sourceID: source.id).count == 1)
    }

    /// Binary sources (non-text MIME) do NOT self-seed — only markdown-native
    /// sources get a chain from their verbatim bytes.
    @Test func processedMarkdownHeadOnBinarySourceReturnsNil() throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)

        model.addSource(filename: "data.bin", data: Data([0x00, 0x01, 0x02]))
        model.reloadFromStore()
        #expect(model.sources.count == 1)
        let source = model.sources[0]

        #expect(model.processedMarkdownHead(for: source) == nil)
        #expect(try !store.hasProcessedMarkdown(sourceID: source.id))
    }
}
