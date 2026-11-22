#if os(macOS)
import Foundation
import WikiDaemonContract
import WikiFSCore

/// Daemon-side projection service (plans/daemon-only-access.md Phase 6):
/// serves the READ-ONLY `projection` family over the domain socket against
/// the daemon's prepared wiki store. The File Provider extension is a
/// separate process that cannot use XPC, so this service is how it reads:
/// every operation mirrors one read `Projection.swift` makes against the
/// wiki SQLite database today — same rows, same ordering, same absence
/// semantics — with zero local database access client-side.
///
/// Discipline (mirrors ``DaemonStoreCommandExecutor``):
/// - NEVER throws: every failure is a typed reply. A store failure rides
///   INSIDE the ``DaemonProjectionReply`` envelope as ``DaemonStoreError``;
///   only a malformed outer envelope / unknown operation is a domain-level
///   `invalidRequest`.
/// - Store resolution goes through ``WikiDaemon/domainCommandStore(wikiID:)``
///   — the SAME admitted seam the CLI command families use, never a bypass.
///   A wiki the daemon does not host is an availability failure
///   (``DaemonStoreError/open``), not an item-gone not-found: the File
///   Provider must render "unavailable", never delete items.
/// - READ-ONLY: the family dispatches only reads. There is no mutation path
///   to admit, no event capture, no `mutate()` involvement.
/// - Request-scoped: one operation resolves the store, answers, and is done;
///   the service holds no per-client state (the payload handle table is the
///   executor's shared committed-handle store, TTL-bounded).
/// - Frame-safe sizing: an encoded op result at or below
///   ``DaemonProjectionFrameSafety/maxInlineResultBytes`` rides inline;
///   anything larger is stashed as a committed payload handle and the reply
///   carries ``DaemonProjectionReply/oversized`` for the client's chunked
///   `payloadRead` download.
// swiftlint:disable:next unchecked_sendable
final class DaemonProjectionService: @unchecked Sendable {

    /// The daemon whose prepared stores serve the reads, and whose registry
    /// answers `listContainers`. Optional only for tests that drive the
    /// executor pieces directly; a nil daemon answers `daemonUnavailable`.
    private let daemon: WikiDaemon?
    /// The shared committed-handle table (also backs the store family's
    /// `payloadRead`), so stashed oversized replies download through the same
    /// bounded, TTL-swept seam.
    private let staging: DaemonPayloadStagingStore

    init(daemon: WikiDaemon?, staging: DaemonPayloadStagingStore) {
        self.daemon = daemon
        self.staging = staging
    }

    // MARK: - Family entry

    /// Execute one `.projection` family request. Never throws.
    func handleProjectionOperation(
        _ domainRequest: DaemonDomainRequest
    ) async -> DaemonDomainReply {
        guard let payload = domainRequest.payload else {
            return Self.invalidRequest(
                domainRequest, "the projection request carries no payload")
        }
        let request: DaemonProjectionRequest
        do {
            request = try DaemonProjectionWire.decodeRequest(payload)
        } catch {
            return Self.invalidRequest(
                domainRequest,
                "the projection request payload could not be decoded: "
                    + Self.errorText(error))
        }
        guard let operation = DaemonProjectionOperation(rawValue: request.operation) else {
            return Self.invalidRequest(
                domainRequest, "unknown projection operation: \(request.operation)")
        }

        // Chunked download infrastructure: daemon-scoped handle-table reads,
        // no store resolution (the handle already holds the bytes).
        if operation == .payloadRead {
            do {
                let read = try Self.decodePayload(
                    DaemonPayloadReadRequest.self, request.payload)
                let reply = try staging.read(read)
                return successReply(
                    domainRequest, request,
                    try JSONEncoder().encode(reply))
            } catch {
                return projectionErrorReply(domainRequest, request, Self.wireError(error))
            }
        }

        guard let daemon else {
            return projectionErrorReply(
                domainRequest, request,
                .daemonUnavailable("the wiki daemon has been released"))
        }

        // Container listing is registry-scoped, not store-scoped: the FP tree
        // root asks "which containers exist" before any per-wiki resolution.
        if operation == .listContainers {
            do {
                let descriptors = try Self.decodeDescriptors(daemon.listWikis())
                let reply = DaemonProjectionListContainersReply(wikis: descriptors.map {
                    DaemonWikiContainerEntry(id: $0.id.rawValue, displayName: $0.displayName)
                })
                return successReply(
                    domainRequest, request, try JSONEncoder().encode(reply))
            } catch {
                return projectionErrorReply(domainRequest, request, Self.wireError(error))
            }
        }

        // Everything else reads the wiki's prepared store through the
        // admitted seam. A wiki the daemon does not host is an AVAILABILITY
        // failure (the FP domain names a wiki that must exist; "unavailable"
        // renders retryably, a not-found would delete items).
        let store: GRDBWikiStore
        do {
            let anyStore = try await daemon.domainCommandStore(
                wikiID: WikiID(rawValue: request.wikiID))
            guard let concrete = anyStore as? GRDBWikiStore else {
                throw DaemonStoreError.unexpected(
                    "the daemon's prepared store is not the SQLite conformer")
            }
            store = concrete
        } catch let error as DaemonStoreError {
            return projectionErrorReply(
                domainRequest, request,
                .open("wiki \(request.wikiID) is not available: \(error.localizedDescription)"))
        } catch {
            return projectionErrorReply(
                domainRequest, request,
                .open("wiki \(request.wikiID) is not available: \(Self.errorText(error))"))
        }

        do {
            let result = try await dispatch(operation, request, store)
            return successReply(domainRequest, request, result)
        } catch let error as DaemonStoreError {
            return projectionErrorReply(domainRequest, request, error)
        } catch {
            return projectionErrorReply(domainRequest, request, Self.wireError(error))
        }
    }

    // MARK: - Operation dispatch

    /// Dispatch one read against the prepared store and return the encoded
    /// reply DTO bytes (oversized replies are promoted inside
    /// ``successReply``). Each case mirrors ONE `Projection.swift` store read.
    private func dispatch(
        _ operation: DaemonProjectionOperation,
        _ request: DaemonProjectionRequest,
        _ store: GRDBWikiStore
    ) async throws -> Data {
        let encoder = JSONEncoder()
        switch operation {
        case .listContainers, .payloadRead:
            // Handled before store resolution (registry-scoped /
            // daemon-scoped respectively); unreachable here.
            throw DaemonStoreError.unexpected(
                "\(operation.rawValue) is not a per-wiki store read")

        case .changeToken:
            let token = try store.changeToken()
            return try encoder.encode(DaemonProjectionChangeTokenReply(token: token.rawString))

        case .getPage:
            let req = try Self.decodePayload(DaemonProjectionGetPageRequest.self, request.payload)
            let page = try store.getPage(id: PageID(rawValue: req.id))
            return try encoder.encode(DaemonProjectionGetPageReply(page: Self.mirror(page)))

        case .getSource:
            let req = try Self.decodePayload(DaemonProjectionGetSourceRequest.self, request.payload)
            let summary = try store.getSource(id: SourceID(rawValue: req.id))
            return try encoder.encode(
                DaemonProjectionGetSourceReply(source: DaemonStoreMirrorMapping.mirror(summary)))

        case .getChat:
            let req = try Self.decodePayload(DaemonProjectionGetChatRequest.self, request.payload)
            let chat = try store.getChat(id: ChatID(rawValue: req.id))
            return try encoder.encode(
                DaemonProjectionGetChatReply(chat: DaemonStoreMirrorMapping.mirror(chat)))

        case .getWikiIndex:
            _ = try Self.decodePayload(DaemonProjectionListRequest.self, request.payload)
            let index = try store.getWikiIndex()
            return try encoder.encode(DaemonProjectionGetWikiIndexReply(index: DaemonWikiIndexMirror(
                body: index.body, updatedAt: index.updatedAt, version: index.version)))

        case .getWikiStrategy:
            _ = try Self.decodePayload(DaemonProjectionListRequest.self, request.payload)
            let strategy = try store.getWikiStrategy()
            let snapshot = strategy.map {
                DaemonStrategySnapshot(
                    name: $0.name, instructions: $0.instructions,
                    revision: $0.revision.rawValue, updatedAt: $0.updatedAt)
            }
            return try encoder.encode(DaemonProjectionGetWikiStrategyReply(strategy: snapshot))

        case .pageHeadVersionID:
            let req = try Self.decodePayload(
                DaemonProjectionPageHeadVersionIDRequest.self, request.payload)
            let versionID = try store.pageHeadVersionID(pageID: PageID(rawValue: req.pageID))
            return try encoder.encode(
                DaemonProjectionPageHeadVersionIDReply(versionID: versionID?.rawValue))

        case .pageOKFMetadata:
            let req = try Self.decodePayload(
                DaemonProjectionPageOKFMetadataRequest.self, request.payload)
            let metadata = try store.pageOKFMetadata(
                versionID: PageVersionID(rawValue: req.versionID),
                includeCorrected: req.includeCorrected)
            return try encoder.encode(DaemonProjectionPageOKFMetadataReply(
                metadata: metadata.map(DaemonStoreMirrorMapping.mirror)))

        case .sourceMarkdownOKFMetadata:
            let req = try Self.decodePayload(
                DaemonProjectionSourceMarkdownOKFMetadataRequest.self, request.payload)
            let metadata = try store.sourceMarkdownOKFMetadata(
                versionID: SourceMarkdownVersionID(rawValue: req.versionID),
                includeCorrected: req.includeCorrected)
            return try encoder.encode(DaemonProjectionSourceMarkdownOKFMetadataReply(
                metadata: metadata.map(DaemonStoreMirrorMapping.mirror)))

        case .listAllPages:
            _ = try Self.decodePayload(DaemonProjectionListRequest.self, request.payload)
            let pages = try store.listAllPagesOrderedByID()
            return try encoder.encode(
                DaemonProjectionListAllPagesReply(pages: pages.map(Self.mirror)))

        case .listAllSources:
            _ = try Self.decodePayload(DaemonProjectionListRequest.self, request.payload)
            let rows = try store.listAllSourcesOrderedByID()
            return try encoder.encode(
                DaemonProjectionListAllSourcesReply(sources: rows.map(Self.mirror)))

        case .listAllChats:
            _ = try Self.decodePayload(DaemonProjectionListRequest.self, request.payload)
            let chats = try store.listAllChatsOrderedByID()
            return try encoder.encode(
                DaemonProjectionListAllChatsReply(
                    chats: chats.map(DaemonStoreMirrorMapping.mirror)))

        case .listBookmarkNodes:
            _ = try Self.decodePayload(DaemonProjectionListRequest.self, request.payload)
            let nodes = try store.listBookmarkNodes()
            return try encoder.encode(
                DaemonProjectionListBookmarkNodesReply(nodes: nodes.map(Self.mirror)))

        case .listAllLinks:
            _ = try Self.decodePayload(DaemonProjectionListRequest.self, request.payload)
            let links = try store.listAllLinks()
            return try encoder.encode(
                DaemonProjectionListAllLinksReply(links: links.map(Self.mirror)))

        case .listAllSourceLinks:
            _ = try Self.decodePayload(DaemonProjectionListRequest.self, request.payload)
            let links = try store.listAllSourceLinks()
            return try encoder.encode(
                DaemonProjectionListAllLinksReply(links: links.map(Self.mirror)))

        case .listLogEntries:
            _ = try Self.decodePayload(DaemonProjectionListRequest.self, request.payload)
            let entries = try store.listAllLogEntriesOrderedByID()
            return try encoder.encode(
                DaemonProjectionListLogEntriesReply(entries: entries.map(Self.mirror)))

        case .sourceContent:
            let req = try Self.decodePayload(
                DaemonProjectionSourceContentRequest.self, request.payload)
            let bytes = try store.sourceContent(id: SourceID(rawValue: req.id))
            return try encoder.encode(DaemonProjectionSourceContentReply(bytes: bytes))

        case .sourceLinks:
            let req = try Self.decodePayload(
                DaemonProjectionSourceLinksRequest.self, request.payload)
            let links = try store.sourceLinks(from: PageID(rawValue: req.pageID))
            return try encoder.encode(
                DaemonProjectionSourceLinksReply(links: links.map(Self.mirror)))

        case .chatMessages:
            let req = try Self.decodePayload(
                DaemonProjectionChatMessagesRequest.self, request.payload)
            let messages = try store.chatMessages(chatID: ChatID(rawValue: req.chatID))
            return try encoder.encode(
                DaemonProjectionChatMessagesReply(
                    messages: messages.map(DaemonStoreMirrorMapping.mirror)))

        case .sourceUsageSignals:
            let req = try Self.decodePayload(
                DaemonProjectionSourceUsageSignalsRequest.self, request.payload)
            let signals = try store.sourceUsageSignals(
                sourceIDs: req.sourceIDs.map(SourceID.init(rawValue:)))
            let entries = signals.keys.sorted { $0.rawValue < $1.rawValue }.map { id in
                DaemonProjectionUsageSignalEntry(
                    id: id.rawValue,
                    signal: DaemonSourceUsageSignal(
                        sourceID: id.rawValue,
                        citeCount: signals[id]?.citeCount ?? 0,
                        latestCitingPageUpdatedAt: signals[id]?.latestCitingPageUpdatedAt))
            }
            return try encoder.encode(
                DaemonProjectionSourceUsageSignalsReply(entries: entries))

        case .sourceHeadProducers:
            let req = try Self.decodePayload(
                DaemonProjectionSourceHeadProducersRequest.self, request.payload)
            let producers = try store.sourceHeadProducers(
                sourceIDs: req.sourceIDs.map(SourceID.init(rawValue:)))
            let entries = producers.keys.sorted { $0.rawValue < $1.rawValue }.map { id in
                DaemonProjectionHeadProducerEntry(
                    id: id.rawValue,
                    producer: DaemonSourceHeadProducer(
                        sourceID: id.rawValue,
                        producerName: producers[id]?.producerName,
                        producerVersion: producers[id]?.producerVersion))
            }
            return try encoder.encode(
                DaemonProjectionSourceHeadProducersReply(entries: entries))

        case .processedMarkdownHeads:
            _ = try Self.decodePayload(DaemonProjectionListRequest.self, request.payload)
            let heads = try store.processedMarkdownHeadsBySource()
            let entries = heads.keys.sorted { $0 < $1 }.compactMap { sourceID in
                heads[sourceID].map {
                    DaemonProjectionMarkdownHeadEntry(
                        sourceID: sourceID, version: Self.mirror($0))
                }
            }
            return try encoder.encode(
                DaemonProjectionProcessedMarkdownHeadsReply(heads: entries))

        case .sourceOrigins:
            _ = try Self.decodePayload(DaemonProjectionListRequest.self, request.payload)
            let origins = try store.sourceOriginsBySource()
            let entries = origins.keys.sorted { $0.rawValue < $1.rawValue }.compactMap { id in
                origins[id].map {
                    DaemonProjectionOriginEntry(
                        id: id.rawValue,
                        origin: DaemonStoreMirrorMapping.mirror($0))
                }
            }
            return try encoder.encode(
                DaemonProjectionSourceOriginsReply(entries: entries))

        case .siblingImageResolvers:
            _ = try Self.decodePayload(DaemonProjectionListRequest.self, request.payload)
            let resolvers = try store.siblingImageResolvers()
            let entries = resolvers.keys.sorted { $0.rawValue < $1.rawValue }.map { id in
                let images = (resolvers[id] ?? [:]).keys.sorted().map { key in
                    DaemonProjectionSiblingImage(
                        key: key, imageID: resolvers[id]?[key]?.rawValue ?? "")
                }
                return DaemonProjectionSiblingImageResolverEntry(
                    sourceID: id.rawValue, images: images)
            }
            return try encoder.encode(
                DaemonProjectionSiblingImageResolversReply(entries: entries))
        }
    }

    // MARK: - Reply shaping

    /// Encode the op result; promote an oversized result into a committed
    /// payload handle so the reply envelope ALWAYS fits the frame cap. The
    /// promotion threshold is on the RAW result bytes (conservative: the
    /// envelope layers inflate 4/3 each — see ``DaemonProjectionFrameSafety``).
    private func successReply(
        _ domainRequest: DaemonDomainRequest,
        _ request: DaemonProjectionRequest,
        _ result: Data
    ) -> DaemonDomainReply {
        let reply: DaemonProjectionReply
        if DaemonProjectionFrameSafety.fitsInline(rawResultByteCount: result.count) {
            reply = DaemonProjectionReply(result: result)
        } else {
            let handle = staging.stashCommitted(result)
            reply = DaemonProjectionReply(oversized: handle)
        }
        let payload: Data
        do {
            payload = try DaemonProjectionWire.encode(reply)
        } catch {
            return Self.invalidRequest(
                domainRequest,
                "projection reply encoding failed: \(Self.errorText(error))")
        }
        return .success(
            requestID: domainRequest.requestID,
            family: .projection,
            operation: request.operation,
            payload: payload)
    }

    /// A typed store-level rejection INSIDE the projection reply envelope.
    private func projectionErrorReply(
        _ domainRequest: DaemonDomainRequest,
        _ request: DaemonProjectionRequest,
        _ error: DaemonStoreError
    ) -> DaemonDomainReply {
        let payload: Data
        do {
            payload = try DaemonProjectionWire.encode(
                DaemonProjectionReply(error: error))
        } catch {
            return Self.invalidRequest(
                domainRequest,
                "projection error reply encoding failed: \(Self.errorText(error))")
        }
        return .success(
            requestID: domainRequest.requestID,
            family: .projection,
            operation: request.operation,
            payload: payload)
    }

    // MARK: - Shared helpers (same shape as the store executor's)

    private static func invalidRequest(
        _ domainRequest: DaemonDomainRequest, _ message: String
    ) -> DaemonDomainReply {
        .failure(
            requestID: domainRequest.requestID,
            family: domainRequest.family,
            operation: domainRequest.operation,
            DaemonDomainError(code: .invalidRequest, message: message))
    }

    private static func errorText(_ error: Error) -> String {
        String(describing: error).prefix(300).description
    }

    private static func wireError(_ error: Error) -> DaemonStoreError {
        // The store throws WikiStoreError natively; the store executor owns
        // the exhaustive WikiStoreError → wire mapping (associated values
        // intact). Reuse it — a local mapping here would stringify every
        // typed case into .unexpected and lose the not-found family the
        // File Provider projection depends on (gone row → nil, not error).
        DaemonStoreCommandExecutor.wireError(error)
    }

    private static func decodePayload<Payload: Decodable>(
        _ type: Payload.Type, _ data: Data?
    ) throws -> Payload {
        guard let data else {
            throw DaemonStoreError.unexpected("projection operation carries no payload")
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw DaemonStoreError.unexpected(
                "projection payload could not be decoded: \(errorText(error))")
        }
    }

    /// Decode the registry's descriptor-array JSON bytes (`daemon.listWikis()`).
    private static func decodeDescriptors(_ data: Data?) throws -> [WikiDescriptor] {
        guard let data else { return [] }
        do {
            return try JSONDecoder().decode([WikiDescriptor].self, from: data)
        } catch {
            // A single-descriptor shape is tolerated for older registries;
            // a failed fallback decode falls through to the typed error just
            // below, so the failure is not silently swallowed.
            // swiftlint:disable:next silent_try_optional
            if let single = try? JSONDecoder().decode(WikiDescriptor.self, from: data) {
                return [single]
            }
            throw DaemonStoreError.unexpected(
                "wiki registry listing could not be decoded: \(errorText(error))")
        }
    }

    // MARK: - Mirror mapping (projection-only core shapes)

    private static func mirror(_ page: WikiPage) -> DaemonWikiPage {
        DaemonWikiPage(
            id: page.id.rawValue, title: page.title, slug: page.slug,
            bodyMarkdown: page.bodyMarkdown, createdAt: page.createdAt,
            updatedAt: page.updatedAt, version: page.version,
            createdBy: page.createdBy, lastEditedBy: page.lastEditedBy)
    }

    private static func mirror(_ entry: LogEntry) -> DaemonLogEntry {
        DaemonLogEntry(
            id: entry.id.rawValue, timestamp: entry.timestamp,
            kind: DaemonLogEntry.Kind(rawValue: entry.kind.rawValue) ?? .ingest,
            title: entry.title, note: entry.note)
    }

    private static func mirror(_ node: BookmarkNode) -> DaemonBookmarkNode {
        let content: DaemonBookmarkContent
        switch node.content {
        case .folder(let label):
            content = .folder(label: label)
        case .page(let id):
            content = .page(id: id.rawValue)
        case .source(let id):
            content = .source(id: id.rawValue)
        case .chat(let id):
            content = .chat(id: id.rawValue)
        }
        return DaemonBookmarkNode(
            id: node.id.rawValue, parentID: node.parentID?.rawValue,
            position: node.position, content: content,
            createdAt: node.createdAt, updatedAt: node.updatedAt)
    }

    private static func mirror(_ row: IndexGenerators.LinkRow) -> DaemonLinkRow {
        DaemonLinkRow(
            from: row.from, to: row.to, linkText: row.linkText, type: row.type)
    }

    private static func mirror(_ row: IndexGenerators.SourceIndexRow) -> DaemonSourceIndexRow {
        DaemonSourceIndexRow(
            id: row.id, filename: row.filename, ext: row.ext, mime: row.mime,
            byteSize: row.byteSize, createdAt: row.createdAt,
            updatedAt: row.updatedAt, version: row.version,
            displayName: row.displayName, hasMarkdown: row.hasMarkdown)
    }

    private static func mirror(_ version: SourceMarkdownVersion) -> DaemonSourceMarkdownVersionMirror {
        DaemonSourceMarkdownVersionMirror(
            id: version.id.rawValue, sourceID: version.sourceID.rawValue,
            parentID: version.parentID?.rawValue, content: version.content,
            origin: version.origin.rawValue, note: version.note,
            createdAt: version.createdAt, activityID: version.activityID,
            sourceVersionID: version.sourceVersionID?.rawValue,
            blobHash: version.blobHash, mimeType: version.mimeType,
            technique: version.technique)
    }

    private static func mirror(_ link: PageSourceLink) -> DaemonPageSourceLink {
        DaemonPageSourceLink(
            pageID: link.pageID.rawValue, sourceID: link.sourceID.rawValue,
            linkText: link.linkText, role: link.role.rawValue)
    }
}
#endif
