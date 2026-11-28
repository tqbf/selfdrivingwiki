// Part 1: Operation messages.
// wiki scope carried by envelope
// Target 1 MiB per encoded list page. A next_page_token is session-bound,
// not an event position. An absent token means there is no next page.
// Row and payload types not defined here are shared by the assembled schema.

message ChatMessagesRequest {
  ChatId chat_id = 1;
}

message ChatMessagesReply {
  // NOTE(step-2-review): consider continuation token for the full message history.
  // Rows follow chat sequence order.
  repeated ChatMessage messages = 1;
  optional string next_page_token = 2;
}

message DeletionImpactRequest {
  // Page targets precede source targets. Each kind follows ascending ULID order.
  repeated ResourceDeletionTarget targets = 1;
}

message DeletionImpactReply {
  // NOTE(step-2-review): consider continuation token for the nested impact rows.
  // TODO(step-2-review): Define how pages split the collections while retaining the total count.
  DeletionImpact impact = 1;
  optional string next_page_token = 2;
}

message SourceEmbedEntry {
  SourceId source_id = 1;
  SourceEmbedDescriptor descriptor = 2;
}

message EmbedDescriptorsRequest {}

message EmbedDescriptorsReply {
  // NOTE(step-2-review): consider continuation token for the full descriptor set.
  // Entries follow ascending source ID order.
  repeated SourceEmbedEntry entries = 1;
  optional string next_page_token = 2;
}

message ListAllChatsOrderedByIDRequest {}

message ListAllChatsOrderedByIDReply {
  // NOTE(step-2-review): consider continuation token for the full chat list.
  // Rows follow ascending chat ID order.
  repeated ChatSummary chats = 1;
  optional string next_page_token = 2;
}

message ListBookmarkNodesRequest {}

message ListBookmarkNodesReply {
  // NOTE(step-2-review): consider continuation token for the full bookmark tree.
  // Parents precede children. Siblings follow position order.
  repeated BookmarkNode nodes = 1;
  optional string next_page_token = 2;
}

message ListChatsRequest {}

message ListChatsReply {
  // NOTE(step-2-review): consider continuation token for the full chat list.
  // Rows follow most-recently-updated-first order.
  repeated ChatSummary chats = 1;
  optional string next_page_token = 2;
}

message ListPersistedChatTurnsRequest {
  ChatId chat_id = 1;
}

message ListPersistedChatTurnsReply {
  // NOTE(step-2-review): consider continuation token for the full turn history.
  // Rows follow turn ordinal order.
  repeated PersistedChatTurn turns = 1;
  optional string next_page_token = 2;
}

message ListSourcesRequest {}

message ListSourcesReply {
  // NOTE(step-2-review): consider continuation token for the full source list.
  // Rows follow most-recent-first order and omit source bytes.
  repeated SourceSummary sources = 1;
  optional string next_page_token = 2;
}

message MarkedSourceIDsRequest {}

message MarkedSourceIDsReply {
  // NOTE(step-2-review): consider continuation token for the full marked-source set.
  repeated SourceId source_ids = 1; // Ascending source ID order.
  optional string next_page_token = 2;
}

message PageEditHistoryRequest {
  PageId page_id = 1;
}

message PageEditHistoryReply {
  // NOTE(step-2-review): consider continuation token for the full edit history.
  repeated PageOrigin entries = 1; // Oldest first. The final row of the full history is HEAD.
  optional string next_page_token = 2;
}

message PagesCitingSourcesRequest {
  repeated SourceId source_ids = 1;
  int64 limit = 2; // A nonpositive limit returns no pages.
}

message PagesCitingSourcesReply {
  // Distinct pages sorted by case-insensitive title, then page ID. Absent titles come last.
  // A full page does not give the total count.
  repeated CitedPage pages = 1;
  optional string next_page_token = 2;
}

message PageVersionHistoryRequest {
  PageId page_id = 1;
}

message PageVersionHistoryReply {
  // NOTE(step-2-review): consider continuation token for the full version history.
  repeated PageVersionSummary versions = 1; // Ascending version ULID order.
  optional string next_page_token = 2;
}

message MarkdownAgentNameEntry {
  PageId version_id = 1; // Source Markdown-version ID in its current PageId representation.
  string agent_name = 2;
}

message ProcessedMarkdownAgentNamesRequest {
  SourceId source_id = 1;
}

message ProcessedMarkdownAgentNamesReply {
  // NOTE(step-2-review): consider continuation token for the full version set.
  repeated MarkdownAgentNameEntry entries = 1; // Ascending version ID order.
  optional string next_page_token = 2;
}

// The bytes behind a processed Markdown contents handle encode this message.
message ProcessedMarkdownContents {
  message Entry {
    PageId version_id = 1; // Source Markdown-version ID.
    string content = 2;
  }
  repeated Entry entries = 1; // Ascending version ID order.
}

message ProcessedMarkdownAlternativesRequest {
  SourceId source_id = 1;
}

message ProcessedMarkdownAlternativesReply {
  // NOTE(step-2-review): consider continuation token for the full alternatives list.
  repeated ExtractionAlternative alternatives = 1; // Newest first.
  // TODO(step-2-review): Confirm whether the handle covers this page or all pages.
  PayloadHandle contents = 2; // Encoded ProcessedMarkdownContents.
  int64 content_byte_count = 3;
  optional string next_page_token = 4;
}

message ProcessedMarkdownHistoryRequest {
  SourceId source_id = 1;
}

message ProcessedMarkdownHistoryReply {
  // NOTE(step-2-review): consider continuation token for the full Markdown history.
  repeated SourceMarkdownVersionHeader versions = 1; // Newest first.
  // TODO(step-2-review): Confirm whether the handle covers this page or all pages.
  PayloadHandle contents = 2; // Encoded ProcessedMarkdownContents.
  int64 content_byte_count = 3;
  optional string next_page_token = 4;
}

message ReadChatTranscriptPageRequest {
  ChatId chat_id = 1;
  // The query cursor is separate from the byte-budget token in the envelope.
  optional ChatTranscriptCursor after = 2;
  int64 limit = 3;
}

message ReadChatTranscriptPageReply {
  // The typed transcript page retains its ordered items, checkpoint, and next cursor.
  // TODO(step-2-review): Confirm how byte-budget pages interact with the transcript next cursor.
  ChatTranscriptPage page = 1;
  optional string next_page_token = 2;
}

message RecentLogEntriesRequest {
  int64 limit = 1;
}

message RecentLogEntriesReply {
  repeated LogEntry entries = 1; // Oldest first within the selected tail.
  optional string next_page_token = 2;
}

message SiblingImageResolver {
  string original_path = 1;
  SourceId source_id = 2;
}

message SiblingImageResolverEntry {
  SourceId source_id = 1;
  // Preserve the first match for each path and its source ULID order.
  repeated SiblingImageResolver resolvers = 2;
}

message SiblingImageResolversRequest {}

message SiblingImageResolversReply {
  // NOTE(step-2-review): consider continuation token for the full resolver set.
  repeated SiblingImageResolverEntry entries = 1; // Ascending source ID order.
  optional string next_page_token = 2;
}

message SourceDerivedChainEntry {
  SourceId source_id = 1;
  repeated PageId chain = 2; // Source Markdown-version IDs in ascending ULID order, starting with v1.
}

message SourceDerivedChainsRequest {}

message SourceDerivedChainsReply {
  // NOTE(step-2-review): consider continuation token for the full chain set.
  repeated SourceDerivedChainEntry entries = 1; // Ascending source ID order.
  optional string next_page_token = 2;
}

message SourceEditHistoryRequest {
  SourceId source_id = 1;
}

message SourceEditHistoryReply {
  // NOTE(step-2-review): consider continuation token for the full source history.
  repeated SourceOrigin origins = 1; // Newest first.
  optional string next_page_token = 2;
}

message SourceOriginEntry {
  SourceId source_id = 1;
  SourceOrigin origin = 2;
}

message SourceOriginsBySourceRequest {}

message SourceOriginsBySourceReply {
  // NOTE(step-2-review): consider continuation token for the full source origin set.
  repeated SourceOriginEntry entries = 1; // Ascending source ID order.
  optional string next_page_token = 2;
}

message SourcesWithPendingFormatJobsRequest {}

message SourcesWithPendingFormatJobsReply {
  // NOTE(step-2-review): consider continuation token for the full recovery scan.
  repeated SourceId source_ids = 1; // Preserve store order.
  optional string next_page_token = 2;
}

message WorkspaceConflictsRequest {
  WorkspaceId workspace_id = 1;
}

message WorkspaceConflictsReply {
  // NOTE(step-2-review): consider continuation token for the full conflict list.
  repeated WorkspaceConflict conflicts = 1;
  optional string next_page_token = 2;
}

message WorkspaceRefsRequest {
  WorkspaceId workspace_id = 1;
}

message WorkspaceRefsReply {
  // NOTE(step-2-review): consider continuation token for the full workspace write set.
  repeated WorkspaceRef refs = 1;
  optional string next_page_token = 2;
}

// Part 2: Envelope arms.
// ARM LEDGER (StoreList): arm 1 = chatMessages → ChatMessagesRequest/ChatMessagesReply
// ARM LEDGER (StoreList): arm 2 = deletionImpact → DeletionImpactRequest/DeletionImpactReply
// ARM LEDGER (StoreList): arm 3 = embedDescriptors → EmbedDescriptorsRequest/EmbedDescriptorsReply
// ARM LEDGER (StoreList): arm 4 = listAllChatsOrderedByID → ListAllChatsOrderedByIDRequest/ListAllChatsOrderedByIDReply
// ARM LEDGER (StoreList): arm 5 = listBookmarkNodes → ListBookmarkNodesRequest/ListBookmarkNodesReply
// ARM LEDGER (StoreList): arm 6 = listChats → ListChatsRequest/ListChatsReply
// listPages: dedicated ListPages RPC (excluded from this envelope)
// ARM LEDGER (StoreList): arm 7 = listPersistedChatTurns → ListPersistedChatTurnsRequest/ListPersistedChatTurnsReply
// ARM LEDGER (StoreList): arm 8 = listSources → ListSourcesRequest/ListSourcesReply
// ARM LEDGER (StoreList): arm 9 = markedSourceIDs → MarkedSourceIDsRequest/MarkedSourceIDsReply
// ARM LEDGER (StoreList): arm 10 = pageEditHistory → PageEditHistoryRequest/PageEditHistoryReply
// ARM LEDGER (StoreList): arm 11 = pagesCitingSources → PagesCitingSourcesRequest/PagesCitingSourcesReply
// ARM LEDGER (StoreList): arm 12 = pageVersionHistory → PageVersionHistoryRequest/PageVersionHistoryReply
// ARM LEDGER (StoreList): arm 13 = processedMarkdownAgentNames → ProcessedMarkdownAgentNamesRequest/ProcessedMarkdownAgentNamesReply
// ARM LEDGER (StoreList): arm 14 = processedMarkdownAlternatives → ProcessedMarkdownAlternativesRequest/ProcessedMarkdownAlternativesReply
// ARM LEDGER (StoreList): arm 15 = processedMarkdownHistory → ProcessedMarkdownHistoryRequest/ProcessedMarkdownHistoryReply
// ARM LEDGER (StoreList): arm 16 = readChatTranscriptPage → ReadChatTranscriptPageRequest/ReadChatTranscriptPageReply
// ARM LEDGER (StoreList): arm 17 = recentLogEntries → RecentLogEntriesRequest/RecentLogEntriesReply
// ARM LEDGER (StoreList): arm 18 = siblingImageResolvers → SiblingImageResolversRequest/SiblingImageResolversReply
// ARM LEDGER (StoreList): arm 19 = sourceDerivedChains → SourceDerivedChainsRequest/SourceDerivedChainsReply
// ARM LEDGER (StoreList): arm 20 = sourceEditHistory → SourceEditHistoryRequest/SourceEditHistoryReply
// ARM LEDGER (StoreList): arm 21 = sourceOriginsBySource → SourceOriginsBySourceRequest/SourceOriginsBySourceReply
// ARM LEDGER (StoreList): arm 22 = sourcesWithPendingFormatJobs → SourcesWithPendingFormatJobsRequest/SourcesWithPendingFormatJobsReply
// ARM LEDGER (StoreList): arm 23 = workspaceConflicts → WorkspaceConflictsRequest/WorkspaceConflictsReply
// ARM LEDGER (StoreList): arm 24 = workspaceRefs → WorkspaceRefsRequest/WorkspaceRefsReply

message StoreListRequest {
  oneof operation {
    ChatMessagesRequest chat_messages = 1;
    DeletionImpactRequest deletion_impact = 2;
    EmbedDescriptorsRequest embed_descriptors = 3;
    ListAllChatsOrderedByIDRequest list_all_chats_ordered_by_id = 4;
    ListBookmarkNodesRequest list_bookmark_nodes = 5;
    ListChatsRequest list_chats = 6;
    ListPersistedChatTurnsRequest list_persisted_chat_turns = 7;
    ListSourcesRequest list_sources = 8;
    MarkedSourceIDsRequest marked_source_ids = 9;
    PageEditHistoryRequest page_edit_history = 10;
    PagesCitingSourcesRequest pages_citing_sources = 11;
    PageVersionHistoryRequest page_version_history = 12;
    ProcessedMarkdownAgentNamesRequest processed_markdown_agent_names = 13;
    ProcessedMarkdownAlternativesRequest processed_markdown_alternatives = 14;
    ProcessedMarkdownHistoryRequest processed_markdown_history = 15;
    ReadChatTranscriptPageRequest read_chat_transcript_page = 16;
    RecentLogEntriesRequest recent_log_entries = 17;
    SiblingImageResolversRequest sibling_image_resolvers = 18;
    SourceDerivedChainsRequest source_derived_chains = 19;
    SourceEditHistoryRequest source_edit_history = 20;
    SourceOriginsBySourceRequest source_origins_by_source = 21;
    SourcesWithPendingFormatJobsRequest sources_with_pending_format_jobs = 22;
    WorkspaceConflictsRequest workspace_conflicts = 23;
    WorkspaceRefsRequest workspace_refs = 24;
  }
  WikiId wiki_id = 25;
  // On continuation, pass the previous reply's token with the same operation and query.
  optional string page_token = 26;
}

message StoreListReply {
  oneof operation {
    ChatMessagesReply chat_messages = 1;
    DeletionImpactReply deletion_impact = 2;
    EmbedDescriptorsReply embed_descriptors = 3;
    ListAllChatsOrderedByIDReply list_all_chats_ordered_by_id = 4;
    ListBookmarkNodesReply list_bookmark_nodes = 5;
    ListChatsReply list_chats = 6;
    ListPersistedChatTurnsReply list_persisted_chat_turns = 7;
    ListSourcesReply list_sources = 8;
    MarkedSourceIDsReply marked_source_ids = 9;
    PageEditHistoryReply page_edit_history = 10;
    PagesCitingSourcesReply pages_citing_sources = 11;
    PageVersionHistoryReply page_version_history = 12;
    ProcessedMarkdownAgentNamesReply processed_markdown_agent_names = 13;
    ProcessedMarkdownAlternativesReply processed_markdown_alternatives = 14;
    ProcessedMarkdownHistoryReply processed_markdown_history = 15;
    ReadChatTranscriptPageReply read_chat_transcript_page = 16;
    RecentLogEntriesReply recent_log_entries = 17;
    SiblingImageResolversReply sibling_image_resolvers = 18;
    SourceDerivedChainsReply source_derived_chains = 19;
    SourceEditHistoryReply source_edit_history = 20;
    SourceOriginsBySourceReply source_origins_by_source = 21;
    SourcesWithPendingFormatJobsReply sources_with_pending_format_jobs = 22;
    WorkspaceConflictsReply workspace_conflicts = 23;
    WorkspaceRefsReply workspace_refs = 24;
  }
  WikiId wiki_id = 25;
}
