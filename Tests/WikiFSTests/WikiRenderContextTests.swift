import Foundation
import Testing
@testable import WikiFSCore

/// Phase A.1 — `WikiRenderContext` unit tests. Builds a context from a fixture
/// store (a page + a byteful source with an embed + a `@vN` chain + a byteless
/// external-embed source + a broken link) and asserts the four render closures
/// resolve exactly as the reader's inline precompute did:
///   - `isResolved`: canonical ULID + name + loose-key tiers, broken link ghost.
///   - `embedInfo`: name + ext-stripped + id-keyed lookup, external target.
///   - `displayName`: canonical ULID → current name heal.
///   - `pinnedExtractionID`: `@vN` ordinal → chain id, out-of-range → nil.
///
/// Also covers the `WikiStoreModel.renderContext()` memo: rebuild only on
/// page/source mutation, reused otherwise (per-delta renders never touch SQLite).
@MainActor
struct WikiRenderContextTests {

    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wiki-render-ctx-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WikiFS.sqlite")
    }

    /// Fixture: one page, one byteful source ("Paper.pdf") with a 3-deep
    /// `@vN` chain, one byteless YouTube source ("youtube-dQw4w9WgXcQ") for the
    /// external embed path. Returns the store + model + the key ids.
    private func makeFixture() throws -> (store: SQLiteWikiStore,
                                          model: WikiStoreModel,
                                          homeID: PageID,
                                          paperID: PageID,
                                          v1ID: PageID,
                                          v2ID: PageID,
                                          v3ID: PageID,
                                          ytID: PageID) {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let model = WikiStoreModel(store: store)

        // A page.
        let home = try store.createPage(title: "Home")

        // A byteful source with a display name + a 3-version derived chain.
        let paper = try store.addSource(
            filename: "Paper.pdf", data: Data("%PDF".utf8),
            zoteroItemKey: nil, zoteroItemTitle: nil,
            mimeType: "application/pdf", provenance: nil, role: .primary,
            originalPath: nil, activityID: nil)
        try store.renameSource(id: paper.id, to: "My Paper")
        let v1 = try store.appendProcessedMarkdown(
            sourceID: paper.id, content: "v1 body", origin: "extraction", note: nil)
        let v2 = try store.appendProcessedMarkdown(
            sourceID: paper.id, content: "v2 body", origin: "extraction", note: nil)
        let v3 = try store.appendProcessedMarkdown(
            sourceID: paper.id, content: "v3 body", origin: "extraction", note: nil)

        // A byteless YouTube source — exercises the external EmbedTarget path.
        let yt = try store.addBytelessSource(
            filename: "youtube-dQw4w9WgXcQ",
            mimeType: "video/youtube",
            provenance: SourceProvenance(
                agentName: "youtube", activityKind: "fetch",
                plan: "https://youtu.be/dQw4w9WgXcQ",
                externalRef: "https://youtu.be/dQw4w9WgXcQ",
                externalIdentity: "dQw4w9WgXcQ"),
            role: .primary)

        model.reloadFromStore()
        return (store, model, home.id, paper.id, v1.id, v2.id, v3.id, yt.id)
    }

    // MARK: - isResolved

    @Test func isResolvedPageByTitle() throws {
        let (_, model, _, _, _, _, _, _) = try makeFixture()
        let ctx = WikiRenderContext.build(from: model)
        let isResolved = ctx.isResolved
        #expect(isResolved("Home", .page))
        #expect(isResolved("home", .page))           // case-insensitive
        #expect(!isResolved("Ghost Page", .page))    // missing → ghost
    }

    @Test func isResolvedPageByCanonicalULID() throws {
        let (_, model, homeID, _, _, _, _, _) = try makeFixture()
        let ctx = WikiRenderContext.build(from: model)
        let isResolved = ctx.isResolved
        #expect(isResolved(homeID.rawValue, .page))
        #expect(!isResolved(homeID.rawValue, .source))  // page id isn't a source
    }

    @Test func isResolvedSourceByNameAndStrippedAndLoose() throws {
        let (_, model, _, paperID, _, _, _, _) = try makeFixture()
        let ctx = WikiRenderContext.build(from: model)
        let isResolved = ctx.isResolved
        // Display name "My Paper" + filename "Paper.pdf" + ext-stripped "Paper".
        #expect(isResolved("My Paper", .source))
        #expect(isResolved("my paper", .source))        // case-insensitive
        #expect(isResolved("Paper.pdf", .source))       // filename
        #expect(isResolved("Paper", .source))           // ext-stripped
        #expect(isResolved(paperID.rawValue, .source))  // canonical ULID
        // A name with no source → ghost (no loose match either, since it's unique).
        #expect(!isResolved("Nonexistent Source", .source))
    }

    // MARK: - embedInfo

    @Test func embedInfoResolvesBytefulByNameAndId() throws {
        let (_, model, _, paperID, _, _, _, _) = try makeFixture()
        let ctx = WikiRenderContext.build(from: model)
        let embedInfo = ctx.embedInfo
        // By display name, filename, and ext-stripped (lowercased).
        let byDisplay = try #require(embedInfo("my paper"))
        #expect(byDisplay.id == paperID)
        #expect(byDisplay.mimeType == "application/pdf")
        #expect(byDisplay.target == nil)  // byteful → no external target
        let byFile = try #require(embedInfo("paper.pdf"))
        #expect(byFile.id == paperID)
        let byStripped = try #require(embedInfo("paper"))
        #expect(byStripped.id == paperID)
        // By canonical id (lowercased).
        let byID = try #require(embedInfo(paperID.rawValue.lowercased()))
        #expect(byID.id == paperID)
        // Unknown name → nil.
        #expect(embedInfo("nope") == nil)
    }

    @Test func embedInfoResolvesBytelessExternalTarget() throws {
        let (_, model, _, _, _, _, _, ytID) = try makeFixture()
        let ctx = WikiRenderContext.build(from: model)
        let embedInfo = ctx.embedInfo
        let info = try #require(embedInfo("youtube-dqw4w9wgxcq"))
        #expect(info.id == ytID)
        let target = try #require(info.target)
        #expect(target.kind == .iframe)
        // Embed URL carries the reader origin (issue #206: no origin ⇒ error 153).
        #expect(target.url.hasPrefix("https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?"))
        #expect(target.url.contains("origin="))
    }

    // MARK: - displayName

    @Test func displayNameHealsCanonicalULIDToCurrentName() throws {
        let (_, model, homeID, paperID, _, _, _, _) = try makeFixture()
        let ctx = WikiRenderContext.build(from: model)
        let displayName = ctx.displayName
        // Source ULID → current display name (not the filename).
        #expect(displayName(paperID, .source) == "My Paper")
        // Page ULID → current title.
        #expect(displayName(homeID, .page) == "Home")
        // Unknown id → nil (renderer keeps the alias).
        let unknown = PageID(rawValue: "01ZZZZZZZZZZZZZZZZZZZZZZZZ")
        #expect(displayName(unknown, .page) == nil)
        #expect(displayName(unknown, .source) == nil)
    }

    // MARK: - pinnedExtractionID

    @Test func pinnedExtractionIDResolvesOrdinalChain() throws {
        let (_, model, _, paperID, v1ID, v2ID, v3ID, _) = try makeFixture()
        let ctx = WikiRenderContext.build(from: model)
        let pin = ctx.pinnedExtractionID
        // 1-based ordinals into the ULID-asc chain (index 0 = v1).
        #expect(pin(paperID, 1) == v1ID)
        #expect(pin(paperID, 2) == v2ID)
        #expect(pin(paperID, 3) == v3ID)
        // Out-of-range / invalid → nil (link opens HEAD).
        #expect(pin(paperID, 4) == nil)
        #expect(pin(paperID, 0) == nil)   // ordinal must be >= 1
        #expect(pin(paperID, -1) == nil)
        // Unknown source → nil.
        let unknown = PageID(rawValue: "01ZZZZZZZZZZZZZZZZZZZZZZZZ")
        #expect(pin(unknown, 1) == nil)
    }

    // MARK: - memoization + invalidation

    @Test func renderContextMemoReusesUntilMutation() throws {
        let (_, model, _, _, _, _, _, _) = try makeFixture()
        // First call builds.
        let c1 = model.renderContext()
        // Second call (no mutation) returns the cached snapshot — same data.
        let c2 = model.renderContext()
        #expect(c1.pageTitles == c2.pageTitles)
        #expect(c1.sourceIDToName == c2.sourceIDToName)
        #expect(c1.embedMap == c2.embedMap)
        #expect(c1.sourceDerivedChain == c2.sourceDerivedChain)
    }

    @Test func renderContextRebuildsAfterPageMutation() throws {
        let (store, model, _, _, _, _, _, _) = try makeFixture()
        let before = model.renderContext()
        // A page mutation → reloadFromStore → reloadSummaries bumps the generation.
        _ = try store.createPage(title: "Another Page")
        model.reloadFromStore()
        let after = model.renderContext()
        #expect(after.pageTitles.contains("another page"))
        #expect(!before.pageTitles.contains("another page"))
    }

    @Test func renderContextRebuildsAfterSourceMutation() throws {
        let (store, model, _, _, _, _, _, _) = try makeFixture()
        let before = model.renderContext()
        _ = try store.addSource(filename: "extra.txt", data: Data("x".utf8))
        model.reloadFromStore()
        let after = model.renderContext()
        #expect(after.sourceNames.contains("extra.txt"))
        #expect(!before.sourceNames.contains("extra.txt"))
    }

    // MARK: - blob scheme

    @Test func blobSchemeMatchesBlobHandlerConstant() throws {
        let (_, model, _, _, _, _, _, _) = try makeFixture()
        let ctx = WikiRenderContext.build(from: model)
        // The context captures the core constant the reader's BlobSchemeHandler
        // also resolves to — so a transcript render (Phase A.2) rewrites image
        // srcs to the same `wiki-blob://` scheme the reader registers.
        #expect(ctx.blobScheme == WikiLinkMarkdown.blobScheme)
        #expect(ctx.blobScheme == "wiki-blob")
    }
}
