#if os(macOS)
import Foundation

// List-family per-operation DTOs for the store family (Phase 2a slice 2,
// tmp/store-ops-manifest.md list partition — 25 operations): every reply
// embeds a ``DaemonReplyCursor`` so the executor can bound the ACCUMULATED
// ENCODED BYTES per page (``DaemonStoreLimits/listReplyBudgetEncodedBytes``).
// Core `Dictionary` values cross as entry arrays sorted by key so the wire
// form is deterministic; core `Set` values cross as sorted arrays. Requests
// carry only op-specific args (wiki id + mutation stamp ride the envelope);
// list operations are reads and never stamp.

/// Entry pairs and keyed-map items shared by the list replies.

/// `embedDescriptors` entry: one byteless source and its embed descriptor.
public struct DaemonSourceEmbedEntry: Codable, Equatable, Sendable {
    public let sourceID: String
    public let descriptor: DaemonSourceEmbedDescriptor

    public init(sourceID: String, descriptor: DaemonSourceEmbedDescriptor) {
        self.sourceID = sourceID
        self.descriptor = descriptor
    }
}

/// `processedMarkdownAgentNames` entry: one markdown version and its
/// producing agent's name.
public struct DaemonMarkdownAgentNameEntry: Codable, Equatable, Sendable {
    public let versionID: String
    public let agentName: String

    public init(versionID: String, agentName: String) {
        self.versionID = versionID
        self.agentName = agentName
    }
}

/// `siblingImageResolvers` entry: one source's `original_path → sibling
/// source id` mapping, first-wins per path in ULID order (order preserved).
public struct DaemonSiblingImageResolver: Codable, Equatable, Sendable {
    public let originalPath: String
    public let sourceID: String

    public init(originalPath: String, sourceID: String) {
        self.originalPath = originalPath
        self.sourceID = sourceID
    }
}

public struct DaemonSiblingImageResolverEntry: Codable, Equatable, Sendable {
    public let sourceID: String
    public let resolvers: [DaemonSiblingImageResolver]

    public init(sourceID: String, resolvers: [DaemonSiblingImageResolver]) {
        self.sourceID = sourceID
        self.resolvers = resolvers
    }
}

/// `sourceDerivedChains` entry: one source's derived-markdown chain as
/// ULID-ascending version ids (index 0 = v1).
public struct DaemonSourceDerivedChainEntry: Codable, Equatable, Sendable {
    public let sourceID: String
    public let chain: [String]

    public init(sourceID: String, chain: [String]) {
        self.sourceID = sourceID
        self.chain = chain
    }
}

/// `sourceOriginsBySource` entry: one source and its origin provenance.
public struct DaemonSourceOriginEntry: Codable, Equatable, Sendable {
    public let sourceID: String
    public let origin: DaemonSourceOrigin

    public init(sourceID: String, origin: DaemonSourceOrigin) {
        self.sourceID = sourceID
        self.origin = origin
    }
}

// MARK: - Ops

/// `chatMessages`: a chat's messages in `seq` order (tolerant read:
/// undecodable rows are skipped store-side).
public struct DaemonChatMessagesRequest: Codable, Equatable, Sendable {
    public let chatID: String
    public init(chatID: String) { self.chatID = chatID }
}

public struct DaemonChatMessagesReply: Codable, Equatable, Sendable {
    public let messages: [DaemonChatMessage]
    public let cursor: DaemonReplyCursor
    public init(messages: [DaemonChatMessage], cursor: DaemonReplyCursor) {
        self.messages = messages
        self.cursor = cursor
    }
}

/// `deletionImpact`: what references the targets (read-only; emits nothing).
/// Targets cross in the canonical deterministic order (pages before sources,
/// raw ULID ascending within each kind).
public struct DaemonDeletionImpactRequest: Codable, Equatable, Sendable {
    public let targets: [DaemonResourceDeletionTarget]
    public init(targets: [DaemonResourceDeletionTarget]) {
        self.targets = targets
    }
}

public struct DaemonDeletionImpactReply: Codable, Equatable, Sendable {
    public let impact: DaemonDeletionImpact
    public let cursor: DaemonReplyCursor
    public init(impact: DaemonDeletionImpact, cursor: DaemonReplyCursor) {
        self.impact = impact
        self.cursor = cursor
    }
}

/// `embedDescriptors`: every byteless source's embed descriptor, entries
/// sorted by source id (the core value is a dictionary).
public struct DaemonEmbedDescriptorsRequest: Codable, Equatable, Sendable {
    public init() {}
}

public struct DaemonEmbedDescriptorsReply: Codable, Equatable, Sendable {
    public let entries: [DaemonSourceEmbedEntry]
    public let cursor: DaemonReplyCursor
    public init(entries: [DaemonSourceEmbedEntry], cursor: DaemonReplyCursor) {
        self.entries = entries
        self.cursor = cursor
    }
}

/// `listAllChatsOrderedByID`: all chat summaries in ULID (creation) order —
/// the File Provider projection read.
public struct DaemonListAllChatsOrderedByIDRequest: Codable, Equatable,
    Sendable {
    public init() {}
}

public struct DaemonListAllChatsOrderedByIDReply: Codable, Equatable,
    Sendable {
    public let chats: [DaemonChatSummary]
    public let cursor: DaemonReplyCursor
    public init(chats: [DaemonChatSummary], cursor: DaemonReplyCursor) {
        self.chats = chats
        self.cursor = cursor
    }
}

/// `listBookmarkNodes`: all nodes flat, parents before children, siblings by
/// position.
public struct DaemonListBookmarkNodesRequest: Codable, Equatable, Sendable {
    public init() {}
}

public struct DaemonListBookmarkNodesReply: Codable, Equatable, Sendable {
    public let nodes: [DaemonBookmarkNode]
    public let cursor: DaemonReplyCursor
    public init(nodes: [DaemonBookmarkNode], cursor: DaemonReplyCursor) {
        self.nodes = nodes
        self.cursor = cursor
    }
}

/// `listChats`: all chat summaries, most-recently-updated first.
public struct DaemonListChatsRequest: Codable, Equatable, Sendable {
    public init() {}
}

public struct DaemonListChatsReply: Codable, Equatable, Sendable {
    public let chats: [DaemonChatSummary]
    public let cursor: DaemonReplyCursor
    public init(chats: [DaemonChatSummary], cursor: DaemonReplyCursor) {
        self.chats = chats
        self.cursor = cursor
    }
}

/// `listPages`: page summaries ordered by the given sort criterion.
public struct DaemonListPagesRequest: Codable, Equatable, Sendable {
    public let sortBy: DaemonPageSortOrder
    public init(sortBy: DaemonPageSortOrder) { self.sortBy = sortBy }
}

public struct DaemonListPagesReply: Codable, Equatable, Sendable {
    public let pages: [DaemonPageSummary]
    public let cursor: DaemonReplyCursor
    public init(pages: [DaemonPageSummary], cursor: DaemonReplyCursor) {
        self.pages = pages
        self.cursor = cursor
    }
}

/// `listPersistedChatTurns`: a chat's durable turn rows in ordinal order.
public struct DaemonListPersistedChatTurnsRequest: Codable, Equatable,
    Sendable {
    public let chatID: String
    public init(chatID: String) { self.chatID = chatID }
}

public struct DaemonListPersistedChatTurnsReply: Codable, Equatable, Sendable {
    public let turns: [DaemonPersistedChatTurn]
    public let cursor: DaemonReplyCursor
    public init(turns: [DaemonPersistedChatTurn], cursor: DaemonReplyCursor) {
        self.turns = turns
        self.cursor = cursor
    }
}

/// `listSources`: source summaries (no bytes), most-recent-first.
public struct DaemonListSourcesRequest: Codable, Equatable, Sendable {
    public init() {}
}

public struct DaemonListSourcesReply: Codable, Equatable, Sendable {
    public let sources: [DaemonSourceSummary]
    public let cursor: DaemonReplyCursor
    public init(sources: [DaemonSourceSummary], cursor: DaemonReplyCursor) {
        self.sources = sources
        self.cursor = cursor
    }
}

/// `markedSourceIDs`: ids of sources marked ingested, sorted ascending (the
/// core value is a set).
public struct DaemonMarkedSourceIDsRequest: Codable, Equatable, Sendable {
    public init() {}
}

public struct DaemonMarkedSourceIDsReply: Codable, Equatable, Sendable {
    public let sourceIDs: [String]
    public let cursor: DaemonReplyCursor
    public init(sourceIDs: [String], cursor: DaemonReplyCursor) {
        self.sourceIDs = sourceIDs
        self.cursor = cursor
    }
}

/// `pageEditHistory`: every version joined to its agent/activity,
/// OLDEST-FIRST (entry.last is the HEAD).
public struct DaemonPageEditHistoryRequest: Codable, Equatable, Sendable {
    public let pageID: String
    public init(pageID: String) { self.pageID = pageID }
}

public struct DaemonPageEditHistoryReply: Codable, Equatable, Sendable {
    public let entries: [DaemonPageOrigin]
    public let cursor: DaemonReplyCursor
    public init(entries: [DaemonPageOrigin], cursor: DaemonReplyCursor) {
        self.entries = entries
        self.cursor = cursor
    }
}

/// `pagesCitingSources`: distinct pages citing any of `sourceIDs`, bounded by
/// `limit` (non-positive → empty; a full page is a floor, never a total).
/// Ordered by title (case-insensitive) then page id, nil-titles last.
public struct DaemonPagesCitingSourcesRequest: Codable, Equatable, Sendable {
    public let sourceIDs: [String]
    public let limit: Int
    public init(sourceIDs: [String], limit: Int) {
        self.sourceIDs = sourceIDs
        self.limit = limit
    }
}

public struct DaemonPagesCitingSourcesReply: Codable, Equatable, Sendable {
    public let pages: [DaemonCitedPage]
    public let cursor: DaemonReplyCursor
    public init(pages: [DaemonCitedPage], cursor: DaemonReplyCursor) {
        self.pages = pages
        self.cursor = cursor
    }
}

/// `pageVersionHistory`: the full version chain, ordered by ULID.
public struct DaemonPageVersionHistoryRequest: Codable, Equatable, Sendable {
    public let pageID: String
    public init(pageID: String) { self.pageID = pageID }
}

public struct DaemonPageVersionHistoryReply: Codable, Equatable, Sendable {
    public let versions: [DaemonPageVersionSummary]
    public let cursor: DaemonReplyCursor
    public init(
        versions: [DaemonPageVersionSummary], cursor: DaemonReplyCursor
    ) {
        self.versions = versions
        self.cursor = cursor
    }
}

/// `processedMarkdownAgentNames`: smv id → producing agent name, entries
/// sorted by version id (the core value is a dictionary).
public struct DaemonProcessedMarkdownAgentNamesRequest: Codable, Equatable,
    Sendable {
    public let sourceID: String
    public init(sourceID: String) { self.sourceID = sourceID }
}

public struct DaemonProcessedMarkdownAgentNamesReply: Codable, Equatable,
    Sendable {
    public let entries: [DaemonMarkdownAgentNameEntry]
    public let cursor: DaemonReplyCursor
    public init(
        entries: [DaemonMarkdownAgentNameEntry], cursor: DaemonReplyCursor
    ) {
        self.entries = entries
        self.cursor = cursor
    }
}

/// `processedMarkdownAlternatives`: every alternative newest-first, each with
/// its provenance bundle and active-HEAD flag. Version CONTENT does not ride
/// inline (N full-text versions would blow the frame): `contents` is a
/// payload handle whose bytes are the JSON object `[versionID: content]` —
/// reassemble `alternative.version` + contents to the core
/// `ExtractionAlternative` values, nothing dropped.
public struct DaemonProcessedMarkdownAlternativesRequest: Codable, Equatable,
    Sendable {
    public let sourceID: String
    public init(sourceID: String) { self.sourceID = sourceID }
}

public struct DaemonProcessedMarkdownAlternativesReply: Codable, Equatable,
    Sendable {
    public let alternatives: [DaemonExtractionAlternative]
    /// Handle over the JSON object `[versionID: content]` (UTF-8).
    public let contents: DaemonPayloadHandle
    public let contentByteCount: Int
    public let cursor: DaemonReplyCursor

    public init(
        alternatives: [DaemonExtractionAlternative],
        contents: DaemonPayloadHandle, contentByteCount: Int,
        cursor: DaemonReplyCursor
    ) {
        self.alternatives = alternatives
        self.contents = contents
        self.contentByteCount = contentByteCount
        self.cursor = cursor
    }
}

/// `processedMarkdownHistory`: all versions newest-first (HEAD → v1). CONTENT
/// does not ride inline (same frame math as alternatives): `contents` is a
/// payload handle whose bytes are the JSON object `[versionID: content]` —
/// reassemble header + contents to the core `SourceMarkdownVersion` values.
public struct DaemonProcessedMarkdownHistoryRequest: Codable, Equatable,
    Sendable {
    public let sourceID: String
    public init(sourceID: String) { self.sourceID = sourceID }
}

public struct DaemonProcessedMarkdownHistoryReply: Codable, Equatable,
    Sendable {
    public let versions: [DaemonSourceMarkdownVersionHeader]
    /// Handle over the JSON object `[versionID: content]` (UTF-8).
    public let contents: DaemonPayloadHandle
    public let contentByteCount: Int
    public let cursor: DaemonReplyCursor

    public init(
        versions: [DaemonSourceMarkdownVersionHeader],
        contents: DaemonPayloadHandle, contentByteCount: Int,
        cursor: DaemonReplyCursor
    ) {
        self.versions = versions
        self.contents = contents
        self.contentByteCount = contentByteCount
        self.cursor = cursor
    }
}

/// `readChatTranscriptPage`: one cursor-bounded typed transcript page (the
/// typed `after` cursor bounds the QUERY; the reply's `cursor` bounds the
/// encoded BYTES).
public struct DaemonReadChatTranscriptPageRequest: Codable, Equatable,
    Sendable {
    public let chatID: String
    public let after: DaemonChatTranscriptCursor?
    public let limit: Int
    public init(
        chatID: String, after: DaemonChatTranscriptCursor?, limit: Int
    ) {
        self.chatID = chatID
        self.after = after
        self.limit = limit
    }
}

public struct DaemonReadChatTranscriptPageReply: Codable, Equatable, Sendable {
    public let page: DaemonChatTranscriptPage
    public let cursor: DaemonReplyCursor
    public init(page: DaemonChatTranscriptPage, cursor: DaemonReplyCursor) {
        self.page = page
        self.cursor = cursor
    }
}

/// `recentLogEntries`: the most recent `limit` entries, chronological
/// (oldest-of-the-tail first).
public struct DaemonRecentLogEntriesRequest: Codable, Equatable, Sendable {
    public let limit: Int
    public init(limit: Int) { self.limit = limit }
}

public struct DaemonRecentLogEntriesReply: Codable, Equatable, Sendable {
    public let entries: [DaemonLogEntry]
    public let cursor: DaemonReplyCursor
    public init(entries: [DaemonLogEntry], cursor: DaemonReplyCursor) {
        self.entries = entries
        self.cursor = cursor
    }
}

/// `siblingImageResolvers`: per-source resolver maps, entries sorted by
/// source id (the core value is a dictionary of dictionaries).
public struct DaemonSiblingImageResolversRequest: Codable, Equatable,
    Sendable {
    public init() {}
}

public struct DaemonSiblingImageResolversReply: Codable, Equatable, Sendable {
    public let entries: [DaemonSiblingImageResolverEntry]
    public let cursor: DaemonReplyCursor
    public init(
        entries: [DaemonSiblingImageResolverEntry], cursor: DaemonReplyCursor
    ) {
        self.entries = entries
        self.cursor = cursor
    }
}

/// `sourceDerivedChains`: every source's chain map, entries sorted by source
/// id (the core value is a dictionary).
public struct DaemonSourceDerivedChainsRequest: Codable, Equatable, Sendable {
    public init() {}
}

public struct DaemonSourceDerivedChainsReply: Codable, Equatable, Sendable {
    public let entries: [DaemonSourceDerivedChainEntry]
    public let cursor: DaemonReplyCursor
    public init(
        entries: [DaemonSourceDerivedChainEntry], cursor: DaemonReplyCursor
    ) {
        self.entries = entries
        self.cursor = cursor
    }
}

/// `sourceEditHistory`: every source-version row joined to its
/// activity/agent, NEWEST-FIRST.
public struct DaemonSourceEditHistoryRequest: Codable, Equatable, Sendable {
    public let sourceID: String
    public init(sourceID: String) { self.sourceID = sourceID }
}

public struct DaemonSourceEditHistoryReply: Codable, Equatable, Sendable {
    public let origins: [DaemonSourceOrigin]
    public let cursor: DaemonReplyCursor
    public init(origins: [DaemonSourceOrigin], cursor: DaemonReplyCursor) {
        self.origins = origins
        self.cursor = cursor
    }
}

/// `sourceOriginsBySource`: batched origins for ALL sources, entries sorted
/// by source id (the core value is a dictionary; no blob filter).
public struct DaemonSourceOriginsBySourceRequest: Codable, Equatable,
    Sendable {
    public init() {}
}

public struct DaemonSourceOriginsBySourceReply: Codable, Equatable, Sendable {
    public let entries: [DaemonSourceOriginEntry]
    public let cursor: DaemonReplyCursor
    public init(
        entries: [DaemonSourceOriginEntry], cursor: DaemonReplyCursor
    ) {
        self.entries = entries
        self.cursor = cursor
    }
}

/// `sourcesWithPendingFormatJobs`: the recovery-scan set, store order
/// preserved.
public struct DaemonSourcesWithPendingFormatJobsRequest: Codable, Equatable,
    Sendable {
    public init() {}
}

public struct DaemonSourcesWithPendingFormatJobsReply: Codable, Equatable,
    Sendable {
    public let sourceIDs: [String]
    public let cursor: DaemonReplyCursor
    public init(sourceIDs: [String], cursor: DaemonReplyCursor) {
        self.sourceIDs = sourceIDs
        self.cursor = cursor
    }
}

/// `workspaceConflicts`: persisted conflict details for a parked workspace.
public struct DaemonWorkspaceConflictsRequest: Codable, Equatable, Sendable {
    public let workspaceID: String
    public init(workspaceID: String) { self.workspaceID = workspaceID }
}

public struct DaemonWorkspaceConflictsReply: Codable, Equatable, Sendable {
    public let conflicts: [DaemonWorkspaceConflict]
    public let cursor: DaemonReplyCursor
    public init(
        conflicts: [DaemonWorkspaceConflict], cursor: DaemonReplyCursor
    ) {
        self.conflicts = conflicts
        self.cursor = cursor
    }
}

/// `workspaceRefs`: all page-overlay refs in a workspace (the write set).
public struct DaemonWorkspaceRefsRequest: Codable, Equatable, Sendable {
    public let workspaceID: String
    public init(workspaceID: String) { self.workspaceID = workspaceID }
}

public struct DaemonWorkspaceRefsReply: Codable, Equatable, Sendable {
    public let refs: [DaemonWorkspaceRef]
    public let cursor: DaemonReplyCursor
    public init(refs: [DaemonWorkspaceRef], cursor: DaemonReplyCursor) {
        self.refs = refs
        self.cursor = cursor
    }
}
#endif
