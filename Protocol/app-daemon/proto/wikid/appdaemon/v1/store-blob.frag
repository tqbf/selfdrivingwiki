// Part 1: Operation messages.
// wiki scope carried by envelope
// Upload handles refer to sealed payloads. Download handles refer to payloads
// that the daemon issued. Check scope, purpose, direction, and expiry before use.
// Mutation stamps identify writes for epoch validation and idempotent admission.
// TODO(step-2-review): Resolve shared value types and ID wrappers in store.proto.

message AddSnapshotImageRequest {
  string filename = 1;
  PayloadHandleRef data = 2;
  ContentTypeDetectionHints detection_hints = 3;
  string original_path = 4;
  string source_url = 5;
  ActivityId activity_id = 6;
  SourceRole role = 7;
  MutationStamp stamp = 8;
}

message AddSnapshotImageReply {
  SourceSummary source = 1;
  MutationOutcome outcome = 2;
  optional ResourceChangeEvent event = 3;
}

message AddSourceRequest {
  string filename = 1;
  PayloadHandleRef data = 2;
  ContentTypeDetectionHints detection_hints = 3;
  optional SourceIngestMetadata ingest_metadata = 4;
  optional SourceProvenance provenance = 5;
  SourceRole role = 6;
  optional string original_path = 7;
  optional ActivityId activity_id = 8;
  optional string resolved_display_name = 9;
  MutationStamp stamp = 10;
}

message AddSourceReply {
  SourceSummary source = 1;
  MutationOutcome outcome = 2;
  optional ResourceChangeEvent event = 3;
}

message AppendChatMessagesRequest {
  ChatId chat_id = 1;
  // Staged protobuf collection of ordered AgentEvent values.
  PayloadHandleRef events = 2;
  int64 event_count = 3;
  MutationStamp stamp = 4;
}

message AppendChatMessagesReply {
  repeated ChatMessage messages = 1;
  MutationOutcome outcome = 2;
  optional ResourceChangeEvent event = 3;
}

message AppendChatTranscriptItemsRequest {
  ChatId chat_id = 1;
  // Staged protobuf collection of ordered ChatTranscriptItem values.
  PayloadHandleRef items = 2;
  int64 item_count = 3;
  MutationStamp stamp = 4;
}

message AppendChatTranscriptItemsReply {
  repeated PersistedChatTranscriptItem items = 1;
  MutationOutcome outcome = 2;
  optional ResourceChangeEvent event = 3;
}

message AppendContentVersionRequest {
  SourceId source_id = 1;
  PayloadHandleRef data = 2;
  ContentTypeDetectionHints detection_hints = 3;
  optional SourceProvenance provenance = 4;
  MutationStamp stamp = 5;
}

message AppendContentVersionReply {
  SourceVersion version = 1;
  MutationOutcome outcome = 2;
  optional ResourceChangeEvent event = 3;
}

message AppendDerivedMarkdownRequest {
  SourceId source_id = 1;
  PayloadHandleRef content = 2;
  SourceMarkdownOrigin origin = 3;
  optional ExtractionProducer producer = 4;
  optional ProviderId provider_id = 5;
  optional ModelId model_id = 6;
  optional string tool_version = 7;
  optional PageId source_version_id = 8;
  optional string note = 9;
  MutationStamp stamp = 10;
}

message AppendDerivedMarkdownReply {
  SourceMarkdownVersionHeader version = 1;
  MutationOutcome outcome = 2;
  optional ResourceChangeEvent event = 3;
}

message AppendFetchMarkdownRequest {
  SourceId source_id = 1;
  PayloadHandleRef content = 2;
  ExtractorPackageProducer package = 3;
  optional string external_item_key = 4;
  optional string external_item_title = 5;
  PageId source_version_id = 6;
  MutationStamp stamp = 7;
}

message AppendFetchMarkdownReply {
  SourceMarkdownVersionHeader version = 1;
  MutationOutcome outcome = 2;
  optional ResourceChangeEvent event = 3;
}

message AppendHostSpeechTranscriptRequest {
  SourceId source_id = 1;
  PayloadHandleRef content = 2;
  ExtractionHostSpeechProducer producer = 3;
  PageId source_version_id = 4;
  MutationStamp stamp = 5;
}

message AppendHostSpeechTranscriptReply {
  SourceMarkdownVersionHeader version = 1;
  MutationOutcome outcome = 2;
  optional ResourceChangeEvent event = 3;
}

message AppendInstalledPackageMarkdownRequest {
  SourceId source_id = 1;
  PayloadHandleRef content = 2;
  ExtractorPackageProducer package = 3;
  SourceMarkdownOrigin origin = 4;
  optional string tool_version = 5;
  optional PageId source_version_id = 6;
  optional string note = 7;
  MutationStamp stamp = 8;
}

message AppendInstalledPackageMarkdownReply {
  SourceMarkdownVersionHeader version = 1;
  MutationOutcome outcome = 2;
  optional ResourceChangeEvent event = 3;
}

message AppendPageVersionRequest {
  PageId page_id = 1;
  string title = 2;
  // An absent body means an empty body.
  optional PayloadHandleRef body = 3;
  // An absent head ID means the write does not check the head.
  optional PageVersionId expected_head_version_id = 4;
  optional string last_edited_by = 5;
  repeated PageVersionSourceInput provenance = 6;
  MutationStamp stamp = 7;
}

message AppendPageVersionReply {
  PageVersionId version_id = 1;
  MutationOutcome outcome = 2;
  optional ResourceChangeEvent event = 3;
}

message AppendProcessedMarkdownRequest {
  SourceId source_id = 1;
  PayloadHandleRef content = 2;
  SourceMarkdownOrigin origin = 3;
  optional string note = 4;
  optional string technique = 5;
  MutationStamp stamp = 6;
}

message AppendProcessedMarkdownReply {
  SourceMarkdownVersionHeader version = 1;
  MutationOutcome outcome = 2;
  optional ResourceChangeEvent event = 3;
}

message AppendUserProcessedMarkdownRequest {
  SourceId source_id = 1;
  PayloadHandleRef content = 2;
  // Source Markdown version ID.
  PageId expected_head = 3;
  MutationStamp stamp = 4;
}

message AppendUserProcessedMarkdownReply {
  SourceMarkdownVersionHeader version = 1;
  MutationOutcome outcome = 2;
  optional ResourceChangeEvent event = 3;
}

message AttachAcquiredBytesRequest {
  SourceId source_id = 1;
  PayloadHandleRef bytes = 2;
  string mime_type = 3;
  optional string original_filename = 4;
  optional string external_item_key = 5;
  optional string external_item_title = 6;
  optional ExtractorPackageProducer producer = 7;
  MutationStamp stamp = 8;
}

message AttachAcquiredBytesReply {
  SourceVersion version = 1;
  MutationOutcome outcome = 2;
  optional ResourceChangeEvent event = 3;
}

message CheckpointStreamingMessageRequest {
  ChatId chat_id = 1;
  // TODO(step-2-review): Confirm the wire wrapper for the stable draft handle.
  string handle = 2;
  // Staged protobuf AgentEvent value.
  PayloadHandleRef event = 3;
  bool is_draft = 4;
  MutationStamp stamp = 5;
}

message CheckpointStreamingMessageReply {
  MutationOutcome outcome = 1;
  optional ResourceChangeEvent event = 2;
}

message ClaimNextPersistedChatTurnRequest {
  ChatId chat_id = 1;
  ChatTurnClaimId claim_id = 2;
  google.protobuf.Timestamp claimed_at = 3;
  optional ProviderId provider_id = 4;
  optional ModelId model_id = 5;
  MutationStamp stamp = 6;
}

message ClaimNextPersistedChatTurnReply {
  optional PersistedChatTurn turn = 1;
  MutationOutcome outcome = 2;
  optional ResourceChangeEvent event = 3;
}

message CreatePageRequest {
  string title = 1;
  // An absent body means an empty body.
  optional PayloadHandleRef body = 2;
  optional string created_by = 3;
  repeated PageVersionSourceInput provenance = 4;
  MutationStamp stamp = 5;
}

message CreatePageReply {
  PageMetadata page = 1;
  // The committed body can differ from the uploaded body.
  PayloadHandleRef body = 2;
  int64 body_byte_count = 3;
  MutationOutcome outcome = 4;
  optional ResourceChangeEvent event = 5;
}

message EnqueuePersistedChatTurnRequest {
  ChatId chat_id = 1;
  ChatTurnSubmission submission = 2;
  MutationStamp stamp = 3;
}

message EnqueuePersistedChatTurnReply {
  PersistedChatTurn turn = 1;
  MutationOutcome outcome = 2;
  optional ResourceChangeEvent event = 3;
}

message FinishPersistedChatTurnRequest {
  ChatId chat_id = 1;
  ChatTurnId turn_id = 2;
  ChatTurnClaimId claim_id = 3;
  ChatTurnPersistenceState state = 4;
  optional string terminal_message = 5;
  // The store supplies the time if absent.
  optional google.protobuf.Timestamp finished_at = 6;
  optional ChatTurnUsageValues usage = 7;
  MutationStamp stamp = 8;
}

message FinishPersistedChatTurnReply {
  PersistedChatTurn turn = 1;
  MutationOutcome outcome = 2;
  optional ResourceChangeEvent event = 3;
}

message GetWikiIndexRequest {}

message GetWikiIndexReply {
  WikiIndexMetadata metadata = 1;
  PayloadHandleRef body = 2;
  int64 body_byte_count = 3;
}

message GetWikiStrategyRequest {}

message GetWikiStrategyReply {
  // Absent if the wiki uses the default strategy.
  optional StrategySnapshot strategy = 1;
}

message MissingChatEmbeddingWorkRequest {}

message MissingChatEmbeddingWorkReply {
  // Staged protobuf collection of chat ID and text pairs.
  PayloadHandleRef work = 1;
  int64 item_count = 2;
}

message MissingPageEmbeddingWorkRequest {}

message MissingPageEmbeddingWorkReply {
  // Staged protobuf collection of page ID and text pairs.
  PayloadHandleRef work = 1;
  int64 item_count = 2;
}

message MissingSourceEmbeddingWorkRequest {}

message MissingSourceEmbeddingWorkReply {
  // Staged protobuf collection of source ID and text pairs.
  PayloadHandleRef work = 1;
  int64 item_count = 2;
}

message PageVersionBodyRequest {
  PageVersionId version_id = 1;
}

message PageVersionBodyReply {
  // Absent if no version matches.
  optional PayloadHandleRef body = 1;
  int64 body_byte_count = 2;
}

message ProcessedMarkdownHeadRequest {
  SourceId source_id = 1;
}

message ProcessedMarkdownHeadReply {
  optional SourceMarkdownVersionHeader version = 1;
  // Present exactly when version is present.
  optional PayloadHandleRef content = 2;
  int64 content_byte_count = 3;
}

message ProcessedMarkdownVersionRequest {
  PageId version_id = 1;
}

message ProcessedMarkdownVersionReply {
  optional SourceMarkdownVersionHeader version = 1;
  optional PayloadHandleRef content = 2;
  int64 content_byte_count = 3;
}

message RecordMarkdownExtractionRequest {
  // TODO(step-2-review): Share this enum with the backend arm of ExtractionProducer.
  enum Backend {
    KIND_UNSPECIFIED = 0;
    KIND_LOCAL_PDF2MD = 1;
    KIND_ACP = 2;
    KIND_ANTHROPIC = 3;
    KIND_GEMINI = 4;
    KIND_DOCLING_SERVE = 5;
  }

  SourceId source_id = 1;
  PayloadHandleRef content = 2;
  Backend backend = 3;
  optional PageId source_version_id = 4;
  optional string note = 5;
  optional string model_version = 6;
  MutationStamp stamp = 7;
}

message RecordMarkdownExtractionReply {
  SourceMarkdownVersionHeader version = 1;
  MutationOutcome outcome = 2;
  optional ResourceChangeEvent event = 3;
}

message SaveWikiStrategyRequest {
  string name = 1;
  PayloadHandleRef instructions = 2;
  // Absent matches only a wiki with no strategy row.
  optional int64 expected_revision = 3;
  MutationStamp stamp = 4;
}

message SaveWikiStrategyReply {
  WikiStrategySaveOutcome result = 1;
  MutationOutcome outcome = 2;
  optional ResourceChangeEvent event = 3;
}

message SetWorkspaceIndexBodyRequest {
  WorkspaceId workspace_id = 1;
  PayloadHandleRef index_body = 2;
  // TODO(step-2-review): Confirm the format of the index base version string.
  string index_base_version = 3;
  MutationStamp stamp = 4;
}

message SetWorkspaceIndexBodyReply {
  MutationOutcome outcome = 1;
  optional ResourceChangeEvent event = 2;
}

message SourceContentRequest {
  oneof target {
    // Resolve the source's active content reference.
    SourceId active = 1;
    // Read the exact content version, in the current PageId representation.
    PageId version = 2;
  }
}

message SourceContentReply {
  // A present handle with byte_count zero is distinct from an absent handle.
  optional PayloadHandleRef bytes = 1;
  int64 byte_count = 2;
}

message StoreChatChunksRequest {
  ChatId id = 1;
  // Staged protobuf collection of ordered chunk blobs.
  PayloadHandleRef chunks = 2;
  int64 chunk_count = 3;
  MutationStamp stamp = 4;
}

message StoreChatChunksReply {
  // Derived write: no change event.
  MutationOutcome outcome = 1;
}

message StorePageChunksRequest {
  PageId id = 1;
  // Staged protobuf collection of ordered chunk blobs.
  PayloadHandleRef chunks = 2;
  int64 chunk_count = 3;
  MutationStamp stamp = 4;
}

message StorePageChunksReply {
  // Derived write: no change event.
  MutationOutcome outcome = 1;
}

message StoreSourceChunksRequest {
  SourceId id = 1;
  // Staged protobuf collection of ordered chunk blobs.
  PayloadHandleRef chunks = 2;
  int64 chunk_count = 3;
  MutationStamp stamp = 4;
}

message StoreSourceChunksReply {
  // Derived write: no change event.
  MutationOutcome outcome = 1;
}

message UpdatePageRequest {
  PageId id = 1;
  string title = 2;
  // An absent body means an empty body.
  optional PayloadHandleRef body = 3;
  optional string last_edited_by = 4;
  repeated PageVersionSourceInput provenance = 5;
  MutationStamp stamp = 6;
}

message UpdatePageReply {
  MutationOutcome outcome = 1;
  optional ResourceChangeEvent event = 2;
}

message UpdateWikiIndexRequest {
  PayloadHandleRef body = 1;
  MutationStamp stamp = 2;
}

message UpdateWikiIndexReply {
  MutationOutcome outcome = 1;
  optional ResourceChangeEvent event = 2;
}

message WorkspacePageBodyRequest {
  WorkspaceId workspace_id = 1;
  PageId page_id = 2;
}

message WorkspacePageBodyReply {
  // Absent if the workspace has no body for this page.
  optional PayloadHandleRef body = 1;
  int64 body_byte_count = 2;
}

message WorkspaceWritePageRequest {
  WorkspaceId workspace_id = 1;
  PageId page_id = 2;
  string title = 3;
  // An absent body means an empty body.
  optional PayloadHandleRef body = 4;
  optional string author = 5;
  repeated PageVersionSourceInput provenance = 6;
  MutationStamp stamp = 7;
}

message WorkspaceWritePageReply {
  optional PageVersionId version_id = 1;
  MutationOutcome outcome = 2;
  optional ResourceChangeEvent event = 3;
}

// Part 2: StoreBlob oneof arms.
// getPage/upsertPage: dedicated RPCs (excluded)
// ARM LEDGER (StoreBlob): arm 1 = addSnapshotImage → AddSnapshotImageRequest/AddSnapshotImageReply
// ARM LEDGER (StoreBlob): arm 2 = addSource → AddSourceRequest/AddSourceReply
// ARM LEDGER (StoreBlob): arm 3 = appendChatMessages → AppendChatMessagesRequest/AppendChatMessagesReply
// ARM LEDGER (StoreBlob): arm 4 = appendChatTranscriptItems → AppendChatTranscriptItemsRequest/AppendChatTranscriptItemsReply
// ARM LEDGER (StoreBlob): arm 5 = appendContentVersion → AppendContentVersionRequest/AppendContentVersionReply
// ARM LEDGER (StoreBlob): arm 6 = appendDerivedMarkdown → AppendDerivedMarkdownRequest/AppendDerivedMarkdownReply
// ARM LEDGER (StoreBlob): arm 7 = appendFetchMarkdown → AppendFetchMarkdownRequest/AppendFetchMarkdownReply
// ARM LEDGER (StoreBlob): arm 8 = appendHostSpeechTranscript → AppendHostSpeechTranscriptRequest/AppendHostSpeechTranscriptReply
// ARM LEDGER (StoreBlob): arm 9 = appendInstalledPackageMarkdown → AppendInstalledPackageMarkdownRequest/AppendInstalledPackageMarkdownReply
// ARM LEDGER (StoreBlob): arm 10 = appendPageVersion → AppendPageVersionRequest/AppendPageVersionReply
// ARM LEDGER (StoreBlob): arm 11 = appendProcessedMarkdown → AppendProcessedMarkdownRequest/AppendProcessedMarkdownReply
// ARM LEDGER (StoreBlob): arm 12 = appendUserProcessedMarkdown → AppendUserProcessedMarkdownRequest/AppendUserProcessedMarkdownReply
// ARM LEDGER (StoreBlob): arm 13 = attachAcquiredBytes → AttachAcquiredBytesRequest/AttachAcquiredBytesReply
// ARM LEDGER (StoreBlob): arm 14 = checkpointStreamingMessage → CheckpointStreamingMessageRequest/CheckpointStreamingMessageReply
// ARM LEDGER (StoreBlob): arm 15 = claimNextPersistedChatTurn → ClaimNextPersistedChatTurnRequest/ClaimNextPersistedChatTurnReply
// ARM LEDGER (StoreBlob): arm 16 = createPage → CreatePageRequest/CreatePageReply
// ARM LEDGER (StoreBlob): arm 17 = enqueuePersistedChatTurn → EnqueuePersistedChatTurnRequest/EnqueuePersistedChatTurnReply
// ARM LEDGER (StoreBlob): arm 18 = finishPersistedChatTurn → FinishPersistedChatTurnRequest/FinishPersistedChatTurnReply
// ARM LEDGER (StoreBlob): arm 20 = getWikiIndex → GetWikiIndexRequest/GetWikiIndexReply
// ARM LEDGER (StoreBlob): arm 21 = getWikiStrategy → GetWikiStrategyRequest/GetWikiStrategyReply
// ARM LEDGER (StoreBlob): arm 22 = missingChatEmbeddingWork → MissingChatEmbeddingWorkRequest/MissingChatEmbeddingWorkReply
// ARM LEDGER (StoreBlob): arm 23 = missingPageEmbeddingWork → MissingPageEmbeddingWorkRequest/MissingPageEmbeddingWorkReply
// ARM LEDGER (StoreBlob): arm 24 = missingSourceEmbeddingWork → MissingSourceEmbeddingWorkRequest/MissingSourceEmbeddingWorkReply
// ARM LEDGER (StoreBlob): arm 25 = pageVersionBody → PageVersionBodyRequest/PageVersionBodyReply
// ARM LEDGER (StoreBlob): arm 26 = processedMarkdownHead → ProcessedMarkdownHeadRequest/ProcessedMarkdownHeadReply
// ARM LEDGER (StoreBlob): arm 27 = processedMarkdownVersion → ProcessedMarkdownVersionRequest/ProcessedMarkdownVersionReply
// ARM LEDGER (StoreBlob): arm 28 = recordMarkdownExtraction → RecordMarkdownExtractionRequest/RecordMarkdownExtractionReply
// ARM LEDGER (StoreBlob): arm 29 = saveWikiStrategy → SaveWikiStrategyRequest/SaveWikiStrategyReply
// ARM LEDGER (StoreBlob): arm 30 = setWorkspaceIndexBody → SetWorkspaceIndexBodyRequest/SetWorkspaceIndexBodyReply
// ARM LEDGER (StoreBlob): arm 31 = sourceContent → SourceContentRequest/SourceContentReply
// ARM LEDGER (StoreBlob): arm 32 = storeChatChunks → StoreChatChunksRequest/StoreChatChunksReply
// ARM LEDGER (StoreBlob): arm 33 = storePageChunks → StorePageChunksRequest/StorePageChunksReply
// ARM LEDGER (StoreBlob): arm 34 = storeSourceChunks → StoreSourceChunksRequest/StoreSourceChunksReply
// ARM LEDGER (StoreBlob): arm 35 = updatePage → UpdatePageRequest/UpdatePageReply
// ARM LEDGER (StoreBlob): arm 36 = updateWikiIndex → UpdateWikiIndexRequest/UpdateWikiIndexReply
// ARM LEDGER (StoreBlob): arm 38 = workspacePageBody → WorkspacePageBodyRequest/WorkspacePageBodyReply
// ARM LEDGER (StoreBlob): arm 39 = workspaceWritePage → WorkspaceWritePageRequest/WorkspaceWritePageReply

message StoreBlobRequest {
  reserved 19, 37;
  oneof operation {
    AddSnapshotImageRequest add_snapshot_image = 1;
    AddSourceRequest add_source = 2;
    AppendChatMessagesRequest append_chat_messages = 3;
    AppendChatTranscriptItemsRequest append_chat_transcript_items = 4;
    AppendContentVersionRequest append_content_version = 5;
    AppendDerivedMarkdownRequest append_derived_markdown = 6;
    AppendFetchMarkdownRequest append_fetch_markdown = 7;
    AppendHostSpeechTranscriptRequest append_host_speech_transcript = 8;
    AppendInstalledPackageMarkdownRequest append_installed_package_markdown = 9;
    AppendPageVersionRequest append_page_version = 10;
    AppendProcessedMarkdownRequest append_processed_markdown = 11;
    AppendUserProcessedMarkdownRequest append_user_processed_markdown = 12;
    AttachAcquiredBytesRequest attach_acquired_bytes = 13;
    CheckpointStreamingMessageRequest checkpoint_streaming_message = 14;
    ClaimNextPersistedChatTurnRequest claim_next_persisted_chat_turn = 15;
    CreatePageRequest create_page = 16;
    EnqueuePersistedChatTurnRequest enqueue_persisted_chat_turn = 17;
    FinishPersistedChatTurnRequest finish_persisted_chat_turn = 18;
    GetWikiIndexRequest get_wiki_index = 20;
    GetWikiStrategyRequest get_wiki_strategy = 21;
    MissingChatEmbeddingWorkRequest missing_chat_embedding_work = 22;
    MissingPageEmbeddingWorkRequest missing_page_embedding_work = 23;
    MissingSourceEmbeddingWorkRequest missing_source_embedding_work = 24;
    PageVersionBodyRequest page_version_body = 25;
    ProcessedMarkdownHeadRequest processed_markdown_head = 26;
    ProcessedMarkdownVersionRequest processed_markdown_version = 27;
    RecordMarkdownExtractionRequest record_markdown_extraction = 28;
    SaveWikiStrategyRequest save_wiki_strategy = 29;
    SetWorkspaceIndexBodyRequest set_workspace_index_body = 30;
    SourceContentRequest source_content = 31;
    StoreChatChunksRequest store_chat_chunks = 32;
    StorePageChunksRequest store_page_chunks = 33;
    StoreSourceChunksRequest store_source_chunks = 34;
    UpdatePageRequest update_page = 35;
    UpdateWikiIndexRequest update_wiki_index = 36;
    WorkspacePageBodyRequest workspace_page_body = 38;
    WorkspaceWritePageRequest workspace_write_page = 39;
  }
}

message StoreBlobReply {
  reserved 19, 37;
  oneof operation {
    AddSnapshotImageReply add_snapshot_image = 1;
    AddSourceReply add_source = 2;
    AppendChatMessagesReply append_chat_messages = 3;
    AppendChatTranscriptItemsReply append_chat_transcript_items = 4;
    AppendContentVersionReply append_content_version = 5;
    AppendDerivedMarkdownReply append_derived_markdown = 6;
    AppendFetchMarkdownReply append_fetch_markdown = 7;
    AppendHostSpeechTranscriptReply append_host_speech_transcript = 8;
    AppendInstalledPackageMarkdownReply append_installed_package_markdown = 9;
    AppendPageVersionReply append_page_version = 10;
    AppendProcessedMarkdownReply append_processed_markdown = 11;
    AppendUserProcessedMarkdownReply append_user_processed_markdown = 12;
    AttachAcquiredBytesReply attach_acquired_bytes = 13;
    CheckpointStreamingMessageReply checkpoint_streaming_message = 14;
    ClaimNextPersistedChatTurnReply claim_next_persisted_chat_turn = 15;
    CreatePageReply create_page = 16;
    EnqueuePersistedChatTurnReply enqueue_persisted_chat_turn = 17;
    FinishPersistedChatTurnReply finish_persisted_chat_turn = 18;
    GetWikiIndexReply get_wiki_index = 20;
    GetWikiStrategyReply get_wiki_strategy = 21;
    MissingChatEmbeddingWorkReply missing_chat_embedding_work = 22;
    MissingPageEmbeddingWorkReply missing_page_embedding_work = 23;
    MissingSourceEmbeddingWorkReply missing_source_embedding_work = 24;
    PageVersionBodyReply page_version_body = 25;
    ProcessedMarkdownHeadReply processed_markdown_head = 26;
    ProcessedMarkdownVersionReply processed_markdown_version = 27;
    RecordMarkdownExtractionReply record_markdown_extraction = 28;
    SaveWikiStrategyReply save_wiki_strategy = 29;
    SetWorkspaceIndexBodyReply set_workspace_index_body = 30;
    SourceContentReply source_content = 31;
    StoreChatChunksReply store_chat_chunks = 32;
    StorePageChunksReply store_page_chunks = 33;
    StoreSourceChunksReply store_source_chunks = 34;
    UpdatePageReply update_page = 35;
    UpdateWikiIndexReply update_wiki_index = 36;
    WorkspacePageBodyReply workspace_page_body = 38;
    WorkspaceWritePageReply workspace_write_page = 39;
  }
}
