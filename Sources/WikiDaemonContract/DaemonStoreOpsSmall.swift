#if os(macOS)
import Foundation

// Small-family per-operation DTOs for the store family (Phase 2a slice 2,
// tmp/store-ops-manifest.md small partition — 37 operations): one small reply
// each, no cursor, no payload handle. Requests carry ONLY op-specific args —
// the wiki id and the mutation admission stamp ride the `DaemonStoreRequest`
// envelope. Reads reply with the op's value; the three annotated no-emit
// mutators in this family (`setMetadata`, the three vacuums' NO_EMIT
// discipline) still echo the mutation outcome so exactly-once stays
// observable. Nothing here emits a `ResourceChangeEvent`.

// MARK: - Reads

/// `activeContentVersion`: the source's active content version, resolved
/// ref-first with the MAX(id) default-active fallback; nil = no version rows.
public struct DaemonActiveContentVersionRequest: Codable, Equatable, Sendable {
    public let sourceID: String
    public init(sourceID: String) { self.sourceID = sourceID }
}

public struct DaemonActiveContentVersionReply: Codable, Equatable, Sendable {
    public let version: DaemonSourceVersion?
    public init(version: DaemonSourceVersion?) { self.version = version }
}

/// `activeExtractionProvenance`: the active markdown version's typed PROV
/// projection; nil when the source has no processed-markdown chain.
public struct DaemonActiveExtractionProvenanceRequest: Codable, Equatable,
    Sendable {
    public let sourceID: String
    public init(sourceID: String) { self.sourceID = sourceID }
}

public struct DaemonActiveExtractionProvenanceReply: Codable, Equatable,
    Sendable {
    public let provenance: DaemonExtractionProvenance?
    public init(provenance: DaemonExtractionProvenance?) {
        self.provenance = provenance
    }
}

/// `chatAttachments`: a chat's ordered attachment targets (empty = no chips).
public struct DaemonChatAttachmentsRequest: Codable, Equatable, Sendable {
    public let chatID: String
    public init(chatID: String) { self.chatID = chatID }
}

public struct DaemonChatAttachmentsReply: Codable, Equatable, Sendable {
    public let targets: [DaemonChatAttachmentTarget]
    public init(targets: [DaemonChatAttachmentTarget]) {
        self.targets = targets
    }
}

/// `chatTranscriptCheckpoint`: the high-water transcript cursor (0 when empty).
public struct DaemonChatTranscriptCheckpointRequest: Codable, Equatable,
    Sendable {
    public let chatID: String
    public init(chatID: String) { self.chatID = chatID }
}

public struct DaemonChatTranscriptCheckpointReply: Codable, Equatable,
    Sendable {
    public let checkpoint: DaemonChatTranscriptCursor
    public init(checkpoint: DaemonChatTranscriptCursor) {
        self.checkpoint = checkpoint
    }
}

/// `chatUsageSummary`: aggregate durable usage for one chat.
public struct DaemonChatUsageSummaryRequest: Codable, Equatable, Sendable {
    public let chatID: String
    public init(chatID: String) { self.chatID = chatID }
}

public struct DaemonChatUsageSummaryReply: Codable, Equatable, Sendable {
    public let summary: DaemonChatUsageSummary
    public init(summary: DaemonChatUsageSummary) { self.summary = summary }
}

/// `fetchState`: the typed fetch lifecycle of one source (nil = never a fetch
/// source).
public struct DaemonFetchStateRequest: Codable, Equatable, Sendable {
    public let sourceID: String
    public init(sourceID: String) { self.sourceID = sourceID }
}

public struct DaemonFetchStateReply: Codable, Equatable, Sendable {
    public let state: DaemonSourceFetchState?
    public init(state: DaemonSourceFetchState?) { self.state = state }
}

/// `getChat`: one chat summary (typed rejection `.chatNotFound` when absent).
public struct DaemonGetChatRequest: Codable, Equatable, Sendable {
    public let id: String
    public init(id: String) { self.id = id }
}

public struct DaemonGetChatReply: Codable, Equatable, Sendable {
    public let chat: DaemonChatSummary
    public init(chat: DaemonChatSummary) { self.chat = chat }
}

/// `getMetadata`: one metadata value; nil = the key doesn't exist.
public struct DaemonGetMetadataRequest: Codable, Equatable, Sendable {
    public let key: String
    public init(key: String) { self.key = key }
}

public struct DaemonGetMetadataReply: Codable, Equatable, Sendable {
    public let value: String?
    public init(value: String?) { self.value = value }
}

/// `getWikiStrategyState`: the committed strategy snapshot + revision read
/// atomically (the editor's CAS-expectation source). No op-specific args.
public struct DaemonGetWikiStrategyStateRequest: Codable, Equatable, Sendable {
    public init() {}
}

public struct DaemonGetWikiStrategyStateReply: Codable, Equatable, Sendable {
    public let state: DaemonWikiStrategyState
    public init(state: DaemonWikiStrategyState) { self.state = state }
}

/// `hasImageSiblings`: true when the source's active version shares an
/// activity with sibling snapshot-image versions.
public struct DaemonHasImageSiblingsRequest: Codable, Equatable, Sendable {
    public let sourceID: String
    public init(sourceID: String) { self.sourceID = sourceID }
}

public struct DaemonHasImageSiblingsReply: Codable, Equatable, Sendable {
    public let hasSiblings: Bool
    public init(hasSiblings: Bool) { self.hasSiblings = hasSiblings }
}

/// `hasProcessedMarkdown`: true when at least one markdown version exists.
public struct DaemonHasProcessedMarkdownRequest: Codable, Equatable, Sendable {
    public let sourceID: String
    public init(sourceID: String) { self.sourceID = sourceID }
}

public struct DaemonHasProcessedMarkdownReply: Codable, Equatable, Sendable {
    public let hasAny: Bool
    public init(hasAny: Bool) { self.hasAny = hasAny }
}

/// `initialContentVersion`: the immutable root content version; nil = no
/// version rows.
public struct DaemonInitialContentVersionRequest: Codable, Equatable, Sendable {
    public let sourceID: String
    public init(sourceID: String) { self.sourceID = sourceID }
}

public struct DaemonInitialContentVersionReply: Codable, Equatable, Sendable {
    public let version: DaemonSourceVersion?
    public init(version: DaemonSourceVersion?) { self.version = version }
}

/// `pageHeadSources`: the HEAD version's source evidence.
public struct DaemonPageHeadSourcesRequest: Codable, Equatable, Sendable {
    public let pageID: String
    public init(pageID: String) { self.pageID = pageID }
}

public struct DaemonPageHeadSourcesReply: Codable, Equatable, Sendable {
    public let sources: [DaemonPageVersionSource]
    public init(sources: [DaemonPageVersionSource]) { self.sources = sources }
}

/// `pageHeadVersionID`: the active page-content version id; nil = no versions.
public struct DaemonPageHeadVersionIDRequest: Codable, Equatable, Sendable {
    public let pageID: String
    public init(pageID: String) { self.pageID = pageID }
}

public struct DaemonPageHeadVersionIDReply: Codable, Equatable, Sendable {
    public let versionID: String?
    public init(versionID: String?) { self.versionID = versionID }
}

/// `pageOKFMetadata`: exact-version OKF trust metadata
/// (`includeCorrected` = keep corrected verifications in the projection).
public struct DaemonPageOKFMetadataRequest: Codable, Equatable, Sendable {
    public let versionID: String
    public let includeCorrected: Bool
    public init(versionID: String, includeCorrected: Bool) {
        self.versionID = versionID
        self.includeCorrected = includeCorrected
    }
}

public struct DaemonPageOKFMetadataReply: Codable, Equatable, Sendable {
    public let metadata: DaemonPageOKFTrustMetadata?
    public init(metadata: DaemonPageOKFTrustMetadata?) {
        self.metadata = metadata
    }
}

/// `pageOrigin`: the HEAD version's origin provenance; nil = no version rows.
public struct DaemonPageOriginRequest: Codable, Equatable, Sendable {
    public let pageID: String
    public init(pageID: String) { self.pageID = pageID }
}

public struct DaemonPageOriginReply: Codable, Equatable, Sendable {
    public let origin: DaemonPageOrigin?
    public init(origin: DaemonPageOrigin?) { self.origin = origin }
}

/// `pageVersionSources`: one version's immutable source evidence.
public struct DaemonPageVersionSourcesRequest: Codable, Equatable, Sendable {
    public let versionID: String
    public init(versionID: String) { self.versionID = versionID }
}

public struct DaemonPageVersionSourcesReply: Codable, Equatable, Sendable {
    public let sources: [DaemonPageVersionSource]
    public init(sources: [DaemonPageVersionSource]) { self.sources = sources }
}

/// `rendererInputByteCount`: the byte count for one exact renderer input
/// version, without materializing it; nil mirrors the core optional.
public struct DaemonRendererInputByteCountRequest: Codable, Equatable,
    Sendable {
    public let input: DaemonRendererBridgeInput
    public init(input: DaemonRendererBridgeInput) { self.input = input }
}

public struct DaemonRendererInputByteCountReply: Codable, Equatable, Sendable {
    public let byteCount: Int?
    public init(byteCount: Int?) { self.byteCount = byteCount }
}

/// `rendererSourcePreference`: one source's persisted renderer preference.
public struct DaemonRendererSourcePreferenceRequest: Codable, Equatable,
    Sendable {
    public let sourceID: String
    public init(sourceID: String) { self.sourceID = sourceID }
}

public struct DaemonRendererSourcePreferenceReply: Codable, Equatable,
    Sendable {
    public let preference: DaemonRendererSourcePreference?
    public init(preference: DaemonRendererSourcePreference?) {
        self.preference = preference
    }
}

/// `rendererSourcePresentation`: one source's persisted reader arrangement.
public struct DaemonRendererSourcePresentationRequest: Codable, Equatable,
    Sendable {
    public let sourceID: String
    public init(sourceID: String) { self.sourceID = sourceID }
}

public struct DaemonRendererSourcePresentationReply: Codable, Equatable,
    Sendable {
    public let presentation: DaemonRendererSourcePresentation?
    public init(presentation: DaemonRendererSourcePresentation?) {
        self.presentation = presentation
    }
}

/// `resolveChatByTitle`: a `[[chat:…]]` target to a chat id (lowest ULID wins
/// a duplicate-title collision); nil = no match.
public struct DaemonResolveChatByTitleRequest: Codable, Equatable, Sendable {
    public let title: String
    public init(title: String) { self.title = title }
}

public struct DaemonResolveChatByTitleReply: Codable, Equatable, Sendable {
    public let chatID: String?
    public init(chatID: String?) { self.chatID = chatID }
}

/// `resolveSourceByName`: a `[[source:…]]` target (display name first, then
/// filename; NOCASE; most-recently-updated wins a collision); nil = no match.
public struct DaemonResolveSourceByNameRequest: Codable, Equatable, Sendable {
    public let displayName: String
    public init(displayName: String) { self.displayName = displayName }
}

public struct DaemonResolveSourceByNameReply: Codable, Equatable, Sendable {
    public let sourceID: String?
    public init(sourceID: String?) { self.sourceID = sourceID }
}

/// `resolveTitleToID`: a page title to its id (lowest ULID wins); nil = no
/// match.
public struct DaemonResolveTitleToIDRequest: Codable, Equatable, Sendable {
    public let title: String
    public init(title: String) { self.title = title }
}

public struct DaemonResolveTitleToIDReply: Codable, Equatable, Sendable {
    public let pageID: String?
    public init(pageID: String?) { self.pageID = pageID }
}

/// `searchSimilar`: hybrid page search. `bm25Leg` is the caller-resolved
/// Tantivy leg (nil = cosine-only).
public struct DaemonSearchSimilarRequest: Codable, Equatable, Sendable {
    public let query: String
    public let limit: Int
    public let bm25Leg: [DaemonPageSummary]?
    public init(
        query: String, limit: Int, bm25Leg: [DaemonPageSummary]?
    ) {
        self.query = query
        self.limit = limit
        self.bm25Leg = bm25Leg
    }
}

public struct DaemonSearchSimilarReply: Codable, Equatable, Sendable {
    public let results: [DaemonPageSummary]
    public init(results: [DaemonPageSummary]) { self.results = results }
}

/// `searchSimilarChats`: hybrid chat search; see `searchSimilar`.
public struct DaemonSearchSimilarChatsRequest: Codable, Equatable, Sendable {
    public let query: String
    public let limit: Int
    public let bm25Leg: [DaemonChatSummary]?
    public init(
        query: String, limit: Int, bm25Leg: [DaemonChatSummary]?
    ) {
        self.query = query
        self.limit = limit
        self.bm25Leg = bm25Leg
    }
}

public struct DaemonSearchSimilarChatsReply: Codable, Equatable, Sendable {
    public let results: [DaemonChatSummary]
    public init(results: [DaemonChatSummary]) { self.results = results }
}

/// `searchSimilarSources`: hybrid source search; see `searchSimilar`.
public struct DaemonSearchSimilarSourcesRequest: Codable, Equatable, Sendable {
    public let query: String
    public let limit: Int
    public let bm25Leg: [DaemonSourceSummary]?
    public init(
        query: String, limit: Int, bm25Leg: [DaemonSourceSummary]?
    ) {
        self.query = query
        self.limit = limit
        self.bm25Leg = bm25Leg
    }
}

public struct DaemonSearchSimilarSourcesReply: Codable, Equatable, Sendable {
    public let results: [DaemonSourceSummary]
    public init(results: [DaemonSourceSummary]) { self.results = results }
}

/// `sourceMarkdownOKFMetadata`: exact-version OKF trust metadata for a
/// markdown version.
public struct DaemonSourceMarkdownOKFMetadataRequest: Codable, Equatable,
    Sendable {
    public let versionID: String
    public let includeCorrected: Bool
    public init(versionID: String, includeCorrected: Bool) {
        self.versionID = versionID
        self.includeCorrected = includeCorrected
    }
}

public struct DaemonSourceMarkdownOKFMetadataReply: Codable, Equatable,
    Sendable {
    public let metadata: DaemonSourceMarkdownOKFTrustMetadata?
    public init(metadata: DaemonSourceMarkdownOKFTrustMetadata?) {
        self.metadata = metadata
    }
}

/// `sourceMatchingURLIdentity`: the active source with that canonical URL
/// identity; nil = none.
public struct DaemonSourceMatchingURLIdentityRequest: Codable, Equatable,
    Sendable {
    public let identity: String
    public init(identity: String) { self.identity = identity }
}

public struct DaemonSourceMatchingURLIdentityReply: Codable, Equatable,
    Sendable {
    public let source: DaemonSourceSummary?
    public init(source: DaemonSourceSummary?) { self.source = source }
}

/// `sourceOrigin`: the source's origin provenance; nil = no version rows.
public struct DaemonSourceOriginRequest: Codable, Equatable, Sendable {
    public let sourceID: String
    public init(sourceID: String) { self.sourceID = sourceID }
}

public struct DaemonSourceOriginReply: Codable, Equatable, Sendable {
    public let origin: DaemonSourceOrigin?
    public init(origin: DaemonSourceOrigin?) { self.origin = origin }
}

/// `sourceVersion`: metadata for one exact immutable content version (never
/// resolves the active ref); nil = no row.
public struct DaemonSourceVersionRequest: Codable, Equatable, Sendable {
    public let versionID: String
    public init(versionID: String) { self.versionID = versionID }
}

public struct DaemonSourceVersionReply: Codable, Equatable, Sendable {
    public let version: DaemonSourceVersion?
    public init(version: DaemonSourceVersion?) { self.version = version }
}

/// `wikiStrategyRevision`: the committed revision counter including
/// tombstones; nil = no row has ever been written. No op-specific args.
public struct DaemonWikiStrategyRevisionRequest: Codable, Equatable, Sendable {
    public init() {}
}

public struct DaemonWikiStrategyRevisionReply: Codable, Equatable, Sendable {
    /// `WikiStrategyRevision.rawValue`.
    public let revision: Int64?
    public init(revision: Int64?) { self.revision = revision }
}

/// `workspacePageVersion`: the workspace's staged version id for a page; nil
/// = the workspace hasn't touched the page.
public struct DaemonWorkspacePageVersionRequest: Codable, Equatable, Sendable {
    public let workspaceID: String
    public let pageID: String
    public init(workspaceID: String, pageID: String) {
        self.workspaceID = workspaceID
        self.pageID = pageID
    }
}

public struct DaemonWorkspacePageVersionReply: Codable, Equatable, Sendable {
    public let versionID: String?
    public init(versionID: String?) { self.versionID = versionID }
}

/// `workspaceSummary`: a workspace's status + metadata; nil = unknown id.
public struct DaemonWorkspaceSummaryRequest: Codable, Equatable, Sendable {
    public let id: String
    public init(id: String) { self.id = id }
}

public struct DaemonWorkspaceSummaryReply: Codable, Equatable, Sendable {
    public let summary: DaemonWorkspaceSummary?
    public init(summary: DaemonWorkspaceSummary?) {
        self.summary = summary
    }
}

// MARK: - No-emit mutators (outcome echo, never an event)

/// `setMetadata`: upsert one metadata flag. Annotated NO-EMIT (metadata flags
/// gate one-time maintenance work; they change no projected content), so the
/// reply carries the mutation outcome echo and NO event.
public struct DaemonSetMetadataRequest: Codable, Equatable, Sendable {
    public let key: String
    public let value: String
    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

public struct DaemonSetMetadataReply: Codable, Equatable, Sendable {
    public let outcome: DaemonMutationOutcome
    public init(outcome: DaemonMutationOutcome) { self.outcome = outcome }
}

/// `vacuumBlobs`: sweep orphaned blob rows (`dryRun` reports without
/// deleting). Annotated NO-EMIT; the reply carries the report + outcome echo.
public struct DaemonVacuumBlobsRequest: Codable, Equatable, Sendable {
    public let dryRun: Bool
    public init(dryRun: Bool) { self.dryRun = dryRun }
}

public struct DaemonVacuumBlobsReply: Codable, Equatable, Sendable {
    public let report: DaemonBlobVacuumReport
    public let outcome: DaemonMutationOutcome
    public init(report: DaemonBlobVacuumReport, outcome: DaemonMutationOutcome) {
        self.report = report
        self.outcome = outcome
    }
}

/// `vacuumActivities`: sweep orphaned activity rows. Annotated NO-EMIT.
public struct DaemonVacuumActivitiesRequest: Codable, Equatable, Sendable {
    public let dryRun: Bool
    public init(dryRun: Bool) { self.dryRun = dryRun }
}

public struct DaemonVacuumActivitiesReply: Codable, Equatable, Sendable {
    public let report: DaemonActivityVacuumReport
    public let outcome: DaemonMutationOutcome
    public init(
        report: DaemonActivityVacuumReport, outcome: DaemonMutationOutcome
    ) {
        self.report = report
        self.outcome = outcome
    }
}

/// `vacuumPageVersions`: sweep unreachable page-version rows. Annotated
/// NO-EMIT.
public struct DaemonVacuumPageVersionsRequest: Codable, Equatable, Sendable {
    public let dryRun: Bool
    public init(dryRun: Bool) { self.dryRun = dryRun }
}

public struct DaemonVacuumPageVersionsReply: Codable, Equatable, Sendable {
    public let report: DaemonPageVersionVacuumReport
    public let outcome: DaemonMutationOutcome
    public init(
        report: DaemonPageVersionVacuumReport, outcome: DaemonMutationOutcome
    ) {
        self.report = report
        self.outcome = outcome
    }
}
#endif
