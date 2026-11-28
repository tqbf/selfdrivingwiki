// ARM LEDGER (StoreSmall): arm 1 = activeContentVersion → ActiveContentVersionRequest/ActiveContentVersionReply
// ARM LEDGER (StoreSmall): arm 2 = activeExtractionProvenance → ActiveExtractionProvenanceRequest/ActiveExtractionProvenanceReply
// ARM LEDGER (StoreSmall): arm 3 = chatAttachments → ChatAttachmentsRequest/ChatAttachmentsReply
// ARM LEDGER (StoreSmall): arm 4 = chatTranscriptCheckpoint → ChatTranscriptCheckpointRequest/ChatTranscriptCheckpointReply
// ARM LEDGER (StoreSmall): arm 5 = chatUsageSummary → ChatUsageSummaryRequest/ChatUsageSummaryReply
// ARM LEDGER (StoreSmall): arm 6 = fetchState → FetchStateRequest/FetchStateReply
// ARM LEDGER (StoreSmall): arm 7 = getChat → GetChatRequest/GetChatReply
// ARM LEDGER (StoreSmall): arm 8 = getMetadata → GetMetadataRequest/GetMetadataReply
// ARM LEDGER (StoreSmall): arm 9 = getWikiStrategyState → GetWikiStrategyStateRequest/GetWikiStrategyStateReply
// ARM LEDGER (StoreSmall): arm 10 = hasImageSiblings → HasImageSiblingsRequest/HasImageSiblingsReply
// ARM LEDGER (StoreSmall): arm 11 = hasProcessedMarkdown → HasProcessedMarkdownRequest/HasProcessedMarkdownReply
// ARM LEDGER (StoreSmall): arm 12 = initialContentVersion → InitialContentVersionRequest/InitialContentVersionReply
// ARM LEDGER (StoreSmall): arm 13 = pageHeadSources → PageHeadSourcesRequest/PageHeadSourcesReply
// ARM LEDGER (StoreSmall): arm 14 = pageHeadVersionID → PageHeadVersionIDRequest/PageHeadVersionIDReply
// ARM LEDGER (StoreSmall): arm 15 = pageOKFMetadata → PageOKFMetadataRequest/PageOKFMetadataReply
// ARM LEDGER (StoreSmall): arm 16 = pageOrigin → PageOriginRequest/PageOriginReply
// ARM LEDGER (StoreSmall): arm 17 = pageVersionSources → PageVersionSourcesRequest/PageVersionSourcesReply
// ARM LEDGER (StoreSmall): arm 18 = rendererInputByteCount → RendererInputByteCountRequest/RendererInputByteCountReply
// ARM LEDGER (StoreSmall): arm 19 = rendererSourcePreference → RendererSourcePreferenceRequest/RendererSourcePreferenceReply
// ARM LEDGER (StoreSmall): arm 20 = rendererSourcePresentation → RendererSourcePresentationRequest/RendererSourcePresentationReply
// ARM LEDGER (StoreSmall): arm 21 = resolveChatByTitle → ResolveChatByTitleRequest/ResolveChatByTitleReply
// ARM LEDGER (StoreSmall): arm 22 = resolveSourceByName → ResolveSourceByNameRequest/ResolveSourceByNameReply
// ARM LEDGER (StoreSmall): arm 23 = resolveTitleToID → ResolveTitleToIDRequest/ResolveTitleToIDReply
// ARM LEDGER (StoreSmall): arm 24 = searchSimilar → SearchSimilarRequest/SearchSimilarReply
// ARM LEDGER (StoreSmall): arm 25 = searchSimilarChats → SearchSimilarChatsRequest/SearchSimilarChatsReply
// ARM LEDGER (StoreSmall): arm 26 = searchSimilarSources → SearchSimilarSourcesRequest/SearchSimilarSourcesReply
// ARM LEDGER (StoreSmall): arm 27 = setMetadata → SetMetadataRequest/SetMetadataReply
// ARM LEDGER (StoreSmall): arm 28 = sourceMarkdownOKFMetadata → SourceMarkdownOKFMetadataRequest/SourceMarkdownOKFMetadataReply
// ARM LEDGER (StoreSmall): arm 29 = sourceMatchingURLIdentity → SourceMatchingURLIdentityRequest/SourceMatchingURLIdentityReply
// ARM LEDGER (StoreSmall): arm 30 = sourceOrigin → SourceOriginRequest/SourceOriginReply
// ARM LEDGER (StoreSmall): arm 31 = sourceVersion → SourceVersionRequest/SourceVersionReply
// ARM LEDGER (StoreSmall): arm 32 = vacuumActivities → VacuumActivitiesRequest/VacuumActivitiesReply
// ARM LEDGER (StoreSmall): arm 33 = vacuumBlobs → VacuumBlobsRequest/VacuumBlobsReply
// ARM LEDGER (StoreSmall): arm 34 = vacuumPageVersions → VacuumPageVersionsRequest/VacuumPageVersionsReply
// ARM LEDGER (StoreSmall): arm 35 = wikiStrategyRevision → WikiStrategyRevisionRequest/WikiStrategyRevisionReply
// ARM LEDGER (StoreSmall): arm 36 = workspacePageVersion → WorkspacePageVersionRequest/WorkspacePageVersionReply
// ARM LEDGER (StoreSmall): arm 37 = workspaceSummary → WorkspaceSummaryRequest/WorkspaceSummaryReply

// Part 1: Operation messages.

message ActiveContentVersionRequest {
  SourceId source_id = 1;
}

message ActiveContentVersionReply {
  optional SourceVersion version = 1;
}

message ActiveExtractionProvenanceRequest {
  SourceId source_id = 1;
}

message ActiveExtractionProvenanceReply {
  optional ExtractionProvenance provenance = 1;
}

message ChatAttachmentsRequest {
  ChatId chat_id = 1;
}

message ChatAttachmentsReply {
  repeated ChatAttachmentTarget targets = 1;
}

message ChatTranscriptCheckpointRequest {
  ChatId chat_id = 1;
}

message ChatTranscriptCheckpointReply {
  ChatTranscriptCursor checkpoint = 1;
}

message ChatUsageSummaryRequest {
  ChatId chat_id = 1;
}

message ChatUsageSummaryReply {
  ChatUsageSummary summary = 1;
}

message FetchStateRequest {
  SourceId source_id = 1;
}

message FetchStateReply {
  optional SourceFetchState state = 1;
}

message GetChatRequest {
  ChatId id = 1;
}

message GetChatReply {
  ChatSummary chat = 1;
}

message GetMetadataRequest {
  string key = 1;
}

message GetMetadataReply {
  optional string value = 1;
}

message GetWikiStrategyStateRequest {}

message GetWikiStrategyStateReply {
  WikiStrategyState state = 1;
}

message HasImageSiblingsRequest {
  SourceId source_id = 1;
}

message HasImageSiblingsReply {
  bool has_siblings = 1;
}

message HasProcessedMarkdownRequest {
  SourceId source_id = 1;
}

message HasProcessedMarkdownReply {
  bool has_any = 1;
}

message InitialContentVersionRequest {
  SourceId source_id = 1;
}

message InitialContentVersionReply {
  optional SourceVersion version = 1;
}

message PageHeadSourcesRequest {
  PageId page_id = 1;
}

message PageHeadSourcesReply {
  repeated PageVersionSource sources = 1;
}

message PageHeadVersionIDRequest {
  PageId page_id = 1;
}

message PageHeadVersionIDReply {
  optional string version_id = 1;
}

message PageOKFMetadataRequest {
  string version_id = 1;
  bool include_corrected = 2;
}

message PageOKFMetadataReply {
  optional PageOKFTrustMetadata metadata = 1;
}

message PageOriginRequest {
  PageId page_id = 1;
}

message PageOriginReply {
  optional PageOrigin origin = 1;
}

message PageVersionSourcesRequest {
  string version_id = 1;
}

message PageVersionSourcesReply {
  repeated PageVersionSource sources = 1;
}

message RendererInputByteCountRequest {
  RendererBridgeInput input = 1;
}

message RendererInputByteCountReply {
  optional int64 byte_count = 1;
}

message RendererSourcePreferenceRequest {
  SourceId source_id = 1;
}

message RendererSourcePreferenceReply {
  optional RendererSourcePreference preference = 1;
}

message RendererSourcePresentationRequest {
  SourceId source_id = 1;
}

message RendererSourcePresentationReply {
  optional RendererSourcePresentation presentation = 1;
}

message ResolveChatByTitleRequest {
  string title = 1;
}

message ResolveChatByTitleReply {
  optional ChatId chat_id = 1;
}

message ResolveSourceByNameRequest {
  string display_name = 1;
}

message ResolveSourceByNameReply {
  optional SourceId source_id = 1;
}

message ResolveTitleToIDRequest {
  string title = 1;
}

message ResolveTitleToIDReply {
  optional PageId page_id = 1;
}

message SearchSimilarRequest {
  message Bm25Leg {
    repeated PageSummary items = 1;
  }

  string query = 1;
  int64 limit = 2;
  // Absent selects cosine-only search. Present with no items is an empty BM25 leg.
  optional Bm25Leg bm25_leg = 3;
}

message SearchSimilarReply {
  repeated PageSummary results = 1;
}

message SearchSimilarChatsRequest {
  message Bm25Leg {
    repeated ChatSummary items = 1;
  }

  string query = 1;
  int64 limit = 2;
  optional Bm25Leg bm25_leg = 3;
}

message SearchSimilarChatsReply {
  repeated ChatSummary results = 1;
}

message SearchSimilarSourcesRequest {
  message Bm25Leg {
    repeated SourceSummary items = 1;
  }

  string query = 1;
  int64 limit = 2;
  optional Bm25Leg bm25_leg = 3;
}

message SearchSimilarSourcesReply {
  repeated SourceSummary results = 1;
}

message SetMetadataRequest {
  string key = 1;
  string value = 2;
}

message SetMetadataReply {
  MutationOutcome outcome = 1;
}

message SourceMarkdownOKFMetadataRequest {
  // TODO(step-2-review): The DTO uses a raw SourceMarkdownVersionID, not a page ID.
  string version_id = 1;
  bool include_corrected = 2;
}

message SourceMarkdownOKFMetadataReply {
  optional SourceMarkdownOKFTrustMetadata metadata = 1;
}

message SourceMatchingURLIdentityRequest {
  string identity = 1;
}

message SourceMatchingURLIdentityReply {
  optional SourceSummary source = 1;
}

message SourceOriginRequest {
  SourceId source_id = 1;
}

message SourceOriginReply {
  optional SourceOrigin origin = 1;
}

message SourceVersionRequest {
  // TODO(step-2-review): The DTO uses a raw SourceVersionID, not a page ID.
  string version_id = 1;
}

message SourceVersionReply {
  optional SourceVersion version = 1;
}

message VacuumActivitiesRequest {
  bool dry_run = 1;
}

message VacuumActivitiesReply {
  ActivityVacuumReport report = 1;
  MutationOutcome outcome = 2;
}

message VacuumBlobsRequest {
  bool dry_run = 1;
}

message VacuumBlobsReply {
  BlobVacuumReport report = 1;
  MutationOutcome outcome = 2;
}

message VacuumPageVersionsRequest {
  bool dry_run = 1;
}

message VacuumPageVersionsReply {
  PageVersionVacuumReport report = 1;
  MutationOutcome outcome = 2;
}

message WikiStrategyRevisionRequest {}

message WikiStrategyRevisionReply {
  optional int64 revision = 1;
}

message WorkspacePageVersionRequest {
  string workspace_id = 1;
  PageId page_id = 2;
}

message WorkspacePageVersionReply {
  optional string version_id = 1;
}

message WorkspaceSummaryRequest {
  string id = 1;
}

message WorkspaceSummaryReply {
  optional WorkspaceSummary summary = 1;
}

// Part 2: Envelope oneofs.

// StoreSmallRequest
oneof operation {
  ActiveContentVersionRequest active_content_version = 1; // arm 1: activeContentVersion
  ActiveExtractionProvenanceRequest active_extraction_provenance = 2; // arm 2: activeExtractionProvenance
  ChatAttachmentsRequest chat_attachments = 3; // arm 3: chatAttachments
  ChatTranscriptCheckpointRequest chat_transcript_checkpoint = 4; // arm 4: chatTranscriptCheckpoint
  ChatUsageSummaryRequest chat_usage_summary = 5; // arm 5: chatUsageSummary
  FetchStateRequest fetch_state = 6; // arm 6: fetchState
  GetChatRequest get_chat = 7; // arm 7: getChat
  GetMetadataRequest get_metadata = 8; // arm 8: getMetadata
  GetWikiStrategyStateRequest get_wiki_strategy_state = 9; // arm 9: getWikiStrategyState
  HasImageSiblingsRequest has_image_siblings = 10; // arm 10: hasImageSiblings
  HasProcessedMarkdownRequest has_processed_markdown = 11; // arm 11: hasProcessedMarkdown
  InitialContentVersionRequest initial_content_version = 12; // arm 12: initialContentVersion
  PageHeadSourcesRequest page_head_sources = 13; // arm 13: pageHeadSources
  PageHeadVersionIDRequest page_head_version_id = 14; // arm 14: pageHeadVersionID
  PageOKFMetadataRequest page_okf_metadata = 15; // arm 15: pageOKFMetadata
  PageOriginRequest page_origin = 16; // arm 16: pageOrigin
  PageVersionSourcesRequest page_version_sources = 17; // arm 17: pageVersionSources
  RendererInputByteCountRequest renderer_input_byte_count = 18; // arm 18: rendererInputByteCount
  RendererSourcePreferenceRequest renderer_source_preference = 19; // arm 19: rendererSourcePreference
  RendererSourcePresentationRequest renderer_source_presentation = 20; // arm 20: rendererSourcePresentation
  ResolveChatByTitleRequest resolve_chat_by_title = 21; // arm 21: resolveChatByTitle
  ResolveSourceByNameRequest resolve_source_by_name = 22; // arm 22: resolveSourceByName
  ResolveTitleToIDRequest resolve_title_to_id = 23; // arm 23: resolveTitleToID
  SearchSimilarRequest search_similar = 24; // arm 24: searchSimilar
  SearchSimilarChatsRequest search_similar_chats = 25; // arm 25: searchSimilarChats
  SearchSimilarSourcesRequest search_similar_sources = 26; // arm 26: searchSimilarSources
  SetMetadataRequest set_metadata = 27; // arm 27: setMetadata
  SourceMarkdownOKFMetadataRequest source_markdown_okf_metadata = 28; // arm 28: sourceMarkdownOKFMetadata
  SourceMatchingURLIdentityRequest source_matching_url_identity = 29; // arm 29: sourceMatchingURLIdentity
  SourceOriginRequest source_origin = 30; // arm 30: sourceOrigin
  SourceVersionRequest source_version = 31; // arm 31: sourceVersion
  VacuumActivitiesRequest vacuum_activities = 32; // arm 32: vacuumActivities
  VacuumBlobsRequest vacuum_blobs = 33; // arm 33: vacuumBlobs
  VacuumPageVersionsRequest vacuum_page_versions = 34; // arm 34: vacuumPageVersions
  WikiStrategyRevisionRequest wiki_strategy_revision = 35; // arm 35: wikiStrategyRevision
  WorkspacePageVersionRequest workspace_page_version = 36; // arm 36: workspacePageVersion
  WorkspaceSummaryRequest workspace_summary = 37; // arm 37: workspaceSummary
}

// StoreSmallReply
oneof operation {
  ActiveContentVersionReply active_content_version = 1; // arm 1: activeContentVersion
  ActiveExtractionProvenanceReply active_extraction_provenance = 2; // arm 2: activeExtractionProvenance
  ChatAttachmentsReply chat_attachments = 3; // arm 3: chatAttachments
  ChatTranscriptCheckpointReply chat_transcript_checkpoint = 4; // arm 4: chatTranscriptCheckpoint
  ChatUsageSummaryReply chat_usage_summary = 5; // arm 5: chatUsageSummary
  FetchStateReply fetch_state = 6; // arm 6: fetchState
  GetChatReply get_chat = 7; // arm 7: getChat
  GetMetadataReply get_metadata = 8; // arm 8: getMetadata
  GetWikiStrategyStateReply get_wiki_strategy_state = 9; // arm 9: getWikiStrategyState
  HasImageSiblingsReply has_image_siblings = 10; // arm 10: hasImageSiblings
  HasProcessedMarkdownReply has_processed_markdown = 11; // arm 11: hasProcessedMarkdown
  InitialContentVersionReply initial_content_version = 12; // arm 12: initialContentVersion
  PageHeadSourcesReply page_head_sources = 13; // arm 13: pageHeadSources
  PageHeadVersionIDReply page_head_version_id = 14; // arm 14: pageHeadVersionID
  PageOKFMetadataReply page_okf_metadata = 15; // arm 15: pageOKFMetadata
  PageOriginReply page_origin = 16; // arm 16: pageOrigin
  PageVersionSourcesReply page_version_sources = 17; // arm 17: pageVersionSources
  RendererInputByteCountReply renderer_input_byte_count = 18; // arm 18: rendererInputByteCount
  RendererSourcePreferenceReply renderer_source_preference = 19; // arm 19: rendererSourcePreference
  RendererSourcePresentationReply renderer_source_presentation = 20; // arm 20: rendererSourcePresentation
  ResolveChatByTitleReply resolve_chat_by_title = 21; // arm 21: resolveChatByTitle
  ResolveSourceByNameReply resolve_source_by_name = 22; // arm 22: resolveSourceByName
  ResolveTitleToIDReply resolve_title_to_id = 23; // arm 23: resolveTitleToID
  SearchSimilarReply search_similar = 24; // arm 24: searchSimilar
  SearchSimilarChatsReply search_similar_chats = 25; // arm 25: searchSimilarChats
  SearchSimilarSourcesReply search_similar_sources = 26; // arm 26: searchSimilarSources
  SetMetadataReply set_metadata = 27; // arm 27: setMetadata
  SourceMarkdownOKFMetadataReply source_markdown_okf_metadata = 28; // arm 28: sourceMarkdownOKFMetadata
  SourceMatchingURLIdentityReply source_matching_url_identity = 29; // arm 29: sourceMatchingURLIdentity
  SourceOriginReply source_origin = 30; // arm 30: sourceOrigin
  SourceVersionReply source_version = 31; // arm 31: sourceVersion
  VacuumActivitiesReply vacuum_activities = 32; // arm 32: vacuumActivities
  VacuumBlobsReply vacuum_blobs = 33; // arm 33: vacuumBlobs
  VacuumPageVersionsReply vacuum_page_versions = 34; // arm 34: vacuumPageVersions
  WikiStrategyRevisionReply wiki_strategy_revision = 35; // arm 35: wikiStrategyRevision
  WorkspacePageVersionReply workspace_page_version = 36; // arm 36: workspacePageVersion
  WorkspaceSummaryReply workspace_summary = 37; // arm 37: workspaceSummary
}
