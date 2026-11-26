#if os(macOS)
import Foundation
import WikiDaemonContract
import WikiFSCore
import WikiFSTypes

// MARK: - Slice-2 wired surface: list family (22 operations)
//
// The list family's client half (plans/daemon-only-access.md slice 2):
// cursor-continuation walks under the daemon's byte-budgeted pages. Reads —
// NEVER stamped (a stamp there is a typed daemon rejection). Every walk
// loops until `nextAvailable == false`, merging the reply cursor's opaque
// `pageToken` beside the DTO's own fields via ``payloadWithPageToken`` —
// the same continuation the wired `listPages` / `listChats` /
// `deletionImpact` exemplars use.
//
// The two bulk-content listings (`processedMarkdownAlternatives` /
// `processedMarkdownHistory`) reassemble their full texts from the reply's
// committed `[versionID: content]` handle — the headers paginate small;
// the bulk never rides inline.

extension RemoteWikiStore {

    public func chatMessages(chatID: ChatID) async throws -> [ChatMessage] {
        _ = try await ensureSession()
        var token: String?
        var messages: [ChatMessage] = []
        repeat {
            let dto = try JSONEncoder().encode(
                DaemonChatMessagesRequest(chatID: chatID.rawValue))
            let result = try await sendStore(
                .chatMessages,
                payload: try Self.payloadWithPageToken(dto, pageToken: token))
            let reply = try Self.decodeResult(
                DaemonChatMessagesReply.self, result, "chatMessages")
            messages += reply.messages.map(RemoteStoreMirrorMapping.coreChatMessage)
            token = reply.cursor.nextAvailable ? reply.cursor.pageToken : nil
        } while token != nil
        return messages
    }

    public func embedDescriptors() async throws -> [SourceID: SourceEmbedDescriptor] {
        _ = try await ensureSession()
        var token: String?
        var descriptors: [SourceID: SourceEmbedDescriptor] = [:]
        repeat {
            let dto = try JSONEncoder().encode(DaemonEmbedDescriptorsRequest())
            let result = try await sendStore(
                .embedDescriptors,
                payload: try Self.payloadWithPageToken(dto, pageToken: token))
            let reply = try Self.decodeResult(
                DaemonEmbedDescriptorsReply.self, result, "embedDescriptors")
            for entry in reply.entries {
                descriptors[SourceID(rawValue: entry.sourceID)] =
                    RemoteStoreMirrorMapping.coreSourceEmbedDescriptor(
                        entry.descriptor)
            }
            token = reply.cursor.nextAvailable ? reply.cursor.pageToken : nil
        } while token != nil
        return descriptors
    }

    public func listAllChatsOrderedByID() async throws -> [ChatSummary] {
        _ = try await ensureSession()
        var token: String?
        var chats: [ChatSummary] = []
        repeat {
            let dto = try JSONEncoder().encode(
                DaemonListAllChatsOrderedByIDRequest())
            let result = try await sendStore(
                .listAllChatsOrderedByID,
                payload: try Self.payloadWithPageToken(dto, pageToken: token))
            let reply = try Self.decodeResult(
                DaemonListAllChatsOrderedByIDReply.self, result,
                "listAllChatsOrderedByID")
            chats += reply.chats.map(Self.coreChatSummary)
            token = reply.cursor.nextAvailable ? reply.cursor.pageToken : nil
        } while token != nil
        return chats
    }

    public func listBookmarkNodes() async throws -> [BookmarkNode] {
        _ = try await ensureSession()
        var token: String?
        var nodes: [BookmarkNode] = []
        repeat {
            let dto = try JSONEncoder().encode(DaemonListBookmarkNodesRequest())
            let result = try await sendStore(
                .listBookmarkNodes,
                payload: try Self.payloadWithPageToken(dto, pageToken: token))
            let reply = try Self.decodeResult(
                DaemonListBookmarkNodesReply.self, result, "listBookmarkNodes")
            nodes += reply.nodes.map(RemoteStoreMirrorMapping.coreBookmarkNode)
            token = reply.cursor.nextAvailable ? reply.cursor.pageToken : nil
        } while token != nil
        return nodes
    }

    public func listPersistedChatTurns(
        chatID: ChatID
    ) async throws -> [PersistedChatTurn] {
        _ = try await ensureSession()
        var token: String?
        var turns: [PersistedChatTurn] = []
        repeat {
            let dto = try JSONEncoder().encode(
                DaemonListPersistedChatTurnsRequest(chatID: chatID.rawValue))
            let result = try await sendStore(
                .listPersistedChatTurns,
                payload: try Self.payloadWithPageToken(dto, pageToken: token))
            let reply = try Self.decodeResult(
                DaemonListPersistedChatTurnsReply.self, result,
                "listPersistedChatTurns")
            turns += reply.turns.map(RemoteStoreMirrorMapping.corePersistedChatTurn)
            token = reply.cursor.nextAvailable ? reply.cursor.pageToken : nil
        } while token != nil
        return turns
    }

    public func listSources() async throws -> [SourceSummary] {
        _ = try await ensureSession()
        var token: String?
        var sources: [SourceSummary] = []
        repeat {
            let dto = try JSONEncoder().encode(DaemonListSourcesRequest())
            let result = try await sendStore(
                .listSources,
                payload: try Self.payloadWithPageToken(dto, pageToken: token))
            let reply = try Self.decodeResult(
                DaemonListSourcesReply.self, result, "listSources")
            sources += reply.sources.map(Self.coreSourceSummary)
            token = reply.cursor.nextAvailable ? reply.cursor.pageToken : nil
        } while token != nil
        return sources
    }

    public func markedSourceIDs() async throws -> Set<String> {
        _ = try await ensureSession()
        var token: String?
        var ids: Set<String> = []
        repeat {
            let dto = try JSONEncoder().encode(DaemonMarkedSourceIDsRequest())
            let result = try await sendStore(
                .markedSourceIDs,
                payload: try Self.payloadWithPageToken(dto, pageToken: token))
            let reply = try Self.decodeResult(
                DaemonMarkedSourceIDsReply.self, result, "markedSourceIDs")
            ids.formUnion(reply.sourceIDs)
            token = reply.cursor.nextAvailable ? reply.cursor.pageToken : nil
        } while token != nil
        return ids
    }

    public func pageEditHistory(pageID: PageID) async throws -> [PageOrigin] {
        _ = try await ensureSession()
        var token: String?
        var entries: [PageOrigin] = []
        repeat {
            let dto = try JSONEncoder().encode(
                DaemonPageEditHistoryRequest(pageID: pageID.rawValue))
            let result = try await sendStore(
                .pageEditHistory,
                payload: try Self.payloadWithPageToken(dto, pageToken: token))
            let reply = try Self.decodeResult(
                DaemonPageEditHistoryReply.self, result, "pageEditHistory")
            entries += reply.entries.map(RemoteStoreMirrorMapping.corePageOrigin)
            token = reply.cursor.nextAvailable ? reply.cursor.pageToken : nil
        } while token != nil
        return entries
    }

    public func pagesCitingSources(
        sourceIDs: [SourceID], limit: Int
    ) async throws -> [CitedPage] {
        _ = try await ensureSession()
        var token: String?
        var pages: [CitedPage] = []
        repeat {
            let dto = try JSONEncoder().encode(DaemonPagesCitingSourcesRequest(
                sourceIDs: sourceIDs.map(\.rawValue), limit: limit))
            let result = try await sendStore(
                .pagesCitingSources,
                payload: try Self.payloadWithPageToken(dto, pageToken: token))
            let reply = try Self.decodeResult(
                DaemonPagesCitingSourcesReply.self, result, "pagesCitingSources")
            pages += reply.pages.map(RemoteStoreMirrorMapping.coreCitedPage)
            token = reply.cursor.nextAvailable ? reply.cursor.pageToken : nil
        } while token != nil
        return pages
    }

    public func pageVersionHistory(pageID: PageID) async throws -> [PageVersionSummary] {
        _ = try await ensureSession()
        var token: String?
        var versions: [PageVersionSummary] = []
        repeat {
            let dto = try JSONEncoder().encode(
                DaemonPageVersionHistoryRequest(pageID: pageID.rawValue))
            let result = try await sendStore(
                .pageVersionHistory,
                payload: try Self.payloadWithPageToken(dto, pageToken: token))
            let reply = try Self.decodeResult(
                DaemonPageVersionHistoryReply.self, result, "pageVersionHistory")
            versions += reply.versions.map(
                RemoteStoreMirrorMapping.corePageVersionSummary)
            token = reply.cursor.nextAvailable ? reply.cursor.pageToken : nil
        } while token != nil
        return versions
    }

    public func processedMarkdownAgentNames(
        sourceID: SourceID
    ) async throws -> [SourceMarkdownVersionID: String] {
        _ = try await ensureSession()
        var token: String?
        var names: [SourceMarkdownVersionID: String] = [:]
        repeat {
            let dto = try JSONEncoder().encode(
                DaemonProcessedMarkdownAgentNamesRequest(
                    sourceID: sourceID.rawValue))
            let result = try await sendStore(
                .processedMarkdownAgentNames,
                payload: try Self.payloadWithPageToken(dto, pageToken: token))
            let reply = try Self.decodeResult(
                DaemonProcessedMarkdownAgentNamesReply.self, result,
                "processedMarkdownAgentNames")
            for entry in reply.entries {
                names[SourceMarkdownVersionID(rawValue: entry.versionID)] =
                    entry.agentName
            }
            token = reply.cursor.nextAvailable ? reply.cursor.pageToken : nil
        } while token != nil
        return names
    }

    /// Bulk content NEVER rides inline: the headers paginate while the full
    /// `[versionID: content]` map rides as ONE committed handle (the same
    /// handle value on every page). The walk reads the FINAL page's handle
    /// once and reassembles every alternative.
    public func processedMarkdownAlternatives(
        sourceID: SourceID
    ) async throws -> [ExtractionAlternative] {
        _ = try await ensureSession()
        var token: String?
        var headers: [DaemonExtractionAlternative] = []
        var contentsHandle: DaemonPayloadHandle?
        repeat {
            let dto = try JSONEncoder().encode(
                DaemonProcessedMarkdownAlternativesRequest(
                    sourceID: sourceID.rawValue))
            let result = try await sendStore(
                .processedMarkdownAlternatives,
                payload: try Self.payloadWithPageToken(dto, pageToken: token))
            let reply = try Self.decodeResult(
                DaemonProcessedMarkdownAlternativesReply.self, result,
                "processedMarkdownAlternatives")
            headers += reply.alternatives
            contentsHandle = reply.contents
            token = reply.cursor.nextAvailable ? reply.cursor.pageToken : nil
        } while token != nil
        guard let handle = contentsHandle else {
            throw RemoteStoreClientError.malformedReply(
                "processedMarkdownAlternatives reply carried no contents handle")
        }
        let contentsData = try await readHandle(handle)
        let contents = try JSONDecoder().decode(
            [String: String].self, from: contentsData)
        return try headers.map { header in
            guard let content = contents[header.version.id] else {
                throw RemoteStoreClientError.malformedReply(
                    "processedMarkdownAlternatives contents handle carries "
                        + "no content for \(header.version.id)")
            }
            return try RemoteStoreMirrorMapping.coreAlternative(
                header, content: content)
        }
    }

    /// Same bulk-as-handle reassembly as the alternatives read.
    public func processedMarkdownHistory(
        sourceID: SourceID
    ) async throws -> [SourceMarkdownVersion] {
        _ = try await ensureSession()
        var token: String?
        var headers: [DaemonSourceMarkdownVersionHeader] = []
        var contentsHandle: DaemonPayloadHandle?
        repeat {
            let dto = try JSONEncoder().encode(
                DaemonProcessedMarkdownHistoryRequest(sourceID: sourceID.rawValue))
            let result = try await sendStore(
                .processedMarkdownHistory,
                payload: try Self.payloadWithPageToken(dto, pageToken: token))
            let reply = try Self.decodeResult(
                DaemonProcessedMarkdownHistoryReply.self, result,
                "processedMarkdownHistory")
            headers += reply.versions
            contentsHandle = reply.contents
            token = reply.cursor.nextAvailable ? reply.cursor.pageToken : nil
        } while token != nil
        guard let handle = contentsHandle else {
            throw RemoteStoreClientError.malformedReply(
                "processedMarkdownHistory reply carried no contents handle")
        }
        let contentsData = try await readHandle(handle)
        let contents = try JSONDecoder().decode(
            [String: String].self, from: contentsData)
        return try headers.map { header in
            guard let content = contents[header.id] else {
                throw RemoteStoreClientError.malformedReply(
                    "processedMarkdownHistory contents handle carries no "
                        + "content for \(header.id)")
            }
            return RemoteStoreMirrorMapping.coreMarkdownVersion(
                header, content: content)
        }
    }

    /// The typed `after` cursor bounds the QUERY; the reply cursor bounds
    /// the encoded BYTES within each query page (page 2's request-side
    /// `after` is nil — the continuation token carries the last-seen
    /// cursor, exactly as the executor resumes it).
    public func readChatTranscriptPage(
        chatID: ChatID, after cursor: ChatTranscriptCursor?, limit: Int
    ) async throws -> ChatTranscriptPage {
        _ = try await ensureSession()
        var items: [PersistedChatTranscriptItem] = []
        var checkpoint = ChatTranscriptCursor(rawValue: 0)
        var nextCursor: ChatTranscriptCursor?
        var token: String?
        repeat {
            let dto = try JSONEncoder().encode(DaemonReadChatTranscriptPageRequest(
                chatID: chatID.rawValue,
                after: cursor.map {
                    DaemonChatTranscriptCursor(rawValue: $0.rawValue)
                },
                limit: limit))
            let result = try await sendStore(
                .readChatTranscriptPage,
                payload: try Self.payloadWithPageToken(dto, pageToken: token))
            let reply = try Self.decodeResult(
                DaemonReadChatTranscriptPageReply.self, result,
                "readChatTranscriptPage")
            items += reply.page.items.map(
                RemoteStoreMirrorMapping.corePersistedTranscriptItem)
            checkpoint = RemoteStoreMirrorMapping.coreTranscriptCursor(
                reply.page.checkpoint)
            nextCursor = reply.page.nextCursor.map(
                RemoteStoreMirrorMapping.coreTranscriptCursor)
            token = reply.cursor.nextAvailable ? reply.cursor.pageToken : nil
        } while token != nil
        return ChatTranscriptPage(
            items: items, checkpoint: checkpoint, nextCursor: nextCursor)
    }

    public func recentLogEntries(limit: Int) async throws -> [LogEntry] {
        _ = try await ensureSession()
        var token: String?
        var entries: [LogEntry] = []
        repeat {
            let dto = try JSONEncoder().encode(
                DaemonRecentLogEntriesRequest(limit: limit))
            let result = try await sendStore(
                .recentLogEntries,
                payload: try Self.payloadWithPageToken(dto, pageToken: token))
            let reply = try Self.decodeResult(
                DaemonRecentLogEntriesReply.self, result, "recentLogEntries")
            entries += reply.entries.map(RemoteStoreMirrorMapping.coreLogEntry)
            token = reply.cursor.nextAvailable ? reply.cursor.pageToken : nil
        } while token != nil
        return entries
    }

    public func siblingImageResolvers() async throws -> [SourceID: [String: SourceID]] {
        _ = try await ensureSession()
        var token: String?
        var resolvers: [SourceID: [String: SourceID]] = [:]
        repeat {
            let dto = try JSONEncoder().encode(DaemonSiblingImageResolversRequest())
            let result = try await sendStore(
                .siblingImageResolvers,
                payload: try Self.payloadWithPageToken(dto, pageToken: token))
            let reply = try Self.decodeResult(
                DaemonSiblingImageResolversReply.self, result,
                "siblingImageResolvers")
            for entry in reply.entries {
                var byPath: [String: SourceID] = [:]
                for resolver in entry.resolvers {
                    byPath[resolver.originalPath] = SourceID(
                        rawValue: resolver.sourceID)
                }
                resolvers[SourceID(rawValue: entry.sourceID)] = byPath
            }
            token = reply.cursor.nextAvailable ? reply.cursor.pageToken : nil
        } while token != nil
        return resolvers
    }

    public func sourceDerivedChains() async throws -> [SourceID: [SourceMarkdownVersionID]] {
        _ = try await ensureSession()
        var token: String?
        var chains: [SourceID: [SourceMarkdownVersionID]] = [:]
        repeat {
            let dto = try JSONEncoder().encode(DaemonSourceDerivedChainsRequest())
            let result = try await sendStore(
                .sourceDerivedChains,
                payload: try Self.payloadWithPageToken(dto, pageToken: token))
            let reply = try Self.decodeResult(
                DaemonSourceDerivedChainsReply.self, result, "sourceDerivedChains")
            for entry in reply.entries {
                chains[SourceID(rawValue: entry.sourceID)] = entry.chain.map {
                    SourceMarkdownVersionID(rawValue: $0)
                }
            }
            token = reply.cursor.nextAvailable ? reply.cursor.pageToken : nil
        } while token != nil
        return chains
    }

    public func sourceEditHistory(sourceID: SourceID) async throws -> [SourceOrigin] {
        _ = try await ensureSession()
        var token: String?
        var origins: [SourceOrigin] = []
        repeat {
            let dto = try JSONEncoder().encode(
                DaemonSourceEditHistoryRequest(sourceID: sourceID.rawValue))
            let result = try await sendStore(
                .sourceEditHistory,
                payload: try Self.payloadWithPageToken(dto, pageToken: token))
            let reply = try Self.decodeResult(
                DaemonSourceEditHistoryReply.self, result, "sourceEditHistory")
            origins += reply.origins.map(RemoteStoreMirrorMapping.coreSourceOrigin)
            token = reply.cursor.nextAvailable ? reply.cursor.pageToken : nil
        } while token != nil
        return origins
    }

    public func sourceOriginsBySource() async throws -> [SourceID: SourceOrigin] {
        _ = try await ensureSession()
        var token: String?
        var origins: [SourceID: SourceOrigin] = [:]
        repeat {
            let dto = try JSONEncoder().encode(DaemonSourceOriginsBySourceRequest())
            let result = try await sendStore(
                .sourceOriginsBySource,
                payload: try Self.payloadWithPageToken(dto, pageToken: token))
            let reply = try Self.decodeResult(
                DaemonSourceOriginsBySourceReply.self, result,
                "sourceOriginsBySource")
            for entry in reply.entries {
                origins[SourceID(rawValue: entry.sourceID)] =
                    RemoteStoreMirrorMapping.coreSourceOrigin(entry.origin)
            }
            token = reply.cursor.nextAvailable ? reply.cursor.pageToken : nil
        } while token != nil
        return origins
    }

    public func sourcesWithPendingFormatJobs() async throws -> [SourceID] {
        _ = try await ensureSession()
        var token: String?
        var ids: [SourceID] = []
        repeat {
            let dto = try JSONEncoder().encode(
                DaemonSourcesWithPendingFormatJobsRequest())
            let result = try await sendStore(
                .sourcesWithPendingFormatJobs,
                payload: try Self.payloadWithPageToken(dto, pageToken: token))
            let reply = try Self.decodeResult(
                DaemonSourcesWithPendingFormatJobsReply.self, result,
                "sourcesWithPendingFormatJobs")
            ids += reply.sourceIDs.map { SourceID(rawValue: $0) }
            token = reply.cursor.nextAvailable ? reply.cursor.pageToken : nil
        } while token != nil
        return ids
    }

    public func workspaceConflicts(
        workspaceID: WorkspaceID
    ) async throws -> [WorkspaceConflict] {
        _ = try await ensureSession()
        var token: String?
        var conflicts: [WorkspaceConflict] = []
        repeat {
            let dto = try JSONEncoder().encode(
                DaemonWorkspaceConflictsRequest(workspaceID: workspaceID.rawValue))
            let result = try await sendStore(
                .workspaceConflicts,
                payload: try Self.payloadWithPageToken(dto, pageToken: token))
            let reply = try Self.decodeResult(
                DaemonWorkspaceConflictsReply.self, result, "workspaceConflicts")
            conflicts += reply.conflicts.map(
                RemoteStoreMirrorMapping.coreWorkspaceConflict)
            token = reply.cursor.nextAvailable ? reply.cursor.pageToken : nil
        } while token != nil
        return conflicts
    }

    public func workspaceRefs(
        workspaceID: WorkspaceID
    ) async throws -> [WorkspaceRef] {
        _ = try await ensureSession()
        var token: String?
        var refs: [WorkspaceRef] = []
        repeat {
            let dto = try JSONEncoder().encode(
                DaemonWorkspaceRefsRequest(workspaceID: workspaceID.rawValue))
            let result = try await sendStore(
                .workspaceRefs,
                payload: try Self.payloadWithPageToken(dto, pageToken: token))
            let reply = try Self.decodeResult(
                DaemonWorkspaceRefsReply.self, result, "workspaceRefs")
            refs += reply.refs.map(RemoteStoreMirrorMapping.coreWorkspaceRef)
            token = reply.cursor.nextAvailable ? reply.cursor.pageToken : nil
        } while token != nil
        return refs
    }
}
#endif
