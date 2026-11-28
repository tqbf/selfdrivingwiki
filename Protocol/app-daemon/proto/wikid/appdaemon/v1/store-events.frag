// Part 1: Store commit events and mutation outcomes.

// Published after commit and unlock. The subscription envelope owns delivery position.
message StoreEvent {
  WikiId wiki_id = 1;
  string change_token = 2;
  repeated ResourceChange batch = 3;
}

message ResourceChange {
  enum Kind {
    KIND_UNSPECIFIED = 0;
    KIND_CREATED = 1;
    KIND_UPDATED = 2;
    KIND_DELETED = 3;
  }

  message PageTarget { PageId id = 1; }
  message SourceTarget { SourceId id = 1; }
  message ChatTarget { ChatId id = 1; }
  message BookmarkTarget { BookmarkId id = 1; }
  message LogTarget { LogEntryId id = 1; }

  // These targets are singletons. Keep the legacy event ID verbatim.
  message SystemPromptTarget { string legacy_id = 1; }
  message WikiIndexTarget { string legacy_id = 1; }
  message StrategyTarget { string legacy_id = 1; }

  // Use only when the legacy event has no resource kind.
  message LegacyUnclassifiedTarget { string id = 1; }

  Kind kind = 1;
  oneof target {
    PageTarget page = 2;
    SourceTarget source = 3;
    ChatTarget chat = 4;
    BookmarkTarget bookmark = 5;
    SystemPromptTarget system_prompt = 6;
    WikiIndexTarget wiki_index = 7;
    LogTarget log = 8;
    StrategyTarget strategy = 9;
    LegacyUnclassifiedTarget legacy_unclassified = 10;
  }
  // Store-local bus sequence, not a subscription position.
  uint64 seq = 11;
}

// Replies carry the event echo separately. Failures use gRPC status details.
message MutationOutcome {
  enum Status {
    KIND_UNSPECIFIED = 0;
    KIND_COMMITTED = 1;
    KIND_JOINED = 2;
    KIND_OUTCOME_UNKNOWN = 3;
  }
  MutationStamp stamp = 1;
  Status status = 2;
}

// Part 2: Operation messages.
// wiki scope carried by envelope
// The request envelope also carries the mutation stamp. Reply events retain
// emission order. An empty list means that the mutation emitted no changes.
// TODO(step-2-review): Use the shared store value types and ID wrappers at assembly.

message AbandonWorkspaceRequest {
  WorkspaceId id = 1;
}

message AbandonWorkspaceReply {
  MutationOutcome outcome = 1;
  repeated ResourceChange events = 2;
}

message AddBytelessSourceRequest {
  string filename = 1;
  optional string mime_type = 2;
  SourceProvenance provenance = 3;
  SourceRole role = 4;
}

message AddBytelessSourceReply {
  SourceSummary source = 1;
  MutationOutcome outcome = 2;
  repeated ResourceChange events = 3;
}

message AppendLogRequest {
  LogEntry.Kind kind = 1;
  string title = 2;
  optional string note = 3;
}

message AppendLogReply {
  LogEntry entry = 1;
  MutationOutcome outcome = 2;
  repeated ResourceChange events = 3;
}

message CancelUnclaimedPersistedChatTurnRequest {
  ChatId chat_id = 1;
  ChatTurnId turn_id = 2;
}

message CancelUnclaimedPersistedChatTurnReply {
  optional PersistedChatTurn turn = 1;
  MutationOutcome outcome = 2;
  repeated ResourceChange events = 3;
}

message CorrectPageOKFVerificationRequest {
  PageVersionId version_id = 1;
  OKFVerificationId verification_id = 2;
  OKFVerifierIdentity correcting_verifier = 3;
  google.protobuf.Timestamp corrected_at = 4;
  optional OKFVerificationCorrectionReason reason = 5;
}

message CorrectPageOKFVerificationReply {
  MutationOutcome outcome = 1;
  repeated ResourceChange events = 2;
}

message CorrectSourceMarkdownOKFVerificationRequest {
  PageId version_id = 1;
  OKFVerificationId verification_id = 2;
  OKFVerifierIdentity correcting_verifier = 3;
  google.protobuf.Timestamp corrected_at = 4;
  optional OKFVerificationCorrectionReason reason = 5;
}

message CorrectSourceMarkdownOKFVerificationReply {
  MutationOutcome outcome = 1;
  repeated ResourceChange events = 2;
}

message CreateBookmarkNodeRequest {
  optional BookmarkId parent_id = 1;
  int64 position = 2;
  BookmarkContent content = 3;
}

message CreateBookmarkNodeReply {
  BookmarkNode node = 1;
  MutationOutcome outcome = 2;
  repeated ResourceChange events = 3;
}

message CreateChatRequest {
  ChatKind kind = 1;
  string title = 2;
  optional ProviderId model_provider_id = 3;
  optional ModelId model_id = 4;
  optional ThinkingOptionId configured_thinking_option_id = 5;
  optional ThinkingOptionId effective_thinking_option_id = 6;
  repeated ChatAttachmentTarget attachments = 7;
}

message CreateChatReply {
  ChatSummary chat = 1;
  MutationOutcome outcome = 2;
  repeated ResourceChange events = 3;
}

message CreateWorkspaceRequest {
  optional string name = 1;
  optional ActivityId activity_id = 2;
}

message CreateWorkspaceReply {
  WorkspaceId workspace_id = 1;
  MutationOutcome outcome = 2;
  repeated ResourceChange events = 3;
}

message DeleteBookmarkNodeRequest {
  BookmarkId id = 1;
}

message DeleteBookmarkNodeReply {
  MutationOutcome outcome = 1;
  repeated ResourceChange events = 2;
}

message DeleteChatRequest {
  ChatId id = 1;
}

message DeleteChatReply {
  MutationOutcome outcome = 1;
  repeated ResourceChange events = 2;
}

message DeleteResourcesRequest {
  ResourceDeletionRequest request = 1;
}

message DeleteResourcesReply {
  ResourceDeletionResult result = 1;
  MutationOutcome outcome = 2;
  repeated ResourceChange events = 3;
}

message EnsureFetchActivityRequest {
  SourceProvenance provenance = 1;
}

message EnsureFetchActivityReply {
  ActivityId activity_id = 1;
  MutationOutcome outcome = 2;
  repeated ResourceChange events = 3;
}

message FinalizeStaleDraftsRequest {
  ChatId chat_id = 1;
}

message FinalizeStaleDraftsReply {
  MutationOutcome outcome = 1;
  repeated ResourceChange events = 2;
}

message MarkFetchCompleteRequest {
  SourceId source_id = 1;
  // Absent selects the unconditional operation.
  optional PageId expected_content_version_id = 2;
}

message MarkFetchCompleteReply {
  // Absent for the unconditional operation. False means the version moved on.
  optional bool did_advance = 1;
  MutationOutcome outcome = 2;
  repeated ResourceChange events = 3;
}

message MarkPersistedChatTurnProviderSubmittedRequest {
  ChatId chat_id = 1;
  ChatTurnId turn_id = 2;
  ChatClaimId claim_id = 3;
  optional ProviderSessionId provider_session_id = 4;
  google.protobuf.Timestamp submitted_at = 5;
}

message MarkPersistedChatTurnProviderSubmittedReply {
  PersistedChatTurn turn = 1;
  MutationOutcome outcome = 2;
  repeated ResourceChange events = 3;
}

message MarkSourceIngestedRequest {
  SourceId id = 1;
}

message MarkSourceIngestedReply {
  MutationOutcome outcome = 1;
  repeated ResourceChange events = 2;
}

message MoveBookmarkNodeRequest {
  BookmarkId id = 1;
  optional BookmarkId to_parent_id = 2;
  int64 position = 3;
}

message MoveBookmarkNodeReply {
  MutationOutcome outcome = 1;
  repeated ResourceChange events = 2;
}

message ReapStaleWorkspacesRequest {
  // TODO(step-2-review): Set the conversion rule for fractional legacy seconds.
  google.protobuf.Duration ttl = 1;
}

message ReapStaleWorkspacesReply {
  int64 reaped_count = 1;
  MutationOutcome outcome = 2;
  repeated ResourceChange events = 3;
}

message RecordPageOKFVerificationRequest {
  PageVersionId version_id = 1;
  OKFVerifierIdentity verifier = 2;
  google.protobuf.Timestamp verified_at = 3;
  OKFVerificationBasis basis = 4;
  optional OKFFreshnessPolicy freshness_policy = 5;
}

message RecordPageOKFVerificationReply {
  OKFVerificationId verification_id = 1;
  MutationOutcome outcome = 2;
  repeated ResourceChange events = 3;
}

message RecordSourceMarkdownOKFVerificationRequest {
  PageId version_id = 1;
  OKFVerifierIdentity verifier = 2;
  google.protobuf.Timestamp verified_at = 3;
  OKFVerificationBasis basis = 4;
  optional OKFFreshnessPolicy freshness_policy = 5;
}

message RecordSourceMarkdownOKFVerificationReply {
  OKFVerificationId verification_id = 1;
  MutationOutcome outcome = 2;
  repeated ResourceChange events = 3;
}

message RemoveRendererSourcePresentationRequest {
  SourceId source_id = 1;
}

message RemoveRendererSourcePresentationReply {
  MutationOutcome outcome = 1;
  repeated ResourceChange events = 2;
}

message RenameBookmarkFolderRequest {
  BookmarkId id = 1;
  string to = 2;
}

message RenameBookmarkFolderReply {
  MutationOutcome outcome = 1;
  repeated ResourceChange events = 2;
}

message RenameChatRequest {
  ChatId id = 1;
  string to = 2;
}

message RenameChatReply {
  MutationOutcome outcome = 1;
  repeated ResourceChange events = 2;
}

message RenameSourceRequest {
  SourceId id = 1;
  string to = 2;
}

message RenameSourceReply {
  MutationOutcome outcome = 1;
  repeated ResourceChange events = 2;
}

message RepairMIMERequest {
  bool dry_run = 1;
}

message RepairMIMEReply {
  MIMERepairReport report = 1;
  MutationOutcome outcome = 2;
  repeated ResourceChange events = 3;
}

message ReplaceLinksRequest {
  PageId page_id = 1;
  repeated ParsedLink parsed_links = 2;
}

message ReplaceLinksReply {
  MutationOutcome outcome = 1;
  repeated ResourceChange events = 2;
}

message RestorePageRequest {
  PageId page_id = 1;
  PageVersionId to = 2;
}

message RestorePageReply {
  PageVersionId version_id = 1;
  MutationOutcome outcome = 2;
  repeated ResourceChange events = 3;
}

message RetargetBookmarkNodeRequest {
  BookmarkId id = 1;
  BookmarkContent to = 2;
}

message RetargetBookmarkNodeReply {
  MutationOutcome outcome = 1;
  repeated ResourceChange events = 2;
}

message RevertPageRequest {
  PageId page_id = 1;
  PageVersionId to = 2;
}

message RevertPageReply {
  MutationOutcome outcome = 1;
  repeated ResourceChange events = 2;
}

message SetActiveMarkdownRequest {
  SourceId source_id = 1;
  PageId to = 2;
}

message SetActiveMarkdownReply {
  MutationOutcome outcome = 1;
  repeated ResourceChange events = 2;
}

message SetChatAttachmentsRequest {
  ChatId chat_id = 1;
  repeated ChatAttachmentTarget targets = 2;
}

message SetChatAttachmentsReply {
  MutationOutcome outcome = 1;
  repeated ResourceChange events = 2;
}

message SetChatTitleIfRequest {
  ChatId chat_id = 1;
  string expected_title = 2;
  string title = 3;
}

message SetChatTitleIfReply {
  bool did_write = 1;
  MutationOutcome outcome = 2;
  repeated ResourceChange events = 3;
}

message SetChatTitleIfEmptyRequest {
  ChatId chat_id = 1;
  string title = 2;
}

message SetChatTitleIfEmptyReply {
  bool did_write = 1;
  MutationOutcome outcome = 2;
  repeated ResourceChange events = 3;
}

message SetPageOKFFreshnessRequest {
  PageVersionId version_id = 1;
  optional OKFFreshnessPolicy policy = 2;
}

message SetPageOKFFreshnessReply {
  MutationOutcome outcome = 1;
  repeated ResourceChange events = 2;
}

message SetPageOKFStatusRequest {
  PageVersionId version_id = 1;
  optional OKFConceptStatus status = 2;
}

message SetPageOKFStatusReply {
  MutationOutcome outcome = 1;
  repeated ResourceChange events = 2;
}

message SetRendererSourcePreferenceRequest {
  SourceId source_id = 1;
  RendererPreferenceReference preference = 2;
}

message SetRendererSourcePreferenceReply {
  MutationOutcome outcome = 1;
  repeated ResourceChange events = 2;
}

message SetRendererSourcePresentationRequest {
  SourceId source_id = 1;
  RendererSourcePresentationMode presentation = 2;
}

message SetRendererSourcePresentationReply {
  MutationOutcome outcome = 1;
  repeated ResourceChange events = 2;
}

message SetSourceDisplayNameRequest {
  SourceId id = 1;
  string display_name = 2;
}

message SetSourceDisplayNameReply {
  MutationOutcome outcome = 1;
  repeated ResourceChange events = 2;
}

message SetSourceMarkdownOKFFreshnessRequest {
  PageId version_id = 1;
  optional OKFFreshnessPolicy policy = 2;
}

message SetSourceMarkdownOKFFreshnessReply {
  MutationOutcome outcome = 1;
  repeated ResourceChange events = 2;
}

message SetSourceMarkdownOKFStatusRequest {
  PageId version_id = 1;
  optional OKFConceptStatus status = 2;
}

message SetSourceMarkdownOKFStatusReply {
  MutationOutcome outcome = 1;
  repeated ResourceChange events = 2;
}

message UpdateChatAcpSessionIdRequest {
  ChatId chat_id = 1;
  optional AcpSessionId acp_session_id = 2;
}

message UpdateChatAcpSessionIdReply {
  MutationOutcome outcome = 1;
  repeated ResourceChange events = 2;
}

message UpdateChatModelAndThinkingSelectionRequest {
  ChatId chat_id = 1;
  optional ProviderId provider_id = 2;
  optional ModelId model_id = 3;
  optional ThinkingOptionId configured_thinking_id = 4;
  optional ThinkingOptionId effective_thinking_id = 5;
}

message UpdateChatModelAndThinkingSelectionReply {
  MutationOutcome outcome = 1;
  repeated ResourceChange events = 2;
}

message UpdateChatModelOverrideRequest {
  ChatId id = 1;
  optional ProviderId provider_id = 2;
  optional ModelId model_id = 3;
}

message UpdateChatModelOverrideReply {
  MutationOutcome outcome = 1;
  repeated ResourceChange events = 2;
}

message UpdateMessageSummaryRequest {
  ChatId chat_id = 1;
  ChatTranscriptCursor cursor = 2;
  string summary = 3;
  ChatMessageSummaryKind kind = 4;
}

message UpdateMessageSummaryReply {
  MutationOutcome outcome = 1;
  repeated ResourceChange events = 2;
}

message UpdatePersistedChatTurnUsageRequest {
  ChatId chat_id = 1;
  ChatTurnId turn_id = 2;
  ChatClaimId claim_id = 3;
  ChatTurnUsageValues usage = 4;
}

message UpdatePersistedChatTurnUsageReply {
  PersistedChatTurn turn = 1;
  MutationOutcome outcome = 2;
  repeated ResourceChange events = 3;
}

message WorkspaceMergeRequest {
  WorkspaceId workspace_id = 1;
}

message WorkspaceMergeReply {
  repeated PageId merged_page_ids = 1;
  MutationOutcome outcome = 2;
  repeated ResourceChange events = 3;
}

message WorkspaceRefreshRequest {
  WorkspaceId workspace_id = 1;
}

message WorkspaceRefreshReply {
  MutationOutcome outcome = 1;
  repeated ResourceChange events = 2;
}

message WorkspaceResolveConflictRequest {
  WorkspaceId workspace_id = 1;
  PageId page_id = 2;
  // TODO(step-2-review): Confirm the inline bound. The legacy DTO has no handle.
  string body = 3;
}

message WorkspaceResolveConflictReply {
  MutationOutcome outcome = 1;
  repeated ResourceChange events = 2;
}

message WorkspaceRetryMergeRequest {
  WorkspaceId workspace_id = 1;
}

message WorkspaceRetryMergeReply {
  MutationOutcome outcome = 1;
  repeated ResourceChange events = 2;
}

// Part 3: StoreMutation request and reply arms.
// ARM LEDGER (StoreMutation): arm 1 = abandonWorkspace → AbandonWorkspaceRequest/AbandonWorkspaceReply
// ARM LEDGER (StoreMutation): arm 2 = addBytelessSource → AddBytelessSourceRequest/AddBytelessSourceReply
// ARM LEDGER (StoreMutation): arm 3 = appendLog → AppendLogRequest/AppendLogReply
// ARM LEDGER (StoreMutation): arm 4 = cancelUnclaimedPersistedChatTurn → CancelUnclaimedPersistedChatTurnRequest/CancelUnclaimedPersistedChatTurnReply
// ARM LEDGER (StoreMutation): arm 5 = correctPageOKFVerification → CorrectPageOKFVerificationRequest/CorrectPageOKFVerificationReply
// ARM LEDGER (StoreMutation): arm 6 = correctSourceMarkdownOKFVerification → CorrectSourceMarkdownOKFVerificationRequest/CorrectSourceMarkdownOKFVerificationReply
// ARM LEDGER (StoreMutation): arm 7 = createBookmarkNode → CreateBookmarkNodeRequest/CreateBookmarkNodeReply
// ARM LEDGER (StoreMutation): arm 8 = createChat → CreateChatRequest/CreateChatReply
// ARM LEDGER (StoreMutation): arm 9 = createWorkspace → CreateWorkspaceRequest/CreateWorkspaceReply
// ARM LEDGER (StoreMutation): arm 10 = deleteBookmarkNode → DeleteBookmarkNodeRequest/DeleteBookmarkNodeReply
// ARM LEDGER (StoreMutation): arm 11 = deleteChat → DeleteChatRequest/DeleteChatReply
// ARM LEDGER (StoreMutation): arm 12 = deleteResources → DeleteResourcesRequest/DeleteResourcesReply
// ARM LEDGER (StoreMutation): arm 13 = ensureFetchActivity → EnsureFetchActivityRequest/EnsureFetchActivityReply
// ARM LEDGER (StoreMutation): arm 14 = finalizeStaleDrafts → FinalizeStaleDraftsRequest/FinalizeStaleDraftsReply
// ARM LEDGER (StoreMutation): arm 15 = markFetchComplete → MarkFetchCompleteRequest/MarkFetchCompleteReply
// ARM LEDGER (StoreMutation): arm 16 = markPersistedChatTurnProviderSubmitted → MarkPersistedChatTurnProviderSubmittedRequest/MarkPersistedChatTurnProviderSubmittedReply
// ARM LEDGER (StoreMutation): arm 17 = markSourceIngested → MarkSourceIngestedRequest/MarkSourceIngestedReply
// ARM LEDGER (StoreMutation): arm 18 = moveBookmarkNode → MoveBookmarkNodeRequest/MoveBookmarkNodeReply
// ARM LEDGER (StoreMutation): arm 19 = reapStaleWorkspaces → ReapStaleWorkspacesRequest/ReapStaleWorkspacesReply
// ARM LEDGER (StoreMutation): arm 20 = recordPageOKFVerification → RecordPageOKFVerificationRequest/RecordPageOKFVerificationReply
// ARM LEDGER (StoreMutation): arm 21 = recordSourceMarkdownOKFVerification → RecordSourceMarkdownOKFVerificationRequest/RecordSourceMarkdownOKFVerificationReply
// ARM LEDGER (StoreMutation): arm 22 = removeRendererSourcePresentation → RemoveRendererSourcePresentationRequest/RemoveRendererSourcePresentationReply
// ARM LEDGER (StoreMutation): arm 23 = renameBookmarkFolder → RenameBookmarkFolderRequest/RenameBookmarkFolderReply
// ARM LEDGER (StoreMutation): arm 24 = renameChat → RenameChatRequest/RenameChatReply
// ARM LEDGER (StoreMutation): arm 25 = renameSource → RenameSourceRequest/RenameSourceReply
// ARM LEDGER (StoreMutation): arm 26 = repairMIME → RepairMIMERequest/RepairMIMEReply
// ARM LEDGER (StoreMutation): arm 27 = replaceLinks → ReplaceLinksRequest/ReplaceLinksReply
// ARM LEDGER (StoreMutation): arm 28 = restorePage → RestorePageRequest/RestorePageReply
// ARM LEDGER (StoreMutation): arm 29 = retargetBookmarkNode → RetargetBookmarkNodeRequest/RetargetBookmarkNodeReply
// ARM LEDGER (StoreMutation): arm 30 = revertPage → RevertPageRequest/RevertPageReply
// ARM LEDGER (StoreMutation): arm 31 = setActiveMarkdown → SetActiveMarkdownRequest/SetActiveMarkdownReply
// ARM LEDGER (StoreMutation): arm 32 = setChatAttachments → SetChatAttachmentsRequest/SetChatAttachmentsReply
// ARM LEDGER (StoreMutation): arm 33 = setChatTitleIf → SetChatTitleIfRequest/SetChatTitleIfReply
// ARM LEDGER (StoreMutation): arm 34 = setChatTitleIfEmpty → SetChatTitleIfEmptyRequest/SetChatTitleIfEmptyReply
// ARM LEDGER (StoreMutation): arm 35 = setPageOKFFreshness → SetPageOKFFreshnessRequest/SetPageOKFFreshnessReply
// ARM LEDGER (StoreMutation): arm 36 = setPageOKFStatus → SetPageOKFStatusRequest/SetPageOKFStatusReply
// ARM LEDGER (StoreMutation): arm 37 = setRendererSourcePreference → SetRendererSourcePreferenceRequest/SetRendererSourcePreferenceReply
// ARM LEDGER (StoreMutation): arm 38 = setRendererSourcePresentation → SetRendererSourcePresentationRequest/SetRendererSourcePresentationReply
// ARM LEDGER (StoreMutation): arm 39 = setSourceDisplayName → SetSourceDisplayNameRequest/SetSourceDisplayNameReply
// ARM LEDGER (StoreMutation): arm 40 = setSourceMarkdownOKFFreshness → SetSourceMarkdownOKFFreshnessRequest/SetSourceMarkdownOKFFreshnessReply
// ARM LEDGER (StoreMutation): arm 41 = setSourceMarkdownOKFStatus → SetSourceMarkdownOKFStatusRequest/SetSourceMarkdownOKFStatusReply
// ARM LEDGER (StoreMutation): arm 42 = updateChatAcpSessionId → UpdateChatAcpSessionIdRequest/UpdateChatAcpSessionIdReply
// ARM LEDGER (StoreMutation): arm 43 = updateChatModelAndThinkingSelection → UpdateChatModelAndThinkingSelectionRequest/UpdateChatModelAndThinkingSelectionReply
// ARM LEDGER (StoreMutation): arm 44 = updateChatModelOverride → UpdateChatModelOverrideRequest/UpdateChatModelOverrideReply
// ARM LEDGER (StoreMutation): arm 45 = updateMessageSummary → UpdateMessageSummaryRequest/UpdateMessageSummaryReply
// ARM LEDGER (StoreMutation): arm 46 = updatePersistedChatTurnUsage → UpdatePersistedChatTurnUsageRequest/UpdatePersistedChatTurnUsageReply
// ARM LEDGER (StoreMutation): arm 47 = workspaceMerge → WorkspaceMergeRequest/WorkspaceMergeReply
// ARM LEDGER (StoreMutation): arm 48 = workspaceRefresh → WorkspaceRefreshRequest/WorkspaceRefreshReply
// ARM LEDGER (StoreMutation): arm 49 = workspaceResolveConflict → WorkspaceResolveConflictRequest/WorkspaceResolveConflictReply
// ARM LEDGER (StoreMutation): arm 50 = workspaceRetryMerge → WorkspaceRetryMergeRequest/WorkspaceRetryMergeReply

message StoreMutationRequest {
  WikiId wiki_id = 51;
  MutationStamp stamp = 52;
  oneof operation {
    AbandonWorkspaceRequest abandon_workspace = 1;
    AddBytelessSourceRequest add_byteless_source = 2;
    AppendLogRequest append_log = 3;
    CancelUnclaimedPersistedChatTurnRequest cancel_unclaimed_persisted_chat_turn = 4;
    CorrectPageOKFVerificationRequest correct_page_okf_verification = 5;
    CorrectSourceMarkdownOKFVerificationRequest correct_source_markdown_okf_verification = 6;
    CreateBookmarkNodeRequest create_bookmark_node = 7;
    CreateChatRequest create_chat = 8;
    CreateWorkspaceRequest create_workspace = 9;
    DeleteBookmarkNodeRequest delete_bookmark_node = 10;
    DeleteChatRequest delete_chat = 11;
    DeleteResourcesRequest delete_resources = 12;
    EnsureFetchActivityRequest ensure_fetch_activity = 13;
    FinalizeStaleDraftsRequest finalize_stale_drafts = 14;
    MarkFetchCompleteRequest mark_fetch_complete = 15;
    MarkPersistedChatTurnProviderSubmittedRequest mark_persisted_chat_turn_provider_submitted = 16;
    MarkSourceIngestedRequest mark_source_ingested = 17;
    MoveBookmarkNodeRequest move_bookmark_node = 18;
    ReapStaleWorkspacesRequest reap_stale_workspaces = 19;
    RecordPageOKFVerificationRequest record_page_okf_verification = 20;
    RecordSourceMarkdownOKFVerificationRequest record_source_markdown_okf_verification = 21;
    RemoveRendererSourcePresentationRequest remove_renderer_source_presentation = 22;
    RenameBookmarkFolderRequest rename_bookmark_folder = 23;
    RenameChatRequest rename_chat = 24;
    RenameSourceRequest rename_source = 25;
    RepairMIMERequest repair_mime = 26;
    ReplaceLinksRequest replace_links = 27;
    RestorePageRequest restore_page = 28;
    RetargetBookmarkNodeRequest retarget_bookmark_node = 29;
    RevertPageRequest revert_page = 30;
    SetActiveMarkdownRequest set_active_markdown = 31;
    SetChatAttachmentsRequest set_chat_attachments = 32;
    SetChatTitleIfRequest set_chat_title_if = 33;
    SetChatTitleIfEmptyRequest set_chat_title_if_empty = 34;
    SetPageOKFFreshnessRequest set_page_okf_freshness = 35;
    SetPageOKFStatusRequest set_page_okf_status = 36;
    SetRendererSourcePreferenceRequest set_renderer_source_preference = 37;
    SetRendererSourcePresentationRequest set_renderer_source_presentation = 38;
    SetSourceDisplayNameRequest set_source_display_name = 39;
    SetSourceMarkdownOKFFreshnessRequest set_source_markdown_okf_freshness = 40;
    SetSourceMarkdownOKFStatusRequest set_source_markdown_okf_status = 41;
    UpdateChatAcpSessionIdRequest update_chat_acp_session_id = 42;
    UpdateChatModelAndThinkingSelectionRequest update_chat_model_and_thinking_selection = 43;
    UpdateChatModelOverrideRequest update_chat_model_override = 44;
    UpdateMessageSummaryRequest update_message_summary = 45;
    UpdatePersistedChatTurnUsageRequest update_persisted_chat_turn_usage = 46;
    WorkspaceMergeRequest workspace_merge = 47;
    WorkspaceRefreshRequest workspace_refresh = 48;
    WorkspaceResolveConflictRequest workspace_resolve_conflict = 49;
    WorkspaceRetryMergeRequest workspace_retry_merge = 50;
  }
}

message StoreMutationReply {
  oneof operation {
    AbandonWorkspaceReply abandon_workspace = 1;
    AddBytelessSourceReply add_byteless_source = 2;
    AppendLogReply append_log = 3;
    CancelUnclaimedPersistedChatTurnReply cancel_unclaimed_persisted_chat_turn = 4;
    CorrectPageOKFVerificationReply correct_page_okf_verification = 5;
    CorrectSourceMarkdownOKFVerificationReply correct_source_markdown_okf_verification = 6;
    CreateBookmarkNodeReply create_bookmark_node = 7;
    CreateChatReply create_chat = 8;
    CreateWorkspaceReply create_workspace = 9;
    DeleteBookmarkNodeReply delete_bookmark_node = 10;
    DeleteChatReply delete_chat = 11;
    DeleteResourcesReply delete_resources = 12;
    EnsureFetchActivityReply ensure_fetch_activity = 13;
    FinalizeStaleDraftsReply finalize_stale_drafts = 14;
    MarkFetchCompleteReply mark_fetch_complete = 15;
    MarkPersistedChatTurnProviderSubmittedReply mark_persisted_chat_turn_provider_submitted = 16;
    MarkSourceIngestedReply mark_source_ingested = 17;
    MoveBookmarkNodeReply move_bookmark_node = 18;
    ReapStaleWorkspacesReply reap_stale_workspaces = 19;
    RecordPageOKFVerificationReply record_page_okf_verification = 20;
    RecordSourceMarkdownOKFVerificationReply record_source_markdown_okf_verification = 21;
    RemoveRendererSourcePresentationReply remove_renderer_source_presentation = 22;
    RenameBookmarkFolderReply rename_bookmark_folder = 23;
    RenameChatReply rename_chat = 24;
    RenameSourceReply rename_source = 25;
    RepairMIMEReply repair_mime = 26;
    ReplaceLinksReply replace_links = 27;
    RestorePageReply restore_page = 28;
    RetargetBookmarkNodeReply retarget_bookmark_node = 29;
    RevertPageReply revert_page = 30;
    SetActiveMarkdownReply set_active_markdown = 31;
    SetChatAttachmentsReply set_chat_attachments = 32;
    SetChatTitleIfReply set_chat_title_if = 33;
    SetChatTitleIfEmptyReply set_chat_title_if_empty = 34;
    SetPageOKFFreshnessReply set_page_okf_freshness = 35;
    SetPageOKFStatusReply set_page_okf_status = 36;
    SetRendererSourcePreferenceReply set_renderer_source_preference = 37;
    SetRendererSourcePresentationReply set_renderer_source_presentation = 38;
    SetSourceDisplayNameReply set_source_display_name = 39;
    SetSourceMarkdownOKFFreshnessReply set_source_markdown_okf_freshness = 40;
    SetSourceMarkdownOKFStatusReply set_source_markdown_okf_status = 41;
    UpdateChatAcpSessionIdReply update_chat_acp_session_id = 42;
    UpdateChatModelAndThinkingSelectionReply update_chat_model_and_thinking_selection = 43;
    UpdateChatModelOverrideReply update_chat_model_override = 44;
    UpdateMessageSummaryReply update_message_summary = 45;
    UpdatePersistedChatTurnUsageReply update_persisted_chat_turn_usage = 46;
    WorkspaceMergeReply workspace_merge = 47;
    WorkspaceRefreshReply workspace_refresh = 48;
    WorkspaceResolveConflictReply workspace_resolve_conflict = 49;
    WorkspaceRetryMergeReply workspace_retry_merge = 50;
  }
}
