#if os(macOS)  // File Provider extension — macOS-only (FileProvider framework)
import CryptoKit
import Foundation
import WikiDaemonContract
import WikiFSCore

/// The projection's data source (Phase 6, plans/daemon-only-access.md): the
/// reads `Projection` used to serve straight from a local SQLite connection,
/// now served over the daemon's App Group domain socket through the
/// READ-ONLY `projection` family (`DaemonProjectionWire`). The protocol's
/// methods are one-to-one with the store reads the tree logic performs, so
/// the tree code reads identically — only the data source underneath changed.
///
/// Synchronous by contract: the File Provider enumerators call these from the
/// framework's own callback queues (the same way the historical SQLite reads
/// parked those threads). The production conformer parks ONLY the calling
/// thread, and only up to ``DaemonProjectionClient/Timeouts/operation`` — a
/// stuck daemon becomes a typed availability failure, never a hung
/// enumeration.
///
/// Error contract: conformers throw `WikiStoreError`. The not-found family
/// (`.notFound` / `.sourceNotFound` / `.chatNotFound`) means "the row is
/// gone" — the projection answers nil. Every other case (open failures,
/// transport loss, timeouts) is an AVAILABILITY failure the checked entry
/// points surface as `Projection.StoreUnavailable` — never an empty folder,
/// never a stale cache.
protocol ProjectionSource: Sendable {

    // MARK: Change token

    /// The whole-database change token's raw string.
    func changeToken() throws -> String

    // MARK: Node lookup

    func getPage(id: PageID) throws -> WikiPage
    func getSource(id: SourceID) throws -> SourceSummary
    func getChat(id: ChatID) throws -> ChatSummary
    func getWikiIndex() throws -> WikiIndex
    func getWikiStrategy() throws -> WikiStrategy?
    func pageHeadVersionID(pageID: PageID) throws -> PageVersionID?
    func pageOKFMetadata(
        versionID: PageVersionID, includeCorrected: Bool
    ) throws -> PageOKFTrustMetadata?
    func sourceMarkdownOKFMetadata(
        versionID: SourceMarkdownVersionID, includeCorrected: Bool
    ) throws -> SourceMarkdownOKFTrustMetadata?

    // MARK: Directory listings

    func listAllPagesOrderedByID() throws -> [WikiPage]
    func listAllSourcesOrderedByID() throws -> [IndexGenerators.SourceIndexRow]
    func listAllChatsOrderedByID() throws -> [ChatSummary]
    func listBookmarkNodes() throws -> [BookmarkNode]
    func listAllLinks() throws -> [IndexGenerators.LinkRow]
    func listAllSourceLinks() throws -> [IndexGenerators.LinkRow]
    func listAllLogEntriesOrderedByID() throws -> [LogEntry]
    func sourceLinks(from pageID: PageID) throws -> [PageSourceLink]
    func chatMessages(chatID: ChatID) throws -> [ChatMessage]
    func sourceUsageSignals(
        sourceIDs: [SourceID]
    ) throws -> [SourceID: GRDBWikiStore.SourceUsageSignal]
    func sourceHeadProducers(
        sourceIDs: [SourceID]
    ) throws -> [SourceID: GRDBWikiStore.SourceHeadProducer]
    func processedMarkdownHeadsBySource() throws -> [String: SourceMarkdownVersion]
    func sourceOriginsBySource() throws -> [SourceID: SourceOrigin]
    func siblingImageResolvers() throws -> [SourceID: [String: SourceID]]

    // MARK: Content fetch

    /// One source's verbatim bytes. Oversized replies arrive through the
    /// wire's chunked payload-handle download; the caller sees plain bytes.
    func sourceContent(id: SourceID) throws -> Data
}

/// The production data source: the daemon's projection family over the App
/// Group domain socket. One instance per logical operation (the projection's
/// `ReadScope` holds exactly one — #291: one connection-equivalent per
/// logical operation); the scope's per-pass caches (token, link maps, heads,
/// origins, signals) collapse repeated reads so an enumeration pass issues a
/// bounded number of wire operations.
struct DaemonProjectionClient: ProjectionSource {

    /// Per-call deadlines. Short on purpose: an enumeration must fail
    /// retryably, not hang the extension. Instances may override the
    /// per-operation budget — the socket fixtures do, because CI's slow
    /// runners can exceed the production budget while the fixture daemon
    /// boots.
    enum Timeouts {
        static let operation: TimeInterval = 10
    }

    /// The wiki this client serves (the FP domain's ULID).
    let wikiID: WikiID

    /// Per-operation deadline budget in seconds. Production default:
    /// ``Timeouts/operation``.
    let operationTimeout: TimeInterval

    /// Resolves the listening socket path at call time (the daemon may not
    /// be up when this client is constructed).
    let socketPath: @Sendable () throws -> String

    /// Counting hook for tests (the #291 bound pins the op count per logical
    /// operation). Nil in production.
    let operationCounter: (@Sendable (String) -> Void)?

    init(
        wikiID: WikiID,
        containerDirectory: @escaping @Sendable () throws -> URL,
        operationCounter: (@Sendable (String) -> Void)? = nil,
        operationTimeout: TimeInterval = Timeouts.operation
    ) {
        self.wikiID = wikiID
        self.socketPath = {
            try SearchSocketWire.socketPath(inContainerDirectory: try containerDirectory())
        }
        self.operationCounter = operationCounter
        self.operationTimeout = operationTimeout
    }

    // MARK: Wire plumbing

    /// One operation: connect, framed request, framed reply, decode. The
    /// transport-level failures (`daemonNotRunning`, timeouts, incomplete
    /// frames) map to `WikiStoreError.open` — the availability class the
    /// projection's checked entry points surface as `StoreUnavailable`.
    ///
    /// ASYNC — always awaited inside the detached bridge task, never on the
    /// caller's thread.
    private func run<Reply: Decodable>(
        _ operation: DaemonProjectionOperation, _ wikiID: WikiID,
        payload: Data? = nil, as type: Reply.Type
    ) async throws -> Reply {
        operationCounter?(operation.rawValue)
        let path = try socketPath()
        let request = DaemonDomainRequest(
            requestID: ULID.generate(),
            family: .projection,
            operation: operation.rawValue,
            payload: try envelope(operation: operation, wikiID: wikiID, payload: payload))
        do {
            let envelopeData = try await Self.roundTrip(
                path: path, request: request, timeout: operationTimeout)
            let reply = try DaemonDomainWire.decodeReply(envelopeData)
            if let domainError = reply.error {
                throw domainError
            }
            let projectionReply = try DaemonProjectionWire.decodeReply(
                reply.payload ?? Data())
            if let error = projectionReply.error {
                throw error
            }
            if let handle = projectionReply.oversized {
                let bytes = try await download(handle: handle, wikiID: wikiID)
                return try JSONDecoder().decode(Reply.self, from: bytes)
            }
            guard let result = projectionReply.result else {
                throw WikiStoreError.unexpected(
                    "projection reply carried neither result nor error")
            }
            return try JSONDecoder().decode(Reply.self, from: result)
        } catch let error as WikiStoreError {
            throw error
        } catch let error as DaemonStoreError {
            throw Self.storeError(error)
        } catch let error as DaemonDomainError {
            throw Self.storeError(error)
        } catch let error as SearchSocketError {
            throw Self.storeError(error)
        } catch {
            throw WikiStoreError.open(Self.errorText(error))
        }
    }

    /// Build the projection-family payload bytes for one operation.
    private func envelope(
        operation: DaemonProjectionOperation, wikiID: WikiID, payload: Data?
    ) throws -> Data {
        try DaemonProjectionWire.encode(DaemonProjectionRequest(
            wikiID: wikiID.rawValue,
            operation: operation.rawValue,
            payload: payload))
    }

    /// One connect → send → receive round trip under the operation deadline
    /// (the established one-request-per-connection framing). Runs on the
    /// detached bridge task's thread — the nonblocking I/O machinery parks
    /// only its own Dispatch-source queues.
    private static func roundTrip(
        path: String, request: DaemonDomainRequest, timeout: TimeInterval
    ) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        let encoded = try DaemonDomainWire.encode(request)
        guard encoded.count <= Int(SearchSocketWire.maxFrameSize) else {
            throw WikiStoreError.open(
                "projection request exceeds the socket frame cap")
        }
        let fd = try await SearchSocketIO.connectSocket(path: path, deadline: deadline)
        do {
            try await SearchSocketIO.sendAll(
                fd: fd, bytes: SearchSocketWire.framed(encoded), deadline: deadline)
            var parser = SearchSocketWire.FrameParser()
            while true {
                if let payload = try parser.nextPayload() { return payload }
                switch SearchSocketIO.recvOnce(fd: fd) {
                case .data(let chunk):
                    parser.append(chunk)
                case .eof:
                    throw SearchSocketError.incompleteFrame
                case .again:
                    try await SearchSocketIO.awaitReady(
                        fd: fd, writable: false, deadline: deadline, operation: "recv")
                case .failed(let error):
                    throw error
                }
            }
        } catch {
            close(fd)
            throw error
        }
    }

    /// Chunked download of an oversized reply's stashed bytes (the
    /// payload-handle pattern). One `payloadRead` op per chunk, reassembled
    /// in order, verified against the handle's byte count + SHA-256 before
    /// returning — a partial or corrupted download throws, never truncates.
    private func download(
        handle: DaemonPayloadHandle, wikiID: WikiID
    ) async throws -> Data {
        var chunks: [Data] = []
        var chunkIndex = 0
        while true {
            let reply: DaemonPayloadReadReply = try await run(
                .payloadRead, wikiID,
                payload: try JSONEncoder().encode(DaemonPayloadReadRequest(
                    handleID: handle.id, chunkIndex: chunkIndex)),
                as: DaemonPayloadReadReply.self)
            chunks.append(reply.bytes)
            if reply.isFinal { break }
            chunkIndex += 1
        }
        let bytes = chunks.reduce(into: Data()) { $0.append($1) }
        guard bytes.count == handle.declaredByteCount else {
            throw WikiStoreError.open(
                "projection download byte count mismatch: got "
                    + "\(bytes.count), handle declares \(handle.declaredByteCount)")
        }
        let digest = SHA256.hash(data: bytes)
            .map { String(format: "%02x", $0) }.joined()
        guard digest == handle.sha256Hex else {
            throw WikiStoreError.open("projection download SHA-256 mismatch")
        }
        return bytes
    }

    // MARK: Synchronous bridging

    /// Park the CALLING thread only (the FP framework's callback thread —
    /// never the cooperative pool) until the detached task completes or the
    /// deadline passes. The async work runs on the cooperative pool, which
    /// nothing here blocks, so the completion always lands; a lost or
    /// starved completion surfaces as a typed deadline failure instead of a
    /// hang (the #1051 discipline).
    private func bridge<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let box = BridgeBox<T>()
        Task.detached {
            do {
                box.fulfill(.success(try await operation()))
            } catch {
                box.fulfill(.failure(error))
            }
        }
        let deadline = Date().addingTimeInterval(operationTimeout)
        while !box.isSettled, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.002)
        }
        guard box.isSettled else {
            throw WikiStoreError.open(
                "projection operation exceeded its "
                    + "\(Int(operationTimeout))s deadline")
        }
        return try box.result()
    }

    /// Resume-once carrier for the bridge (an NSLock guards the only
    /// mutable state, per the repo's Sendable discipline).
    // swiftlint:disable:next unchecked_sendable
    private final class BridgeBox<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var outcome: Result<Value, Error>?

        var isSettled: Bool {
            lock.lock(); defer { lock.unlock() }
            return outcome != nil
        }

        func fulfill(_ result: Result<Value, Error>) {
            lock.lock()
            if outcome == nil { outcome = result }
            lock.unlock()
        }

        func result() throws -> Value {
            lock.lock(); defer { lock.unlock() }
            switch outcome {
            case .success(let value): return value
            case .failure(let error): throw error
            case .none:
                throw WikiStoreError.unexpected("bridge settled without a result")
            }
        }
    }

    // MARK: Error mapping

    /// Typed daemon failures → the WikiStoreError family the projection's
    /// read discipline already interprets:
    /// - not-found cases stay not-found (the row is gone → nil, NEVER a
    ///   failure);
    /// - `open` / transport loss / timeouts stay availability failures
    ///   (`.open`) — the FP renders them retryable-unavailable, with no
    ///   stale cache and no silent empty folders.
    static func storeError(_ error: DaemonStoreError) -> WikiStoreError {
        switch error {
        case .notFound(let id):
            return .notFound(PageID(rawValue: id))
        case .sourceNotFound(let id):
            return .sourceNotFound(SourceID(rawValue: id))
        case .chatNotFound(let id):
            return .chatNotFound(ChatID(rawValue: id))
        case .open(let message):
            return .open(message)
        case .sqlite(let code, let message):
            return .sqlite(code: code, message: message)
        case .unexpected(let message):
            return .unexpected(message)
        default:
            return .open(error.localizedDescription)
        }
    }

    /// A domain-envelope rejection (invalid request, unsupported version, a
    /// family/operation the daemon does not serve) is an availability
    /// failure for the projection: the tree cannot answer, and "retry" is
    /// the honest state.
    static func storeError(_ error: DaemonDomainError) -> WikiStoreError {
        .open("\(error.code.rawValue): \(error.message)")
    }

    static func storeError(_ error: SearchSocketError) -> WikiStoreError {
        .open(error.localizedDescription)
    }

    static func errorText(_ error: Error) -> String {
        String(describing: error).prefix(300).description
    }

    // MARK: ProjectionSource (each op = one wire operation)

    func changeToken() throws -> String {
        try bridge {
            let reply: DaemonProjectionChangeTokenReply = try await self.run(
                .changeToken, self.wikiID, as: DaemonProjectionChangeTokenReply.self)
            return reply.token
        }
    }

    func getPage(id: PageID) throws -> WikiPage {
        try bridge {
            let reply: DaemonProjectionGetPageReply = try await self.run(
                .getPage, self.wikiID,
                payload: try JSONEncoder().encode(
                    DaemonProjectionGetPageRequest(id: id.rawValue)),
                as: DaemonProjectionGetPageReply.self)
            return DaemonProjectionMirrors.core(reply.page)
        }
    }

    func getSource(id: SourceID) throws -> SourceSummary {
        try bridge {
            let reply: DaemonProjectionGetSourceReply = try await self.run(
                .getSource, self.wikiID,
                payload: try JSONEncoder().encode(
                    DaemonProjectionGetSourceRequest(id: id.rawValue)),
                as: DaemonProjectionGetSourceReply.self)
            return DaemonProjectionMirrors.core(reply.source)
        }
    }

    func getChat(id: ChatID) throws -> ChatSummary {
        try bridge {
            let reply: DaemonProjectionGetChatReply = try await self.run(
                .getChat, self.wikiID,
                payload: try JSONEncoder().encode(
                    DaemonProjectionGetChatRequest(id: id.rawValue)),
                as: DaemonProjectionGetChatReply.self)
            return DaemonProjectionMirrors.core(reply.chat)
        }
    }

    func getWikiIndex() throws -> WikiIndex {
        try bridge {
            let reply: DaemonProjectionGetWikiIndexReply = try await self.run(
                .getWikiIndex, self.wikiID,
                payload: try JSONEncoder().encode(DaemonProjectionGetWikiIndexRequest()),
                as: DaemonProjectionGetWikiIndexReply.self)
            return WikiIndex(
                body: reply.index.body, updatedAt: reply.index.updatedAt,
                version: reply.index.version)
        }
    }

    func getWikiStrategy() throws -> WikiStrategy? {
        try bridge {
            let reply: DaemonProjectionGetWikiStrategyReply = try await self.run(
                .getWikiStrategy, self.wikiID,
                payload: try JSONEncoder().encode(DaemonProjectionGetWikiStrategyRequest()),
                as: DaemonProjectionGetWikiStrategyReply.self)
            return reply.strategy.map {
                WikiStrategy(
                    name: $0.name, instructions: $0.instructions,
                    revision: WikiStrategyRevision(rawValue: $0.revision),
                    updatedAt: $0.updatedAt)
            }
        }
    }

    func pageHeadVersionID(pageID: PageID) throws -> PageVersionID? {
        try bridge {
            let reply: DaemonProjectionPageHeadVersionIDReply = try await self.run(
                .pageHeadVersionID, self.wikiID,
                payload: try JSONEncoder().encode(
                    DaemonProjectionPageHeadVersionIDRequest(pageID: pageID.rawValue)),
                as: DaemonProjectionPageHeadVersionIDReply.self)
            return reply.versionID.map(PageVersionID.init(rawValue:))
        }
    }

    func pageOKFMetadata(
        versionID: PageVersionID, includeCorrected: Bool
    ) throws -> PageOKFTrustMetadata? {
        try bridge {
            let reply: DaemonProjectionPageOKFMetadataReply = try await self.run(
                .pageOKFMetadata, self.wikiID,
                payload: try JSONEncoder().encode(DaemonProjectionPageOKFMetadataRequest(
                    versionID: versionID.rawValue, includeCorrected: includeCorrected)),
                as: DaemonProjectionPageOKFMetadataReply.self)
            return try reply.metadata.map(DaemonProjectionMirrors.core)
        }
    }

    func sourceMarkdownOKFMetadata(
        versionID: SourceMarkdownVersionID, includeCorrected: Bool
    ) throws -> SourceMarkdownOKFTrustMetadata? {
        try bridge {
            let reply: DaemonProjectionSourceMarkdownOKFMetadataReply = try await self.run(
                .sourceMarkdownOKFMetadata, self.wikiID,
                payload: try JSONEncoder().encode(
                    DaemonProjectionSourceMarkdownOKFMetadataRequest(
                        versionID: versionID.rawValue,
                        includeCorrected: includeCorrected)),
                as: DaemonProjectionSourceMarkdownOKFMetadataReply.self)
            return try reply.metadata.map(DaemonProjectionMirrors.core)
        }
    }

    func listAllPagesOrderedByID() throws -> [WikiPage] {
        try bridge {
            let reply: DaemonProjectionListAllPagesReply = try await self.run(
                .listAllPages, self.wikiID,
                payload: try JSONEncoder().encode(DaemonProjectionListRequest()),
                as: DaemonProjectionListAllPagesReply.self)
            return reply.pages.map(DaemonProjectionMirrors.core)
        }
    }

    func listAllSourcesOrderedByID() throws -> [IndexGenerators.SourceIndexRow] {
        try bridge {
            let reply: DaemonProjectionListAllSourcesReply = try await self.run(
                .listAllSources, self.wikiID,
                payload: try JSONEncoder().encode(DaemonProjectionListRequest()),
                as: DaemonProjectionListAllSourcesReply.self)
            return reply.sources.map(DaemonProjectionMirrors.core)
        }
    }

    func listAllChatsOrderedByID() throws -> [ChatSummary] {
        try bridge {
            let reply: DaemonProjectionListAllChatsReply = try await self.run(
                .listAllChats, self.wikiID,
                payload: try JSONEncoder().encode(DaemonProjectionListRequest()),
                as: DaemonProjectionListAllChatsReply.self)
            return reply.chats.map(DaemonProjectionMirrors.core)
        }
    }

    func listBookmarkNodes() throws -> [BookmarkNode] {
        try bridge {
            let reply: DaemonProjectionListBookmarkNodesReply = try await self.run(
                .listBookmarkNodes, self.wikiID,
                payload: try JSONEncoder().encode(DaemonProjectionListRequest()),
                as: DaemonProjectionListBookmarkNodesReply.self)
            return try reply.nodes.map(DaemonProjectionMirrors.core)
        }
    }

    func listAllLinks() throws -> [IndexGenerators.LinkRow] {
        try bridge {
            let reply: DaemonProjectionListAllLinksReply = try await self.run(
                .listAllLinks, self.wikiID,
                payload: try JSONEncoder().encode(DaemonProjectionListRequest()),
                as: DaemonProjectionListAllLinksReply.self)
            return reply.links.map(DaemonProjectionMirrors.coreLinkRow)
        }
    }

    func listAllSourceLinks() throws -> [IndexGenerators.LinkRow] {
        try bridge {
            let reply: DaemonProjectionListAllLinksReply = try await self.run(
                .listAllSourceLinks, self.wikiID,
                payload: try JSONEncoder().encode(DaemonProjectionListRequest()),
                as: DaemonProjectionListAllLinksReply.self)
            return reply.links.map(DaemonProjectionMirrors.coreLinkRow)
        }
    }

    func listAllLogEntriesOrderedByID() throws -> [LogEntry] {
        try bridge {
            let reply: DaemonProjectionListLogEntriesReply = try await self.run(
                .listLogEntries, self.wikiID,
                payload: try JSONEncoder().encode(DaemonProjectionListRequest()),
                as: DaemonProjectionListLogEntriesReply.self)
            return reply.entries.map(DaemonProjectionMirrors.core)
        }
    }

    func sourceLinks(from pageID: PageID) throws -> [PageSourceLink] {
        try bridge {
            let reply: DaemonProjectionSourceLinksReply = try await self.run(
                .sourceLinks, self.wikiID,
                payload: try JSONEncoder().encode(
                    DaemonProjectionSourceLinksRequest(pageID: pageID.rawValue)),
                as: DaemonProjectionSourceLinksReply.self)
            return reply.links.map(DaemonProjectionMirrors.core)
        }
    }

    func chatMessages(chatID: ChatID) throws -> [ChatMessage] {
        try bridge {
            let reply: DaemonProjectionChatMessagesReply = try await self.run(
                .chatMessages, self.wikiID,
                payload: try JSONEncoder().encode(
                    DaemonProjectionChatMessagesRequest(chatID: chatID.rawValue)),
                as: DaemonProjectionChatMessagesReply.self)
            return try reply.messages.map(DaemonProjectionMirrors.core)
        }
    }

    func sourceUsageSignals(
        sourceIDs: [SourceID]
    ) throws -> [SourceID: GRDBWikiStore.SourceUsageSignal] {
        try bridge {
            let reply: DaemonProjectionSourceUsageSignalsReply = try await self.run(
                .sourceUsageSignals, self.wikiID,
                payload: try JSONEncoder().encode(DaemonProjectionSourceUsageSignalsRequest(
                    sourceIDs: sourceIDs.map(\.rawValue))),
                as: DaemonProjectionSourceUsageSignalsReply.self)
            var result: [SourceID: GRDBWikiStore.SourceUsageSignal] = [:]
            for entry in reply.entries {
                result[SourceID(rawValue: entry.id)] = GRDBWikiStore.SourceUsageSignal(
                    sourceID: SourceID(rawValue: entry.signal.sourceID),
                    citeCount: entry.signal.citeCount,
                    latestCitingPageUpdatedAt: entry.signal.latestCitingPageUpdatedAt)
            }
            return result
        }
    }

    func sourceHeadProducers(
        sourceIDs: [SourceID]
    ) throws -> [SourceID: GRDBWikiStore.SourceHeadProducer] {
        try bridge {
            let reply: DaemonProjectionSourceHeadProducersReply = try await self.run(
                .sourceHeadProducers, self.wikiID,
                payload: try JSONEncoder().encode(DaemonProjectionSourceHeadProducersRequest(
                    sourceIDs: sourceIDs.map(\.rawValue))),
                as: DaemonProjectionSourceHeadProducersReply.self)
            var result: [SourceID: GRDBWikiStore.SourceHeadProducer] = [:]
            for entry in reply.entries {
                result[SourceID(rawValue: entry.id)] = GRDBWikiStore.SourceHeadProducer(
                    sourceID: SourceID(rawValue: entry.producer.sourceID),
                    producerName: entry.producer.producerName,
                    producerVersion: entry.producer.producerVersion)
            }
            return result
        }
    }

    func processedMarkdownHeadsBySource() throws -> [String: SourceMarkdownVersion] {
        try bridge {
            let reply: DaemonProjectionProcessedMarkdownHeadsReply = try await self.run(
                .processedMarkdownHeads, self.wikiID,
                payload: try JSONEncoder().encode(DaemonProjectionListRequest()),
                as: DaemonProjectionProcessedMarkdownHeadsReply.self)
            var result: [String: SourceMarkdownVersion] = [:]
            for entry in reply.heads {
                result[entry.sourceID] = DaemonProjectionMirrors.core(entry.version)
            }
            return result
        }
    }

    func sourceOriginsBySource() throws -> [SourceID: SourceOrigin] {
        try bridge {
            let reply: DaemonProjectionSourceOriginsReply = try await self.run(
                .sourceOrigins, self.wikiID,
                payload: try JSONEncoder().encode(DaemonProjectionListRequest()),
                as: DaemonProjectionSourceOriginsReply.self)
            var result: [SourceID: SourceOrigin] = [:]
            for entry in reply.entries {
                result[SourceID(rawValue: entry.id)] =
                    DaemonProjectionMirrors.core(entry.origin)
            }
            return result
        }
    }

    func siblingImageResolvers() throws -> [SourceID: [String: SourceID]] {
        try bridge {
            let reply: DaemonProjectionSiblingImageResolversReply = try await self.run(
                .siblingImageResolvers, self.wikiID,
                payload: try JSONEncoder().encode(DaemonProjectionListRequest()),
                as: DaemonProjectionSiblingImageResolversReply.self)
            var result: [SourceID: [String: SourceID]] = [:]
            for entry in reply.entries {
                var images: [String: SourceID] = [:]
                for image in entry.images {
                    images[image.key] = SourceID(rawValue: image.imageID)
                }
                result[SourceID(rawValue: entry.sourceID)] = images
            }
            return result
        }
    }

    func sourceContent(id: SourceID) throws -> Data {
        try bridge {
            let reply: DaemonProjectionSourceContentReply = try await self.run(
                .sourceContent, self.wikiID,
                payload: try JSONEncoder().encode(
                    DaemonProjectionSourceContentRequest(id: id.rawValue)),
                as: DaemonProjectionSourceContentReply.self)
            return reply.bytes
        }
    }
}
#endif
