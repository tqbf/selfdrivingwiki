#if os(macOS)
import Foundation

// Blob-family per-operation DTOs for the store family (Phase 2a slice 2,
// tmp/store-ops-manifest.md blob partition — 39 operations): bytes or large
// text cross via ``DaemonPayloadHandle`` (uploads reference a committed
// staged handle; oversized downloads reference a daemon-issued read handle
// plus the byte count). Small metadata rides inline. Writes embed the
// ``DaemonMutationOutcome`` echo and, where the commit emits, the
// ``DaemonResourceChangeEvent`` echo; the three chunk stores are annotated
// NO-EMIT and carry no event. Requests carry only op-specific args — the
// wiki id and the mutation stamp ride the `DaemonStoreRequest` envelope.

// MARK: - Writes (bytes / content up)

/// `addSnapshotImage`: one snapshot image as a per-snapshot `.media` source
/// (no source-level dedup; the blob itself is still deduped).
public struct DaemonAddSnapshotImageRequest: Codable, Equatable, Sendable {
    public let filename: String
    public let data: DaemonPayloadHandle
    public let detectionHints: DaemonContentTypeDetectionHints
    public let originalPath: String
    public let sourceURL: String
    public let activityID: String
    public let role: DaemonSourceRole

    public init(
        filename: String, data: DaemonPayloadHandle,
        detectionHints: DaemonContentTypeDetectionHints, originalPath: String,
        sourceURL: String, activityID: String, role: DaemonSourceRole
    ) {
        self.filename = filename
        self.data = data
        self.detectionHints = detectionHints
        self.originalPath = originalPath
        self.sourceURL = sourceURL
        self.activityID = activityID
        self.role = role
    }
}

public struct DaemonAddSnapshotImageReply: Codable, Equatable, Sendable {
    public let source: DaemonSourceSummary
    public let outcome: DaemonMutationOutcome
    /// The commit's emitted change (nil mirrors a no-event commit).
    public let event: DaemonResourceChangeEvent?
    public init(
        source: DaemonSourceSummary, outcome: DaemonMutationOutcome,
        event: DaemonResourceChangeEvent?
    ) {
        self.source = source
        self.outcome = outcome
        self.event = event
    }
}

/// `addSource`: store verbatim source bytes with typed detection hints.
/// CARRIES ALL THREE PROTOCOL OVERLOADS losslessly: the 2-arg convenience
/// (`filename:data:`) maps to empty hints + nil metadata/provenance/
/// originalPath/activityID, role `.primary`, and `resolvedDisplayName == nil`
/// (core-side, an absent display name and an explicit nil both fall through
/// to the filename-derived resolver — `resolvedDisplayName ?? resolver`).
public struct DaemonAddSourceRequest: Codable, Equatable, Sendable {
    public let filename: String
    public let data: DaemonPayloadHandle
    public let detectionHints: DaemonContentTypeDetectionHints
    public let ingestMetadata: DaemonSourceIngestMetadata?
    public let provenance: DaemonSourceProvenance?
    public let role: DaemonSourceRole
    public let originalPath: String?
    public let activityID: String?
    public let resolvedDisplayName: String?

    public init(
        filename: String, data: DaemonPayloadHandle,
        detectionHints: DaemonContentTypeDetectionHints,
        ingestMetadata: DaemonSourceIngestMetadata?,
        provenance: DaemonSourceProvenance?, role: DaemonSourceRole,
        originalPath: String?, activityID: String?,
        resolvedDisplayName: String?
    ) {
        self.filename = filename
        self.data = data
        self.detectionHints = detectionHints
        self.ingestMetadata = ingestMetadata
        self.provenance = provenance
        self.role = role
        self.originalPath = originalPath
        self.activityID = activityID
        self.resolvedDisplayName = resolvedDisplayName
    }
}

public struct DaemonAddSourceReply: Codable, Equatable, Sendable {
    public let source: DaemonSourceSummary
    public let outcome: DaemonMutationOutcome
    public let event: DaemonResourceChangeEvent?
    public init(
        source: DaemonSourceSummary, outcome: DaemonMutationOutcome,
        event: DaemonResourceChangeEvent?
    ) {
        self.source = source
        self.outcome = outcome
        self.event = event
    }
}

/// `appendChatMessages`: append events as new `chat_messages` rows in one
/// transaction. `events` rides as a staged handle: its bytes are the JSON
/// array `[DaemonAgentEvent]` (an empty upload encodes the documented
/// skip-empty behavior store-side).
public struct DaemonAppendChatMessagesRequest: Codable, Equatable, Sendable {
    public let chatID: String
    /// Handle over the JSON array of `DaemonAgentEvent` values.
    public let events: DaemonPayloadHandle
    public let eventCount: Int

    public init(chatID: String, events: DaemonPayloadHandle, eventCount: Int) {
        self.chatID = chatID
        self.events = events
        self.eventCount = eventCount
    }
}

public struct DaemonAppendChatMessagesReply: Codable, Equatable, Sendable {
    /// The inserted rows in `seq` order (ids/seq assigned store-side).
    public let messages: [DaemonChatMessage]
    public let outcome: DaemonMutationOutcome
    public let event: DaemonResourceChangeEvent?
    public init(
        messages: [DaemonChatMessage], outcome: DaemonMutationOutcome,
        event: DaemonResourceChangeEvent?
    ) {
        self.messages = messages
        self.outcome = outcome
        self.event = event
    }
}

/// `appendChatTranscriptItems`: persist typed transcript rows while
/// maintaining the renderer compatibility projection. `items` rides as a
/// staged handle over the JSON array `[DaemonChatTranscriptItem]`.
public struct DaemonAppendChatTranscriptItemsRequest: Codable, Equatable,
    Sendable {
    public let chatID: String
    /// Handle over the JSON array of `DaemonChatTranscriptItem` values.
    public let items: DaemonPayloadHandle
    public let itemCount: Int

    public init(chatID: String, items: DaemonPayloadHandle, itemCount: Int) {
        self.chatID = chatID
        self.items = items
        self.itemCount = itemCount
    }
}

public struct DaemonAppendChatTranscriptItemsReply: Codable, Equatable,
    Sendable {
    /// The persisted rows with their assigned cursors.
    public let items: [DaemonPersistedChatTranscriptItem]
    public let outcome: DaemonMutationOutcome
    public let event: DaemonResourceChangeEvent?
    public init(
        items: [DaemonPersistedChatTranscriptItem],
        outcome: DaemonMutationOutcome, event: DaemonResourceChangeEvent?
    ) {
        self.items = items
        self.outcome = outcome
        self.event = event
    }
}

/// `appendContentVersion`: the store-level refresh/re-ingest primitive (new
/// content version + ref UPSERT + mirror refresh in one transaction).
public struct DaemonAppendContentVersionRequest: Codable, Equatable, Sendable {
    public let sourceID: String
    public let data: DaemonPayloadHandle
    public let detectionHints: DaemonContentTypeDetectionHints
    public let provenance: DaemonSourceProvenance?

    public init(
        sourceID: String, data: DaemonPayloadHandle,
        detectionHints: DaemonContentTypeDetectionHints,
        provenance: DaemonSourceProvenance?
    ) {
        self.sourceID = sourceID
        self.data = data
        self.detectionHints = detectionHints
        self.provenance = provenance
    }
}

public struct DaemonAppendContentVersionReply: Codable, Equatable, Sendable {
    public let version: DaemonSourceVersion
    public let outcome: DaemonMutationOutcome
    public let event: DaemonResourceChangeEvent?
    public init(
        version: DaemonSourceVersion, outcome: DaemonMutationOutcome,
        event: DaemonResourceChangeEvent?
    ) {
        self.version = version
        self.outcome = outcome
        self.event = event
    }
}

/// `appendDerivedMarkdown`: typed, non-user derived markdown made the active
/// head. `content` rides as a staged handle over the UTF-8 markdown; the
/// reply echoes the committed version's metadata — the content is exactly
/// the uploaded bytes (the store hashes them verbatim).
public struct DaemonAppendDerivedMarkdownRequest: Codable, Equatable,
    Sendable {
    public let sourceID: String
    public let content: DaemonPayloadHandle
    public let origin: DaemonSourceMarkdownOrigin
    public let producer: DaemonExtractionProducer?
    public let providerID: String?
    public let modelID: String?
    public let toolVersion: String?
    public let sourceVersionID: String?
    public let note: String?

    public init(
        sourceID: String, content: DaemonPayloadHandle,
        origin: DaemonSourceMarkdownOrigin,
        producer: DaemonExtractionProducer?, providerID: String?,
        modelID: String?, toolVersion: String?, sourceVersionID: String?,
        note: String?
    ) {
        self.sourceID = sourceID
        self.content = content
        self.origin = origin
        self.producer = producer
        self.providerID = providerID
        self.modelID = modelID
        self.toolVersion = toolVersion
        self.sourceVersionID = sourceVersionID
        self.note = note
    }
}

public struct DaemonAppendDerivedMarkdownReply: Codable, Equatable, Sendable {
    /// Header of the committed version; content == the uploaded bytes.
    public let version: DaemonSourceMarkdownVersionHeader
    public let outcome: DaemonMutationOutcome
    public let event: DaemonResourceChangeEvent?
    public init(
        version: DaemonSourceMarkdownVersionHeader,
        outcome: DaemonMutationOutcome, event: DaemonResourceChangeEvent?
    ) {
        self.version = version
        self.outcome = outcome
        self.event = event
    }
}

/// `appendFetchMarkdown`: the fetcher markdown result's single-transaction
/// write (derived markdown version + external provenance + `complete`
/// advance).
public struct DaemonAppendFetchMarkdownRequest: Codable, Equatable, Sendable {
    public let sourceID: String
    public let content: DaemonPayloadHandle
    public let package: DaemonExtractorPackageProducer
    public let externalItemKey: String?
    public let externalItemTitle: String?
    public let sourceVersionID: String

    public init(
        sourceID: String, content: DaemonPayloadHandle,
        package: DaemonExtractorPackageProducer, externalItemKey: String?,
        externalItemTitle: String?, sourceVersionID: String
    ) {
        self.sourceID = sourceID
        self.content = content
        self.package = package
        self.externalItemKey = externalItemKey
        self.externalItemTitle = externalItemTitle
        self.sourceVersionID = sourceVersionID
    }
}

public struct DaemonAppendFetchMarkdownReply: Codable, Equatable, Sendable {
    public let version: DaemonSourceMarkdownVersionHeader
    public let outcome: DaemonMutationOutcome
    public let event: DaemonResourceChangeEvent?
    public init(
        version: DaemonSourceMarkdownVersionHeader,
        outcome: DaemonMutationOutcome, event: DaemonResourceChangeEvent?
    ) {
        self.version = version
        self.outcome = outcome
        self.event = event
    }
}

/// `appendHostSpeechTranscript`: one HOST-produced on-device speech
/// transcript as ONE `.transcript` version (required initial-version link).
public struct DaemonAppendHostSpeechTranscriptRequest: Codable, Equatable,
    Sendable {
    public let sourceID: String
    public let content: DaemonPayloadHandle
    public let producer: DaemonExtractionHostSpeechProducer
    public let sourceVersionID: String

    public init(
        sourceID: String, content: DaemonPayloadHandle,
        producer: DaemonExtractionHostSpeechProducer, sourceVersionID: String
    ) {
        self.sourceID = sourceID
        self.content = content
        self.producer = producer
        self.sourceVersionID = sourceVersionID
    }
}

public struct DaemonAppendHostSpeechTranscriptReply: Codable, Equatable,
    Sendable {
    public let version: DaemonSourceMarkdownVersionHeader
    public let outcome: DaemonMutationOutcome
    public let event: DaemonResourceChangeEvent?
    public init(
        version: DaemonSourceMarkdownVersionHeader,
        outcome: DaemonMutationOutcome, event: DaemonResourceChangeEvent?
    ) {
        self.version = version
        self.outcome = outcome
        self.event = event
    }
}

/// `appendInstalledPackageMarkdown`: one package-backed result with exact
/// immutable package identity (the origin is derived store-side: `.extraction`
/// for document packages, `.transcript` for package transcripts).
public struct DaemonAppendInstalledPackageMarkdownRequest: Codable, Equatable,
    Sendable {
    public let sourceID: String
    public let content: DaemonPayloadHandle
    public let package: DaemonExtractorPackageProducer
    public let origin: DaemonSourceMarkdownOrigin
    public let toolVersion: String?
    public let sourceVersionID: String?
    public let note: String?

    public init(
        sourceID: String, content: DaemonPayloadHandle,
        package: DaemonExtractorPackageProducer,
        origin: DaemonSourceMarkdownOrigin, toolVersion: String?,
        sourceVersionID: String?, note: String?
    ) {
        self.sourceID = sourceID
        self.content = content
        self.package = package
        self.origin = origin
        self.toolVersion = toolVersion
        self.sourceVersionID = sourceVersionID
        self.note = note
    }
}

public struct DaemonAppendInstalledPackageMarkdownReply: Codable, Equatable,
    Sendable {
    public let version: DaemonSourceMarkdownVersionHeader
    public let outcome: DaemonMutationOutcome
    public let event: DaemonResourceChangeEvent?
    public init(
        version: DaemonSourceMarkdownVersionHeader,
        outcome: DaemonMutationOutcome, event: DaemonResourceChangeEvent?
    ) {
        self.version = version
        self.outcome = outcome
        self.event = event
    }
}

/// `appendPageVersion`: append a new page version with CAS conflict
/// detection. CARRIES BOTH CORE SHAPES: a nil `expectedHeadVersionID` is the
/// blind write; the empty-body overload maps to a nil `body` handle (a
/// zero-byte body and a missing body commit identically).
public struct DaemonAppendPageVersionRequest: Codable, Equatable, Sendable {
    public let pageID: String
    public let title: String
    /// Handle over the UTF-8 body; nil = the empty body.
    public let body: DaemonPayloadHandle?
    public let expectedHeadVersionID: String?
    public let lastEditedBy: String?
    public let provenance: [DaemonPageVersionSourceInput]

    public init(
        pageID: String, title: String, body: DaemonPayloadHandle?,
        expectedHeadVersionID: String?, lastEditedBy: String?,
        provenance: [DaemonPageVersionSourceInput]
    ) {
        self.pageID = pageID
        self.title = title
        self.body = body
        self.expectedHeadVersionID = expectedHeadVersionID
        self.lastEditedBy = lastEditedBy
        self.provenance = provenance
    }
}

public struct DaemonAppendPageVersionReply: Codable, Equatable, Sendable {
    public let versionID: String
    public let outcome: DaemonMutationOutcome
    public let event: DaemonResourceChangeEvent?
    public init(
        versionID: String, outcome: DaemonMutationOutcome,
        event: DaemonResourceChangeEvent?
    ) {
        self.versionID = versionID
        self.outcome = outcome
        self.event = event
    }
}

/// `appendProcessedMarkdown`: append a new full-text markdown version (the
/// store reads the current head to set `parentID`).
public struct DaemonAppendProcessedMarkdownRequest: Codable, Equatable,
    Sendable {
    public let sourceID: String
    public let content: DaemonPayloadHandle
    public let origin: DaemonSourceMarkdownOrigin
    public let note: String?
    public let technique: String?

    public init(
        sourceID: String, content: DaemonPayloadHandle,
        origin: DaemonSourceMarkdownOrigin, note: String?, technique: String?
    ) {
        self.sourceID = sourceID
        self.content = content
        self.origin = origin
        self.note = note
        self.technique = technique
    }
}

public struct DaemonAppendProcessedMarkdownReply: Codable, Equatable,
    Sendable {
    public let version: DaemonSourceMarkdownVersionHeader
    public let outcome: DaemonMutationOutcome
    public let event: DaemonResourceChangeEvent?
    public init(
        version: DaemonSourceMarkdownVersionHeader,
        outcome: DaemonMutationOutcome, event: DaemonResourceChangeEvent?
    ) {
        self.version = version
        self.outcome = outcome
        self.event = event
    }
}

/// `appendUserProcessedMarkdown`: `.user` version with compare-and-swap on
/// the active head (a moved head is the typed
/// `sourceMarkdownConflict` rejection before any row change).
public struct DaemonAppendUserProcessedMarkdownRequest: Codable, Equatable,
    Sendable {
    public let sourceID: String
    public let content: DaemonPayloadHandle
    public let expectedHead: String

    public init(
        sourceID: String, content: DaemonPayloadHandle, expectedHead: String
    ) {
        self.sourceID = sourceID
        self.content = content
        self.expectedHead = expectedHead
    }
}

public struct DaemonAppendUserProcessedMarkdownReply: Codable, Equatable,
    Sendable {
    public let version: DaemonSourceMarkdownVersionHeader
    public let outcome: DaemonMutationOutcome
    public let event: DaemonResourceChangeEvent?
    public init(
        version: DaemonSourceMarkdownVersionHeader,
        outcome: DaemonMutationOutcome, event: DaemonResourceChangeEvent?
    ) {
        self.version = version
        self.outcome = outcome
        self.event = event
    }
}

/// `attachAcquiredBytes`: attach acquired bytes to an existing (byteless)
/// source — the attachment drain's one store write.
public struct DaemonAttachAcquiredBytesRequest: Codable, Equatable, Sendable {
    public let sourceID: String
    public let bytes: DaemonPayloadHandle
    public let mimeType: String
    public let originalFilename: String?
    public let externalItemKey: String?
    public let externalItemTitle: String?
    public let producer: DaemonExtractorPackageProducer?

    public init(
        sourceID: String, bytes: DaemonPayloadHandle, mimeType: String,
        originalFilename: String?, externalItemKey: String?,
        externalItemTitle: String?, producer: DaemonExtractorPackageProducer?
    ) {
        self.sourceID = sourceID
        self.bytes = bytes
        self.mimeType = mimeType
        self.originalFilename = originalFilename
        self.externalItemKey = externalItemKey
        self.externalItemTitle = externalItemTitle
        self.producer = producer
    }
}

public struct DaemonAttachAcquiredBytesReply: Codable, Equatable, Sendable {
    public let version: DaemonSourceVersion
    public let outcome: DaemonMutationOutcome
    public let event: DaemonResourceChangeEvent?
    public init(
        version: DaemonSourceVersion, outcome: DaemonMutationOutcome,
        event: DaemonResourceChangeEvent?
    ) {
        self.version = version
        self.outcome = outcome
        self.event = event
    }
}

/// `checkpointStreamingMessage`: upsert a streaming assistant row under a
/// stable draft handle (#826). The event rides as a staged handle over its
/// JSON `DaemonAgentEvent` encoding.
public struct DaemonCheckpointStreamingMessageRequest: Codable, Equatable,
    Sendable {
    public let chatID: String
    public let handle: String
    /// Handle over the JSON `DaemonAgentEvent` value.
    public let event: DaemonPayloadHandle
    public let isDraft: Bool

    public init(
        chatID: String, handle: String, event: DaemonPayloadHandle,
        isDraft: Bool
    ) {
        self.chatID = chatID
        self.handle = handle
        self.event = event
        self.isDraft = isDraft
    }
}

public struct DaemonCheckpointStreamingMessageReply: Codable, Equatable,
    Sendable {
    public let outcome: DaemonMutationOutcome
    public let event: DaemonResourceChangeEvent?
    public init(
        outcome: DaemonMutationOutcome, event: DaemonResourceChangeEvent?
    ) {
        self.outcome = outcome
        self.event = event
    }
}

/// `claimNextPersistedChatTurn`: atomically claim the oldest queued turn.
/// CARRIES BOTH OVERLOADS losslessly: the 3-arg claim maps to nil
/// provider/model snapshots; the 5-arg claim carries them.
public struct DaemonClaimNextPersistedChatTurnRequest: Codable, Equatable,
    Sendable {
    public let chatID: String
    public let claimID: String
    public let claimedAt: Date
    public let providerID: String?
    public let modelID: String?

    public init(
        chatID: String, claimID: String, claimedAt: Date,
        providerID: String?, modelID: String?
    ) {
        self.chatID = chatID
        self.claimID = claimID
        self.claimedAt = claimedAt
        self.providerID = providerID
        self.modelID = modelID
    }
}

public struct DaemonClaimNextPersistedChatTurnReply: Codable, Equatable,
    Sendable {
    /// nil when no queued turn remains.
    public let turn: DaemonPersistedChatTurn?
    public let outcome: DaemonMutationOutcome
    public let event: DaemonResourceChangeEvent?
    public init(
        turn: DaemonPersistedChatTurn?, outcome: DaemonMutationOutcome,
        event: DaemonResourceChangeEvent?
    ) {
        self.turn = turn
        self.outcome = outcome
        self.event = event
    }
}

/// `createPage`: create a page. CARRIES ALL THREE OVERLOADS losslessly: the
/// 1-arg (`title:`) maps to nil body/createdBy and empty provenance; the
/// 3-arg (`title:createdBy:provenance:`) maps to a nil body (the empty
/// body); the full form carries the body handle. The reply carries the page
/// WITHOUT its body inline — the committed (canonicalized) body may differ
/// from the uploaded raw body, so it crosses via a daemon-issued handle.
public struct DaemonCreatePageRequest: Codable, Equatable, Sendable {
    public let title: String
    /// Handle over the UTF-8 body; nil = the empty body.
    public let body: DaemonPayloadHandle?
    public let createdBy: String?
    public let provenance: [DaemonPageVersionSourceInput]

    public init(
        title: String, body: DaemonPayloadHandle?, createdBy: String?,
        provenance: [DaemonPageVersionSourceInput]
    ) {
        self.title = title
        self.body = body
        self.createdBy = createdBy
        self.provenance = provenance
    }
}

public struct DaemonCreatePageReply: Codable, Equatable, Sendable {
    /// The committed page's metadata (everything but the body).
    public let page: DaemonPageMetadata
    /// Handle over the committed (canonicalized) body — read through
    /// `payloadRead` before the handle's TTL.
    public let body: DaemonPayloadHandle
    public let bodyByteCount: Int
    public let outcome: DaemonMutationOutcome
    public let event: DaemonResourceChangeEvent?

    public init(
        page: DaemonPageMetadata, body: DaemonPayloadHandle,
        bodyByteCount: Int, outcome: DaemonMutationOutcome,
        event: DaemonResourceChangeEvent?
    ) {
        self.page = page
        self.body = body
        self.bodyByteCount = bodyByteCount
        self.outcome = outcome
        self.event = event
    }
}

/// `enqueuePersistedChatTurn`: persist one durable Phase 2 turn (the
/// commandID boundary is idempotent per chat store-side).
public struct DaemonEnqueuePersistedChatTurnRequest: Codable, Equatable,
    Sendable {
    public let chatID: String
    public let submission: DaemonChatTurnSubmission

    public init(chatID: String, submission: DaemonChatTurnSubmission) {
        self.chatID = chatID
        self.submission = submission
    }
}

public struct DaemonEnqueuePersistedChatTurnReply: Codable, Equatable,
    Sendable {
    public let turn: DaemonPersistedChatTurn
    public let outcome: DaemonMutationOutcome
    public let event: DaemonResourceChangeEvent?
    public init(
        turn: DaemonPersistedChatTurn, outcome: DaemonMutationOutcome,
        event: DaemonResourceChangeEvent?
    ) {
        self.turn = turn
        self.outcome = outcome
        self.event = event
    }
}

/// `finishPersistedChatTurn`: mark a claimed or submitted durable turn
/// terminal. CARRIES BOTH OVERLOADS losslessly: the 5-arg finish maps to nil
/// `finishedAt` (store stamps "now") and nil `usage`.
public struct DaemonFinishPersistedChatTurnRequest: Codable, Equatable,
    Sendable {
    public let chatID: String
    public let turnID: String
    public let claimID: String
    public let state: DaemonChatTurnPersistenceState
    public let terminalMessage: String?
    /// nil = the store stamps "now" (the 5-arg overload's behavior).
    public let finishedAt: Date?
    public let usage: DaemonChatTurnUsageValues?

    public init(
        chatID: String, turnID: String, claimID: String,
        state: DaemonChatTurnPersistenceState, terminalMessage: String?,
        finishedAt: Date?, usage: DaemonChatTurnUsageValues?
    ) {
        self.chatID = chatID
        self.turnID = turnID
        self.claimID = claimID
        self.state = state
        self.terminalMessage = terminalMessage
        self.finishedAt = finishedAt
        self.usage = usage
    }
}

public struct DaemonFinishPersistedChatTurnReply: Codable, Equatable,
    Sendable {
    public let turn: DaemonPersistedChatTurn
    public let outcome: DaemonMutationOutcome
    public let event: DaemonResourceChangeEvent?
    public init(
        turn: DaemonPersistedChatTurn, outcome: DaemonMutationOutcome,
        event: DaemonResourceChangeEvent?
    ) {
        self.turn = turn
        self.outcome = outcome
        self.event = event
    }
}

// MARK: - Reads (bytes / content down)

/// `getPage`: the full wiki page. The body crosses via a daemon-issued
/// handle beside the inline metadata.
public struct DaemonGetPageRequest: Codable, Equatable, Sendable {
    public let id: String
    public init(id: String) { self.id = id }
}

public struct DaemonGetPageReply: Codable, Equatable, Sendable {
    public let page: DaemonPageMetadata
    public let body: DaemonPayloadHandle
    public let bodyByteCount: Int

    public init(
        page: DaemonPageMetadata, body: DaemonPayloadHandle,
        bodyByteCount: Int
    ) {
        self.page = page
        self.body = body
        self.bodyByteCount = bodyByteCount
    }
}

/// `getWikiIndex`: the curated singleton catalog. The body crosses via a
/// handle beside the inline metadata (nil handle = the seeded default body
/// store-side is still materialized as a handle; absence never occurs).
public struct DaemonGetWikiIndexRequest: Codable, Equatable, Sendable {
    public init() {}
}

public struct DaemonGetWikiIndexReply: Codable, Equatable, Sendable {
    public let metadata: DaemonWikiIndexMetadata
    public let body: DaemonPayloadHandle
    public let bodyByteCount: Int

    public init(
        metadata: DaemonWikiIndexMetadata, body: DaemonPayloadHandle,
        bodyByteCount: Int
    ) {
        self.metadata = metadata
        self.body = body
        self.bodyByteCount = bodyByteCount
    }
}

/// `getWikiStrategy`: the committed strategy document, or nil when the wiki
/// uses the Default strategy. BOUNDED INLINE (reuses slice 1's snapshot):
/// instructions are validated ≤ 32 KiB store-side
/// (`WikiStrategy.instructionsUTF8ByteLimit`), far under the 1 MiB chunk
/// limit, so no handle round trip is warranted.
public struct DaemonGetWikiStrategyRequest: Codable, Equatable, Sendable {
    public init() {}
}

public struct DaemonGetWikiStrategyReply: Codable, Equatable, Sendable {
    public let strategy: DaemonStrategySnapshot?
    public init(strategy: DaemonStrategySnapshot?) {
        self.strategy = strategy
    }
}

/// `missingPageEmbeddingWork` / `missingSourceEmbeddingWork` /
/// `missingChatEmbeddingWork`: the backfill batch. The `[(id, text)]` pairs
/// ride as ONE staged handle over the JSON array
/// `[{id: String, text: String}]` (page bodies are full-text sized);
/// `itemCount` pins the expected length.
public struct DaemonMissingPageEmbeddingWorkRequest: Codable, Equatable,
    Sendable {
    public init() {}
}

public struct DaemonMissingPageEmbeddingWorkReply: Codable, Equatable,
    Sendable {
    /// Handle over the JSON array of `{id, text}` objects.
    public let work: DaemonPayloadHandle
    public let itemCount: Int

    public init(work: DaemonPayloadHandle, itemCount: Int) {
        self.work = work
        self.itemCount = itemCount
    }
}

/// `missingSourceEmbeddingWork`: see `missingPageEmbeddingWork`.
public struct DaemonMissingSourceEmbeddingWorkRequest: Codable, Equatable,
    Sendable {
    public init() {}
}

public struct DaemonMissingSourceEmbeddingWorkReply: Codable, Equatable,
    Sendable {
    public let work: DaemonPayloadHandle
    public let itemCount: Int

    public init(work: DaemonPayloadHandle, itemCount: Int) {
        self.work = work
        self.itemCount = itemCount
    }
}

/// `missingChatEmbeddingWork`: see `missingPageEmbeddingWork`.
public struct DaemonMissingChatEmbeddingWorkRequest: Codable, Equatable,
    Sendable {
    public init() {}
}

public struct DaemonMissingChatEmbeddingWorkReply: Codable, Equatable,
    Sendable {
    public let work: DaemonPayloadHandle
    public let itemCount: Int

    public init(work: DaemonPayloadHandle, itemCount: Int) {
        self.work = work
        self.itemCount = itemCount
    }
}

/// `pageVersionBody`: the blob-decoded body of one historical page version;
/// nil handle = no row matches. READ-ONLY.
public struct DaemonPageVersionBodyRequest: Codable, Equatable, Sendable {
    public let versionID: String
    public init(versionID: String) { self.versionID = versionID }
}

public struct DaemonPageVersionBodyReply: Codable, Equatable, Sendable {
    /// Handle over the UTF-8 body; nil = no matching version row.
    public let body: DaemonPayloadHandle?
    public let bodyByteCount: Int

    public init(body: DaemonPayloadHandle?, bodyByteCount: Int) {
        self.body = body
        self.bodyByteCount = bodyByteCount
    }
}

/// `processedMarkdownHead`: the HEAD processed-markdown version (nil = not
/// seeded/extracted yet). Content rides via a handle beside the header.
public struct DaemonProcessedMarkdownHeadRequest: Codable, Equatable,
    Sendable {
    public let sourceID: String
    public init(sourceID: String) { self.sourceID = sourceID }
}

public struct DaemonProcessedMarkdownHeadReply: Codable, Equatable, Sendable {
    public let version: DaemonSourceMarkdownVersionHeader?
    /// Handle over the UTF-8 content; present exactly when `version` is.
    public let content: DaemonPayloadHandle?
    public let contentByteCount: Int

    public init(
        version: DaemonSourceMarkdownVersionHeader?,
        content: DaemonPayloadHandle?, contentByteCount: Int
    ) {
        self.version = version
        self.content = content
        self.contentByteCount = contentByteCount
    }
}

/// `processedMarkdownVersion`: one resolved-markdown version by smv id
/// (nil = no row matches). Content rides via a handle beside the header.
public struct DaemonProcessedMarkdownVersionRequest: Codable, Equatable,
    Sendable {
    public let versionID: String
    public init(versionID: String) { self.versionID = versionID }
}

public struct DaemonProcessedMarkdownVersionReply: Codable, Equatable,
    Sendable {
    public let version: DaemonSourceMarkdownVersionHeader?
    public let content: DaemonPayloadHandle?
    public let contentByteCount: Int

    public init(
        version: DaemonSourceMarkdownVersionHeader?,
        content: DaemonPayloadHandle?, contentByteCount: Int
    ) {
        self.version = version
        self.content = content
        self.contentByteCount = contentByteCount
    }
}

/// `recordMarkdownExtraction`: a provenance-carrying extraction alternative
/// (agent + extract activity + CAS'd markdown row in one transaction; no
/// ref write — alternatives coexist).
public struct DaemonRecordMarkdownExtractionRequest: Codable, Equatable,
    Sendable {
    public let sourceID: String
    public let content: DaemonPayloadHandle
    /// `ExtractionBackend` raw value.
    public let backend: String
    public let sourceVersionID: String?
    public let note: String?
    public let modelVersion: String?

    public init(
        sourceID: String, content: DaemonPayloadHandle, backend: String,
        sourceVersionID: String?, note: String?, modelVersion: String?
    ) {
        self.sourceID = sourceID
        self.content = content
        self.backend = backend
        self.sourceVersionID = sourceVersionID
        self.note = note
        self.modelVersion = modelVersion
    }
}

public struct DaemonRecordMarkdownExtractionReply: Codable, Equatable,
    Sendable {
    public let version: DaemonSourceMarkdownVersionHeader
    public let outcome: DaemonMutationOutcome
    public let event: DaemonResourceChangeEvent?
    public init(
        version: DaemonSourceMarkdownVersionHeader,
        outcome: DaemonMutationOutcome, event: DaemonResourceChangeEvent?
    ) {
        self.version = version
        self.outcome = outcome
        self.event = event
    }
}

/// `saveWikiStrategy`: compare-and-swap save of the strategy document.
/// Instructions ride as a staged handle over the UTF-8 document (validated
/// ≤ 32 KiB store-side); `expectedRevision` is `WikiStrategyRevision.rawValue`
/// (nil matches only a wiki where no row has ever been written).
public struct DaemonSaveWikiStrategyRequest: Codable, Equatable, Sendable {
    public let name: String
    public let instructions: DaemonPayloadHandle
    public let expectedRevision: Int64?

    public init(
        name: String, instructions: DaemonPayloadHandle,
        expectedRevision: Int64?
    ) {
        self.name = name
        self.instructions = instructions
        self.expectedRevision = expectedRevision
    }
}

public struct DaemonSaveWikiStrategyReply: Codable, Equatable, Sendable {
    /// The save's result (revision advanced + committed strategy, or
    /// unchanged with no event).
    public let result: DaemonWikiStrategySaveOutcome
    public let outcome: DaemonMutationOutcome
    public let event: DaemonResourceChangeEvent?

    public init(
        result: DaemonWikiStrategySaveOutcome,
        outcome: DaemonMutationOutcome, event: DaemonResourceChangeEvent?
    ) {
        self.result = result
        self.outcome = outcome
        self.event = event
    }
}

/// `setWorkspaceIndexBody`: stage wiki-index changes into a workspace
/// overlay.
public struct DaemonSetWorkspaceIndexBodyRequest: Codable, Equatable,
    Sendable {
    public let workspaceID: String
    public let indexBody: DaemonPayloadHandle
    public let indexBaseVersion: String

    public init(
        workspaceID: String, indexBody: DaemonPayloadHandle,
        indexBaseVersion: String
    ) {
        self.workspaceID = workspaceID
        self.indexBody = indexBody
        self.indexBaseVersion = indexBaseVersion
    }
}

public struct DaemonSetWorkspaceIndexBodyReply: Codable, Equatable, Sendable {
    public let outcome: DaemonMutationOutcome
    public let event: DaemonResourceChangeEvent?
    public init(
        outcome: DaemonMutationOutcome, event: DaemonResourceChangeEvent?
    ) {
        self.outcome = outcome
        self.event = event
    }
}

/// `sourceContent`: the verbatim bytes for one source. CARRIES BOTH OVERLOADS
/// as tagged cases: `.active` resolves the live `source-content` ref (the
/// staging path); `.version` reads one exact immutable content version (the
/// only source-byte read permitted to a version-pinned renderer session).
public enum DaemonSourceContentRequest: Codable, Equatable, Sendable {
    case active(sourceID: String)
    case version(versionID: String)
}

public struct DaemonSourceContentReply: Codable, Equatable, Sendable {
    /// Handle over the verbatim bytes; nil = the byteless/absent case —
    /// `.active` on a byteless source yields a committed EMPTY payload (the
    /// core returns empty `Data()` without throwing), `.version` with no row
    /// throws `.sourceVersionNotFound` so nil never appears there.
    public let bytes: DaemonPayloadHandle?
    public let byteCount: Int

    public init(bytes: DaemonPayloadHandle?, byteCount: Int) {
        self.bytes = bytes
        self.byteCount = byteCount
    }
}

/// `storePageChunks`: store or replace ALL chunk embeddings for a page.
/// Annotated NO-EMIT (derived data) — the reply carries the outcome echo and
/// NO event. `chunks` rides as a staged handle over the JSON array of
/// base64 chunk blobs (`[String]`, each 512 × Float32).
public struct DaemonStorePageChunksRequest: Codable, Equatable, Sendable {
    public let id: String
    /// Handle over the JSON array of base64-encoded chunk blobs.
    public let chunks: DaemonPayloadHandle
    public let chunkCount: Int

    public init(id: String, chunks: DaemonPayloadHandle, chunkCount: Int) {
        self.id = id
        self.chunks = chunks
        self.chunkCount = chunkCount
    }
}

public struct DaemonStorePageChunksReply: Codable, Equatable, Sendable {
    public let outcome: DaemonMutationOutcome
    public init(outcome: DaemonMutationOutcome) { self.outcome = outcome }
}

/// `storeSourceChunks`: see `storePageChunks`.
public struct DaemonStoreSourceChunksRequest: Codable, Equatable, Sendable {
    public let id: String
    public let chunks: DaemonPayloadHandle
    public let chunkCount: Int

    public init(id: String, chunks: DaemonPayloadHandle, chunkCount: Int) {
        self.id = id
        self.chunks = chunks
        self.chunkCount = chunkCount
    }
}

public struct DaemonStoreSourceChunksReply: Codable, Equatable, Sendable {
    public let outcome: DaemonMutationOutcome
    public init(outcome: DaemonMutationOutcome) { self.outcome = outcome }
}

/// `storeChatChunks`: see `storePageChunks`.
public struct DaemonStoreChatChunksRequest: Codable, Equatable, Sendable {
    public let id: String
    public let chunks: DaemonPayloadHandle
    public let chunkCount: Int

    public init(id: String, chunks: DaemonPayloadHandle, chunkCount: Int) {
        self.id = id
        self.chunks = chunks
        self.chunkCount = chunkCount
    }
}

public struct DaemonStoreChatChunksReply: Codable, Equatable, Sendable {
    public let outcome: DaemonMutationOutcome
    public init(outcome: DaemonMutationOutcome) { self.outcome = outcome }
}

/// `updatePage`: rewrite a page's title + body + provenance (the non-CAS
/// editor save).
public struct DaemonUpdatePageRequest: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    /// Handle over the UTF-8 body; nil = the empty body.
    public let body: DaemonPayloadHandle?
    public let lastEditedBy: String?
    public let provenance: [DaemonPageVersionSourceInput]

    public init(
        id: String, title: String, body: DaemonPayloadHandle?,
        lastEditedBy: String?, provenance: [DaemonPageVersionSourceInput]
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.lastEditedBy = lastEditedBy
        self.provenance = provenance
    }
}

public struct DaemonUpdatePageReply: Codable, Equatable, Sendable {
    public let outcome: DaemonMutationOutcome
    public let event: DaemonResourceChangeEvent?
    public init(
        outcome: DaemonMutationOutcome, event: DaemonResourceChangeEvent?
    ) {
        self.outcome = outcome
        self.event = event
    }
}

/// `updateWikiIndex`: replace the wiki-index body wholesale, bumping its
/// version + `updated_at`.
public struct DaemonUpdateWikiIndexRequest: Codable, Equatable, Sendable {
    public let body: DaemonPayloadHandle
    public init(body: DaemonPayloadHandle) { self.body = body }
}

public struct DaemonUpdateWikiIndexReply: Codable, Equatable, Sendable {
    public let outcome: DaemonMutationOutcome
    public let event: DaemonResourceChangeEvent?
    public init(
        outcome: DaemonMutationOutcome, event: DaemonResourceChangeEvent?
    ) {
        self.outcome = outcome
        self.event = event
    }
}

/// `upsertPage`: the composed page write (title/id resolution, expectation
/// check, canonicalization, version/provenance write, link replacement — ONE
/// operation). The raw body rides as a staged handle; nil = the empty body.
public struct DaemonUpsertPageRequest: Codable, Equatable, Sendable {
    public let pageID: String?
    public let title: String
    /// Handle over the UTF-8 raw body; nil = the empty body.
    public let rawBody: DaemonPayloadHandle?
    public let expectation: DaemonPageWriteExpectation
    public let author: String?
    public let provenance: [DaemonPageVersionSourceInput]

    public init(
        pageID: String?, title: String, rawBody: DaemonPayloadHandle?,
        expectation: DaemonPageWriteExpectation, author: String?,
        provenance: [DaemonPageVersionSourceInput]
    ) {
        self.pageID = pageID
        self.title = title
        self.rawBody = rawBody
        self.expectation = expectation
        self.author = author
        self.provenance = provenance
    }
}

public struct DaemonUpsertPageReply: Codable, Equatable, Sendable {
    public let result: DaemonPageUpsertOutcome
    public let outcome: DaemonMutationOutcome
    /// nil when the commit rolled back (CAS/create-only conflict) — a failed
    /// expectation emits nothing.
    public let event: DaemonResourceChangeEvent?

    public init(
        result: DaemonPageUpsertOutcome, outcome: DaemonMutationOutcome,
        event: DaemonResourceChangeEvent?
    ) {
        self.result = result
        self.outcome = outcome
        self.event = event
    }
}

/// `workspacePageBody`: the workspace's staged page body (overlay read);
/// nil = the workspace hasn't touched the page. READ-ONLY.
public struct DaemonWorkspacePageBodyRequest: Codable, Equatable, Sendable {
    public let workspaceID: String
    public let pageID: String
    public init(workspaceID: String, pageID: String) {
        self.workspaceID = workspaceID
        self.pageID = pageID
    }
}

public struct DaemonWorkspacePageBodyReply: Codable, Equatable, Sendable {
    public let body: DaemonPayloadHandle?
    public let bodyByteCount: Int

    public init(body: DaemonPayloadHandle?, bodyByteCount: Int) {
        self.body = body
        self.bodyByteCount = bodyByteCount
    }
}

/// `workspaceWritePage`: write a page version into the workspace overlay
/// (main untouched until merge). Body rides as a staged handle; nil = the
/// empty body (the convenience overload's default).
public struct DaemonWorkspaceWritePageRequest: Codable, Equatable, Sendable {
    public let workspaceID: String
    public let pageID: String
    public let title: String
    public let body: DaemonPayloadHandle?
    public let author: String?
    public let provenance: [DaemonPageVersionSourceInput]

    public init(
        workspaceID: String, pageID: String, title: String,
        body: DaemonPayloadHandle?, author: String?,
        provenance: [DaemonPageVersionSourceInput]
    ) {
        self.workspaceID = workspaceID
        self.pageID = pageID
        self.title = title
        self.body = body
        self.author = author
        self.provenance = provenance
    }
}

public struct DaemonWorkspaceWritePageReply: Codable, Equatable, Sendable {
    /// The new overlay version's id; nil mirrors the core optional.
    public let versionID: String?
    public let outcome: DaemonMutationOutcome
    public let event: DaemonResourceChangeEvent?

    public init(
        versionID: String?, outcome: DaemonMutationOutcome,
        event: DaemonResourceChangeEvent?
    ) {
        self.versionID = versionID
        self.outcome = outcome
        self.event = event
    }
}
#endif
