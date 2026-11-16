#if os(macOS)
import Foundation
import WikiDaemonContract
import WikiFSCore
import WikiFSTypes

// MARK: - Slice-2 wired surface: small family (32 operations)
//
// The small family's client half (plans/daemon-only-access.md slice 2): one
// small reply each, no cursor, no payload handle. Reads are unstamped —
// every call first awaits the handshake barrier, then rides `sendStore`.
// The family's four stamped mutators (`setMetadata` lives wired in the core
// file; the three vacuums here) stamp through the shared mutation path and
// guard the echoed outcome. Nothing here emits a `ResourceChangeEvent`.
//
// Every reply's mirror values reconstruct through
// ``RemoteStoreMirrorMapping`` — associated values intact.

extension RemoteWikiStore {

    public func activeContentVersion(sourceID: SourceID) async throws -> SourceVersion? {
        _ = try await ensureSession()
        let result = try await sendStore(
            .activeContentVersion,
            payload: JSONEncoder().encode(
                DaemonActiveContentVersionRequest(sourceID: sourceID.rawValue)))
        let reply = try Self.decodeResult(
            DaemonActiveContentVersionReply.self, result, "activeContentVersion")
        return reply.version.map(RemoteStoreMirrorMapping.coreSourceVersion)
    }

    public func activeExtractionProvenance(
        sourceID: SourceID
    ) async throws -> ExtractionProvenance? {
        _ = try await ensureSession()
        let result = try await sendStore(
            .activeExtractionProvenance,
            payload: JSONEncoder().encode(
                DaemonActiveExtractionProvenanceRequest(sourceID: sourceID.rawValue)))
        let reply = try Self.decodeResult(
            DaemonActiveExtractionProvenanceReply.self, result,
            "activeExtractionProvenance")
        return try reply.provenance.map(
            RemoteStoreMirrorMapping.coreExtractionProvenance)
    }

    public func pageOKFMetadata(
        versionID: PageVersionID, includeCorrected: Bool
    ) async throws -> PageOKFTrustMetadata? {
        _ = try await ensureSession()
        let result = try await sendStore(
            .pageOKFMetadata,
            payload: JSONEncoder().encode(
                DaemonPageOKFMetadataRequest(
                    versionID: versionID.rawValue,
                    includeCorrected: includeCorrected)))
        let reply = try Self.decodeResult(
            DaemonPageOKFMetadataReply.self, result, "pageOKFMetadata")
        return try reply.metadata.map(
            RemoteStoreMirrorMapping.corePageOKFTrustMetadata)
    }

    public func sourceMarkdownOKFMetadata(
        versionID: SourceMarkdownVersionID, includeCorrected: Bool
    ) async throws -> SourceMarkdownOKFTrustMetadata? {
        _ = try await ensureSession()
        let result = try await sendStore(
            .sourceMarkdownOKFMetadata,
            payload: JSONEncoder().encode(
                DaemonSourceMarkdownOKFMetadataRequest(
                    versionID: versionID.rawValue,
                    includeCorrected: includeCorrected)))
        let reply = try Self.decodeResult(
            DaemonSourceMarkdownOKFMetadataReply.self, result,
            "sourceMarkdownOKFMetadata")
        return try reply.metadata.map(
            RemoteStoreMirrorMapping.coreSourceMarkdownOKFTrustMetadata)
    }

    public func chatAttachments(chatID: ChatID) async throws -> [ChatAttachmentTarget] {
        _ = try await ensureSession()
        let result = try await sendStore(
            .chatAttachments,
            payload: JSONEncoder().encode(
                DaemonChatAttachmentsRequest(chatID: chatID.rawValue)))
        let reply = try Self.decodeResult(
            DaemonChatAttachmentsReply.self, result, "chatAttachments")
        return reply.targets.map(RemoteStoreMirrorMapping.coreAttachmentTarget)
    }

    public func chatTranscriptCheckpoint(
        chatID: ChatID
    ) async throws -> ChatTranscriptCursor {
        _ = try await ensureSession()
        let result = try await sendStore(
            .chatTranscriptCheckpoint,
            payload: JSONEncoder().encode(
                DaemonChatTranscriptCheckpointRequest(chatID: chatID.rawValue)))
        let reply = try Self.decodeResult(
            DaemonChatTranscriptCheckpointReply.self, result,
            "chatTranscriptCheckpoint")
        return RemoteStoreMirrorMapping.coreTranscriptCursor(reply.checkpoint)
    }

    public func chatUsageSummary(chatID: ChatID) async throws -> ChatUsageSummary {
        _ = try await ensureSession()
        let result = try await sendStore(
            .chatUsageSummary,
            payload: JSONEncoder().encode(
                DaemonChatUsageSummaryRequest(chatID: chatID.rawValue)))
        let reply = try Self.decodeResult(
            DaemonChatUsageSummaryReply.self, result, "chatUsageSummary")
        return RemoteStoreMirrorMapping.coreChatUsageSummary(reply.summary)
    }

    public func fetchState(sourceID: SourceID) async throws -> SourceFetchState? {
        _ = try await ensureSession()
        let result = try await sendStore(
            .fetchState,
            payload: JSONEncoder().encode(
                DaemonFetchStateRequest(sourceID: sourceID.rawValue)))
        let reply = try Self.decodeResult(
            DaemonFetchStateReply.self, result, "fetchState")
        return reply.state.flatMap {
            SourceFetchState(rawValue: $0.rawValue)
        }
    }

    public func getChat(id: ChatID) async throws -> ChatSummary {
        _ = try await ensureSession()
        let result = try await sendStore(
            .getChat,
            payload: JSONEncoder().encode(DaemonGetChatRequest(id: id.rawValue)))
        let reply = try Self.decodeResult(DaemonGetChatReply.self, result, "getChat")
        return Self.coreChatSummary(reply.chat)
    }

    public func getWikiStrategyState() async throws -> WikiStrategyState {
        _ = try await ensureSession()
        let result = try await sendStore(
            .getWikiStrategyState,
            payload: JSONEncoder().encode(DaemonGetWikiStrategyStateRequest()))
        let reply = try Self.decodeResult(
            DaemonGetWikiStrategyStateReply.self, result, "getWikiStrategyState")
        return RemoteStoreMirrorMapping.coreWikiStrategyState(reply.state)
    }

    public func hasImageSiblings(sourceID: SourceID) async throws -> Bool {
        _ = try await ensureSession()
        let result = try await sendStore(
            .hasImageSiblings,
            payload: JSONEncoder().encode(
                DaemonHasImageSiblingsRequest(sourceID: sourceID.rawValue)))
        let reply = try Self.decodeResult(
            DaemonHasImageSiblingsReply.self, result, "hasImageSiblings")
        return reply.hasSiblings
    }

    public func initialContentVersion(sourceID: SourceID) async throws -> SourceVersion? {
        _ = try await ensureSession()
        let result = try await sendStore(
            .initialContentVersion,
            payload: JSONEncoder().encode(
                DaemonInitialContentVersionRequest(sourceID: sourceID.rawValue)))
        let reply = try Self.decodeResult(
            DaemonInitialContentVersionReply.self, result, "initialContentVersion")
        return reply.version.map(RemoteStoreMirrorMapping.coreSourceVersion)
    }

    public func pageHeadSources(pageID: PageID) async throws -> [PageVersionSource] {
        _ = try await ensureSession()
        let result = try await sendStore(
            .pageHeadSources,
            payload: JSONEncoder().encode(
                DaemonPageHeadSourcesRequest(pageID: pageID.rawValue)))
        let reply = try Self.decodeResult(
            DaemonPageHeadSourcesReply.self, result, "pageHeadSources")
        return reply.sources.map(Self.corePageVersionSource)
    }

    public func pageOrigin(pageID: PageID) async throws -> PageOrigin? {
        _ = try await ensureSession()
        let result = try await sendStore(
            .pageOrigin,
            payload: JSONEncoder().encode(
                DaemonPageOriginRequest(pageID: pageID.rawValue)))
        let reply = try Self.decodeResult(
            DaemonPageOriginReply.self, result, "pageOrigin")
        return reply.origin.map(RemoteStoreMirrorMapping.corePageOrigin)
    }

    public func pageVersionSources(
        versionID: PageVersionID
    ) async throws -> [PageVersionSource] {
        _ = try await ensureSession()
        let result = try await sendStore(
            .pageVersionSources,
            payload: JSONEncoder().encode(
                DaemonPageVersionSourcesRequest(versionID: versionID.rawValue)))
        let reply = try Self.decodeResult(
            DaemonPageVersionSourcesReply.self, result, "pageVersionSources")
        return reply.sources.map(Self.corePageVersionSource)
    }

    public func rendererInputByteCount(
        _ input: RendererBridgeInput
    ) async throws -> Int? {
        _ = try await ensureSession()
        let result = try await sendStore(
            .rendererInputByteCount,
            payload: JSONEncoder().encode(DaemonRendererInputByteCountRequest(
                input: try RemoteStoreMirrorMapping.wireRendererInput(input))))
        let reply = try Self.decodeResult(
            DaemonRendererInputByteCountReply.self, result,
            "rendererInputByteCount")
        return reply.byteCount
    }

    public func rendererSourcePreference(
        sourceID: SourceID
    ) async throws -> RendererSourcePreference? {
        _ = try await ensureSession()
        let result = try await sendStore(
            .rendererSourcePreference,
            payload: JSONEncoder().encode(
                DaemonRendererSourcePreferenceRequest(sourceID: sourceID.rawValue)))
        let reply = try Self.decodeResult(
            DaemonRendererSourcePreferenceReply.self, result,
            "rendererSourcePreference")
        return try reply.preference.map(
            RemoteStoreMirrorMapping.coreRendererSourcePreference)
    }

    public func rendererSourcePresentation(
        sourceID: SourceID
    ) async throws -> RendererSourcePresentation? {
        _ = try await ensureSession()
        let result = try await sendStore(
            .rendererSourcePresentation,
            payload: JSONEncoder().encode(
                DaemonRendererSourcePresentationRequest(sourceID: sourceID.rawValue)))
        let reply = try Self.decodeResult(
            DaemonRendererSourcePresentationReply.self, result,
            "rendererSourcePresentation")
        return try reply.presentation.map(
            RemoteStoreMirrorMapping.coreRendererSourcePresentation)
    }

    public func resolveChatByTitle(_ title: String) async throws -> ChatID? {
        _ = try await ensureSession()
        let result = try await sendStore(
            .resolveChatByTitle,
            payload: JSONEncoder().encode(
                DaemonResolveChatByTitleRequest(title: title)))
        let reply = try Self.decodeResult(
            DaemonResolveChatByTitleReply.self, result, "resolveChatByTitle")
        return reply.chatID.map { ChatID(rawValue: $0) }
    }

    public func resolveSourceByName(_ displayName: String) async throws -> SourceID? {
        _ = try await ensureSession()
        let result = try await sendStore(
            .resolveSourceByName,
            payload: JSONEncoder().encode(
                DaemonResolveSourceByNameRequest(displayName: displayName)))
        let reply = try Self.decodeResult(
            DaemonResolveSourceByNameReply.self, result, "resolveSourceByName")
        return reply.sourceID.map { SourceID(rawValue: $0) }
    }

    public func searchSimilar(
        query: String, limit: Int, bm25Leg: [WikiPageSummary]?
    ) async throws -> [WikiPageSummary] {
        _ = try await ensureSession()
        let result = try await sendStore(
            .searchSimilar,
            payload: JSONEncoder().encode(DaemonSearchSimilarRequest(
                query: query, limit: limit,
                bm25Leg: bm25Leg.map { $0.map(Self.wirePageSummary) })))
        let reply = try Self.decodeResult(
            DaemonSearchSimilarReply.self, result, "searchSimilar")
        return reply.results.map(Self.corePageSummary)
    }

    public func searchSimilarChats(
        query: String, limit: Int, bm25Leg: [ChatSummary]?
    ) async throws -> [ChatSummary] {
        _ = try await ensureSession()
        let result = try await sendStore(
            .searchSimilarChats,
            payload: JSONEncoder().encode(DaemonSearchSimilarChatsRequest(
                query: query, limit: limit,
                bm25Leg: bm25Leg.map { $0.map(Self.wireChatSummary) })))
        let reply = try Self.decodeResult(
            DaemonSearchSimilarChatsReply.self, result, "searchSimilarChats")
        return reply.results.map(Self.coreChatSummary)
    }

    public func searchSimilarSources(
        query: String, limit: Int, bm25Leg: [SourceSummary]?
    ) async throws -> [SourceSummary] {
        _ = try await ensureSession()
        let result = try await sendStore(
            .searchSimilarSources,
            payload: JSONEncoder().encode(DaemonSearchSimilarSourcesRequest(
                query: query, limit: limit,
                bm25Leg: bm25Leg.map { $0.map(Self.wireSourceSummary) })))
        let reply = try Self.decodeResult(
            DaemonSearchSimilarSourcesReply.self, result, "searchSimilarSources")
        return reply.results.map(Self.coreSourceSummary)
    }

    public func sourceMatchingURLIdentity(
        _ identity: String
    ) async throws -> SourceSummary? {
        _ = try await ensureSession()
        let result = try await sendStore(
            .sourceMatchingURLIdentity,
            payload: JSONEncoder().encode(
                DaemonSourceMatchingURLIdentityRequest(identity: identity)))
        let reply = try Self.decodeResult(
            DaemonSourceMatchingURLIdentityReply.self, result,
            "sourceMatchingURLIdentity")
        return reply.source.map(Self.coreSourceSummary)
    }

    public func sourceOrigin(sourceID: SourceID) async throws -> SourceOrigin? {
        _ = try await ensureSession()
        let result = try await sendStore(
            .sourceOrigin,
            payload: JSONEncoder().encode(
                DaemonSourceOriginRequest(sourceID: sourceID.rawValue)))
        let reply = try Self.decodeResult(
            DaemonSourceOriginReply.self, result, "sourceOrigin")
        return reply.origin.map(RemoteStoreMirrorMapping.coreSourceOrigin)
    }

    public func sourceVersion(id: SourceVersionID) async throws -> SourceVersion? {
        _ = try await ensureSession()
        let result = try await sendStore(
            .sourceVersion,
            payload: JSONEncoder().encode(
                DaemonSourceVersionRequest(versionID: id.rawValue)))
        let reply = try Self.decodeResult(
            DaemonSourceVersionReply.self, result, "sourceVersion")
        return reply.version.map(RemoteStoreMirrorMapping.coreSourceVersion)
    }

    public func wikiStrategyRevision() async throws -> WikiStrategyRevision? {
        _ = try await ensureSession()
        let result = try await sendStore(
            .wikiStrategyRevision,
            payload: JSONEncoder().encode(DaemonWikiStrategyRevisionRequest()))
        let reply = try Self.decodeResult(
            DaemonWikiStrategyRevisionReply.self, result, "wikiStrategyRevision")
        return reply.revision.map(WikiStrategyRevision.init(rawValue:))
    }

    public func workspacePageVersion(
        workspaceID: WorkspaceID, pageID: PageID
    ) async throws -> PageVersionID? {
        _ = try await ensureSession()
        let result = try await sendStore(
            .workspacePageVersion,
            payload: JSONEncoder().encode(DaemonWorkspacePageVersionRequest(
                workspaceID: workspaceID.rawValue, pageID: pageID.rawValue)))
        let reply = try Self.decodeResult(
            DaemonWorkspacePageVersionReply.self, result, "workspacePageVersion")
        return reply.versionID.map { PageVersionID(rawValue: $0) }
    }

    public func workspaceSummary(id: WorkspaceID) async throws -> WorkspaceSummary? {
        _ = try await ensureSession()
        let result = try await sendStore(
            .workspaceSummary,
            payload: JSONEncoder().encode(DaemonWorkspaceSummaryRequest(id: id.rawValue)))
        let reply = try Self.decodeResult(
            DaemonWorkspaceSummaryReply.self, result, "workspaceSummary")
        return reply.summary.map(RemoteStoreMirrorMapping.coreWorkspaceSummary)
    }

    // MARK: stamped no-emit mutators (vacuums — outcome echo, never an event)

    public func vacuumBlobs(dryRun: Bool) async throws -> BlobVacuumReport {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .vacuumBlobs,
            payload: JSONEncoder().encode(DaemonVacuumBlobsRequest(dryRun: dryRun)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonVacuumBlobsReply.self, result, "vacuumBlobs")
        try Self.requireCommittedOutcome(reply.outcome, "vacuumBlobs")
        return RemoteStoreMirrorMapping.coreBlobVacuumReport(reply.report)
    }

    public func vacuumActivities(dryRun: Bool) async throws -> ActivityVacuumReport {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .vacuumActivities,
            payload: JSONEncoder().encode(
                DaemonVacuumActivitiesRequest(dryRun: dryRun)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonVacuumActivitiesReply.self, result, "vacuumActivities")
        try Self.requireCommittedOutcome(reply.outcome, "vacuumActivities")
        return RemoteStoreMirrorMapping.coreActivityVacuumReport(reply.report)
    }

    public func vacuumPageVersions(dryRun: Bool) async throws -> PageVersionVacuumReport {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .vacuumPageVersions,
            payload: JSONEncoder().encode(
                DaemonVacuumPageVersionsRequest(dryRun: dryRun)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonVacuumPageVersionsReply.self, result, "vacuumPageVersions")
        try Self.requireCommittedOutcome(reply.outcome, "vacuumPageVersions")
        return RemoteStoreMirrorMapping.corePageVersionVacuumReport(reply.report)
    }

    // MARK: shared value helpers (small-family reads)

    static func corePageVersionSource(
        _ value: DaemonPageVersionSource
    ) -> PageVersionSource {
        PageVersionSource(
            pageVersionID: PageVersionID(rawValue: value.pageVersionID),
            sourceID: SourceID(rawValue: value.sourceID),
            role: PageVersionSourceRole(rawValue: value.role.rawValue) ?? .primary)
    }

    static func wirePageSummary(_ value: WikiPageSummary) -> DaemonPageSummary {
        DaemonPageSummary(
            id: value.id.rawValue, title: value.title,
            updatedAt: value.updatedAt, createdAt: value.createdAt)
    }

    static func wireChatSummary(_ value: ChatSummary) -> DaemonChatSummary {
        DaemonChatSummary(
            id: value.id.rawValue,
            kind: DaemonChatKind(rawValue: value.kind.rawValue) ?? .edit,
            title: value.title, createdAt: value.createdAt,
            updatedAt: value.updatedAt, messageCount: value.messageCount,
            acpSessionId: value.acpSessionId?.rawValue,
            modelProviderId: value.modelProviderId?.rawValue,
            modelId: value.modelId?.rawValue,
            configuredThinkingOptionID: value.configuredThinkingOptionID?.rawValue,
            effectiveThinkingOptionID: value.effectiveThinkingOptionID?.rawValue)
    }

    static func wireSourceSummary(_ value: SourceSummary) -> DaemonSourceSummary {
        DaemonSourceSummary(
            id: value.id.rawValue, filename: value.filename, ext: value.ext,
            mimeType: value.mimeType, byteSize: value.byteSize,
            createdAt: value.createdAt, updatedAt: value.updatedAt,
            version: value.version, externalItemKey: value.externalItemKey,
            externalItemTitle: value.externalItemTitle,
            displayName: value.displayName, role: value.role.rawValue)
    }
}
#endif
