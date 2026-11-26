#if os(macOS)
import Foundation

// Projection wire family (plans/daemon-only-access.md Phase 6): the read-only
// surface the File Provider extension serves its tree from. The extension is a
// separate process that cannot use XPC, so it reads through the App Group
// domain socket; this family mirrors EXACTLY the reads
// `Sources/WikiFSFileProvider/Projection.swift` makes against the wiki SQLite
// database today (container listing, node/row lookups, directory listings,
// document fetches, content bytes, and the whole-database change token).
//
// Shape conventions (inherited from the `store` family, DaemonStoreWire):
// - One operation per request; per-op DTOs ride in `payload` as JSON bytes.
//   Operation DTO names carry a `Projection` infix so the two families never
//   collide; the VALUE mirrors (source rows, chat summaries, bookmark nodes,
//   log entries, OKF trust metadata, chat messages) are REUSED from
//   ``DaemonStoreValueMirrors`` — one shape per value, never two.
// - Typed errors travel INSIDE the reply as ``DaemonStoreError`` — unknown
//   rows keep their distinct not-found cases (`.notFound` / `.sourceNotFound`
//   / `.chatNotFound`), which the File Provider interprets as "the item is
//   gone"; every other failure is an availability failure it renders as
//   retryable/unavailable. A store failure is never stringified into the
//   outer envelope.
// - READ-ONLY: the family declares no mutating operation, and the daemon
//   serves it from its prepared stores through the same admitted seam as the
//   CLI command families. There is no write path to admit.
// - Frame-safe sizing: the daemon encodes the op reply and checks the FINAL
//   OUTER encoded size (``DaemonStoreFrameSizing``); a reply that would not
//   fit the 4 MiB frame cap is stashed as a committed payload handle and the
//   reply carries ``DaemonProjectionReply/oversized`` instead. The client
//   downloads the bytes through the `payloadRead` operation (chunked,
//   ``DaemonStoreLimits/maxChunkBytes`` per chunk) and decodes the original
//   result. Oversized page bodies, source bytes, whole-directory listings,
//   and the processed-markdown heads map all cross through this one path.
//
// Like every file in this module: Foundation-only leaf, no WikiFSCore import,
// `#if os(macOS)` throughout.

// MARK: - Versions

public enum DaemonProjectionWireVersion {
    /// The projection family payload version this daemon serves and this
    /// client speaks. Versioning starts at 1 with the Phase 6 wire.
    public static let current: UInt16 = 1
}

// MARK: - Operation registry

/// The projection family's operation strings — the ONE registry shared by the
/// daemon's projection service and the File Provider's projection client.
/// `rawValue` is the wire operation string inside a `.projection` domain
/// envelope. Names mirror the store reads they serve so a reader can match
/// each op to `Projection.swift`'s call site one-to-one.
public enum DaemonProjectionOperation: String, Codable, Sendable, CaseIterable {

    // MARK: Container listing (wikis)

    /// The wiki containers the daemon hosts (registry descriptors, display
    /// names included). The File Provider's per-domain tree is bound to one
    /// wiki; this op answers "which containers exist".
    case listContainers

    // MARK: Change token (the sync anchor)

    /// The whole-database change token (`GRDBWikiStore.changeToken()`) — the
    /// File Provider's live sync anchor.
    case changeToken

    // MARK: Node lookup (row reads behind the FP tree nodes)

    /// One full page row (metadata + body).
    case getPage
    /// One source row WITHOUT bytes (`SourceSummary`).
    case getSource
    /// One chat row (`ChatSummary`).
    case getChat
    /// The singleton curated catalog (`WikiIndex`).
    case getWikiIndex
    /// The committed strategy document (`WikiStrategy?`; nil = Default).
    case getWikiStrategy
    /// One page's head version id.
    case pageHeadVersionID
    /// One page version's OKF trust metadata.
    case pageOKFMetadata
    /// One source markdown version's OKF trust metadata.
    case sourceMarkdownOKFMetadata

    // MARK: Directory listings (the FP by-id/by-name rows)

    /// All pages, ULID order (`listAllPagesOrderedByID`).
    case listAllPages
    /// All source rows without bytes, ULID order (`listAllSourcesOrderedByID`).
    case listAllSources
    /// All chats, ULID order (`listAllChatsOrderedByID`).
    case listAllChats
    /// The bookmark folder/ref tree (`listBookmarkNodes`).
    case listBookmarkNodes
    /// All page link rows (`listAllLinks`).
    case listAllLinks
    /// All source link rows (`listAllSourceLinks`).
    case listAllSourceLinks
    /// The append-only log, id order (`listAllLogEntriesOrderedByID`).
    case listLogEntries
    /// One page's source links (`sourceLinks(from:)`).
    case sourceLinks
    /// One chat's messages (`chatMessages(chatID:)`).
    case chatMessages
    /// Batched cite-usage signals (`sourceUsageSignals`).
    case sourceUsageSignals
    /// Batched head producers (`sourceHeadProducers`).
    case sourceHeadProducers
    /// Batched processed-markdown heads for ALL sources
    /// (`processedMarkdownHeadsBySource`).
    case processedMarkdownHeads
    /// Batched origin candidates for ALL sources (`sourceOriginsBySource`).
    case sourceOrigins
    /// Batched sibling-image resolvers (`siblingImageResolvers`).
    case siblingImageResolvers

    // MARK: Content fetch (bytes)

    /// One source's verbatim bytes (`sourceContent(id:)`). The bytes ride
    /// inline below the promotion threshold, otherwise the reply is oversized
    /// and the client fetches chunks through `payloadRead`.
    case sourceContent

    // MARK: Chunked download infrastructure

    /// Download one chunk of an oversized reply's stashed bytes. Same
    /// semantics as the store family's `payloadRead`
    /// (`DaemonPayloadReadRequest` / `DaemonPayloadReadReply`); served from
    /// the daemon's committed-handle table.
    case payloadRead
}

// MARK: - Request / reply envelopes

/// The projection family's request payload: the JSON inside a `.projection`
/// domain envelope's `payload`. Read-only by construction — no stamp, no
/// mutation semantics; the daemon rejects any unknown operation string as a
/// typed `invalidRequest`.
public struct DaemonProjectionRequest: Codable, Equatable, Sendable {
    public let version: UInt16
    /// The wiki's raw ULID string (which prepared store serves the reads).
    public let wikiID: String
    /// A ``DaemonProjectionOperation`` raw value.
    public let operation: String
    /// Operation-specific JSON bytes; `nil` where the operation carries none.
    public let payload: Data?

    public init(
        version: UInt16 = DaemonProjectionWireVersion.current,
        wikiID: String,
        operation: String,
        payload: Data? = nil
    ) {
        self.version = version
        self.wikiID = wikiID
        self.operation = operation
        self.payload = payload
    }
}

/// The projection family's reply payload: the JSON inside a `.projection`
/// domain envelope's `payload` on BOTH outcomes. Exactly one of `result`,
/// `error`, or `oversized` is set:
/// - `result` — the operation's reply DTO bytes (JSON), inline.
/// - `error` — the typed rejection (``DaemonStoreError``); not-found cases
///   mean "the row is gone", everything else is an availability failure.
/// - `oversized` — the encoded result exceeded the frame-safe inline budget;
///   the full result JSON is downloadable through `payloadRead` one chunk at
///   a time (integrity: the handle carries the byte count + SHA-256).
public struct DaemonProjectionReply: Codable, Equatable, Sendable {
    public let version: UInt16
    public let result: Data?
    public let error: DaemonStoreError?
    public let oversized: DaemonPayloadHandle?

    public init(
        version: UInt16 = DaemonProjectionWireVersion.current,
        result: Data? = nil,
        error: DaemonStoreError? = nil,
        oversized: DaemonPayloadHandle? = nil
    ) {
        self.version = version
        self.result = result
        self.error = error
        self.oversized = oversized
    }
}

/// Encode/decode for the projection family payload pair. Decode failures are
/// typed — a malformed projection payload is a rejection INSIDE the reply,
/// never a transport fault.
public enum DaemonProjectionWire {
    public static func encode(_ request: DaemonProjectionRequest) throws -> Data {
        try JSONEncoder().encode(request)
    }

    public static func decodeRequest(_ data: Data) throws -> DaemonProjectionRequest {
        let request: DaemonProjectionRequest
        do {
            request = try JSONDecoder().decode(DaemonProjectionRequest.self, from: data)
        } catch {
            throw DaemonStoreError.unexpected(
                "projection request could not be decoded: "
                    + String(describing: error).prefix(200).description)
        }
        guard request.version == DaemonProjectionWireVersion.current else {
            throw DaemonStoreError.unexpected(
                "unsupported projection wire version: \(request.version)")
        }
        return request
    }

    public static func encode(_ reply: DaemonProjectionReply) throws -> Data {
        try JSONEncoder().encode(reply)
    }

    public static func decodeReply(_ data: Data) throws -> DaemonProjectionReply {
        do {
            return try JSONDecoder().decode(DaemonProjectionReply.self, from: data)
        } catch {
            throw DaemonStoreError.unexpected(
                "projection reply could not be decoded: "
                    + String(describing: error).prefix(200).description)
        }
    }

    /// The inline result bytes. `nil` when the reply carried an error or was
    /// oversized — an oversized reply's bytes arrive through the client's own
    /// `payloadRead` reassembly (the handle carries the integrity contract),
    /// so nothing here pretends to decode it.
    public static func inlineResult(_ reply: DaemonProjectionReply) -> Data? {
        reply.result
    }
}

// MARK: - Container listing

/// One wiki container (a trimmed registry descriptor — the projection family
/// never carries lifecycle fields the FP tree does not render).
public struct DaemonWikiContainerEntry: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

public struct DaemonProjectionListContainersRequest: Codable, Equatable, Sendable {
    public init() {}
}

public struct DaemonProjectionListContainersReply: Codable, Equatable, Sendable {
    public let wikis: [DaemonWikiContainerEntry]

    public init(wikis: [DaemonWikiContainerEntry]) {
        self.wikis = wikis
    }
}

// MARK: - Change token

public struct DaemonProjectionChangeTokenRequest: Codable, Equatable, Sendable {
    public init() {}
}

public struct DaemonProjectionChangeTokenReply: Codable, Equatable, Sendable {
    /// The token's raw string (`ChangeToken.rawString`), e.g. `"rev:count"`.
    public let token: String

    public init(token: String) {
        self.token = token
    }
}

// MARK: - Projection value mirrors

// Only the projection-only shapes are declared here. Where the store family
// already mirrors the value (``DaemonSourceSummary``, ``DaemonChatSummary``,
// ``DaemonBookmarkNode``, ``DaemonLogEntry``, ``DaemonSourceOrigin``,
// ``DaemonChatMessage``, ``DaemonStrategySnapshot``, the OKF trust family),
// those types are REUSED — one shape per value.

/// Mirror of `WikiPage` — the full page row including the body.
public struct DaemonWikiPage: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let slug: String
    public let bodyMarkdown: String
    public let createdAt: Date
    public let updatedAt: Date
    public let version: Int
    public let createdBy: String?
    public let lastEditedBy: String?

    public init(
        id: String, title: String, slug: String, bodyMarkdown: String,
        createdAt: Date, updatedAt: Date, version: Int,
        createdBy: String?, lastEditedBy: String?
    ) {
        self.id = id
        self.title = title
        self.slug = slug
        self.bodyMarkdown = bodyMarkdown
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.version = version
        self.createdBy = createdBy
        self.lastEditedBy = lastEditedBy
    }
}

/// Mirror of `WikiIndex` — the curated catalog singleton (body inline; an
/// oversized index is promoted wholesale by the reply envelope).
public struct DaemonWikiIndexMirror: Codable, Equatable, Sendable {
    public let body: String
    public let updatedAt: Date
    public let version: Int

    public init(body: String, updatedAt: Date, version: Int) {
        self.body = body
        self.updatedAt = updatedAt
        self.version = version
    }
}

/// Mirror of `GRDBWikiStore.SourceUsageSignal` — one source's cite-usage
/// credibility signal.
public struct DaemonSourceUsageSignal: Codable, Equatable, Sendable {
    public let sourceID: String
    public let citeCount: Int
    public let latestCitingPageUpdatedAt: Date?

    public init(
        sourceID: String, citeCount: Int, latestCitingPageUpdatedAt: Date?
    ) {
        self.sourceID = sourceID
        self.citeCount = citeCount
        self.latestCitingPageUpdatedAt = latestCitingPageUpdatedAt
    }
}

/// Mirror of `GRDBWikiStore.SourceHeadProducer` — one source's head producer
/// attribution (agent name/version).
public struct DaemonSourceHeadProducer: Codable, Equatable, Sendable {
    public let sourceID: String
    public let producerName: String?
    public let producerVersion: String?

    public init(sourceID: String, producerName: String?, producerVersion: String?) {
        self.sourceID = sourceID
        self.producerName = producerName
        self.producerVersion = producerVersion
    }
}

/// Mirror of `IndexGenerators.LinkRow` — one wiki link row (page or source).
public struct DaemonLinkRow: Codable, Equatable, Sendable {
    public let from: String
    public let to: String
    public let linkText: String
    /// `"page"` or `"source"`.
    public let type: String

    public init(from: String, to: String, linkText: String, type: String) {
        self.from = from
        self.to = to
        self.linkText = linkText
        self.type = type
    }
}

/// Mirror of `IndexGenerators.SourceIndexRow` — one source row without
/// bytes, as `sources.jsonl` and the `sources/` enumeration read it.
public struct DaemonSourceIndexRow: Codable, Equatable, Sendable {
    public let id: String
    public let filename: String
    public let ext: String
    public let mime: String?
    public let byteSize: Int
    public let createdAt: Date
    public let updatedAt: Date
    public let version: Int
    public let displayName: String?
    public let hasMarkdown: Bool

    public init(
        id: String, filename: String, ext: String, mime: String?,
        byteSize: Int, createdAt: Date, updatedAt: Date, version: Int,
        displayName: String?, hasMarkdown: Bool
    ) {
        self.id = id
        self.filename = filename
        self.ext = ext
        self.mime = mime
        self.byteSize = byteSize
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.version = version
        self.displayName = displayName
        self.hasMarkdown = hasMarkdown
    }
}

/// Mirror of `SourceMarkdownVersion` — the FULL version row including the
/// markdown content (the `.md` sibling render consumes the body).
public struct DaemonSourceMarkdownVersionMirror: Codable, Equatable, Sendable {
    public let id: String
    public let sourceID: String
    public let parentID: String?
    public let content: String
    /// `SourceMarkdownOrigin` raw value.
    public let origin: String
    public let note: String?
    public let createdAt: Date
    public let activityID: String?
    public let sourceVersionID: String?
    public let blobHash: String?
    public let mimeType: String
    public let technique: String?

    public init(
        id: String, sourceID: String, parentID: String?, content: String,
        origin: String, note: String?, createdAt: Date, activityID: String?,
        sourceVersionID: String?, blobHash: String?, mimeType: String,
        technique: String?
    ) {
        self.id = id
        self.sourceID = sourceID
        self.parentID = parentID
        self.content = content
        self.origin = origin
        self.note = note
        self.createdAt = createdAt
        self.activityID = activityID
        self.sourceVersionID = sourceVersionID
        self.blobHash = blobHash
        self.mimeType = mimeType
        self.technique = technique
    }
}

/// Mirror of `PageSourceLink` — one page→source link row.
public struct DaemonPageSourceLink: Codable, Equatable, Sendable {
    public let pageID: String
    public let sourceID: String
    public let linkText: String
    /// `PageSourceLinkRole` raw value (cite / embed).
    public let role: String

    public init(pageID: String, sourceID: String, linkText: String, role: String) {
        self.pageID = pageID
        self.sourceID = sourceID
        self.linkText = linkText
        self.role = role
    }
}

// MARK: Keyed-map entry shapes

// The store's `[SourceID: T]` returns cross as ordered entry arrays (the key
// rides inside the entry), so the wire never depends on dictionary-key
// encoding of a custom id type.

public struct DaemonProjectionUsageSignalEntry: Codable, Equatable, Sendable {
    public let id: String
    public let signal: DaemonSourceUsageSignal
    public init(id: String, signal: DaemonSourceUsageSignal) {
        self.id = id
        self.signal = signal
    }
}

public struct DaemonProjectionHeadProducerEntry: Codable, Equatable, Sendable {
    public let id: String
    public let producer: DaemonSourceHeadProducer
    public init(id: String, producer: DaemonSourceHeadProducer) {
        self.id = id
        self.producer = producer
    }
}

public struct DaemonProjectionOriginEntry: Codable, Equatable, Sendable {
    public let id: String
    public let origin: DaemonSourceOrigin
    public init(id: String, origin: DaemonSourceOrigin) {
        self.id = id
        self.origin = origin
    }
}

public struct DaemonProjectionMarkdownHeadEntry: Codable, Equatable, Sendable {
    public let sourceID: String
    public let version: DaemonSourceMarkdownVersionMirror
    public init(sourceID: String, version: DaemonSourceMarkdownVersionMirror) {
        self.sourceID = sourceID
        self.version = version
    }
}

public struct DaemonProjectionSiblingImage: Codable, Equatable, Sendable {
    public let key: String
    public let imageID: String
    public init(key: String, imageID: String) {
        self.key = key
        self.imageID = imageID
    }
}

public struct DaemonProjectionSiblingImageResolverEntry: Codable, Equatable, Sendable {
    public let sourceID: String
    public let images: [DaemonProjectionSiblingImage]
    public init(sourceID: String, images: [DaemonProjectionSiblingImage]) {
        self.sourceID = sourceID
        self.images = images
    }
}

// MARK: - Per-operation request DTOs

public struct DaemonProjectionGetPageRequest: Codable, Equatable, Sendable {
    public let id: String
    public init(id: String) { self.id = id }
}

public struct DaemonProjectionGetSourceRequest: Codable, Equatable, Sendable {
    public let id: String
    public init(id: String) { self.id = id }
}

public struct DaemonProjectionGetChatRequest: Codable, Equatable, Sendable {
    public let id: String
    public init(id: String) { self.id = id }
}

public struct DaemonProjectionGetWikiIndexRequest: Codable, Equatable, Sendable {
    public init() {}
}

public struct DaemonProjectionGetWikiStrategyRequest: Codable, Equatable, Sendable {
    public init() {}
}

public struct DaemonProjectionPageHeadVersionIDRequest: Codable, Equatable, Sendable {
    public let pageID: String
    public init(pageID: String) { self.pageID = pageID }
}

public struct DaemonProjectionPageOKFMetadataRequest: Codable, Equatable, Sendable {
    public let versionID: String
    public let includeCorrected: Bool
    public init(versionID: String, includeCorrected: Bool) {
        self.versionID = versionID
        self.includeCorrected = includeCorrected
    }
}

public struct DaemonProjectionSourceMarkdownOKFMetadataRequest: Codable, Equatable, Sendable {
    public let versionID: String
    public let includeCorrected: Bool
    public init(versionID: String, includeCorrected: Bool) {
        self.versionID = versionID
        self.includeCorrected = includeCorrected
    }
}

public struct DaemonProjectionSourceContentRequest: Codable, Equatable, Sendable {
    public let id: String
    public init(id: String) { self.id = id }
}

public struct DaemonProjectionSourceLinksRequest: Codable, Equatable, Sendable {
    public let pageID: String
    public init(pageID: String) { self.pageID = pageID }
}

public struct DaemonProjectionChatMessagesRequest: Codable, Equatable, Sendable {
    public let chatID: String
    public init(chatID: String) { self.chatID = chatID }
}

public struct DaemonProjectionSourceUsageSignalsRequest: Codable, Equatable, Sendable {
    /// Raw SourceID ULIDs, deduplicated and ordered store-side.
    public let sourceIDs: [String]
    public init(sourceIDs: [String]) { self.sourceIDs = sourceIDs }
}

public struct DaemonProjectionSourceHeadProducersRequest: Codable, Equatable, Sendable {
    public let sourceIDs: [String]
    public init(sourceIDs: [String]) { self.sourceIDs = sourceIDs }
}

/// The no-payload listing operations share one empty request DTO.
public struct DaemonProjectionListRequest: Codable, Equatable, Sendable {
    public init() {}
}

// MARK: - Per-operation reply DTOs

public struct DaemonProjectionGetPageReply: Codable, Equatable, Sendable {
    public let page: DaemonWikiPage
    public init(page: DaemonWikiPage) { self.page = page }
}

public struct DaemonProjectionGetSourceReply: Codable, Equatable, Sendable {
    public let source: DaemonSourceSummary
    public init(source: DaemonSourceSummary) { self.source = source }
}

public struct DaemonProjectionGetChatReply: Codable, Equatable, Sendable {
    public let chat: DaemonChatSummary
    public init(chat: DaemonChatSummary) { self.chat = chat }
}

public struct DaemonProjectionGetWikiIndexReply: Codable, Equatable, Sendable {
    public let index: DaemonWikiIndexMirror
    public init(index: DaemonWikiIndexMirror) { self.index = index }
}

public struct DaemonProjectionGetWikiStrategyReply: Codable, Equatable, Sendable {
    /// nil = the wiki uses the Default strategy (true absence, never a
    /// stand-in — the FP omits `WIKI-STRATEGY.md` on a failed read instead).
    public let strategy: DaemonStrategySnapshot?
    public init(strategy: DaemonStrategySnapshot?) {
        self.strategy = strategy
    }
}

public struct DaemonProjectionPageHeadVersionIDReply: Codable, Equatable, Sendable {
    public let versionID: String?
    public init(versionID: String?) { self.versionID = versionID }
}

public struct DaemonProjectionPageOKFMetadataReply: Codable, Equatable, Sendable {
    public let metadata: DaemonPageOKFTrustMetadata?
    public init(metadata: DaemonPageOKFTrustMetadata?) {
        self.metadata = metadata
    }
}

public struct DaemonProjectionSourceMarkdownOKFMetadataReply: Codable, Equatable, Sendable {
    public let metadata: DaemonSourceMarkdownOKFTrustMetadata?
    public init(metadata: DaemonSourceMarkdownOKFTrustMetadata?) {
        self.metadata = metadata
    }
}

public struct DaemonProjectionListAllPagesReply: Codable, Equatable, Sendable {
    public let pages: [DaemonWikiPage]
    public init(pages: [DaemonWikiPage]) { self.pages = pages }
}

public struct DaemonProjectionListAllSourcesReply: Codable, Equatable, Sendable {
    public let sources: [DaemonSourceIndexRow]
    public init(sources: [DaemonSourceIndexRow]) { self.sources = sources }
}

public struct DaemonProjectionListAllChatsReply: Codable, Equatable, Sendable {
    public let chats: [DaemonChatSummary]
    public init(chats: [DaemonChatSummary]) { self.chats = chats }
}

public struct DaemonProjectionListBookmarkNodesReply: Codable, Equatable, Sendable {
    public let nodes: [DaemonBookmarkNode]
    public init(nodes: [DaemonBookmarkNode]) { self.nodes = nodes }
}

public struct DaemonProjectionListAllLinksReply: Codable, Equatable, Sendable {
    public let links: [DaemonLinkRow]
    public init(links: [DaemonLinkRow]) { self.links = links }
}

public struct DaemonProjectionListLogEntriesReply: Codable, Equatable, Sendable {
    public let entries: [DaemonLogEntry]
    public init(entries: [DaemonLogEntry]) { self.entries = entries }
}

public struct DaemonProjectionSourceContentReply: Codable, Equatable, Sendable {
    public let bytes: Data
    public init(bytes: Data) { self.bytes = bytes }
}

public struct DaemonProjectionSourceLinksReply: Codable, Equatable, Sendable {
    public let links: [DaemonPageSourceLink]
    public init(links: [DaemonPageSourceLink]) { self.links = links }
}

public struct DaemonProjectionChatMessagesReply: Codable, Equatable, Sendable {
    public let messages: [DaemonChatMessage]
    public init(messages: [DaemonChatMessage]) {
        self.messages = messages
    }
}

public struct DaemonProjectionSourceUsageSignalsReply: Codable, Equatable, Sendable {
    public let entries: [DaemonProjectionUsageSignalEntry]
    public init(entries: [DaemonProjectionUsageSignalEntry]) {
        self.entries = entries
    }
}

public struct DaemonProjectionSourceHeadProducersReply: Codable, Equatable, Sendable {
    public let entries: [DaemonProjectionHeadProducerEntry]
    public init(entries: [DaemonProjectionHeadProducerEntry]) {
        self.entries = entries
    }
}

public struct DaemonProjectionProcessedMarkdownHeadsReply: Codable, Equatable, Sendable {
    public let heads: [DaemonProjectionMarkdownHeadEntry]
    public init(heads: [DaemonProjectionMarkdownHeadEntry]) {
        self.heads = heads
    }
}

public struct DaemonProjectionSourceOriginsReply: Codable, Equatable, Sendable {
    public let entries: [DaemonProjectionOriginEntry]
    public init(entries: [DaemonProjectionOriginEntry]) {
        self.entries = entries
    }
}

public struct DaemonProjectionSiblingImageResolversReply: Codable, Equatable, Sendable {
    public let entries: [DaemonProjectionSiblingImageResolverEntry]
    public init(entries: [DaemonProjectionSiblingImageResolverEntry]) {
        self.entries = entries
    }
}

// MARK: - Frame safety

/// The projection family's frame-safety seam. The daemon promotes any encoded
/// op reply whose FINAL OUTER envelope would exceed the socket frame cap into
/// a committed payload handle (chunked download through `payloadRead`);
/// clients reassemble and verify against the handle's byte count + SHA-256
/// before decoding. The promotion threshold already accounts for the three
/// base64 layers between raw result bytes and the outer envelope (see
/// ``DaemonStoreFrameSizing/outerEncodedBound``), so a promoted reply's own
/// envelope always fits.
public enum DaemonProjectionFrameSafety {
    /// The maximum RAW result-bytes length served INLINE. Above this the
    /// daemon stashes the bytes and answers `oversized`. The bound is
    /// conservative: a full-size inline result must leave room for the reply
    /// JSON, the projection reply envelope, the domain envelope, and the
    /// length prefix — the same three-layer 4/3 math the store family pins.
    public static let maxInlineResultBytes = 256 * 1024

    /// True when `rawResultByteCount` may be served inline.
    public static func fitsInline(rawResultByteCount: Int) -> Bool {
        rawResultByteCount <= maxInlineResultBytes
    }
}
#endif
