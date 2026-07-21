import Foundation
import WikiFSTypes
import WikiFSSearch

// MARK: - StoreBackedTantivyContentSource

/// `TantivyContentSource` backed by `WikiStore`. Lives in `WikiFSCore` (where
/// the store + event bus live); produces `TantivyContentSnapshot`s that the
/// `TantivyIndexer` (in `WikiFSSearch`) converts into Tantivy documents.
///
/// **Reads are synchronous throws** (the store is a non-actor
/// `@unchecked Sendable` class guarded by its own recursive lock), surfaced as
/// `async` to satisfy the protocol. Per the SQLite concurrency discipline,
/// these reads happen on the indexer actor's executor, off the main actor —
/// the lock serializes them and no statement handle crosses a boundary.
///
/// **Phase 1 shadow index** (plans/tantivy-search-sidecar.md §2.3): the index
/// reflects only the *active* state — pages' current `bodyMarkdown`, sources'
/// processed-markdown HEAD, chats' concatenated message plain text.
final public class StoreBackedTantivyContentSource: TantivyContentSource {
    private let store: WikiStore

    public init(store: WikiStore) {
        self.store = store
    }

    // MARK: - TantivyContentSource

    public func snapshot(ulid: String, kind: TantivyDocumentKind) async throws -> TantivyContentSnapshot? {
        let id = PageID(rawValue: ulid)
        do {
            switch kind {
            case .page:
                let page = try store.getPage(id: id)
                return TantivyContentSnapshot(
                    ulid: ulid,
                    kind: .page,
                    title: page.title,
                    body: page.bodyMarkdown,
                    updatedAt: page.updatedAt,
                    versionSum: UInt64(max(0, page.version))
                )
            case .source:
                // `listSources` is the cheap lookup; processedMarkdownHead
                // gives the active HEAD body (§2.3 — only active version is
                // indexed). A missing HEAD (no extracted markdown yet) is NOT
                // a delete — index the source with an empty body so its title
                // is searchable; the version will re-index when markdown lands.
                let sources = try store.listSources()
                guard let source = sources.first(where: { $0.id == id }) else { return nil }
                let body: String
                if let head = try store.processedMarkdownHead(sourceID: id) {
                    body = head.content
                } else {
                    body = ""
                }
                return TantivyContentSnapshot(
                    ulid: ulid,
                    kind: .source,
                    title: source.effectiveName,
                    body: body,
                    updatedAt: source.updatedAt,
                    versionSum: UInt64(max(0, source.version))
                )
            case .chat:
                let chats = try store.listChats()
                guard let chat = chats.first(where: { $0.id == id }) else { return nil }
                let body = chatBody(chatID: id)
                return TantivyContentSnapshot(
                    ulid: ulid,
                    kind: .chat,
                    title: chat.title,
                    body: body,
                    updatedAt: chat.updatedAt,
                    versionSum: UInt64(max(0, chat.messageCount))
                )
            }
        } catch WikiStoreError.notFound {
            // Race: the resource was deleted between the event emit and this
            // read. Return nil so the indexer mirrors the delete — this is the
            // expected signal, not an error to log.
            return nil
        } catch {
            // A genuine read failure — log it (never bare try?) and treat as
            // "no snapshot available" so the indexer skips this cycle.
            DebugLog.store("StoreBackedTantivyContentSource: snapshot(\(kind) \(ulid)) read failed: \(error)")
            return nil
        }
    }

    public func allSnapshots() async throws -> [TantivyContentSnapshot] {
        var snapshots: [TantivyContentSnapshot] = []
        // Pages
        let pageSummaries: [WikiPageSummary]
        do {
            pageSummaries = try store.listPages(sortBy: .newestFirst)
        } catch {
            DebugLog.store("StoreBackedTantivyContentSource: listPages failed: \(error)")
            pageSummaries = []
        }
        for summary in pageSummaries {
            do {
                let page = try store.getPage(id: summary.id)
                snapshots.append(TantivyContentSnapshot(
                    ulid: summary.id.rawValue,
                    kind: .page,
                    title: page.title,
                    body: page.bodyMarkdown,
                    updatedAt: page.updatedAt,
                    versionSum: UInt64(max(0, page.version))
                ))
            } catch {
                DebugLog.store("StoreBackedTantivyContentSource: page \(summary.id.rawValue) skipped in build: \(error)")
            }
        }
        // Sources
        let sources: [SourceSummary]
        do {
            sources = try store.listSources()
        } catch {
            DebugLog.store("StoreBackedTantivyContentSource: listSources failed: \(error)")
            sources = []
        }
        for source in sources {
            // Missing HEAD (no extraction yet) → empty body; title still
            // searchable. A missing HEAD is not an error worth aborting the
            // build over.
            var body = ""
            if let head = try? store.processedMarkdownHead(sourceID: source.id) {
                body = head.content
            }
            snapshots.append(TantivyContentSnapshot(
                ulid: source.id.rawValue,
                kind: .source,
                title: source.effectiveName,
                body: body,
                updatedAt: source.updatedAt,
                versionSum: UInt64(max(0, source.version))
            ))
        }
        // Chats
        let chats: [ChatSummary]
        do {
            chats = try store.listChats()
        } catch {
            DebugLog.store("StoreBackedTantivyContentSource: listChats failed: \(error)")
            chats = []
        }
        for chat in chats {
            snapshots.append(TantivyContentSnapshot(
                ulid: chat.id.rawValue,
                kind: .chat,
                title: chat.title,
                body: chatBody(chatID: chat.id),
                updatedAt: chat.updatedAt,
                versionSum: UInt64(max(0, chat.messageCount))
            ))
        }
        return snapshots
    }

    // MARK: - Private

    /// Concatenate the plain text of every chat message (user/assistant/tool
    /// events) into one searchable body. `AgentEvent.plainText` already
    /// produces a human-readable rendering per event kind.
    private func chatBody(chatID: PageID) -> String {
        let messages: [ChatMessage]
        do {
            messages = try store.chatMessages(chatID: chatID)
        } catch {
            // A chat with no retrievable messages (e.g. race during deletion)
            // indexes empty body — the title is still searchable. This is an
            // intentional fallback, not a swallowed error: the next event for
            // this chat re-indexes with the real content.
            DebugLog.store("StoreBackedTantivyContentSource: chatMessages(\(chatID.rawValue)) failed: \(error)")
            return ""
        }
        return messages.map(\.event.plainText)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

// MARK: - TantivyShadowSync

#if os(macOS)
/// Wires the `WikiEventBus` to the `TantivySearchService`'s indexer. Subscribes
/// to all resource-change events and forwards kind-specific create/update/
/// delete to the indexer; coarse `.external` events (kind == nil) trigger a
/// full rebuild (plans/tantivy-search-sidecar.md §3.5 — Phase 1: simple,
/// correct; Phase 2+: diff-and-reindex optimization).
///
/// **Lifecycle:** created per wiki session alongside `WikiSession`; owns its
/// subscription token and unsubscribes on `detach()`. Mirrors the
/// `FileProviderFacade.subscribeBus` pattern.
@MainActor
final public class TantivyShadowSync {
    private let service: TantivySearchService
    private let bus: WikiEventBus
    private var token: SubscriptionToken?

    public init(service: TantivySearchService, bus: WikiEventBus) {
        self.service = service
        self.bus = bus
    }

    /// Subscribe to the bus and (best-effort) ensure the index is populated.
    /// The initial build runs on a detached task so it never blocks wiki open.
    public func start() {
        let token = bus.subscribe(nil) { [weak self] event in
            self?.handle(event)
        }
        self.token = token
        // Kick off the initial/empty-index rebuild off the call site. Shadow
        // mode — failures are logged, never fatal.
        Task.detached { [service] in
            await service.rebuildIfNeeded()
        }
    }

    /// Cancel the subscription (call on session teardown / wiki switch).
    public func detach() {
        if let token { bus.unsubscribe(token) }
        token = nil
    }

    // MARK: - Private

    /// Runs on the MainActor (bus dispatches via `@MainActor`). Forwards to
    /// the indexer on the actor's executor via a fire-and-forget `Task` so the
    /// main thread is never blocked by a Tantivy write.
    private func handle(_ event: ResourceChangeEvent) {
        // Coarse / external event (wikictl, cross-process): we can't tell what
        // changed — rebuild from SQLite (§3.5 Phase 1 recommendation).
        guard let kind = event.kind else {
            Task.detached { [service] in await service.rebuild() }
            return
        }
        // Map ResourceKind → TantivyDocumentKind. Only page/source/chat are
        // searched; bookmark/systemPrompt/wikiIndex/log are skipped.
        guard let docKind = Self.docKind(for: kind) else { return }
        let ulid = event.id
        Task.detached { [service] in
            switch event.change {
            case .created, .updated:
                await service.indexer.upsert(ulid: ulid, kind: docKind)
            case .deleted:
                await service.indexer.delete(ulid: ulid, kind: docKind)
            }
        }
    }

    private static func docKind(for kind: ResourceKind) -> TantivyDocumentKind? {
        switch kind {
        case .page: return .page
        case .source: return .source
        case .chat: return .chat
        case .bookmark, .systemPrompt, .wikiIndex, .log: return nil
        }
    }
}
#endif // os(macOS)
