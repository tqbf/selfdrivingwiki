import Foundation
import SQLite3
import Testing
import CryptoKit
@testable import WikiFSCore

/// Phase 3a tests: provider materialization + real provenance persistence.
/// Covers AC.1–AC.5 (website/Zotero/local/folder provenance, agent idempotency,
/// and the legacy nil-provenance fallback regression).
struct SourceMaterializerTests {

    // MARK: - Test doubles

    /// A fake fetcher returning a canned response.
    struct FakeFetcher: URLFetchService.URLResourceFetcher {
        var response: URLFetchService.FetchResponse

        func fetch(_ url: URL) async throws -> URLFetchService.FetchResponse {
            response
        }
    }

    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-prov-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WikiFS.sqlite")
    }

    private func tempStore() throws -> SQLiteWikiStore {
        try SQLiteWikiStore(databaseURL: tempDatabaseURL())
    }

    private func htmlResponse(_ body: String, url: String) -> URLFetchService.FetchResponse {
        URLFetchService.FetchResponse(
            data: Data(body.utf8), contentType: "text/html; charset=utf-8",
            finalURL: URL(string: url)!)
    }

    /// `#require` can't wrap a throwing call directly, so resolve first.
    private func requireOrigin(_ store: SQLiteWikiStore, _ id: PageID) throws -> SourceOrigin {
        let origin = try store.sourceOrigin(sourceID: id)
        return try #require(origin)
    }

    // MARK: - AC.1: WebsiteMaterializer + store provenance

    @Test func websiteProviderRecordsOriginURL() async throws {
        let fetcher = FakeFetcher(response: htmlResponse(
            "<html><head><title>Example</title></head><body><p>Hi</p></body></html>",
            url: "https://example.com/page"))
        let provider = WebsiteMaterializer(rawInput: "example.com/page", fetcher: fetcher)
        let (source, _) = try await provider.materializeWithPlan()
        let prov = try #require(source.provenance)
        #expect(prov.agentName == "website")
        #expect(prov.activityKind == "fetch")
        #expect(prov.plan == "https://example.com/page")
        #expect(prov.externalIdentity == "https://example.com/page")
        #expect(prov.externalRef == "https://example.com/page")
    }

    @Test func addSourceWebsitePersistsOriginURL() async throws {
        let store = try tempStore()
        let fetcher = FakeFetcher(response: htmlResponse(
            "<html><head><title>Test</title></head><body>x</body></html>",
            url: "https://example.com/article"))
        let provider = WebsiteMaterializer(rawInput: "https://example.com/article", fetcher: fetcher)
        let (source, _) = try await provider.materializeWithPlan()
        let summary = try store.addSource(
            filename: source.filename, data: source.data,
            zoteroItemKey: nil, zoteroItemTitle: nil, mimeType: nil,
            provenance: source.provenance)

        let origin = try requireOrigin(store, summary.id)
        #expect(origin.agentName == "website")
        #expect(origin.activityKind == "fetch")
        #expect(origin.plan == "https://example.com/article")
        #expect(origin.externalIdentity == "https://example.com/article")
        #expect(origin.externalRef == "https://example.com/article")
    }

    /// AC.1 — two website sources from DIFFERENT URLs each return their own URL
    /// (proves sourceOrigin reads the per-ingest activity row, not the shared
    /// first-writer-wins agent row).
    @Test func twoWebsiteSourcesKeepDistinctURLs() async throws {
        let store = try tempStore()
        let html = { (title: String) in
            "<html><head><title>\(title)</title></head><body>x</body></html>"
        }
        let p1 = WebsiteMaterializer(rawInput: "https://a.com/one", fetcher: FakeFetcher(
            response: htmlResponse(html("One").replacingOccurrences(of: "x", with: "alpha"),
                                   url: "https://a.com/one")))
        let p2 = WebsiteMaterializer(rawInput: "https://b.com/two", fetcher: FakeFetcher(
            response: htmlResponse(html("Two").replacingOccurrences(of: "x", with: "beta"),
                                   url: "https://b.com/two")))

        let (m1, _) = try await p1.materializeWithPlan()
        let (m2, _) = try await p2.materializeWithPlan()
        let s1 = try store.addSource(
            filename: m1.filename, data: m1.data, zoteroItemKey: nil, zoteroItemTitle: nil,
            mimeType: nil, provenance: m1.provenance)
        let s2 = try store.addSource(
            filename: m2.filename, data: m2.data, zoteroItemKey: nil, zoteroItemTitle: nil,
            mimeType: nil, provenance: m2.provenance)

        let o1 = try requireOrigin(store, s1.id)
        let o2 = try requireOrigin(store, s2.id)
        #expect(o1.plan == "https://a.com/one")
        #expect(o2.plan == "https://b.com/two")
        #expect(o1.externalRef != o2.externalRef)
    }

    // MARK: - AC.5: agent idempotency

    /// AC.5 — two website ingests produce two activities but ONE agents row named
    /// "website" (idempotent ensureAgent).
    @Test func providerAgentIsIdempotent() async throws {
        let url = tempDatabaseURL()
        let store = try SQLiteWikiStore(databaseURL: url)
        let html = { (title: String, body: String) in
            "<html><head><title>\(title)</title></head><body>\(body)</body></html>"
        }
        let p1 = WebsiteMaterializer(rawInput: "https://a.com", fetcher: FakeFetcher(
            response: htmlResponse(html("A", "alpha"), url: "https://a.com")))
        let p2 = WebsiteMaterializer(rawInput: "https://b.com", fetcher: FakeFetcher(
            response: htmlResponse(html("B", "beta"), url: "https://b.com")))
        let (m1, _) = try await p1.materializeWithPlan()
        let (m2, _) = try await p2.materializeWithPlan()
        _ = try store.addSource(
            filename: m1.filename, data: m1.data, zoteroItemKey: nil, zoteroItemTitle: nil,
            mimeType: nil, provenance: m1.provenance)
        _ = try store.addSource(
            filename: m2.filename, data: m2.data, zoteroItemKey: nil, zoteroItemTitle: nil,
            mimeType: nil, provenance: m2.provenance)

        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let agentCount = scalarText(db, "SELECT COUNT(*) FROM agents WHERE name='website';")
        #expect(agentCount == "1")
        // Two activities (one per ingest).
        let actCount = scalarText(db, "SELECT COUNT(*) FROM activities WHERE kind='fetch';")
        #expect(actCount == "2")
    }

    // MARK: - AC.3: LocalFileMaterializer + MarkdownFolderMaterializer

    @Test func localFileProviderReadsBytesAndSetsProvenance() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prov-local-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("note.md")
        try Data("# Hello".utf8).write(to: fileURL)

        let provider = LocalFileMaterializer(fileURL: fileURL)
        let source = try await provider.materialize()
        #expect(source.data == Data("# Hello".utf8))
        let prov = try #require(source.provenance)
        #expect(prov.agentName == "local-file")
        #expect(prov.activityKind == "import")
        #expect(prov.externalIdentity == nil)
    }

    @Test func markdownFolderProviderSetsFolderProvenance() async throws {
        let provider = MarkdownFolderMaterializer(
            filename: "Note.md", data: Data("# Body".utf8), mimeType: "text/markdown")
        let source = try await provider.materialize()
        let prov = try #require(source.provenance)
        #expect(prov.agentName == "markdown-folder")
        #expect(prov.activityKind == "import")
        #expect(source.filename == "Note.md")
    }

    @Test func addSourceLocalAndFolderRecordDistinctAgents() async throws {
        let store = try tempStore()
        let local = try await LocalFileMaterializer(fileURL: writeTempFile(
            "local.txt", Data("x".utf8))).materialize()
        let folder = try await MarkdownFolderMaterializer(
            filename: "f.md", data: Data("y".utf8)).materialize()
        let s1 = try store.addSource(
            filename: local.filename, data: local.data, zoteroItemKey: nil, zoteroItemTitle: nil,
            mimeType: local.mimeType, provenance: local.provenance)
        let s2 = try store.addSource(
            filename: folder.filename, data: folder.data, zoteroItemKey: nil, zoteroItemTitle: nil,
            mimeType: folder.mimeType, provenance: folder.provenance)

        #expect(try store.sourceOrigin(sourceID: s1.id)?.agentName == "local-file")
        #expect(try store.sourceOrigin(sourceID: s2.id)?.agentName == "markdown-folder")
    }

    // MARK: - AC.2: ZoteroMaterializer

    @Test func zoteroProviderSetsItemKeyProvenance() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prov-zotero-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Zotero stores attachments at <storageDir>/storage/<key>/<filename>.
        let attachmentDir = dir.appendingPathComponent("storage", isDirectory: true)
            .appendingPathComponent("ABCD1234", isDirectory: true)
        try FileManager.default.createDirectory(at: attachmentDir, withIntermediateDirectories: true)
        let pdf = attachmentDir.appendingPathComponent("paper.pdf")
        try Data("%PDF".utf8).write(to: pdf)

        let attachment = ZoteroAttachment(
            key: "ABCD1234", parentItem: "PARENT1", linkMode: "imported_file",
            filename: "paper.pdf", contentType: "application/pdf", title: nil)
        let parent = ZoteroItem(
            key: "PARENT1", version: 1, itemType: "journalArticle",
            title: "My Paper", creatorSummary: "Doe", date: "2024")
        let provider = ZoteroMaterializer(
            attachment: attachment, parentItem: parent, zoteroDir: dir)
        let source = try await provider.materialize()
        // AC.4 — assert filename + bytes (not just provenance fields).
        #expect(source.filename == "paper.pdf")
        #expect(source.data == Data("%PDF".utf8))
        let prov = try #require(source.provenance)
        #expect(prov.agentName == "zotero")
        #expect(prov.activityKind == "import")
        #expect(prov.externalIdentity == "PARENT1")
        #expect(source.zoteroItemKey == "PARENT1")
        #expect(source.zoteroItemTitle == "My Paper")
    }

    /// AC.3 — a Zotero HTML attachment now routes through format dispatch and
    /// converts to Markdown (matching what `WebsiteMaterializer` would produce).
    /// Before this refactor it was stored as raw HTML — a latent bug.
    @Test func zoteroHtmlAttachmentConvertsToMarkdown() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prov-zotero-html-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let attachmentDir = dir.appendingPathComponent("storage", isDirectory: true)
            .appendingPathComponent("HTML1234", isDirectory: true)
        try FileManager.default.createDirectory(at: attachmentDir, withIntermediateDirectories: true)
        let htmlFile = attachmentDir.appendingPathComponent("page.html")
        try Data("<html><head><title>Zotero Page</title></head><body><p>Hello world</p></body></html>".utf8)
            .write(to: htmlFile)

        let attachment = ZoteroAttachment(
            key: "HTML1234", parentItem: "PARENT1", linkMode: "imported_file",
            filename: "page.html", contentType: "text/html", title: nil)
        let parent = ZoteroItem(
            key: "PARENT1", version: 1, itemType: "journalArticle",
            title: "HTML Paper", creatorSummary: "Doe", date: "2024")
        let provider = ZoteroMaterializer(
            attachment: attachment, parentItem: parent, zoteroDir: dir)
        let source = try await provider.materialize()

        // The HTML is converted to Markdown; the filename derives from <title>.
        #expect(source.filename == "Zotero Page.md")
        let md = String(data: source.data, encoding: .utf8) ?? ""
        #expect(md.contains("Hello world"))
        #expect(!md.contains("<html>"))
    }

    @Test func addSourceZoteroPersistsAgentAndRetainedColumns() async throws {
        let store = try tempStore()
        let prov = SourceProvenance(
            agentName: "zotero", activityKind: "import", externalIdentity: "KEY123")
        let summary = try store.addSource(
            filename: "paper.pdf", data: Data("%PDF".utf8),
            zoteroItemKey: "KEY123", zoteroItemTitle: "Title",
            mimeType: "application/pdf", provenance: prov)

        let origin = try requireOrigin(store, summary.id)
        #expect(origin.agentName == "zotero")
        #expect(origin.externalIdentity == "KEY123")
        // Retained legacy columns are still populated.
        #expect(summary.zoteroItemKey == "KEY123")
        #expect(summary.zoteroItemTitle == "Title")
    }

    // MARK: - AC.4: nil-provenance legacy fallback

    /// AC.4 — addSource with NO provenance behaves byte-identically to pre-Phase-3:
    /// the legacy-import agent + an 'import' activity, NULL external_identity.
    @Test func addSourceNoProvenanceUsesLegacyAgent() throws {
        let url = tempDatabaseURL()
        let store = try SQLiteWikiStore(databaseURL: url)
        let summary = try store.addSource(filename: "legacy.txt", data: Data("x".utf8))

        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        // The legacy-import agent exists.
        let legacyAgent = scalarText(db, "SELECT COUNT(*) FROM agents WHERE name='legacy-import';")
        #expect(legacyAgent == "1")
        // The activity is an 'import' with NULL plan/external_ref.
        let actKind = scalarText(db, """
        SELECT kind FROM activities a
        JOIN source_versions sv ON sv.activity_id = a.id
        WHERE sv.source_id='\(summary.id.rawValue)';
        """)
        #expect(actKind == "import")
        let nullPlan = scalarText(db, """
        SELECT COUNT(*) FROM activities a
        JOIN source_versions sv ON sv.activity_id = a.id
        WHERE sv.source_id='\(summary.id.rawValue)' AND a.plan IS NULL AND a.external_ref IS NULL;
        """)
        #expect(nullPlan == "1")
        // external_identity is NULL.
        let nullExtID = scalarText(db, """
        SELECT COUNT(*) FROM source_versions
        WHERE source_id='\(summary.id.rawValue)' AND external_identity IS NULL;
        """)
        #expect(nullExtID == "1")
        // sourceOrigin reads the legacy agent name.
        let origin = try requireOrigin(store, summary.id)
        #expect(origin.agentName == "legacy-import")
        #expect(origin.plan == nil)
        #expect(origin.externalIdentity == nil)
    }

    /// AC.4 — appendContentVersion with no provenance stays byte-identical (the
    /// existing appendContentVersionDedupsBlob covers the dedup; this asserts the
    /// activity is still the legacy 'fetch' fallback).
    @Test func appendContentVersionNoProvenanceUsesLegacyAgent() throws {
        let store = try tempStore()
        let source = try store.addSource(filename: "a.txt", data: Data("v1".utf8))
        let version = try store.appendContentVersion(
            sourceID: source.id, data: Data("v2".utf8))
        #expect(version.externalIdentity == nil)
        let origin = try requireOrigin(store, source.id)
        #expect(origin.agentName == "legacy-import")
        #expect(origin.activityKind == "fetch")
    }

    // MARK: - appendContentVersion WITH provenance (forward-compat substrate)

    @Test func appendContentVersionWithProvenanceRecordsAgent() async throws {
        let store = try tempStore()
        let source = try store.addSource(filename: "w.md", data: Data("v1".utf8))
        let prov = SourceProvenance(
            agentName: "website", activityKind: "fetch",
            plan: "https://x.com", externalRef: "https://x.com",
            externalIdentity: "https://x.com")
        let version = try store.appendContentVersion(
            sourceID: source.id, data: Data("v2".utf8), provenance: prov)
        #expect(version.externalIdentity == "https://x.com")
        let origin = try requireOrigin(store, source.id)
        #expect(origin.agentName == "website")
        #expect(origin.plan == "https://x.com")
        #expect(origin.externalIdentity == "https://x.com")
    }

    // MARK: - sourceOrigin unknown id

    @Test func sourceOriginReturnsNilForUnknownID() throws {
        let store = try tempStore()
        let origin = try store.sourceOrigin(sourceID: PageID(rawValue: "UNKNOWN"))
        #expect(origin == nil)
    }

    // MARK: - Helpers

    @discardableResult
    private func writeTempFile(_ name: String, _ data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prov-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func scalarText(_ db: OpaquePointer?, _ sql: String) -> String {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cstr = sqlite3_column_text(stmt, 0) else { return "" }
        return String(cString: cstr)
    }

    // MARK: - Apple Podcasts provenance (AC.5)

    // MARK: - AC.6: security boundary (agent surface cannot reach podcast code)

    /// AC.6 — the agent-surface modules must contain NO reference to any podcast
    /// symbol. This converts the "agent cannot reach the token code" claim from
    /// inspection-only into an executable regression guard.
    ///
    /// Host-environment-dependent: locates the repo root by walking up from
    /// `#filePath` to the `Package.swift` directory, then greps the enumerated
    /// agent-surface files. Acceptable for this repo's dev workflow. Deliberately
    /// OUTSIDE `#if PODCAST_TRANSCRIPTS` so it runs in every config (it greps
    /// source files, not compiled symbols — meaningful regardless of the flag).
    @Test func agentSurfaceHasNoPodcastReferences() throws {
        // Coarse: every podcast type/token in this feature is `Podcast`-prefixed
        // (`PodcastEpisodeURL`, `PodcastTranscriptFetching`, `PodcastTokenProviding`,
        // `PodcastHTTPClient`, `PodcastTranscriptError`, `ApplePodcast*`,
        // `HelperPodcastToken*`, `podcastFetcher`). Any occurrence of "Podcast" in
        // an agent-surface file is itself a smell, so a single token catches them all.
        let symbols = ["ApplePodcast", "Podcast", "podcastFetcher", "HelperPodcastToken"]
        let agentFiles = [
            "Sources/WikiFSCore/OperationCommand.swift",
            "Sources/WikiFSCore/AgentCommandConfig.swift",
            "Sources/WikiFSCore/Core/WikiOperation.swift",
            "Sources/WikiFSCore/Sources/IngestWriteRule.swift",
        ]
        let repoRoot = try #require(Self.locateRepoRoot())
        var hits: [String] = []
        for relPath in agentFiles {
            let path = repoRoot.appendingPathComponent(relPath)
            guard FileManager.default.fileExists(atPath: path.path) else { continue }
            let content = try String(contentsOf: path, encoding: .utf8)
            for symbol in symbols where content.contains(symbol) {
                hits.append("\(relPath): \(symbol)")
            }
        }
        // Also check the prompt layer the agent sees (SystemPrompt + GeneratedPrompts).
        for promptFile in ["Sources/WikiFSCore/Core/SystemPrompt.swift", "Sources/WikiFSCore/GeneratedPrompts.swift"] {
            let path = repoRoot.appendingPathComponent(promptFile)
            guard FileManager.default.fileExists(atPath: path.path) else { continue }
            let content = try String(contentsOf: path, encoding: .utf8)
            for symbol in symbols where content.contains(symbol) {
                hits.append("\(promptFile): \(symbol)")
            }
        }
        #expect(hits.isEmpty, "Agent-surface modules must not reference podcast symbols: \(hits)")
    }

    /// Walk up from `#filePath` to the directory containing `Package.swift`.
    private static func locateRepoRoot() -> URL? {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url = url.deletingLastPathComponent()
        }
        return nil
    }

    #if PODCAST_TRANSCRIPTS
    /// A fake transcript fetcher returning a canned transcript — same shape the
    /// routing/service tests use. `@unchecked Sendable` because it records into
    /// mutable state (serial test access only — read after `await` on one actor).
    final class FakePodcastFetcher: PodcastTranscriptFetching, @unchecked Sendable {
        func transcript(for episode: PodcastEpisodeURL.EpisodeRef) async throws -> PodcastTranscript {
            PodcastTranscript(
                episodeID: episode.id,
                markdown: "SPEAKER_1: Hello from the episode.",
                filename: "chinatalk-\(episode.id)-transcript.md")
        }
    }

    private static let chinaTalkEpisode = PodcastEpisodeURL.EpisodeRef(id: "1000774368453", slug: "chinatalk")
    private static let chinaTalkPageURL = URL(string: "https://podcasts.apple.com/us/podcast/chinatalk/id1289062927?i=1000774368453")!

    /// AC.5 — `ApplePodcastMaterializer.materialize()` produces provenance that
    /// survives a store round-trip: agentName, externalIdentity (episode ID),
    /// plan (the page URL), and the displayLabel.
    @Test func applePodcastProviderPersistsProvenance() async throws {
        let store = try tempStore()
        let provider = ApplePodcastMaterializer(
            episode: Self.chinaTalkEpisode,
            pageURL: Self.chinaTalkPageURL,
            fetcher: FakePodcastFetcher())
        let source = try await provider.materialize()
        let summary = try store.addSource(
            filename: source.filename, data: source.data,
            zoteroItemKey: nil, zoteroItemTitle: nil,
            mimeType: source.mimeType, provenance: source.provenance)

        let origin = try requireOrigin(store, summary.id)
        #expect(origin.agentName == "apple-podcast")
        #expect(origin.activityKind == "fetch")
        #expect(origin.externalIdentity == "1000774368453")
        #expect(origin.plan == Self.chinaTalkPageURL.absoluteString)
        #expect(origin.displayLabel == "Apple Podcast")
    }

    /// displayLabel unit test — the `apple-podcast` arm renders "Apple Podcast",
    /// not the `.capitalized` fallback ("Apple-podcast").
    @Test func applePodcastDisplayLabel() {
        let origin = SourceOrigin(
            agentName: "apple-podcast", activityKind: "fetch",
            plan: nil, externalRef: nil, externalIdentity: nil, fetchedAt: Date())
        #expect(origin.displayLabel == "Apple Podcast")
    }
    #endif

    // MARK: - AC.4/AC.9: Byteless source store tests

    @Test func addBytelessSourceCreatesEmptyBytelessSource() throws {
        let store = try tempStore()
        let summary = try store.addBytelessSource(
            filename: "episode-123-transcript.md", mimeType: "text/markdown",
            provenance: SourceProvenance(
                agentName: "apple-podcast", activityKind: "fetch",
                plan: "https://podcasts.apple.com/x?i=123",
                externalRef: "https://podcasts.apple.com/x?i=123",
                externalIdentity: "123"))

        #expect(summary.byteSize == 0)
        // sourceContent returns empty Data for a byteless source.
        #expect(try store.sourceContent(id: summary.id).isEmpty)
        // Origin preserved.
        let origin = try #require(try store.sourceOrigin(sourceID: summary.id))
        #expect(origin.agentName == "apple-podcast")
        #expect(origin.externalIdentity == "123")
    }

    @Test func bytelessSourceDedupsOnExternalIdentity() throws {
        let store = try tempStore()
        let prov = SourceProvenance(
            agentName: "apple-podcast", activityKind: "fetch",
            plan: "https://podcasts.apple.com/x?i=456",
            externalIdentity: "456")
        _ = try store.addBytelessSource(filename: "a.md", mimeType: nil, provenance: prov)

        // Same external_identity → duplicate.
        #expect(throws: WikiStoreError.self) {
            _ = try store.addBytelessSource(filename: "b.md", mimeType: nil, provenance: prov)
        }
        // Only one source.
        #expect(try store.listSources().count == 1)
    }

    @Test func bytelessAndContentSourceCoexistWithSameIdentity() throws {
        let store = try tempStore()
        // A byteless source with external_identity "X".
        _ = try store.addBytelessSource(
            filename: "ep.md", mimeType: nil,
            provenance: SourceProvenance(
                agentName: "apple-podcast", activityKind: "fetch",
                externalIdentity: "X"))
        // A content source (different content_hash) — coexists (disjoint dedup).
        _ = try store.addSource(
            filename: "doc.txt", data: Data("hello".utf8),
            zoteroItemKey: nil, zoteroItemTitle: nil, mimeType: nil,
            provenance: SourceProvenance(
                agentName: "website", activityKind: "fetch",
                externalIdentity: "X"))
        // Both exist — byteless dedup and content dedup are disjoint.
        #expect(try store.listSources().count == 2)
    }
}
