import Foundation
import Testing
@testable import WikiFSCore

/// #797 Phase 1 — typed page-author provenance. Exercises `PageAuthor` /
/// `AgentKind` round-trip identity, the parse mapping for each
/// `agents.name` convention, the `agentKind` classification, and the
/// store-integration behaviour for the three nil-author leak fixes:
///
/// - AC.4 — rename a chat-authored page → HEAD author is `"user"`,
///   prior version retains `chat:<id>`.
/// - AC.5 — preflight lint auto-fix (`PageUpsert.upsert` with the new
///   `author: PageAuthor.agent("lint").rawValue`) → HEAD is `"agent:lint"`.
/// - AC.6 — daemon bootstrap `createPage(createdBy: PageAuthor.user.rawValue)`
///   → HEAD is `"user"`.
///
/// The store integration tests use the same in-memory `GRDBWikiStore`
/// pattern as `PageVersionTests` (the spec for `tempStore` lives there).
@Suite struct PageAuthorTests {

    // MARK: - Constants

    private static let chatULID = "01JTESTCHAT00000000"
    private static let chatName = "chat:01JTESTCHAT00000000"

    // MARK: - AC.1: round-trip identity

    /// `PageAuthor(rawValue: a.rawValue) == a` for every case.
    @Test("PageAuthor round-trips every case through rawValue", arguments: [
        PageAuthor.user,
        .chat(PageAuthorTests.chatULID),
        .agent("ingest"),
        .agent("lint"),
        .agent("query"),
        .agent("bootstrap"),
        .legacyImport,
        .other("claude-sonnet-4-5-20250929")
    ])
    func roundTripIdentity(_ author: PageAuthor) {
        let parsed = PageAuthor(rawValue: author.rawValue)
        #expect(parsed == author,
                "\(author.rawValue) should round-trip (got \(parsed))")
    }

    // MARK: - AC.2: init(rawValue:) edge cases

    @Test("init(rawValue:) parses nil and empty as .legacyImport")
    func parsesNilAndEmptyAsLegacyImport() {
        #expect(PageAuthor(rawValue: nil) == .legacyImport)
        #expect(PageAuthor(rawValue: "") == .legacyImport)
    }

    @Test("init(rawValue:) parses each convention")
    func parsesEachConvention() {
        #expect(PageAuthor(rawValue: "user") == .user)
        #expect(PageAuthor(rawValue: "legacy-import") == .legacyImport)
        #expect(PageAuthor(rawValue: Self.chatName) == .chat(Self.chatULID))
        #expect(PageAuthor(rawValue: "agent:lint") == .agent("lint"))
        #expect(PageAuthor(rawValue: "agent:ingest") == .agent("ingest"))
        #expect(PageAuthor(rawValue: "agent:query") == .agent("query"))
    }

    @Test("init(rawValue:) preserves unknown values as .other")
    func preservesUnknownAsOther() {
        // A model id or any future value round-trips verbatim.
        let modelID = "claude-sonnet-4-5-20250929"
        #expect(PageAuthor(rawValue: modelID) == .other(modelID))
        // PageAuthor.init(rawValue:) is non-failable (always returns a value —
        // unknown values become .other, never nil), so no optional chaining.
        #expect(PageAuthor(rawValue: modelID).rawValue == modelID)
    }

    @Test("init(rawValue:) strips the chat prefix ResourceKind.chat.linkPrefix")
    func chatPrefixIsSourcedFromResourceKind() {
        // Cross-checks that the parse side drops exactly
        // ResourceKind.chat.linkPrefix ("chat:") from the suffix —
        // so a future change to the link prefix propagates to parsing.
        let prefix = ResourceKind.chat.linkPrefix!
        let id = "01JFFFFFFFFFFFFFF00"
        #expect(PageAuthor(rawValue: prefix + id) == .chat(id))
    }

    @Test("init(rawValue:) strips the 6-char agent: prefix")
    func agentPrefixIsSixChars() {
        // Mirrors the SQL `substr(a.name, 6)` strip for chat: (5 chars + 1)
        // and documents the 6-char agent: prefix drop.
        #expect(PageAuthor(rawValue: "agent:lint").agentKind == .agent)
        if case .agent(let kind) = PageAuthor(rawValue: "agent:lint") {
            #expect(kind == "lint")
        } else {
            Issue.record("agent:lint should parse to .agent(\"lint\")")
        }
    }

    // MARK: - AC.3: agentKind mapping

    @Test("agentKind maps each case to its AgentKind")
    func agentKindMapping() {
        #expect(PageAuthor.user.agentKind == .human)
        #expect(PageAuthor.chat(Self.chatULID).agentKind == .chat)
        #expect(PageAuthor.agent("ingest").agentKind == .agent)
        #expect(PageAuthor.agent("lint").agentKind == .agent)
        #expect(PageAuthor.legacyImport.agentKind == .software)
        #expect(PageAuthor.other("claude-sonnet-4-5-20250929").agentKind == .model)
    }

    // MARK: - chatID accessor

    @Test("chatID returns the ULID only for .chat")
    func chatIDAccessor() {
        #expect(PageAuthor.chat(Self.chatULID).chatID == Self.chatULID)
        #expect(PageAuthor.user.chatID == nil)
        #expect(PageAuthor.agent("lint").chatID == nil)
        #expect(PageAuthor.legacyImport.chatID == nil)
        #expect(PageAuthor.other("some-model").chatID == nil)
    }

    // MARK: - rawValue construction

    @Test("rawValue constructs the canonical string for each case")
    func rawValueConstruction() {
        #expect(PageAuthor.user.rawValue == "user")
        #expect(PageAuthor.chat(Self.chatULID).rawValue == Self.chatName)
        #expect(PageAuthor.agent("lint").rawValue == "agent:lint")
        #expect(PageAuthor.legacyImport.rawValue == "legacy-import")
        #expect(PageAuthor.other("claude-sonnet-4-5-20250929").rawValue
                == "claude-sonnet-4-5-20250929")
    }

    // MARK: - AC.7: AgentKind round-trip + unknown fallback

    @Test("AgentKind round-trips all 5 cases through rawValue")
    func agentKindRoundTrip() {
        for kind in AgentKind.allCases {
            #expect(AgentKind(rawValue: kind.rawValue) == kind,
                    "\(kind.rawValue) should round-trip")
        }
    }

    @Test("AgentKind init(rawValue:) maps nil/empty/unknown to .software")
    func agentKindUnknownFallback() {
        #expect(AgentKind(rawValue: nil) == .software)
        #expect(AgentKind(rawValue: "") == .software)
        #expect(AgentKind(rawValue: "unknown-kind") == .software)
        #expect(AgentKind(rawValue: "future-value") == .software)
    }

    @Test("AgentKind.allCases covers 5 cases")
    func agentKindAllCases() {
        #expect(AgentKind.allCases.count == 5)
        #expect(AgentKind.allCases.contains(.human))
        #expect(AgentKind.allCases.contains(.chat))
        #expect(AgentKind.allCases.contains(.agent))
        #expect(AgentKind.allCases.contains(.software))
        #expect(AgentKind.allCases.contains(.model))
    }

    // MARK: - AC.4, AC.5, AC.6 — store integration

    private func tempStore() throws -> GRDBWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pageauthor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }

    /// AC.4 — Rename a chat-authored page: the store-level write that
    /// `WikiStoreModel.rename(id:to:)` (post-fix) performs is
    /// `store.updatePage(..., lastEditedBy: PageAuthor.user.rawValue)`.
    /// After the edit the HEAD's `agentName` is `"user"` and the prior
    /// version (entry [1] in DESC order) still carries `chat:<id>`.
    @MainActor
    @Test func renameChatAuthoredPageStampsUserOnHead() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Chat-Written",
                                        createdBy: PageAuthor.chat(Self.chatULID).rawValue)

        // The post-fix rename path: user-initiated edit, so the editor
        // identity is PageAuthor.user (NOT nil — the pre-fix nil leaked
        // `legacy-import` here).
        try store.updatePage(id: page.id, title: "Chat-Written",
                             body: "renamed body",
                             lastEditedBy: PageAuthor.user.rawValue)

        // HEAD flips to "user" — the leak is closed.
        let head = try store.pageOrigin(pageID: page.id)
        #expect(head?.agentName == "user",
                "rename should stamp 'user' on HEAD (got \(head?.agentName ?? "nil"))")
        #expect(head?.agentKind == "human")

        // The prior version retains the chat author (provenance survives).
        let history = try store.pageEditHistory(pageID: page.id)
        #expect(history.count >= 2,
                "create + edit must yield ≥2 entries (got \(history.count))")
        // DESC: entry[0] = the edit (HEAD), entry[1] = the root 'import'.
        #expect(history[0].agentName == "user",
                "HEAD entry should be 'user' (got \(history[0].agentName))")
        #expect(history[1].agentName == PageAuthor.chat(Self.chatULID).rawValue,
                "root entry should retain chat:<id> (got \(history[1].agentName))")
        #expect(history[1].agentKind == "chat")
    }

    /// AC.5 — The preflight lint auto-fix (`WikiStoreModel.preflightLint`)
    /// routes through `PageUpsert.upsert(..., author:
    /// PageAuthor.agent("lint").rawValue)`. Verifies the lint author
    /// stamping at the store level: HEAD is `"agent:lint"` (not
    /// `legacy-import`) and `agentKind` is `"agent"`.
    @MainActor
    @Test func preflightLintAutoFixStampsAgentLintOnHead() throws {
        let store = try tempStore()
        // Pre-fix: the page exists with a (legitimate) prior chat author.
        let page = try store.createPage(title: "Lint Target",
                                        createdBy: PageAuthor.chat(Self.chatULID).rawValue)

        // The post-fix lint call: PageUpsert.upsert with the explicit
        // author param (pre-fix this passed nil — leaking legacy-import).
        _ = try PageUpsert.upsert(
            in: store, id: page.id,
            title: "Lint Target", body: "fixed [[links]]",
            author: PageAuthor.agent("lint").rawValue)

        let head = try store.pageOrigin(pageID: page.id)
        #expect(head?.agentName == PageAuthor.agent("lint").rawValue,
                "lint auto-fix should stamp 'agent:lint' (got \(head?.agentName ?? "nil"))")
        #expect(head?.agentKind == "agent",
                "agentKind should be 'agent' (got \(head?.agentKind ?? "nil"))")
    }

    /// AC.6 — The daemon Home bootstrap (`WikiDaemon.createWiki`) calls
    /// `store.createPage(title: "Home", createdBy: PageAuthor.user.rawValue)`
    /// post-fix. Verifies the store stamps `"user"` (not `legacy-import`)
    /// and the activity is `"import"`.
    @MainActor
    @Test func daemonBootstrapCreatePageStampsUser() throws {
        let store = try tempStore()
        // Mirror WikiDaemon.createWiki's Home-page seed (post-fix path).
        _ = try store.createPage(title: "Home",
                                 createdBy: PageAuthor.user.rawValue)

        let pages = try store.listPages(sortBy: .newestFirst)
        #expect(pages.count == 1)
        #expect(pages[0].title == "Home")

        // The Home page's HEAD activity should be `user`, NOT legacy-import.
        let origin = try store.pageOrigin(pageID: pages[0].id)
        #expect(origin?.agentName == "user",
                "daemon bootstrap should stamp 'user' (got \(origin?.agentName ?? "nil"))")
        #expect(origin?.agentKind == "human")
        #expect(origin?.activityKind == "import")
    }
}
