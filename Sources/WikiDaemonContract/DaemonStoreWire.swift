#if os(macOS)
import Foundation

// Store wire primitives for the daemon's structured store family (Phase 2a
// slice 1 of plans/daemon-only-access.md). The envelope stays
// `DaemonDomainRequest` / `DaemonDomainReply` with `family: .store`; the
// family payload is the JSON `DaemonStoreRequest` / `DaemonStoreReply` pair
// below, whose `payload` / `result` carry one operation's DTO bytes. Slice 2
// commits the per-operation DTOs; this slice fixes the shared infrastructure:
//
// - ``DaemonStoreOperation`` — the single operation-string registry, grouped
//   by payload family per tmp/store-ops-manifest.md (small 37 / list 25 /
//   blob 39 / event-producer 50) plus the staged-payload and mutation
//   semantics primitives.
// - Staged payload handles (`payloadBegin` → `payloadChunk` →
//   `payloadCommit` → `payloadRead`): large inputs cross the 4 MiB frame cap
//   as ordered, hash-checked chunks; the real operation then executes with
//   the committed handle inside its own method-atomic store entry point.
// - ``DaemonReplyCursor`` — byte-budgeted reply pagination: cursors bound
//   ACCUMULATED ENCODED BYTES, not just item count.
// - Mutation outcome semantics: submissions stamp a client `requestID` (ULID)
//   plus the expected daemon epoch; `resolveOutcome` never dispatches a
//   mutation — it joins an in-flight admission or reads the bounded outcome
//   cache, answering `outcomeUnknown` on miss or epoch mismatch.
// - ``DaemonStoreError`` — the exhaustive tagged error contract, one case per
//   supported typed error with associated values intact (mirrors of the
//   WikiFSCore shapes; this module stays dependency-free).
//
// Like every file in this module: Foundation-only leaf, no WikiFSCore /
// WikiFSImports import, `#if os(macOS)` throughout.

// MARK: - Versions

public enum DaemonStoreWireVersion {
    /// The store family payload version this daemon serves and this client
    /// speaks. Versioning starts at 1 with the Phase 2a wire.
    public static let current: UInt16 = 1
}

// MARK: - Operation registry

/// The payload family each store operation belongs to
/// (tmp/store-ops-manifest.md). The counts are contract constants the
/// exhaustiveness tests pin; slice 2's DTO shapes follow them.
public enum DaemonStorePayloadFamily: String, Codable, Sendable, CaseIterable {
    /// Single small reply (37 operations).
    case small
    /// Cursor-paginated listing reply, byte-budgeted (25 operations).
    case list
    /// Bytes up or down via a staged payload handle (39 operations).
    case blob
    /// A commit that produces exactly one store event per mutation (50
    /// operations); the daemon executor preserves the store's
    /// `mutate(event:)` discipline.
    case eventProducer
    /// Staged payload handle flow (`payloadBegin` / `payloadChunk` /
    /// `payloadCommit` / `payloadRead`) — infrastructure, not a `WikiStore`
    /// requirement.
    case stagedPayload
    /// Mutation outcome semantics (`resolveOutcome`, `sessionBootstrap`) —
    /// infrastructure, not a `WikiStore` requirement.
    case mutationSemantics
    /// The store EVENT CONTRACT (2c): the acknowledged `sinkHandshake` —
    /// daemon-scoped (never a per-wiki store resolution). The events slice
    /// consumed the name reserved here as `.reservedEvents` before 2c;
    /// nothing is reserved anymore.
    case events
}

/// The store family's operation strings — the ONE registry shared by the
/// daemon executor, the remote store client, slice 2's per-op DTOs, and the
/// 2f exhaustiveness test. Cases are named after the manifest operation
/// strings (tmp/store-ops-manifest.md); `rawValue` is the wire operation
/// string inside a `.store` envelope. `CaseIterable` makes the registry
/// compiler-enumerable, so an added operation must be classified (a missed
/// family mapping is a compile error at ``family``), and the count tests pin
/// the manifest partition: 151 manifest operations (small 37, list 25, blob
/// 39, event-producer 50) plus 7 infrastructure/events operations.
public enum DaemonStoreOperation: String, Codable, Sendable, CaseIterable {

    // MARK: Staged payload handle flow (infrastructure)

    /// Open a staged upload: declares total size + SHA-256; reply carries the
    /// staging id the chunks reference.
    case payloadBegin
    /// Append one ordered chunk (≤ ``DaemonStoreLimits/maxChunkBytes`` raw)
    /// with the running SHA-256 expectation over everything received so far.
    case payloadChunk
    /// Seal a complete staged upload; reply carries the committed payload
    /// handle + its expiry. Incomplete uploads never commit.
    case payloadCommit
    /// Download a committed handle's bytes one chunk at a time (oversized
    /// page bodies, source bytes, strategy documents, oversized single list
    /// items).
    case payloadRead

    // MARK: Mutation outcome semantics (infrastructure)

    /// RESOLVE-ONLY: joins an in-flight admission or reads the bounded
    /// outcome cache. NEVER dispatches a mutation; cache miss or epoch
    /// mismatch answers `outcomeUnknown`.
    case resolveOutcome
    /// Session bootstrap payload: registered extraction inputs, registered
    /// renderer source types, change token, strategy snapshot (plan 2e).
    case sessionBootstrap

    // MARK: Store event contract (2c)

    /// Acknowledged sink handshake — returns `{daemonEpoch, perWiki:
    /// [{wikiID, changeToken, lastSequence}]}`, flips the requesting sink
    /// from buffering to live, and replays the bounded pre-handshake ring.
    /// Implemented in the events slice (2c).
    case sinkHandshake

    // MARK: Manifest operations — small (37)

    case activeContentVersion
    case activeExtractionProvenance
    case chatAttachments
    case chatTranscriptCheckpoint
    case chatUsageSummary
    case fetchState
    case getChat
    case getMetadata
    case getWikiStrategyState
    case hasImageSiblings
    case hasProcessedMarkdown
    case initialContentVersion
    case pageHeadSources
    case pageHeadVersionID
    case pageOKFMetadata
    case pageOrigin
    case pageVersionSources
    case rendererInputByteCount
    case rendererSourcePreference
    case rendererSourcePresentation
    case resolveChatByTitle
    case resolveSourceByName
    case resolveTitleToID
    case searchSimilar
    case searchSimilarChats
    case searchSimilarSources
    case setMetadata
    case sourceMarkdownOKFMetadata
    case sourceMatchingURLIdentity
    case sourceOrigin
    case sourceVersion
    case vacuumActivities
    case vacuumBlobs
    case vacuumPageVersions
    case wikiStrategyRevision
    case workspacePageVersion
    case workspaceSummary

    // MARK: Manifest operations — list (25)

    case chatMessages
    case deletionImpact
    case embedDescriptors
    case listAllChatsOrderedByID
    case listBookmarkNodes
    case listChats
    case listPages
    case listPersistedChatTurns
    case listSources
    case markedSourceIDs
    case pageEditHistory
    case pagesCitingSources
    case pageVersionHistory
    case processedMarkdownAgentNames
    case processedMarkdownAlternatives
    case processedMarkdownHistory
    case readChatTranscriptPage
    case recentLogEntries
    case siblingImageResolvers
    case sourceDerivedChains
    case sourceEditHistory
    case sourceOriginsBySource
    case sourcesWithPendingFormatJobs
    case workspaceConflicts
    case workspaceRefs

    // MARK: Manifest operations — blob (39)

    case addSnapshotImage
    case addSource
    case appendChatMessages
    case appendChatTranscriptItems
    case appendContentVersion
    case appendDerivedMarkdown
    case appendFetchMarkdown
    case appendHostSpeechTranscript
    case appendInstalledPackageMarkdown
    case appendPageVersion
    case appendProcessedMarkdown
    case appendUserProcessedMarkdown
    case attachAcquiredBytes
    case checkpointStreamingMessage
    case claimNextPersistedChatTurn
    case createPage
    case enqueuePersistedChatTurn
    case finishPersistedChatTurn
    case getPage
    case getWikiIndex
    case getWikiStrategy
    case missingChatEmbeddingWork
    case missingPageEmbeddingWork
    case missingSourceEmbeddingWork
    case pageVersionBody
    case processedMarkdownHead
    case processedMarkdownVersion
    case recordMarkdownExtraction
    case saveWikiStrategy
    case setWorkspaceIndexBody
    case sourceContent
    case storeChatChunks
    case storePageChunks
    case storeSourceChunks
    case updatePage
    case updateWikiIndex
    case upsertPage
    case workspacePageBody
    case workspaceWritePage

    // MARK: Manifest operations — event producer (50)

    case abandonWorkspace
    case addBytelessSource
    case appendLog
    case cancelUnclaimedPersistedChatTurn
    case correctPageOKFVerification
    case correctSourceMarkdownOKFVerification
    case createBookmarkNode
    case createChat
    case createWorkspace
    case deleteBookmarkNode
    case deleteChat
    case deleteResources
    case ensureFetchActivity
    case finalizeStaleDrafts
    case markFetchComplete
    case markPersistedChatTurnProviderSubmitted
    case markSourceIngested
    case moveBookmarkNode
    case reapStaleWorkspaces
    case recordPageOKFVerification
    case recordSourceMarkdownOKFVerification
    case removeRendererSourcePresentation
    case renameBookmarkFolder
    case renameChat
    case renameSource
    case repairMIME
    case replaceLinks
    case restorePage
    case retargetBookmarkNode
    case revertPage
    case setActiveMarkdown
    case setChatAttachments
    case setChatTitleIf
    case setChatTitleIfEmpty
    case setPageOKFFreshness
    case setPageOKFStatus
    case setRendererSourcePreference
    case setRendererSourcePresentation
    case setSourceDisplayName
    case setSourceMarkdownOKFFreshness
    case setSourceMarkdownOKFStatus
    case updateChatAcpSessionId
    case updateChatModelAndThinkingSelection
    case updateChatModelOverride
    case updateMessageSummary
    case updatePersistedChatTurnUsage
    case workspaceMerge
    case workspaceRefresh
    case workspaceResolveConflict
    case workspaceRetryMerge

    /// The manifest partition this operation belongs to. Exhaustive over all
    /// cases: adding an operation without classifying it is a compile error.
    public var family: DaemonStorePayloadFamily {
        switch self {
        case .payloadBegin, .payloadChunk, .payloadCommit, .payloadRead:
            return .stagedPayload
        case .resolveOutcome, .sessionBootstrap:
            return .mutationSemantics
        case .sinkHandshake:
            return .events
        case .activeContentVersion, .activeExtractionProvenance,
             .chatAttachments, .chatTranscriptCheckpoint, .chatUsageSummary,
             .fetchState, .getChat, .getMetadata, .getWikiStrategyState,
             .hasImageSiblings, .hasProcessedMarkdown, .initialContentVersion,
             .pageHeadSources, .pageHeadVersionID, .pageOKFMetadata,
             .pageOrigin, .pageVersionSources, .rendererInputByteCount,
             .rendererSourcePreference, .rendererSourcePresentation,
             .resolveChatByTitle, .resolveSourceByName, .resolveTitleToID,
             .searchSimilar, .searchSimilarChats, .searchSimilarSources,
             .setMetadata, .sourceMarkdownOKFMetadata,
             .sourceMatchingURLIdentity, .sourceOrigin, .sourceVersion,
             .vacuumActivities, .vacuumBlobs, .vacuumPageVersions,
             .wikiStrategyRevision, .workspacePageVersion, .workspaceSummary:
            return .small
        case .chatMessages, .deletionImpact, .embedDescriptors,
             .listAllChatsOrderedByID, .listBookmarkNodes, .listChats,
             .listPages, .listPersistedChatTurns, .listSources,
             .markedSourceIDs, .pageEditHistory, .pagesCitingSources,
             .pageVersionHistory, .processedMarkdownAgentNames,
             .processedMarkdownAlternatives, .processedMarkdownHistory,
             .readChatTranscriptPage, .recentLogEntries,
             .siblingImageResolvers, .sourceDerivedChains, .sourceEditHistory,
             .sourceOriginsBySource, .sourcesWithPendingFormatJobs,
             .workspaceConflicts, .workspaceRefs:
            return .list
        case .addSnapshotImage, .addSource, .appendChatMessages,
             .appendChatTranscriptItems, .appendContentVersion,
             .appendDerivedMarkdown, .appendFetchMarkdown,
             .appendHostSpeechTranscript, .appendInstalledPackageMarkdown,
             .appendPageVersion, .appendProcessedMarkdown,
             .appendUserProcessedMarkdown, .attachAcquiredBytes,
             .checkpointStreamingMessage, .claimNextPersistedChatTurn,
             .createPage, .enqueuePersistedChatTurn, .finishPersistedChatTurn,
             .getPage, .getWikiIndex, .getWikiStrategy,
             .missingChatEmbeddingWork, .missingPageEmbeddingWork,
             .missingSourceEmbeddingWork, .pageVersionBody,
             .processedMarkdownHead, .processedMarkdownVersion,
             .recordMarkdownExtraction, .saveWikiStrategy,
             .setWorkspaceIndexBody, .sourceContent, .storeChatChunks,
             .storePageChunks, .storeSourceChunks, .updatePage,
             .updateWikiIndex, .upsertPage, .workspacePageBody,
             .workspaceWritePage:
            return .blob
        case .abandonWorkspace, .addBytelessSource, .appendLog,
             .cancelUnclaimedPersistedChatTurn,
             .correctPageOKFVerification,
             .correctSourceMarkdownOKFVerification, .createBookmarkNode,
             .createChat, .createWorkspace, .deleteBookmarkNode, .deleteChat,
             .deleteResources, .ensureFetchActivity, .finalizeStaleDrafts,
             .markFetchComplete, .markPersistedChatTurnProviderSubmitted,
             .markSourceIngested, .moveBookmarkNode, .reapStaleWorkspaces,
             .recordPageOKFVerification,
             .recordSourceMarkdownOKFVerification,
             .removeRendererSourcePresentation, .renameBookmarkFolder,
             .renameChat, .renameSource, .repairMIME, .replaceLinks,
             .restorePage, .retargetBookmarkNode, .revertPage,
             .setActiveMarkdown, .setChatAttachments, .setChatTitleIf,
             .setChatTitleIfEmpty, .setPageOKFFreshness, .setPageOKFStatus,
             .setRendererSourcePreference, .setRendererSourcePresentation,
             .setSourceDisplayName, .setSourceMarkdownOKFFreshness,
             .setSourceMarkdownOKFStatus, .updateChatAcpSessionId,
             .updateChatModelAndThinkingSelection, .updateChatModelOverride,
             .updateMessageSummary, .updatePersistedChatTurnUsage,
             .workspaceMerge, .workspaceRefresh, .workspaceResolveConflict,
             .workspaceRetryMerge:
            return .eventProducer
        }
    }
}

/// The manifest partition counts this registry pins
/// (tmp/store-ops-manifest.md). The wire tests assert the live registry
/// matches; drift in either direction fails fast.
public enum DaemonStoreOperationCounts {
    public static let small = 37
    public static let list = 25
    public static let blob = 39
    public static let eventProducer = 50
    /// 37 + 25 + 39 + 50 — every `WikiStore` requirement classified rpc.
    public static let manifestOperations = 151
    public static let stagedPayload = 4
    public static let mutationSemantics = 2
    /// Tombstone: the events slice (2c) consumed the `.reservedEvents`
    /// reservation — `sinkHandshake` is served under ``family``'s `.events`
    /// case (count 1 below). Zero pins that NO operation is reserved anymore;
    /// the registry test asserts it so a future slice cannot quietly
    /// re-reserve.
    public static let reservedEvents = 0
    public static let events = 1
    public static let total = manifestOperations + stagedPayload
        + mutationSemantics + events
}

// MARK: - Limits

/// The store family's wire limits (plan 2a: staged payload caps, TTLs,
/// byte-budgeted replies, bounded outcome cache). One namespace so the
/// executor, the client, and the tests cite the same constants.
public enum DaemonStoreLimits {

    /// Maximum RAW byte count for one `payloadChunk` request. 1 MiB per the
    /// plan's chunk math. After the store family's nested envelope layers
    /// (chunk `Data` inside the per-op DTO JSON, the DTO JSON inside the
    /// store reply's `result` `Data`, the store reply JSON inside the domain
    /// envelope's `payload` `Data` — each a 4/3 base64 layer) a full chunk
    /// lands ≈ 2.37 MiB — inside the 4 MiB outer frame cap
    /// (`SearchSocketWire.maxFrameSize`) with >1.5 MiB headroom. The design
    /// record's ≈1.83 MiB figure counted the two layers of a single-nested
    /// payload; the store family's reply envelope adds the third.
    public static let maxChunkBytes = 1_048_576

    /// Maximum TOTAL byte count one staged upload may declare. The daemon
    /// rejects `payloadBegin` above this; tunable.
    public static let maxTotalStagedBytes = 256 * 1_048_576

    /// How long an INCOMPLETE staged upload survives after its last chunk
    /// before the daemon reaps it. Disconnect cleanup reaps sooner; a partial
    /// handle is never executable either way.
    public static let stagedUploadTTLSeconds: TimeInterval = 900

    /// How long a COMMITTED handle's bytes remain downloadable through
    /// `payloadRead` after commit. The caller should immediately invoke the
    /// real operation that consumes the handle.
    public static let committedHandleTTLSeconds: TimeInterval = 600

    /// The reply budget a LIST operation's cursor accumulates against: once
    /// the accumulated ENCODED bytes of the items served so far reach this,
    /// the server stops and hands back a cursor (`nextAvailable: true`). An
    /// oversized single item is itself served through a payload-handle read.
    public static let listReplyBudgetEncodedBytes = 1_048_576

    /// Bounded per-wiki outcome cache: the last 64 requestIDs keep their
    /// outcomes resolvable (plan 2a mutation outcome semantics). After
    /// eviction or a daemon restart, `resolveOutcome` answers
    /// `outcomeUnknown` and the client reconciles through change tokens.
    public static let outcomeCacheCapacity = 64

    /// Direct small-payload XPC carry keeps the 1 MiB rule for symmetry with
    /// the chunked path (plan 2a byte-budgeted replies).
    public static let xpcDirectPayloadBytes = 1_048_576

    /// Bounded per-wiki replay ring for the store event contract (plan 2c):
    /// events emitted before a sink completes its `sinkHandshake` are kept
    /// per wiki in insertion (sequence) order, oldest dropped first once the
    /// ring is full. A handshake replays the survivors; a client that
    /// observes a sequence gap reconciles through the handshake's
    /// `changeToken`.
    public static let sinkEventBufferCapacity = 256
}

// MARK: - Staged payload handles

/// An opaque reference to bytes the daemon holds — either a committed staged
/// upload (ready for the real operation to consume) or a large reply body
/// served through `payloadRead`. The id is daemon-generated and meaningless
/// to clients; `declaredByteCount` and `sha256Hex` are the integrity contract
/// checked before execution.
public struct DaemonPayloadHandle: Codable, Equatable, Sendable {
    /// Daemon-generated opaque id (ULID).
    public let id: String
    /// Total RAW byte count the payload carries (declared at begin, verified
    /// at commit; reads report the same value).
    public let declaredByteCount: Int
    /// Lowercase SHA-256 hex over the full raw payload.
    public let sha256Hex: String

    public init(id: String, declaredByteCount: Int, sha256Hex: String) {
        self.id = id
        self.declaredByteCount = declaredByteCount
        self.sha256Hex = sha256Hex
    }
}

/// `payloadBegin` request: opens a staged upload. The daemon validates the
/// declared size against ``DaemonStoreLimits/maxTotalStagedBytes`` and hands
/// back a staging id.
public struct DaemonPayloadBeginRequest: Codable, Equatable, Sendable {
    public let declaredByteCount: Int
    /// Lowercase SHA-256 hex over the full payload; commit fails closed on
    /// mismatch, so a partial upload can never masquerade as complete.
    public let sha256Hex: String

    public init(declaredByteCount: Int, sha256Hex: String) {
        self.declaredByteCount = declaredByteCount
        self.sha256Hex = sha256Hex
    }
}

/// `payloadBegin` reply: the staging session id every chunk and the commit
/// reference.
public struct DaemonPayloadBeginReply: Codable, Equatable, Sendable {
    public let uploadID: String

    public init(uploadID: String) {
        self.uploadID = uploadID
    }
}

/// `payloadChunk` request: one ordered chunk. `bytes` must be
/// ≤ ``DaemonStoreLimits/maxChunkBytes`` raw; `runningSHA256Hex` is the
/// SHA-256 over everything received so far INCLUDING this chunk, so the
/// daemon verifies order and content incrementally (ordered, hash-checked).
public struct DaemonPayloadChunkRequest: Codable, Equatable, Sendable {
    public let uploadID: String
    /// Zero-based position in the chunk sequence; out-of-order or repeated
    /// indexes are typed rejections.
    public let orderIndex: Int
    public let bytes: Data
    /// SHA-256 hex over the concatenated raw bytes received so far.
    public let runningSHA256Hex: String

    public init(
        uploadID: String, orderIndex: Int, bytes: Data, runningSHA256Hex: String
    ) {
        self.uploadID = uploadID
        self.orderIndex = orderIndex
        self.bytes = bytes
        self.runningSHA256Hex = runningSHA256Hex
    }
}

/// `payloadChunk` reply: progress accounting so the client can bound retries.
public struct DaemonPayloadChunkReply: Codable, Equatable, Sendable {
    public let receivedChunkCount: Int
    public let receivedByteCount: Int

    public init(receivedChunkCount: Int, receivedByteCount: Int) {
        self.receivedChunkCount = receivedChunkCount
        self.receivedByteCount = receivedByteCount
    }
}

/// `payloadCommit` request: seals a COMPLETE staged upload. The daemon
/// verifies total size + SHA-256 against the begin declaration; a mismatch —
/// or any missing chunk — is a typed rejection and the partial bytes are
/// never executable.
public struct DaemonPayloadCommitRequest: Codable, Equatable, Sendable {
    public let uploadID: String

    public init(uploadID: String) {
        self.uploadID = uploadID
    }
}

/// `payloadCommit` reply: the handle the real operation references, plus its
/// expiry — the caller must invoke the consuming operation before
/// `expiresAt` (TTL / disconnect expiry; partial handles never execute).
public struct DaemonPayloadCommitReply: Codable, Equatable, Sendable {
    public let handle: DaemonPayloadHandle
    public let expiresAt: Date

    public init(handle: DaemonPayloadHandle, expiresAt: Date) {
        self.handle = handle
        self.expiresAt = expiresAt
    }
}

/// `payloadRead` request: downloads one chunk of a committed handle's bytes.
public struct DaemonPayloadReadRequest: Codable, Equatable, Sendable {
    public let handleID: String
    /// Zero-based chunk index, bounded by the reply's `chunkCount`.
    public let chunkIndex: Int

    public init(handleID: String, chunkIndex: Int) {
        self.handleID = handleID
        self.chunkIndex = chunkIndex
    }
}

/// `payloadRead` reply: one chunk slice (≤ ``DaemonStoreLimits/maxChunkBytes``
/// raw). The client reassembles in order and verifies the full SHA-256
/// against the handle it already holds.
public struct DaemonPayloadReadReply: Codable, Equatable, Sendable {
    public let totalByteCount: Int
    public let chunkIndex: Int
    public let chunkCount: Int
    public let bytes: Data
    /// True on the final chunk (client-side completion check).
    public let isFinal: Bool

    public init(
        totalByteCount: Int, chunkIndex: Int, chunkCount: Int, bytes: Data,
        isFinal: Bool
    ) {
        self.totalByteCount = totalByteCount
        self.chunkIndex = chunkIndex
        self.chunkCount = chunkCount
        self.bytes = bytes
        self.isFinal = isFinal
    }
}

// MARK: - Reply cursors (byte-budgeted listing)

/// Pagination cursor for the LIST operations (plan 2a: byte-budgeted
/// replies bound ACCUMULATED ENCODED BYTES, not just item count). The server
/// fills the reply until the accumulated encoded byte count reaches
/// ``DaemonStoreLimits/listReplyBudgetEncodedBytes``, then stops and hands
/// this cursor back. A single item larger than the budget is itself served
/// through a payload-handle read, never inlined.
public struct DaemonReplyCursor: Codable, Equatable, Sendable {
    /// Opaque server-defined token for the next page; `nil` (or absent) means
    /// "from the beginning". Clients never parse it.
    public let pageToken: String?
    /// True when more items remain past this page.
    public let nextAvailable: Bool
    /// ENCODED byte count accumulated across this listing so far (including
    /// the items on the page this cursor was returned with).
    public let accumulatedEncodedByteCount: Int

    public init(
        pageToken: String?, nextAvailable: Bool,
        accumulatedEncodedByteCount: Int
    ) {
        self.pageToken = pageToken
        self.nextAvailable = nextAvailable
        self.accumulatedEncodedByteCount = accumulatedEncodedByteCount
    }
}

// MARK: - Mutation outcome semantics

/// The admission stamp every INITIAL mutation submission carries (plan 2a).
/// The daemon performs atomic in-flight admission keyed by
/// `(wikiID, requestID)` plus an operation/payload fingerprint: identical
/// concurrent duplicates join one outcome; ID reuse with a different
/// fingerprint is a typed rejection; an epoch mismatch is a typed rejection.
public struct DaemonMutationStamp: Codable, Equatable, Sendable {
    /// Client-generated ULID requestID.
    public let requestID: String
    /// The daemon epoch the client saw (sink handshake / bootstrap). A stale
    /// epoch after a daemon restart is a typed rejection — never a silent
    /// replay.
    public let expectedEpoch: UInt64

    public init(requestID: String, expectedEpoch: UInt64) {
        self.requestID = requestID
        self.expectedEpoch = expectedEpoch
    }
}

/// The outcome of a mutation submission or a resolve-only lookup. There is NO
/// automatic client retry of mutations: `outcomeUnknown` sends the client to
/// change-token reconciliation, never to a blind resend.
public enum DaemonOutcomeStatus: String, Codable, Sendable {
    /// This submission executed the mutation (first admission won).
    case committed
    /// An identical in-flight duplicate joined an admission already running;
    /// the shared outcome rides with the winner's completion.
    case joined
    /// The requestID is neither in flight nor cached (evicted past the 64-ID
    /// window, daemon restarted, or epoch mismatch). The mutation MAY or MAY
    /// NOT have committed — reconcile through change tokens.
    case outcomeUnknown
}

/// `resolveOutcome` request — RESOLVE-ONLY: joins an in-flight admission or
/// reads the bounded per-wiki outcome cache (last 64 requestIDs). It NEVER
/// dispatches a mutation. The fingerprint must match the original
/// submission's operation/payload fingerprint; reuse of an ID with a
/// different fingerprint is a typed rejection rather than a join.
public struct DaemonResolveOutcomeRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let stamp: DaemonMutationStamp
    /// The original submission's operation string.
    public let operation: String
    /// SHA-256 hex over the original submission's payload bytes (the
    /// operation/payload fingerprint admission is keyed by).
    public let payloadFingerprintSHA256Hex: String

    public init(
        wikiID: String, stamp: DaemonMutationStamp, operation: String,
        payloadFingerprintSHA256Hex: String
    ) {
        self.wikiID = wikiID
        self.stamp = stamp
        self.operation = operation
        self.payloadFingerprintSHA256Hex = payloadFingerprintSHA256Hex
    }
}

/// `resolveOutcome` reply. `result` carries the operation's reply DTO bytes
/// when the outcome is known (`committed` / `joined`); it is nil for
/// `outcomeUnknown`, where `message` names the reason (cache miss, evicted,
/// epoch mismatch).
public struct DaemonResolveOutcomeReply: Codable, Equatable, Sendable {
    public let status: DaemonOutcomeStatus
    public let result: Data?
    public let message: String?

    public init(
        status: DaemonOutcomeStatus, result: Data?, message: String? = nil
    ) {
        self.status = status
        self.result = result
        self.message = message
    }
}

// MARK: - Session bootstrap (plan 2e)

/// Contract-local mirror of WikiFSCore's `RegisteredExtractionInputs`: one
/// active extractor registration's declared input surface. The wire shape
/// mirrors the core type (kind raw string + MIME set + extension set + the
/// agent-cleanup claim); slice 2 / 2e wires the mapping in both directions.
/// Package data, never host policy — no kind-named fields.
public struct DaemonRegisteredExtractionInputs: Codable, Equatable, Sendable {
    public struct Claim: Codable, Equatable, Hashable, Sendable {
        /// `ExtractorKind` raw value.
        public let kind: String
        public let mimeTypes: Set<String>
        public let filenameExtensions: Set<String>
        /// The registration's agent-cleanup claim (manifest revision 5).
        public let wantsAgentCleanup: Bool

        public init(
            kind: String, mimeTypes: Set<String>,
            filenameExtensions: Set<String>, wantsAgentCleanup: Bool
        ) {
            self.kind = kind
            self.mimeTypes = mimeTypes
            self.filenameExtensions = filenameExtensions
            self.wantsAgentCleanup = wantsAgentCleanup
        }
    }

    public let claims: Set<Claim>

    public init(claims: Set<Claim>) {
        self.claims = claims
    }
}

/// Contract-local mirror of one `RegisteredRendererSourceTypes` claim: the
/// presentation identity + declared routes of one renderer source type
/// (descriptor reference, display name, canonical MIME, aliases,
/// extensions). Deliberately a SUBSET of the core claim — the descriptor's
/// matchers/artifact predicates stay daemon-side; clients only route
/// presentation by these values. Slice 2 / 2e wires the mapping.
public struct DaemonRendererSourceClaim: Codable, Equatable, Hashable, Sendable {
    /// The renderer descriptor's reference (stable identity string).
    public let descriptorReference: String
    public let displayName: String
    public let canonicalMIMEType: String
    public let mimeAliases: Set<String>
    public let filenameExtensions: Set<String>

    public init(
        descriptorReference: String, displayName: String,
        canonicalMIMEType: String, mimeAliases: Set<String>,
        filenameExtensions: Set<String>
    ) {
        self.descriptorReference = descriptorReference
        self.displayName = displayName
        self.canonicalMIMEType = canonicalMIMEType
        self.mimeAliases = mimeAliases
        self.filenameExtensions = filenameExtensions
    }
}

/// Contract-local mirror of WikiFSCore's `WikiStrategy` — the committed
/// strategy snapshot `sessionBootstrap` returns. `nil` snapshot = the wiki is
/// at the Default strategy (absence is the representation, matching
/// `getWikiStrategy()`'s nil).
public struct DaemonStrategySnapshot: Codable, Equatable, Sendable {
    public let name: String
    public let instructions: String
    /// `WikiStrategyRevision.rawValue` (monotonic; 0 is the never-written
    /// floor).
    public let revision: Int64
    public let updatedAt: Date

    public init(
        name: String, instructions: String, revision: Int64, updatedAt: Date
    ) {
        self.name = name
        self.instructions = instructions
        self.revision = revision
        self.updatedAt = updatedAt
    }
}

/// `sessionBootstrap` reply payload (plan 2e): the daemon-authoritative
/// values the app previously set from local services. `eventBus` stays a
/// client-local object fed by sink events — it is NOT part of this payload.
/// The registered-inputs / renderer-types mirrors arrive here and are set
/// locally by the session wiring.
public struct DaemonStoreSessionBootstrap: Codable, Equatable, Sendable {
    /// Mirrors `RegisteredExtractionInputs` (contract-local shapes above).
    public let registeredExtractionInputs: DaemonRegisteredExtractionInputs
    /// Mirrors `RegisteredRendererSourceTypes` claims, sorted by descriptor
    /// reference for wire stability (the core value is a Set).
    public let registeredRendererSourceTypes: [DaemonRendererSourceClaim]
    /// The wiki's current change token (reconciliation watermark).
    public let changeToken: String
    /// The committed strategy snapshot; `nil` = Default strategy.
    public let strategySnapshot: DaemonStrategySnapshot?

    public init(
        registeredExtractionInputs: DaemonRegisteredExtractionInputs,
        registeredRendererSourceTypes: [DaemonRendererSourceClaim],
        changeToken: String,
        strategySnapshot: DaemonStrategySnapshot?
    ) {
        self.registeredExtractionInputs = registeredExtractionInputs
        self.registeredRendererSourceTypes = registeredRendererSourceTypes
        self.changeToken = changeToken
        self.strategySnapshot = strategySnapshot
    }
}

// MARK: - Error contract (exhaustive)

// Contract-local mirrors of the WikiFSCore shapes the typed errors carry.
// This module is dependency-free, so every associated value crosses as its
// own mirror struct with identical field semantics; slice 2's client maps
// them back to the core types with associated values intact.

/// Mirror of `SourceSummary` (WikiFSCore/Sources/SourceSummary.swift): the
/// source row's metadata WITHOUT the bytes. `id` is the raw SourceID ULID;
/// `role` is the `SourceRole` raw string ("primary" / "media").
public struct DaemonSourceSummary: Codable, Equatable, Sendable {
    public let id: String
    public let filename: String
    /// Lowercased extension with no leading dot ("" when none).
    public let ext: String
    public let mimeType: String?
    public let byteSize: Int
    public let createdAt: Date
    public let updatedAt: Date
    public let version: Int
    public let externalItemKey: String?
    public let externalItemTitle: String?
    public let displayName: String?
    public let role: String

    public init(
        id: String, filename: String, ext: String, mimeType: String?,
        byteSize: Int, createdAt: Date, updatedAt: Date, version: Int,
        externalItemKey: String? = nil, externalItemTitle: String? = nil,
        displayName: String? = nil, role: String
    ) {
        self.id = id
        self.filename = filename
        self.ext = ext
        self.mimeType = mimeType
        self.byteSize = byteSize
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.version = version
        self.externalItemKey = externalItemKey
        self.externalItemTitle = externalItemTitle
        self.displayName = displayName
        self.role = role
    }
}

/// Mirror of `ProvenanceDeletionBlocker`: one source a page version's
/// immutable provenance cites, blocking that source's deletion.
public struct DaemonProvenanceDeletionBlocker: Codable, Equatable, Sendable {
    public let sourceID: String
    public let pageVersionID: String
    public let pageID: String

    public init(sourceID: String, pageVersionID: String, pageID: String) {
        self.sourceID = sourceID
        self.pageVersionID = pageVersionID
        self.pageID = pageID
    }
}

/// Mirror of `NonEmptyProvenanceDeletionBlockers`: the ordered blocker set
/// `deletionRestricted` carries. Order is SQLite's deterministic page,
/// version, source order; consumers preserve it. Never empty — the typed
/// case only exists when something actually blocks.
public struct DaemonDeletionBlockers: Codable, Equatable, Sendable {
    public let ordered: [DaemonProvenanceDeletionBlocker]

    public init(ordered: [DaemonProvenanceDeletionBlocker]) {
        self.ordered = ordered
    }
}

/// Mirror of `PageConflictError`: a CAS head moved — another writer
/// committed a new version after the caller loaded the page.
public struct DaemonPageConflictDetail: Codable, Equatable, Sendable {
    public let pageID: String
    public let expectedVersionID: String
    public let actualVersionID: String?

    public init(
        pageID: String, expectedVersionID: String, actualVersionID: String?
    ) {
        self.pageID = pageID
        self.expectedVersionID = expectedVersionID
        self.actualVersionID = actualVersionID
    }
}

/// Mirror of `PageCreateConflictError`: a create-only write found the title
/// occupied by a page that appeared since the caller's read.
public struct DaemonPageCreateConflictDetail: Codable, Equatable, Sendable {
    public let pageID: String
    public let title: String
    public let actualVersionID: String?

    public init(pageID: String, title: String, actualVersionID: String?) {
        self.pageID = pageID
        self.title = title
        self.actualVersionID = actualVersionID
    }
}

/// Mirror of `PageExpectedTargetMissingError`: an expected-head write whose
/// target no longer exists. `pageID` is nil when the target was selected by
/// title and that title no longer resolves.
public struct DaemonPageExpectedTargetMissingDetail: Codable, Equatable,
    Sendable {
    public let pageID: String?
    public let expectedHeadVersionID: String
    public let title: String

    public init(
        pageID: String?, expectedHeadVersionID: String, title: String
    ) {
        self.pageID = pageID
        self.expectedHeadVersionID = expectedHeadVersionID
        self.title = title
    }
}

/// Mirror of `WikiStrategyConflictError`: the strategy singleton's revision
/// moved under a compare-and-swap save. Revisions cross as raw Int64
/// (`WikiStrategyRevision.rawValue`; nil = absent row); the committed winner
/// rides as a ``DaemonStrategySnapshot`` so the caller can offer Reload.
public struct DaemonStrategyConflictDetail: Codable, Equatable, Sendable {
    public let expectedRevision: Int64?
    public let currentRevision: Int64?
    public let currentStrategy: DaemonStrategySnapshot?

    public init(
        expectedRevision: Int64?, currentRevision: Int64?,
        currentStrategy: DaemonStrategySnapshot?
    ) {
        self.expectedRevision = expectedRevision
        self.currentRevision = currentRevision
        self.currentStrategy = currentStrategy
    }
}

/// Mirror of `SourceMarkdownConflictError`: a CAS check failed on a source's
/// processed-markdown chain — the active head moved after the caller read
/// it. The write throws BEFORE any row, ref, or FTS change.
public struct DaemonSourceMarkdownConflictDetail: Codable, Equatable, Sendable {
    public let sourceID: String
    public let expectedHead: String
    public let currentHead: String?

    public init(sourceID: String, expectedHead: String, currentHead: String?) {
        self.sourceID = sourceID
        self.expectedHead = expectedHead
        self.currentHead = currentHead
    }
}

/// The store family's exhaustive typed error contract (plan 2a; the design
/// record's Error mapping table). One case per supported typed error with
/// associated values carried intact — every `WikiStoreError` case (IDs as
/// raw ULID strings; deliberate collapses: NONE), the CAS family as dedicated
/// mirror details, and the two transport-level cases. The daemon's executor
/// catches the typed store errors and produces these; the remote client
/// reconstructs the same typed errors the in-process path would have thrown.
public enum DaemonStoreError: Error, Codable, Equatable, Sendable,
    LocalizedError {
    /// Store open failed (`WikiStoreError.open`).
    case open(String)
    /// SQLite failure (`WikiStoreError.sqlite(code:message:)`) —
    /// transport-opaque: the code + `sqlite3_errmsg` text cross so failures
    /// are diagnosable, and nothing more specific is inferred.
    case sqlite(code: Int32, message: String)
    /// Typed not-found family (`WikiStoreError.notFound(PageID)`) — the page
    /// id crosses as its raw ULID string. NOT collapsed with the other
    /// not-found cases: each id namespace keeps its own case.
    case notFound(String)
    /// No chat row matches the id (`WikiStoreError.chatNotFound`).
    case chatNotFound(String)
    /// No source row matches the id (`WikiStoreError.sourceNotFound`).
    case sourceNotFound(String)
    /// No source content-version row matches the id
    /// (`WikiStoreError.sourceVersionNotFound`).
    case sourceVersionNotFound(String)
    /// No source markdown-version row matches the id
    /// (`WikiStoreError.sourceMarkdownVersionNotFound`).
    case sourceMarkdownVersionNotFound(String)
    /// The source has no processed-markdown chain yet
    /// (`WikiStoreError.noProcessedMarkdown` — extract/seed first).
    case noProcessedMarkdown(String)
    /// Deletion blocked by immutable provenance citations
    /// (`WikiStoreError.deletionRestricted`); the blockers cross in SQLite's
    /// deterministic order, never empty.
    case deletionRestricted(DaemonDeletionBlockers)
    /// A bookmark row failed validation
    /// (`WikiStoreError.invalidBookmarkRow(id:reason:)`).
    case invalidBookmarkRow(id: String, reason: String)
    /// A renderer event id failed validation
    /// (`WikiStoreError.invalidRendererEventID`).
    case invalidRendererEventID(String)
    /// An invariant violation that should be unreachable
    /// (`WikiStoreError.unexpected`).
    case unexpected(String)
    /// The incoming bytes are byte-identical to an already-stored source
    /// (`WikiStoreError.duplicateContent`); the existing row rides as a
    /// ``DaemonSourceSummary`` so callers can reference it.
    case duplicateContent(DaemonSourceSummary)
    /// An active source already records the same normalized URL provenance
    /// (`WikiStoreError.duplicateURL`); distinct from content-hash
    /// deduplication, which happens only after bytes are available.
    case duplicateURL(DaemonSourceSummary)
    /// CAS: the page head moved (`PageConflictError`).
    case pageConflict(DaemonPageConflictDetail)
    /// CAS: a create-only page write found the title occupied
    /// (`PageCreateConflictError`).
    case pageCreateConflict(DaemonPageCreateConflictDetail)
    /// CAS: an expected-head write whose target no longer exists
    /// (`PageExpectedTargetMissingError`).
    case pageExpectedTargetMissing(DaemonPageExpectedTargetMissingDetail)
    /// CAS: the strategy revision moved (`WikiStrategyConflictError`).
    case strategyRevisionConflict(DaemonStrategyConflictDetail)
    /// CAS: the processed-markdown head moved
    /// (`SourceMarkdownConflictError`).
    case sourceMarkdownConflict(DaemonSourceMarkdownConflictDetail)
    /// Transport-level: the daemon is unreachable / the connection died
    /// before an answer. Nothing queues locally and no local fallback exists.
    case daemonUnavailable(String)
    /// Transport-level outcome semantics: a mutation may or may not have
    /// committed (post-eviction resolve, restart). The client reconciles
    /// through change tokens; it never blind-retries.
    case outcomeUnknown(String)

    public var errorDescription: String? {
        switch self {
        case .open(let message):
            return "WikiStore open failed: \(message)"
        case .sqlite(let code, let message):
            return "SQLite error \(code): \(message)"
        case .notFound(let id):
            return "Page not found: \(id)"
        case .chatNotFound(let id):
            return "Chat not found: \(id)"
        case .sourceNotFound(let id):
            return "Source not found: \(id)"
        case .sourceVersionNotFound(let id):
            return "Source version not found: \(id)"
        case .sourceMarkdownVersionNotFound(let id):
            return "Source markdown version not found: \(id)"
        case .noProcessedMarkdown(let id):
            return "Source has no processed markdown yet: \(id) — "
                + "extract or seed it first"
        case .deletionRestricted(let blockers):
            return "Source deletion restricted by "
                + "\(blockers.ordered.count) page version provenance "
                + "reference(s)"
        case .invalidBookmarkRow(let id, let reason):
            return "Invalid bookmark row \(id): \(reason)"
        case .invalidRendererEventID(let raw):
            return "Invalid renderer event ID: \(raw)"
        case .unexpected(let message):
            return "Unexpected: \(message)"
        case .duplicateContent(let existing):
            return "Duplicate content: already stored as "
                + "\(existing.displayName ?? existing.filename) (\(existing.id))"
        case .duplicateURL(let existing):
            return "Duplicate URL: already stored as "
                + "\(existing.displayName ?? existing.filename) (\(existing.id))"
        case .pageConflict(let detail):
            return "Page conflict on \(detail.pageID): expected "
                + "\(detail.expectedVersionID), actual "
                + "\(detail.actualVersionID ?? "none")"
        case .pageCreateConflict(let detail):
            return "Page '\(detail.title)' already exists as "
                + "\(detail.pageID) — re-read and reconcile"
        case .pageExpectedTargetMissing(let detail):
            return "Page target missing for '\(detail.title)' — expected "
                + "\(detail.expectedHeadVersionID)"
        case .strategyRevisionConflict(let detail):
            return "Strategy revision conflict: expected "
                + "\(detail.expectedRevision.map(String.init) ?? "absent"), "
                + "current "
                + "\(detail.currentRevision.map(String.init) ?? "absent")"
        case .sourceMarkdownConflict(let detail):
            return "Source markdown conflict on \(detail.sourceID): expected "
                + "\(detail.expectedHead), current "
                + "\(detail.currentHead ?? "none")"
        case .daemonUnavailable(let message):
            return "The wiki daemon is unavailable: \(message)"
        case .outcomeUnknown(let message):
            return "Mutation outcome unknown: \(message)"
        }
    }
}

// MARK: - Store family envelopes

/// The `store` family's request payload: the JSON inside a `.store` domain
/// envelope's `payload`. One operation per request; slice 2's per-op DTOs
/// ride in `payload` as their JSON bytes.
public struct DaemonStoreRequest: Codable, Equatable, Sendable {
    public let version: UInt16
    /// The wiki's raw ULID string (admission, watermark, and dispatch scope).
    public let wikiID: String
    /// A ``DaemonStoreOperation`` raw value; unknown strings are typed
    /// `invalidRequest` rejections.
    public let operation: String
    /// Mutation admission stamp; `nil` for reads and resolve-only calls.
    public let stamp: DaemonMutationStamp?
    /// Operation-specific JSON bytes (slice 2's DTOs); `nil` where the
    /// operation carries none.
    public let payload: Data?

    public init(
        version: UInt16 = DaemonStoreWireVersion.current,
        wikiID: String,
        operation: String,
        stamp: DaemonMutationStamp? = nil,
        payload: Data? = nil
    ) {
        self.version = version
        self.wikiID = wikiID
        self.operation = operation
        self.stamp = stamp
        self.payload = payload
    }
}

/// The `store` family's reply payload: the JSON inside a `.store` domain
/// envelope's `payload` on BOTH outcomes. `result` carries the operation's
/// reply DTO bytes on success; `error` carries the typed rejection otherwise
/// — a store failure is never stringified into the outer envelope's
/// `operationFailed`.
public struct DaemonStoreReply: Codable, Equatable, Sendable {
    public let version: UInt16
    /// Operation-specific JSON bytes on success; `nil` on failure.
    public let result: Data?
    /// Typed rejection; `nil` on success.
    public let error: DaemonStoreError?

    public init(
        version: UInt16 = DaemonStoreWireVersion.current,
        result: Data?,
        error: DaemonStoreError?
    ) {
        self.version = version
        self.result = result
        self.error = error
    }
}

/// Encode/decode for the store family payload pair. Decode failures are
/// typed — a malformed store payload is a rejection INSIDE the reply, never
/// a transport fault.
public enum DaemonStoreWire {
    public static func encode(_ request: DaemonStoreRequest) throws -> Data {
        try JSONEncoder().encode(request)
    }

    public static func decodeRequest(_ data: Data) throws -> DaemonStoreRequest {
        let request: DaemonStoreRequest
        do {
            request = try JSONDecoder().decode(DaemonStoreRequest.self, from: data)
        } catch {
            throw DaemonStoreError.unexpected(
                "store request could not be decoded: "
                    + String(describing: error).prefix(200).description)
        }
        guard request.version == DaemonStoreWireVersion.current else {
            throw DaemonStoreError.unexpected(
                "unsupported store wire version: \(request.version)")
        }
        return request
    }

    public static func encode(_ reply: DaemonStoreReply) throws -> Data {
        try JSONEncoder().encode(reply)
    }

    public static func decodeReply(_ data: Data) throws -> DaemonStoreReply {
        do {
            return try JSONDecoder().decode(DaemonStoreReply.self, from: data)
        } catch {
            throw DaemonStoreError.unexpected(
                "store reply could not be decoded: "
                    + String(describing: error).prefix(200).description)
        }
    }
}

// MARK: - Frame sizing (the ONE place the math lives)

/// Errors raised by the frame sizing checks. Typed, so an oversized chunk or
/// envelope is a contract rejection, never a silent truncation or a raw
/// transport fault.
public enum DaemonStoreFrameError: Error, Equatable, Sendable, LocalizedError {
    /// The FINAL OUTER encoded envelope exceeded the transport frame cap.
    case exceedsMaxFrameSize(outerEncodedBytes: Int, limit: UInt32)
    /// One chunk request carried more raw bytes than
    /// ``DaemonStoreLimits/maxChunkBytes``.
    case chunkTooLarge(rawBytes: Int, limit: Int)

    public var errorDescription: String? {
        switch self {
        case .exceedsMaxFrameSize(let outerEncodedBytes, let limit):
            return "encoded envelope of \(outerEncodedBytes) bytes exceeds "
                + "the \(limit)-byte frame cap — chunk it through "
                + "payloadBegin/payloadChunk/payloadCommit"
        case .chunkTooLarge(let rawBytes, let limit):
            return "chunk of \(rawBytes) raw bytes exceeds the "
                + "\(limit)-byte chunk limit"
        }
    }
}

/// The frame math in one place (plan 2a "tests assert the final outer
/// encoded size, never the inner DTO size"). A chunk crosses THREE base64
/// layers in the store family's envelope stack — chunk `Data` inside the
/// per-op DTO JSON, the DTO JSON bytes inside the store reply's `result`
/// `Data` field (the queue family nests its envelope the same way), and the
/// store reply JSON inside the domain envelope's `payload` `Data` field.
/// Each layer inflates 4/3 (JSONEncoder renders `Data` as base64); the FINAL
/// OUTER encoded envelope is what the framed transport carries, so THAT is
/// what every check measures (a full 1 MiB chunk ≈ 2.37 MiB outer — inside
/// the 4 MiB cap).
///
/// The executor's reply path and the client's request path both encode
/// through ``encodeValidatedRequest(_:)`` / ``encodeValidatedReply(_:)`` so
/// the cap is enforced at the only seam that produces frames.
public enum DaemonStoreFrameSizing {

    /// The outer frame cap the store family shares with the socket transport.
    public static let maxFrameSize: UInt32 = SearchSocketWire.maxFrameSize

    /// Base64 length of `rawByteCount` bytes (4 chars per 3 bytes, rounded
    /// up) — the inflation one JSON `Data` field contributes.
    public static func base64EncodedLength(_ rawByteCount: Int) -> Int {
        4 * ((rawByteCount + 2) / 3)
    }

    /// Conservative PRE-FLIGHT bound on the final outer encoded frame size
    /// for one store operation whose DTO JSON carries `rawChunkByteCount`
    /// raw bytes of `Data` (plus small fixed JSON overhead). Clients use it
    /// to plan chunk sizes before building requests; the bound covers the
    /// real encoded size (asserted by the wire tests) so preflight acceptance
    /// never surprises at encode time.
    ///
    /// Chain — every `Data` field appears in its container JSON as base64
    /// text, so each application inflates 4/3: chunk raw bytes → per-op DTO
    /// JSON → base64 as the store reply's `result` text → store reply JSON →
    /// base64 as the domain envelope's `payload` text → outer envelope JSON.
    public static func outerEncodedBound(rawChunkByteCount: Int) -> Int {
        // Layer 1: chunk `Data` inside the per-op DTO JSON, plus generous
        // fixed overhead for the remaining DTO keys (ids, order index,
        // running hash).
        let chunkDTOBytes = 512 + base64EncodedLength(rawChunkByteCount)
        // Layer 2: the DTO JSON bytes appear base64-encoded as the store
        // reply's `result` text, plus the reply's own keys.
        let storeReplyBytes = 256 + base64EncodedLength(chunkDTOBytes)
        // Layer 3: the store reply JSON bytes appear base64-encoded as the
        // domain envelope's `payload` text — the outer envelope's dominant
        // term.
        let payloadTextBytes = base64EncodedLength(storeReplyBytes)
        // The framed transport prepends the 4-byte length prefix; the outer
        // envelope JSON itself rides raw (no fourth base64 layer).
        return SearchSocketWire.lengthPrefixBytes + 256 + payloadTextBytes
    }

    /// True when `rawChunkByteCount`'s conservative outer bound fits the
    /// frame cap — the client's chunk-size planning check.
    public static func chunkFitsFrameCap(rawChunkByteCount: Int) -> Bool {
        outerEncodedBound(rawChunkByteCount: rawChunkByteCount)
            <= Int(maxFrameSize)
    }

    /// Validates one chunk request's raw size against the chunk limit
    /// (``DaemonStoreLimits/maxChunkBytes``).
    public static func validateChunkByteCount(_ rawByteCount: Int) throws {
        guard rawByteCount <= DaemonStoreLimits.maxChunkBytes else {
            throw DaemonStoreFrameError.chunkTooLarge(
                rawBytes: rawByteCount, limit: DaemonStoreLimits.maxChunkBytes)
        }
    }

    /// Encodes a `.store` REQUEST into its domain envelope and checks the
    /// FINAL OUTER encoded size against the frame cap. The executor and the
    /// remote store client send through this so an oversized envelope is a
    /// typed error at the seam that would produce the frame.
    public static func encodeValidatedRequest(
        _ request: DaemonDomainRequest
    ) throws -> Data {
        let data = try DaemonDomainWire.encode(request)
        guard data.count <= Int(maxFrameSize) else {
            throw DaemonStoreFrameError.exceedsMaxFrameSize(
                outerEncodedBytes: data.count, limit: maxFrameSize)
        }
        return data
    }

    /// Encodes a `.store` REPLY into its domain envelope and checks the
    /// FINAL OUTER encoded size against the frame cap (the executor's
    /// send seam).
    public static func encodeValidatedReply(
        _ reply: DaemonDomainReply
    ) throws -> Data {
        let data = try DaemonDomainWire.encode(reply)
        guard data.count <= Int(maxFrameSize) else {
            throw DaemonStoreFrameError.exceedsMaxFrameSize(
                outerEncodedBytes: data.count, limit: maxFrameSize)
        }
        return data
    }
}
#endif
