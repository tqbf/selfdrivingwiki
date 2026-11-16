#if os(macOS)
import Foundation
import Testing
import WikiDaemonContract

// Phase 2a slice 2 verification: the DTO-pair completeness ledger for all
// 151 manifest operations (small 37 / list 25 / blob 39 / event-producer 50)
// plus representative full-envelope round trips per family.
//
// Swift cannot reflect types, so the ledger is a hand-built switch-based
// factory over `DaemonStoreOperation`: the switch must name EVERY case (the
// module is compiled without library evolution, so a missing case is a
// compile error, and an added operation fails the build until it is
// classified here). The test then asserts every manifest-family op resolves
// to a pair and every infrastructure/reserved op resolves to nil — its DTOs
// are slice 1's (`DaemonPayload*`, `DaemonResolveOutcome*`,
// `DaemonStoreSessionBootstrap`, the reserved `sinkHandshake`).

/// The mechanical completeness pin: op → (request type, reply type).
enum DaemonStoreOpsLedger {

    /// The DTO pair for one operation, or nil for the seven
    /// infrastructure/reserved operations whose DTOs live in slice 1.
    static func pair(
        for operation: DaemonStoreOperation
    ) -> (request: any Codable.Type, reply: any Codable.Type)? {
        switch operation {
        // Infrastructure: staged payload flow (slice 1 DTOs).
        case .payloadBegin, .payloadChunk, .payloadCommit, .payloadRead:
            return nil
        // Infrastructure: mutation outcome semantics (slice 1 DTOs).
        case .resolveOutcome, .sessionBootstrap:
            return nil
        // Reserved for the events slice.
        case .sinkHandshake:
            return nil

        // MARK: Small (37)

        case .activeContentVersion:
            return (
                DaemonActiveContentVersionRequest.self,
                DaemonActiveContentVersionReply.self)
        case .activeExtractionProvenance:
            return (
                DaemonActiveExtractionProvenanceRequest.self,
                DaemonActiveExtractionProvenanceReply.self)
        case .chatAttachments:
            return (
                DaemonChatAttachmentsRequest.self,
                DaemonChatAttachmentsReply.self)
        case .chatTranscriptCheckpoint:
            return (
                DaemonChatTranscriptCheckpointRequest.self,
                DaemonChatTranscriptCheckpointReply.self)
        case .chatUsageSummary:
            return (
                DaemonChatUsageSummaryRequest.self,
                DaemonChatUsageSummaryReply.self)
        case .fetchState:
            return (DaemonFetchStateRequest.self, DaemonFetchStateReply.self)
        case .getChat:
            return (DaemonGetChatRequest.self, DaemonGetChatReply.self)
        case .getMetadata:
            return (
                DaemonGetMetadataRequest.self, DaemonGetMetadataReply.self)
        case .getWikiStrategyState:
            return (
                DaemonGetWikiStrategyStateRequest.self,
                DaemonGetWikiStrategyStateReply.self)
        case .hasImageSiblings:
            return (
                DaemonHasImageSiblingsRequest.self,
                DaemonHasImageSiblingsReply.self)
        case .hasProcessedMarkdown:
            return (
                DaemonHasProcessedMarkdownRequest.self,
                DaemonHasProcessedMarkdownReply.self)
        case .initialContentVersion:
            return (
                DaemonInitialContentVersionRequest.self,
                DaemonInitialContentVersionReply.self)
        case .pageHeadSources:
            return (
                DaemonPageHeadSourcesRequest.self,
                DaemonPageHeadSourcesReply.self)
        case .pageHeadVersionID:
            return (
                DaemonPageHeadVersionIDRequest.self,
                DaemonPageHeadVersionIDReply.self)
        case .pageOKFMetadata:
            return (
                DaemonPageOKFMetadataRequest.self,
                DaemonPageOKFMetadataReply.self)
        case .pageOrigin:
            return (DaemonPageOriginRequest.self, DaemonPageOriginReply.self)
        case .pageVersionSources:
            return (
                DaemonPageVersionSourcesRequest.self,
                DaemonPageVersionSourcesReply.self)
        case .rendererInputByteCount:
            return (
                DaemonRendererInputByteCountRequest.self,
                DaemonRendererInputByteCountReply.self)
        case .rendererSourcePreference:
            return (
                DaemonRendererSourcePreferenceRequest.self,
                DaemonRendererSourcePreferenceReply.self)
        case .rendererSourcePresentation:
            return (
                DaemonRendererSourcePresentationRequest.self,
                DaemonRendererSourcePresentationReply.self)
        case .resolveChatByTitle:
            return (
                DaemonResolveChatByTitleRequest.self,
                DaemonResolveChatByTitleReply.self)
        case .resolveSourceByName:
            return (
                DaemonResolveSourceByNameRequest.self,
                DaemonResolveSourceByNameReply.self)
        case .resolveTitleToID:
            return (
                DaemonResolveTitleToIDRequest.self,
                DaemonResolveTitleToIDReply.self)
        case .searchSimilar:
            return (
                DaemonSearchSimilarRequest.self,
                DaemonSearchSimilarReply.self)
        case .searchSimilarChats:
            return (
                DaemonSearchSimilarChatsRequest.self,
                DaemonSearchSimilarChatsReply.self)
        case .searchSimilarSources:
            return (
                DaemonSearchSimilarSourcesRequest.self,
                DaemonSearchSimilarSourcesReply.self)
        case .setMetadata:
            return (
                DaemonSetMetadataRequest.self, DaemonSetMetadataReply.self)
        case .sourceMarkdownOKFMetadata:
            return (
                DaemonSourceMarkdownOKFMetadataRequest.self,
                DaemonSourceMarkdownOKFMetadataReply.self)
        case .sourceMatchingURLIdentity:
            return (
                DaemonSourceMatchingURLIdentityRequest.self,
                DaemonSourceMatchingURLIdentityReply.self)
        case .sourceOrigin:
            return (
                DaemonSourceOriginRequest.self, DaemonSourceOriginReply.self)
        case .sourceVersion:
            return (
                DaemonSourceVersionRequest.self, DaemonSourceVersionReply.self)
        case .vacuumActivities:
            return (
                DaemonVacuumActivitiesRequest.self,
                DaemonVacuumActivitiesReply.self)
        case .vacuumBlobs:
            return (
                DaemonVacuumBlobsRequest.self, DaemonVacuumBlobsReply.self)
        case .vacuumPageVersions:
            return (
                DaemonVacuumPageVersionsRequest.self,
                DaemonVacuumPageVersionsReply.self)
        case .wikiStrategyRevision:
            return (
                DaemonWikiStrategyRevisionRequest.self,
                DaemonWikiStrategyRevisionReply.self)
        case .workspacePageVersion:
            return (
                DaemonWorkspacePageVersionRequest.self,
                DaemonWorkspacePageVersionReply.self)
        case .workspaceSummary:
            return (
                DaemonWorkspaceSummaryRequest.self,
                DaemonWorkspaceSummaryReply.self)

        // MARK: List (25)

        case .chatMessages:
            return (
                DaemonChatMessagesRequest.self, DaemonChatMessagesReply.self)
        case .deletionImpact:
            return (
                DaemonDeletionImpactRequest.self,
                DaemonDeletionImpactReply.self)
        case .embedDescriptors:
            return (
                DaemonEmbedDescriptorsRequest.self,
                DaemonEmbedDescriptorsReply.self)
        case .listAllChatsOrderedByID:
            return (
                DaemonListAllChatsOrderedByIDRequest.self,
                DaemonListAllChatsOrderedByIDReply.self)
        case .listBookmarkNodes:
            return (
                DaemonListBookmarkNodesRequest.self,
                DaemonListBookmarkNodesReply.self)
        case .listChats:
            return (
                DaemonListChatsRequest.self, DaemonListChatsReply.self)
        case .listPages:
            return (
                DaemonListPagesRequest.self, DaemonListPagesReply.self)
        case .listPersistedChatTurns:
            return (
                DaemonListPersistedChatTurnsRequest.self,
                DaemonListPersistedChatTurnsReply.self)
        case .listSources:
            return (
                DaemonListSourcesRequest.self, DaemonListSourcesReply.self)
        case .markedSourceIDs:
            return (
                DaemonMarkedSourceIDsRequest.self,
                DaemonMarkedSourceIDsReply.self)
        case .pageEditHistory:
            return (
                DaemonPageEditHistoryRequest.self,
                DaemonPageEditHistoryReply.self)
        case .pagesCitingSources:
            return (
                DaemonPagesCitingSourcesRequest.self,
                DaemonPagesCitingSourcesReply.self)
        case .pageVersionHistory:
            return (
                DaemonPageVersionHistoryRequest.self,
                DaemonPageVersionHistoryReply.self)
        case .processedMarkdownAgentNames:
            return (
                DaemonProcessedMarkdownAgentNamesRequest.self,
                DaemonProcessedMarkdownAgentNamesReply.self)
        case .processedMarkdownAlternatives:
            return (
                DaemonProcessedMarkdownAlternativesRequest.self,
                DaemonProcessedMarkdownAlternativesReply.self)
        case .processedMarkdownHistory:
            return (
                DaemonProcessedMarkdownHistoryRequest.self,
                DaemonProcessedMarkdownHistoryReply.self)
        case .readChatTranscriptPage:
            return (
                DaemonReadChatTranscriptPageRequest.self,
                DaemonReadChatTranscriptPageReply.self)
        case .recentLogEntries:
            return (
                DaemonRecentLogEntriesRequest.self,
                DaemonRecentLogEntriesReply.self)
        case .siblingImageResolvers:
            return (
                DaemonSiblingImageResolversRequest.self,
                DaemonSiblingImageResolversReply.self)
        case .sourceDerivedChains:
            return (
                DaemonSourceDerivedChainsRequest.self,
                DaemonSourceDerivedChainsReply.self)
        case .sourceEditHistory:
            return (
                DaemonSourceEditHistoryRequest.self,
                DaemonSourceEditHistoryReply.self)
        case .sourceOriginsBySource:
            return (
                DaemonSourceOriginsBySourceRequest.self,
                DaemonSourceOriginsBySourceReply.self)
        case .sourcesWithPendingFormatJobs:
            return (
                DaemonSourcesWithPendingFormatJobsRequest.self,
                DaemonSourcesWithPendingFormatJobsReply.self)
        case .workspaceConflicts:
            return (
                DaemonWorkspaceConflictsRequest.self,
                DaemonWorkspaceConflictsReply.self)
        case .workspaceRefs:
            return (
                DaemonWorkspaceRefsRequest.self,
                DaemonWorkspaceRefsReply.self)

        // MARK: Blob (39)

        case .addSnapshotImage:
            return (
                DaemonAddSnapshotImageRequest.self,
                DaemonAddSnapshotImageReply.self)
        case .addSource:
            return (
                DaemonAddSourceRequest.self, DaemonAddSourceReply.self)
        case .appendChatMessages:
            return (
                DaemonAppendChatMessagesRequest.self,
                DaemonAppendChatMessagesReply.self)
        case .appendChatTranscriptItems:
            return (
                DaemonAppendChatTranscriptItemsRequest.self,
                DaemonAppendChatTranscriptItemsReply.self)
        case .appendContentVersion:
            return (
                DaemonAppendContentVersionRequest.self,
                DaemonAppendContentVersionReply.self)
        case .appendDerivedMarkdown:
            return (
                DaemonAppendDerivedMarkdownRequest.self,
                DaemonAppendDerivedMarkdownReply.self)
        case .appendFetchMarkdown:
            return (
                DaemonAppendFetchMarkdownRequest.self,
                DaemonAppendFetchMarkdownReply.self)
        case .appendHostSpeechTranscript:
            return (
                DaemonAppendHostSpeechTranscriptRequest.self,
                DaemonAppendHostSpeechTranscriptReply.self)
        case .appendInstalledPackageMarkdown:
            return (
                DaemonAppendInstalledPackageMarkdownRequest.self,
                DaemonAppendInstalledPackageMarkdownReply.self)
        case .appendPageVersion:
            return (
                DaemonAppendPageVersionRequest.self,
                DaemonAppendPageVersionReply.self)
        case .appendProcessedMarkdown:
            return (
                DaemonAppendProcessedMarkdownRequest.self,
                DaemonAppendProcessedMarkdownReply.self)
        case .appendUserProcessedMarkdown:
            return (
                DaemonAppendUserProcessedMarkdownRequest.self,
                DaemonAppendUserProcessedMarkdownReply.self)
        case .attachAcquiredBytes:
            return (
                DaemonAttachAcquiredBytesRequest.self,
                DaemonAttachAcquiredBytesReply.self)
        case .checkpointStreamingMessage:
            return (
                DaemonCheckpointStreamingMessageRequest.self,
                DaemonCheckpointStreamingMessageReply.self)
        case .claimNextPersistedChatTurn:
            return (
                DaemonClaimNextPersistedChatTurnRequest.self,
                DaemonClaimNextPersistedChatTurnReply.self)
        case .createPage:
            return (
                DaemonCreatePageRequest.self, DaemonCreatePageReply.self)
        case .enqueuePersistedChatTurn:
            return (
                DaemonEnqueuePersistedChatTurnRequest.self,
                DaemonEnqueuePersistedChatTurnReply.self)
        case .finishPersistedChatTurn:
            return (
                DaemonFinishPersistedChatTurnRequest.self,
                DaemonFinishPersistedChatTurnReply.self)
        case .getPage:
            return (DaemonGetPageRequest.self, DaemonGetPageReply.self)
        case .getWikiIndex:
            return (
                DaemonGetWikiIndexRequest.self, DaemonGetWikiIndexReply.self)
        case .getWikiStrategy:
            return (
                DaemonGetWikiStrategyRequest.self,
                DaemonGetWikiStrategyReply.self)
        case .missingChatEmbeddingWork:
            return (
                DaemonMissingChatEmbeddingWorkRequest.self,
                DaemonMissingChatEmbeddingWorkReply.self)
        case .missingPageEmbeddingWork:
            return (
                DaemonMissingPageEmbeddingWorkRequest.self,
                DaemonMissingPageEmbeddingWorkReply.self)
        case .missingSourceEmbeddingWork:
            return (
                DaemonMissingSourceEmbeddingWorkRequest.self,
                DaemonMissingSourceEmbeddingWorkReply.self)
        case .pageVersionBody:
            return (
                DaemonPageVersionBodyRequest.self,
                DaemonPageVersionBodyReply.self)
        case .processedMarkdownHead:
            return (
                DaemonProcessedMarkdownHeadRequest.self,
                DaemonProcessedMarkdownHeadReply.self)
        case .processedMarkdownVersion:
            return (
                DaemonProcessedMarkdownVersionRequest.self,
                DaemonProcessedMarkdownVersionReply.self)
        case .recordMarkdownExtraction:
            return (
                DaemonRecordMarkdownExtractionRequest.self,
                DaemonRecordMarkdownExtractionReply.self)
        case .saveWikiStrategy:
            return (
                DaemonSaveWikiStrategyRequest.self,
                DaemonSaveWikiStrategyReply.self)
        case .setWorkspaceIndexBody:
            return (
                DaemonSetWorkspaceIndexBodyRequest.self,
                DaemonSetWorkspaceIndexBodyReply.self)
        case .sourceContent:
            return (
                DaemonSourceContentRequest.self,
                DaemonSourceContentReply.self)
        case .storeChatChunks:
            return (
                DaemonStoreChatChunksRequest.self,
                DaemonStoreChatChunksReply.self)
        case .storePageChunks:
            return (
                DaemonStorePageChunksRequest.self,
                DaemonStorePageChunksReply.self)
        case .storeSourceChunks:
            return (
                DaemonStoreSourceChunksRequest.self,
                DaemonStoreSourceChunksReply.self)
        case .updatePage:
            return (
                DaemonUpdatePageRequest.self, DaemonUpdatePageReply.self)
        case .updateWikiIndex:
            return (
                DaemonUpdateWikiIndexRequest.self,
                DaemonUpdateWikiIndexReply.self)
        case .upsertPage:
            return (
                DaemonUpsertPageRequest.self, DaemonUpsertPageReply.self)
        case .workspacePageBody:
            return (
                DaemonWorkspacePageBodyRequest.self,
                DaemonWorkspacePageBodyReply.self)
        case .workspaceWritePage:
            return (
                DaemonWorkspaceWritePageRequest.self,
                DaemonWorkspaceWritePageReply.self)

        // MARK: Event producer (50)

        case .abandonWorkspace:
            return (
                DaemonAbandonWorkspaceRequest.self,
                DaemonAbandonWorkspaceReply.self)
        case .addBytelessSource:
            return (
                DaemonAddBytelessSourceRequest.self,
                DaemonAddBytelessSourceReply.self)
        case .appendLog:
            return (
                DaemonAppendLogRequest.self, DaemonAppendLogReply.self)
        case .cancelUnclaimedPersistedChatTurn:
            return (
                DaemonCancelUnclaimedPersistedChatTurnRequest.self,
                DaemonCancelUnclaimedPersistedChatTurnReply.self)
        case .correctPageOKFVerification:
            return (
                DaemonCorrectPageOKFVerificationRequest.self,
                DaemonCorrectPageOKFVerificationReply.self)
        case .correctSourceMarkdownOKFVerification:
            return (
                DaemonCorrectSourceMarkdownOKFVerificationRequest.self,
                DaemonCorrectSourceMarkdownOKFVerificationReply.self)
        case .createBookmarkNode:
            return (
                DaemonCreateBookmarkNodeRequest.self,
                DaemonCreateBookmarkNodeReply.self)
        case .createChat:
            return (
                DaemonCreateChatRequest.self, DaemonCreateChatReply.self)
        case .createWorkspace:
            return (
                DaemonCreateWorkspaceRequest.self,
                DaemonCreateWorkspaceReply.self)
        case .deleteBookmarkNode:
            return (
                DaemonDeleteBookmarkNodeRequest.self,
                DaemonDeleteBookmarkNodeReply.self)
        case .deleteChat:
            return (
                DaemonDeleteChatRequest.self, DaemonDeleteChatReply.self)
        case .deleteResources:
            return (
                DaemonDeleteResourcesRequest.self,
                DaemonDeleteResourcesReply.self)
        case .ensureFetchActivity:
            return (
                DaemonEnsureFetchActivityRequest.self,
                DaemonEnsureFetchActivityReply.self)
        case .finalizeStaleDrafts:
            return (
                DaemonFinalizeStaleDraftsRequest.self,
                DaemonFinalizeStaleDraftsReply.self)
        case .markFetchComplete:
            return (
                DaemonMarkFetchCompleteRequest.self,
                DaemonMarkFetchCompleteReply.self)
        case .markPersistedChatTurnProviderSubmitted:
            return (
                DaemonMarkPersistedChatTurnProviderSubmittedRequest.self,
                DaemonMarkPersistedChatTurnProviderSubmittedReply.self)
        case .markSourceIngested:
            return (
                DaemonMarkSourceIngestedRequest.self,
                DaemonMarkSourceIngestedReply.self)
        case .moveBookmarkNode:
            return (
                DaemonMoveBookmarkNodeRequest.self,
                DaemonMoveBookmarkNodeReply.self)
        case .reapStaleWorkspaces:
            return (
                DaemonReapStaleWorkspacesRequest.self,
                DaemonReapStaleWorkspacesReply.self)
        case .recordPageOKFVerification:
            return (
                DaemonRecordPageOKFVerificationRequest.self,
                DaemonRecordPageOKFVerificationReply.self)
        case .recordSourceMarkdownOKFVerification:
            return (
                DaemonRecordSourceMarkdownOKFVerificationRequest.self,
                DaemonRecordSourceMarkdownOKFVerificationReply.self)
        case .removeRendererSourcePresentation:
            return (
                DaemonRemoveRendererSourcePresentationRequest.self,
                DaemonRemoveRendererSourcePresentationReply.self)
        case .renameBookmarkFolder:
            return (
                DaemonRenameBookmarkFolderRequest.self,
                DaemonRenameBookmarkFolderReply.self)
        case .renameChat:
            return (
                DaemonRenameChatRequest.self, DaemonRenameChatReply.self)
        case .renameSource:
            return (
                DaemonRenameSourceRequest.self, DaemonRenameSourceReply.self)
        case .repairMIME:
            return (
                DaemonRepairMIMERequest.self, DaemonRepairMIMEReply.self)
        case .replaceLinks:
            return (
                DaemonReplaceLinksRequest.self,
                DaemonReplaceLinksReply.self)
        case .restorePage:
            return (
                DaemonRestorePageRequest.self, DaemonRestorePageReply.self)
        case .retargetBookmarkNode:
            return (
                DaemonRetargetBookmarkNodeRequest.self,
                DaemonRetargetBookmarkNodeReply.self)
        case .revertPage:
            return (
                DaemonRevertPageRequest.self, DaemonRevertPageReply.self)
        case .setActiveMarkdown:
            return (
                DaemonSetActiveMarkdownRequest.self,
                DaemonSetActiveMarkdownReply.self)
        case .setChatAttachments:
            return (
                DaemonSetChatAttachmentsRequest.self,
                DaemonSetChatAttachmentsReply.self)
        case .setChatTitleIf:
            return (
                DaemonSetChatTitleIfRequest.self,
                DaemonSetChatTitleIfReply.self)
        case .setChatTitleIfEmpty:
            return (
                DaemonSetChatTitleIfEmptyRequest.self,
                DaemonSetChatTitleIfEmptyReply.self)
        case .setPageOKFFreshness:
            return (
                DaemonSetPageOKFFreshnessRequest.self,
                DaemonSetPageOKFFreshnessReply.self)
        case .setPageOKFStatus:
            return (
                DaemonSetPageOKFStatusRequest.self,
                DaemonSetPageOKFStatusReply.self)
        case .setRendererSourcePreference:
            return (
                DaemonSetRendererSourcePreferenceRequest.self,
                DaemonSetRendererSourcePreferenceReply.self)
        case .setRendererSourcePresentation:
            return (
                DaemonSetRendererSourcePresentationRequest.self,
                DaemonSetRendererSourcePresentationReply.self)
        case .setSourceDisplayName:
            return (
                DaemonSetSourceDisplayNameRequest.self,
                DaemonSetSourceDisplayNameReply.self)
        case .setSourceMarkdownOKFFreshness:
            return (
                DaemonSetSourceMarkdownOKFFreshnessRequest.self,
                DaemonSetSourceMarkdownOKFFreshnessReply.self)
        case .setSourceMarkdownOKFStatus:
            return (
                DaemonSetSourceMarkdownOKFStatusRequest.self,
                DaemonSetSourceMarkdownOKFStatusReply.self)
        case .updateChatAcpSessionId:
            return (
                DaemonUpdateChatAcpSessionIdRequest.self,
                DaemonUpdateChatAcpSessionIdReply.self)
        case .updateChatModelAndThinkingSelection:
            return (
                DaemonUpdateChatModelAndThinkingSelectionRequest.self,
                DaemonUpdateChatModelAndThinkingSelectionReply.self)
        case .updateChatModelOverride:
            return (
                DaemonUpdateChatModelOverrideRequest.self,
                DaemonUpdateChatModelOverrideReply.self)
        case .updateMessageSummary:
            return (
                DaemonUpdateMessageSummaryRequest.self,
                DaemonUpdateMessageSummaryReply.self)
        case .updatePersistedChatTurnUsage:
            return (
                DaemonUpdatePersistedChatTurnUsageRequest.self,
                DaemonUpdatePersistedChatTurnUsageReply.self)
        case .workspaceMerge:
            return (
                DaemonWorkspaceMergeRequest.self,
                DaemonWorkspaceMergeReply.self)
        case .workspaceRefresh:
            return (
                DaemonWorkspaceRefreshRequest.self,
                DaemonWorkspaceRefreshReply.self)
        case .workspaceResolveConflict:
            return (
                DaemonWorkspaceResolveConflictRequest.self,
                DaemonWorkspaceResolveConflictReply.self)
        case .workspaceRetryMerge:
            return (
                DaemonWorkspaceRetryMergeRequest.self,
                DaemonWorkspaceRetryMergeReply.self)
        }
    }

    /// The manifest operations, derived from the registry (families exclude
    /// the infrastructure/reserved partitions).
    static var manifestOperations: [DaemonStoreOperation] {
        DaemonStoreOperation.allCases.filter {
            $0.family == .small || $0.family == .list || $0.family == .blob
                || $0.family == .eventProducer
        }
    }
}

@Suite("Daemon store ops completeness ledger", .timeLimit(.minutes(1)))
struct DaemonStoreOpsCompletenessTests {

    @Test("every manifest operation resolves to a DTO pair; infrastructure does not")
    func ledgerCoversAllManifestOperations() {
        let manifest = DaemonStoreOpsLedger.manifestOperations
        #expect(
            manifest.count == DaemonStoreOperationCounts.manifestOperations,
            "manifest partition drifted: \(manifest.count) ops")
        for op in manifest {
            let pair = DaemonStoreOpsLedger.pair(for: op)
            #expect(pair != nil, "\(op.rawValue) has no DTO pair")
        }
        for op in DaemonStoreOperation.allCases
        where !manifest.contains(op) {
            let pair = DaemonStoreOpsLedger.pair(for: op)
            #expect(
                pair == nil,
                "\(op.rawValue) is infrastructure and must not carry a slice-2 pair")
        }
    }

    @Test("ledger partition counts match the manifest constants")
    func ledgerPartitionCounts() {
        for family in [
            DaemonStorePayloadFamily.small, .list, .blob, .eventProducer,
        ] {
            let ops = DaemonStoreOpsLedger.manifestOperations
                .filter { $0.family == family }
            let expected: Int = switch family {
            case .small: DaemonStoreOperationCounts.small
            case .list: DaemonStoreOperationCounts.list
            case .blob: DaemonStoreOperationCounts.blob
            case .eventProducer: DaemonStoreOperationCounts.eventProducer
            default: 0
            }
            #expect(
                ops.count == expected,
                "\(family.rawValue) ledger has \(ops.count), manifest says \(expected)")
        }
    }
}
#endif
