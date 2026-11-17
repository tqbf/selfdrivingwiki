#if os(macOS)
import Foundation
import WikiDaemonContract
import WikiFSCore
import WikiFSTypes

// MARK: - Slice-2 wired surface: blob family (36 operations)
//
// The blob family's client half (plans/daemon-only-access.md slice 2):
// bytes up or down via staged payload handles, mirroring the wired
// `getPage` / `upsertPage` / `addSource` exemplars in the core file.
//
// - Reads (bytes down): the metadata crosses inline; bulk content
//   reassembles through ``readHandle`` with the SHA-256 + declared-size
//   integrity check. Unstamped.
// - Mutators (bytes up): inputs stage through ``stageUpload`` (ordered,
//   hash-checked chunks), the mutation carries an admission stamp, and the
//   echoed outcome guards the call (``requireCommittedOutcome``).
// - The three chunk stores encode their `[Data]` chunks as the executor's
//   `[String]` base64 JSON shape behind one upload handle.
// - `appendHostSpeechTranscript` wires the faithful request shape; the
//   daemon answers its own typed rejection (the mirror dropped the exact
//   package identity) — the round trip is honest, the failure is typed.

extension RemoteWikiStore {

    // MARK: reads (bytes down — unstamped)

    public func getWikiIndex() async throws -> WikiIndex {
        _ = try await ensureSession()
        let result = try await sendStore(
            .getWikiIndex,
            payload: JSONEncoder().encode(DaemonGetWikiIndexRequest()))
        let reply = try Self.decodeResult(
            DaemonGetWikiIndexReply.self, result, "getWikiIndex")
        let body = try await readHandle(reply.body)
        guard let bodyText = String(data: body, encoding: .utf8) else {
            throw RemoteStoreClientError.malformedReply(
                "getWikiIndex body was not UTF-8")
        }
        return WikiIndex(
            body: bodyText,
            updatedAt: reply.metadata.updatedAt,
            version: reply.metadata.version)
    }

    public func missingPageEmbeddingWork() async throws -> [(id: PageID, text: String)] {
        _ = try await ensureSession()
        let result = try await sendStore(
            .missingPageEmbeddingWork,
            payload: JSONEncoder().encode(DaemonMissingPageEmbeddingWorkRequest()))
        let reply = try Self.decodeResult(
            DaemonMissingPageEmbeddingWorkReply.self, result,
            "missingPageEmbeddingWork")
        let bytes = try await readHandle(reply.work)
        return try RemoteStoreMirrorMapping.coreEmbeddingWork(bytes) {
            PageID(rawValue: $0)
        }
    }

    public func missingSourceEmbeddingWork() async throws -> [(id: SourceID, text: String)] {
        _ = try await ensureSession()
        let result = try await sendStore(
            .missingSourceEmbeddingWork,
            payload: JSONEncoder().encode(
                DaemonMissingSourceEmbeddingWorkRequest()))
        let reply = try Self.decodeResult(
            DaemonMissingSourceEmbeddingWorkReply.self, result,
            "missingSourceEmbeddingWork")
        let bytes = try await readHandle(reply.work)
        return try RemoteStoreMirrorMapping.coreEmbeddingWork(bytes) {
            SourceID(rawValue: $0)
        }
    }

    public func missingChatEmbeddingWork() async throws -> [(id: ChatID, text: String)] {
        _ = try await ensureSession()
        let result = try await sendStore(
            .missingChatEmbeddingWork,
            payload: JSONEncoder().encode(DaemonMissingChatEmbeddingWorkRequest()))
        let reply = try Self.decodeResult(
            DaemonMissingChatEmbeddingWorkReply.self, result,
            "missingChatEmbeddingWork")
        let bytes = try await readHandle(reply.work)
        return try RemoteStoreMirrorMapping.coreEmbeddingWork(bytes) {
            ChatID(rawValue: $0)
        }
    }

    public func pageVersionBody(versionID: PageVersionID) async throws -> String? {
        _ = try await ensureSession()
        let result = try await sendStore(
            .pageVersionBody,
            payload: JSONEncoder().encode(
                DaemonPageVersionBodyRequest(versionID: versionID.rawValue)))
        let reply = try Self.decodeResult(
            DaemonPageVersionBodyReply.self, result, "pageVersionBody")
        guard let handle = reply.body else { return nil }
        let bytes = try await readHandle(handle)
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw RemoteStoreClientError.malformedReply(
                "pageVersionBody was not UTF-8")
        }
        return text
    }

    public func processedMarkdownHead(
        sourceID: SourceID
    ) async throws -> SourceMarkdownVersion? {
        _ = try await ensureSession()
        let result = try await sendStore(
            .processedMarkdownHead,
            payload: JSONEncoder().encode(
                DaemonProcessedMarkdownHeadRequest(sourceID: sourceID.rawValue)))
        let reply = try Self.decodeResult(
            DaemonProcessedMarkdownHeadReply.self, result, "processedMarkdownHead")
        return try await markdownVersion(
            reply.version, contentHandle: reply.content, operation: "processedMarkdownHead")
    }

    public func processedMarkdownVersion(
        id: SourceMarkdownVersionID
    ) async throws -> SourceMarkdownVersion? {
        _ = try await ensureSession()
        let result = try await sendStore(
            .processedMarkdownVersion,
            payload: JSONEncoder().encode(
                DaemonProcessedMarkdownVersionRequest(versionID: id.rawValue)))
        let reply = try Self.decodeResult(
            DaemonProcessedMarkdownVersionReply.self, result,
            "processedMarkdownVersion")
        return try await markdownVersion(
            reply.version, contentHandle: reply.content,
            operation: "processedMarkdownVersion")
    }

    /// The two-sourceContent witnesses share one wire op: the DTO enum
    /// distinguishes the active-source read from the exact-version read
    /// (the request shape carries no collapse).
    public func sourceContent(id: SourceID) async throws -> Data {
        _ = try await ensureSession()
        return try await sourceContentRoundTrip(
            .active(sourceID: id.rawValue), operation: "sourceContent(id:)")
    }

    public func sourceContent(versionID: SourceVersionID) async throws -> Data {
        _ = try await ensureSession()
        return try await sourceContentRoundTrip(
            .version(versionID: versionID.rawValue),
            operation: "sourceContent(versionID:)")
    }

    private func sourceContentRoundTrip(
        _ request: DaemonSourceContentRequest, operation: String
    ) async throws -> Data {
        let result = try await sendStore(
            .sourceContent,
            payload: JSONEncoder().encode(request))
        let reply = try Self.decodeResult(
            DaemonSourceContentReply.self, result, operation)
        guard let handle = reply.bytes else {
            throw RemoteStoreClientError.malformedReply(
                "\(operation) reply carried no bytes handle")
        }
        return try await readHandle(handle)
    }

    public func workspacePageBody(
        workspaceID: WorkspaceID, pageID: PageID
    ) async throws -> String? {
        _ = try await ensureSession()
        let result = try await sendStore(
            .workspacePageBody,
            payload: JSONEncoder().encode(DaemonWorkspacePageBodyRequest(
                workspaceID: workspaceID.rawValue, pageID: pageID.rawValue)))
        let reply = try Self.decodeResult(
            DaemonWorkspacePageBodyReply.self, result, "workspacePageBody")
        guard let handle = reply.body else { return nil }
        let bytes = try await readHandle(handle)
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw RemoteStoreClientError.malformedReply(
                "workspacePageBody was not UTF-8")
        }
        return text
    }

    /// BOUNDED INLINE (≤ 32 KiB store-side): the strategy document crosses
    /// inline, no handle round trip — mirrors the executor's reply shape.
    public func getWikiStrategy() async throws -> WikiStrategy? {
        _ = try await ensureSession()
        let result = try await sendStore(
            .getWikiStrategy,
            payload: JSONEncoder().encode(DaemonGetWikiStrategyRequest()))
        let reply = try Self.decodeResult(
            DaemonGetWikiStrategyReply.self, result, "getWikiStrategy")
        return reply.strategy.map(RemoteStoreMirrorMapping.coreStrategySnapshot)
    }

    // MARK: mutators (bytes up — staged handle consumed once, stamped)

    public func addSnapshotImage(
        filename: String,
        data: Data,
        detectionHints: ContentTypeDetectionHints,
        originalPath: String,
        sourceURL: URL,
        activityID: String,
        role: SourceRole
    ) async throws -> SourceSummary {
        _ = try await ensureSession()
        let handle = try await stageUpload(data)
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .addSnapshotImage,
            payload: JSONEncoder().encode(DaemonAddSnapshotImageRequest(
                filename: filename,
                data: handle,
                detectionHints: Self.wireHints(detectionHints),
                originalPath: originalPath,
                sourceURL: sourceURL.absoluteString,
                activityID: activityID,
                role: DaemonSourceRole(rawValue: role.rawValue) ?? .primary)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonAddSnapshotImageReply.self, result, "addSnapshotImage")
        try Self.requireCommittedOutcome(reply.outcome, "addSnapshotImage")
        return Self.coreSourceSummary(reply.source)
    }

    public func appendChatMessages(
        chatID: ChatID, events: [AgentEvent]
    ) async throws -> [ChatMessage] {
        _ = try await ensureSession()
        let wireEvents = events.map(Self.wireAgentEvent)
        let handle = try await stageUpload(
            try JSONEncoder().encode(wireEvents))
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .appendChatMessages,
            payload: JSONEncoder().encode(DaemonAppendChatMessagesRequest(
                chatID: chatID.rawValue, events: handle,
                eventCount: wireEvents.count)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonAppendChatMessagesReply.self, result, "appendChatMessages")
        try Self.requireCommittedOutcome(reply.outcome, "appendChatMessages")
        return reply.messages.map(RemoteStoreMirrorMapping.coreChatMessage)
    }

    public func appendChatTranscriptItems(
        chatID: ChatID, items: [ChatTranscriptItem]
    ) async throws -> [PersistedChatTranscriptItem] {
        _ = try await ensureSession()
        let wireItems = items.map(RemoteStoreMirrorMapping.wireTranscriptItem)
        let handle = try await stageUpload(
            try JSONEncoder().encode(wireItems))
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .appendChatTranscriptItems,
            payload: JSONEncoder().encode(DaemonAppendChatTranscriptItemsRequest(
                chatID: chatID.rawValue, items: handle,
                itemCount: wireItems.count)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonAppendChatTranscriptItemsReply.self, result,
            "appendChatTranscriptItems")
        try Self.requireCommittedOutcome(reply.outcome, "appendChatTranscriptItems")
        return reply.items.map(
            RemoteStoreMirrorMapping.corePersistedTranscriptItem)
    }

    public func appendContentVersion(
        sourceID: SourceID,
        data: Data,
        detectionHints: ContentTypeDetectionHints,
        provenance: SourceProvenance?
    ) async throws -> SourceVersion {
        _ = try await ensureSession()
        let handle = try await stageUpload(data)
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .appendContentVersion,
            payload: JSONEncoder().encode(DaemonAppendContentVersionRequest(
                sourceID: sourceID.rawValue,
                data: handle,
                detectionHints: Self.wireHints(detectionHints),
                provenance: Self.wireProvenance(provenance))),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonAppendContentVersionReply.self, result, "appendContentVersion")
        try Self.requireCommittedOutcome(reply.outcome, "appendContentVersion")
        return RemoteStoreMirrorMapping.coreSourceVersion(reply.version)
    }

    public func appendDerivedMarkdown(
        sourceID: SourceID,
        content: String,
        origin: SourceMarkdownOrigin,
        producer: ExtractionProducer?,
        providerID: ProviderID?,
        modelID: ModelID?,
        toolVersion: String?,
        sourceVersionID: SourceVersionID?,
        note: String?
    ) async throws -> SourceMarkdownVersion {
        _ = try await ensureSession()
        let handle = try await stageUpload(Data(content.utf8))
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .appendDerivedMarkdown,
            payload: JSONEncoder().encode(DaemonAppendDerivedMarkdownRequest(
                sourceID: sourceID.rawValue,
                content: handle,
                origin: DaemonSourceMarkdownOrigin(
                    rawValue: origin.rawValue) ?? .extraction,
                producer: producer.map(RemoteStoreMirrorMapping.wireProducer),
                providerID: providerID?.rawValue,
                modelID: modelID?.rawValue,
                toolVersion: toolVersion,
                sourceVersionID: sourceVersionID?.rawValue,
                note: note)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonAppendDerivedMarkdownReply.self, result,
            "appendDerivedMarkdown")
        try Self.requireCommittedOutcome(reply.outcome, "appendDerivedMarkdown")
        return markdownVersionFromHeader(reply.version, content: content)
    }

    public func appendFetchMarkdown(
        sourceID: SourceID,
        content: String,
        package: ExtractionInstalledPackageProducer,
        externalItemKey: String?,
        externalItemTitle: String?,
        sourceVersionID: SourceVersionID
    ) async throws -> SourceMarkdownVersion {
        _ = try await ensureSession()
        let handle = try await stageUpload(Data(content.utf8))
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .appendFetchMarkdown,
            payload: JSONEncoder().encode(DaemonAppendFetchMarkdownRequest(
                sourceID: sourceID.rawValue,
                content: handle,
                package: RemoteStoreMirrorMapping.wirePackageProducer(package),
                externalItemKey: externalItemKey,
                externalItemTitle: externalItemTitle,
                sourceVersionID: sourceVersionID.rawValue)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonAppendFetchMarkdownReply.self, result, "appendFetchMarkdown")
        try Self.requireCommittedOutcome(reply.outcome, "appendFetchMarkdown")
        return markdownVersionFromHeader(reply.version, content: content)
    }

    /// Faithful request shape; the daemon answers its own typed rejection
    /// (the acquisition fetcher crosses as one identity string without the
    /// exact package identity the core producer requires). Both ends ship
    /// together, so the typed failure is the contract — not a client-side
    /// pre-emptive `unsupportedRemote`.
    public func appendHostSpeechTranscript(
        sourceID: SourceID,
        content: String,
        producer: ExtractionHostSpeechProducer,
        sourceVersionID: SourceVersionID
    ) async throws -> SourceMarkdownVersion {
        _ = try await ensureSession()
        let handle = try await stageUpload(Data(content.utf8))
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .appendHostSpeechTranscript,
            payload: JSONEncoder().encode(DaemonAppendHostSpeechTranscriptRequest(
                sourceID: sourceID.rawValue,
                content: handle,
                producer: RemoteStoreMirrorMapping.wireHostSpeechProducer(
                    producer),
                sourceVersionID: sourceVersionID.rawValue)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonAppendHostSpeechTranscriptReply.self, result,
            "appendHostSpeechTranscript")
        try Self.requireCommittedOutcome(
            reply.outcome, "appendHostSpeechTranscript")
        return markdownVersionFromHeader(reply.version, content: content)
    }

    public func appendInstalledPackageMarkdown(
        sourceID: SourceID,
        content: String,
        package: ExtractionInstalledPackageProducer,
        origin: SourceMarkdownOrigin,
        toolVersion: String?,
        sourceVersionID: SourceVersionID?,
        note: String?
    ) async throws -> SourceMarkdownVersion {
        _ = try await ensureSession()
        let handle = try await stageUpload(Data(content.utf8))
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .appendInstalledPackageMarkdown,
            payload: JSONEncoder().encode(
                DaemonAppendInstalledPackageMarkdownRequest(
                    sourceID: sourceID.rawValue,
                    content: handle,
                    package: RemoteStoreMirrorMapping.wirePackageProducer(
                        package),
                    origin: DaemonSourceMarkdownOrigin(
                        rawValue: origin.rawValue) ?? .extraction,
                    toolVersion: toolVersion,
                    sourceVersionID: sourceVersionID?.rawValue,
                    note: note)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonAppendInstalledPackageMarkdownReply.self, result,
            "appendInstalledPackageMarkdown")
        try Self.requireCommittedOutcome(
            reply.outcome, "appendInstalledPackageMarkdown")
        return markdownVersionFromHeader(reply.version, content: content)
    }

    public func appendPageVersion(
        pageID: PageID,
        title: String,
        body: String,
        expectedHeadVersionID: PageVersionID?,
        lastEditedBy: String?,
        provenance: [PageVersionSourceInput]
    ) async throws -> PageVersionID {
        _ = try await ensureSession()
        let bodyBytes = Data(body.utf8)
        let handle = bodyBytes.isEmpty ? nil : try await stageUpload(bodyBytes)
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .appendPageVersion,
            payload: JSONEncoder().encode(DaemonAppendPageVersionRequest(
                pageID: pageID.rawValue,
                title: title,
                body: handle,
                expectedHeadVersionID: expectedHeadVersionID?.rawValue,
                lastEditedBy: lastEditedBy,
                provenance: provenance.map(Self.wireVersionSourceInput))),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonAppendPageVersionReply.self, result, "appendPageVersion")
        try Self.requireCommittedOutcome(reply.outcome, "appendPageVersion")
        return PageVersionID(rawValue: reply.versionID)
    }

    public func appendProcessedMarkdown(
        sourceID: SourceID,
        content: String,
        origin: SourceMarkdownOrigin,
        note: String?,
        technique: String?
    ) async throws -> SourceMarkdownVersion {
        _ = try await ensureSession()
        let handle = try await stageUpload(Data(content.utf8))
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .appendProcessedMarkdown,
            payload: JSONEncoder().encode(DaemonAppendProcessedMarkdownRequest(
                sourceID: sourceID.rawValue,
                content: handle,
                origin: DaemonSourceMarkdownOrigin(
                    rawValue: origin.rawValue) ?? .extraction,
                note: note, technique: technique)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonAppendProcessedMarkdownReply.self, result,
            "appendProcessedMarkdown")
        try Self.requireCommittedOutcome(reply.outcome, "appendProcessedMarkdown")
        return markdownVersionFromHeader(reply.version, content: content)
    }

    public func appendUserProcessedMarkdown(
        sourceID: SourceID,
        content: String,
        expectedHead: SourceMarkdownVersionID
    ) async throws -> SourceMarkdownVersion {
        _ = try await ensureSession()
        let handle = try await stageUpload(Data(content.utf8))
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .appendUserProcessedMarkdown,
            payload: JSONEncoder().encode(
                DaemonAppendUserProcessedMarkdownRequest(
                    sourceID: sourceID.rawValue,
                    content: handle,
                    expectedHead: expectedHead.rawValue)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonAppendUserProcessedMarkdownReply.self, result,
            "appendUserProcessedMarkdown")
        try Self.requireCommittedOutcome(
            reply.outcome, "appendUserProcessedMarkdown")
        return markdownVersionFromHeader(reply.version, content: content)
    }

    public func attachAcquiredBytes(
        sourceID: SourceID,
        bytes: Data,
        mimeType: String,
        originalFilename: String?,
        externalItemKey: String?,
        externalItemTitle: String?,
        producer: ExtractionInstalledPackageProducer?
    ) async throws -> SourceVersion {
        _ = try await ensureSession()
        let handle = try await stageUpload(bytes)
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .attachAcquiredBytes,
            payload: JSONEncoder().encode(DaemonAttachAcquiredBytesRequest(
                sourceID: sourceID.rawValue,
                bytes: handle,
                mimeType: mimeType,
                originalFilename: originalFilename,
                externalItemKey: externalItemKey,
                externalItemTitle: externalItemTitle,
                producer: producer.map(
                    RemoteStoreMirrorMapping.wirePackageProducer))),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonAttachAcquiredBytesReply.self, result, "attachAcquiredBytes")
        try Self.requireCommittedOutcome(reply.outcome, "attachAcquiredBytes")
        return RemoteStoreMirrorMapping.coreSourceVersion(reply.version)
    }

    public func checkpointStreamingMessage(
        chatID: ChatID, handle: String, event: AgentEvent, isDraft: Bool
    ) async throws {
        _ = try await ensureSession()
        let eventHandle = try await stageUpload(
            try JSONEncoder().encode(Self.wireAgentEvent(event)))
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .checkpointStreamingMessage,
            payload: JSONEncoder().encode(
                DaemonCheckpointStreamingMessageRequest(
                    chatID: chatID.rawValue, handle: handle,
                    event: eventHandle, isDraft: isDraft)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonCheckpointStreamingMessageReply.self, result,
            "checkpointStreamingMessage")
        try Self.requireCommittedOutcome(
            reply.outcome, "checkpointStreamingMessage")
    }

    /// The 4-arg overload: no provider/model override rides.
    public func claimNextPersistedChatTurn(
        chatID: ChatID, claimID: ChatTurnClaimID, claimedAt: Date
    ) async throws -> PersistedChatTurn? {
        try await claimNextPersistedChatTurn(
            chatID: chatID, claimID: claimID, claimedAt: claimedAt,
            providerID: nil, modelID: nil)
    }

    /// The 5-arg overload — the DTO carries the override fields losslessly.
    public func claimNextPersistedChatTurn(
        chatID: ChatID, claimID: ChatTurnClaimID, claimedAt: Date,
        providerID: ProviderID?, modelID: ModelID?
    ) async throws -> PersistedChatTurn? {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .claimNextPersistedChatTurn,
            payload: JSONEncoder().encode(
                DaemonClaimNextPersistedChatTurnRequest(
                    chatID: chatID.rawValue, claimID: claimID.rawValue,
                    claimedAt: claimedAt, providerID: providerID?.rawValue,
                    modelID: modelID?.rawValue)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonClaimNextPersistedChatTurnReply.self, result,
            "claimNextPersistedChatTurn")
        try Self.requireCommittedOutcome(
            reply.outcome, "claimNextPersistedChatTurn")
        return reply.turn.map(RemoteStoreMirrorMapping.corePersistedChatTurn)
    }

    /// The full three-overload compose: the 1-arg convenience forwards to
    /// the 4-arg shape (nil body/author/provenance), which is the DTO's
    /// total shape. The reply carries the committed page metadata plus a
    /// body handle — downloaded here so the caller sees the whole page.
    public func createPage(title: String) async throws -> WikiPage {
        try await createPage(title: title, createdBy: nil, provenance: [])
    }

    public func createPage(
        title: String, createdBy: String?, provenance: [PageVersionSourceInput]
    ) async throws -> WikiPage {
        try await createPage(
            title: title, body: "", createdBy: createdBy,
            provenance: provenance)
    }

    public func createPage(
        title: String, body: String, createdBy: String?,
        provenance: [PageVersionSourceInput]
    ) async throws -> WikiPage {
        _ = try await ensureSession()
        let bodyBytes = Data(body.utf8)
        let handle = bodyBytes.isEmpty ? nil : try await stageUpload(bodyBytes)
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .createPage,
            payload: JSONEncoder().encode(DaemonCreatePageRequest(
                title: title, body: handle, createdBy: createdBy,
                provenance: provenance.map(Self.wireVersionSourceInput))),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonCreatePageReply.self, result, "createPage")
        try Self.requireCommittedOutcome(reply.outcome, "createPage")
        let bodyData = try await readHandle(reply.body)
        guard let bodyText = String(data: bodyData, encoding: .utf8) else {
            throw RemoteStoreClientError.malformedReply(
                "createPage body was not UTF-8")
        }
        return WikiPage(
            id: PageID(rawValue: reply.page.id),
            title: reply.page.title,
            slug: reply.page.slug,
            bodyMarkdown: bodyText,
            createdAt: reply.page.createdAt,
            updatedAt: reply.page.updatedAt,
            version: reply.page.version,
            createdBy: reply.page.createdBy,
            lastEditedBy: reply.page.lastEditedBy)
    }

    public func enqueuePersistedChatTurn(
        chatID: ChatID, submission: ChatTurnSubmission
    ) async throws -> PersistedChatTurn {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .enqueuePersistedChatTurn,
            payload: JSONEncoder().encode(DaemonEnqueuePersistedChatTurnRequest(
                chatID: chatID.rawValue,
                submission: RemoteStoreMirrorMapping.wireTurnSubmission(
                    submission))),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonEnqueuePersistedChatTurnReply.self, result,
            "enqueuePersistedChatTurn")
        try Self.requireCommittedOutcome(
            reply.outcome, "enqueuePersistedChatTurn")
        return RemoteStoreMirrorMapping.corePersistedChatTurn(reply.turn)
    }

    /// The 5-arg overload: the store stamps "now" and no usage rides.
    public func finishPersistedChatTurn(
        chatID: ChatID, turnID: ChatTurnID, claimID: ChatTurnClaimID,
        state: ChatTurnPersistenceState, terminalMessage: String?
    ) async throws -> PersistedChatTurn {
        try await finishPersistedChatTurn(
            chatID: chatID, turnID: turnID, claimID: claimID, state: state,
            terminalMessage: terminalMessage, finishedAt: Optional<Date>.none,
            usageOptional: nil)
    }

    /// The 7-arg overload — the DTO distinguishes the two store overloads
    /// by `finishedAt`'s presence, exactly as the executor dispatches.
    public func finishPersistedChatTurn(
        chatID: ChatID, turnID: ChatTurnID, claimID: ChatTurnClaimID,
        state: ChatTurnPersistenceState, terminalMessage: String?,
        finishedAt: Date, usage: ChatTurnUsageValues?
    ) async throws -> PersistedChatTurn {
        try await finishPersistedChatTurn(
            chatID: chatID, turnID: turnID, claimID: claimID, state: state,
            terminalMessage: terminalMessage, finishedAt: Optional(finishedAt),
            usageOptional: usage)
    }

    /// The DTO-shaped private form: `finishedAt == nil` dispatches the
    /// store's 5-arg overload daemon-side (the executor's distinction).
    private func finishPersistedChatTurn(
        chatID: ChatID, turnID: ChatTurnID, claimID: ChatTurnClaimID,
        state: ChatTurnPersistenceState, terminalMessage: String?,
        finishedAt: Date?, usageOptional usage: ChatTurnUsageValues?
    ) async throws -> PersistedChatTurn {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .finishPersistedChatTurn,
            payload: JSONEncoder().encode(DaemonFinishPersistedChatTurnRequest(
                chatID: chatID.rawValue,
                turnID: turnID.rawValue,
                claimID: claimID.rawValue,
                state: DaemonChatTurnPersistenceState(
                    rawValue: state.rawValue) ?? .queued,
                terminalMessage: terminalMessage,
                finishedAt: finishedAt,
                usage: usage.map(RemoteStoreMirrorMapping.wireUsageValues))),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonFinishPersistedChatTurnReply.self, result,
            "finishPersistedChatTurn")
        try Self.requireCommittedOutcome(
            reply.outcome, "finishPersistedChatTurn")
        return RemoteStoreMirrorMapping.corePersistedChatTurn(reply.turn)
    }

    public func recordMarkdownExtraction(
        sourceID: SourceID,
        content: String,
        backend: ExtractionBackend,
        sourceVersionID: SourceVersionID?,
        note: String?,
        modelVersion: String?
    ) async throws -> SourceMarkdownVersion {
        _ = try await ensureSession()
        let handle = try await stageUpload(Data(content.utf8))
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .recordMarkdownExtraction,
            payload: JSONEncoder().encode(
                DaemonRecordMarkdownExtractionRequest(
                    sourceID: sourceID.rawValue, content: handle,
                    backend: backend.rawValue,
                    sourceVersionID: sourceVersionID?.rawValue,
                    note: note, modelVersion: modelVersion)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonRecordMarkdownExtractionReply.self, result,
            "recordMarkdownExtraction")
        try Self.requireCommittedOutcome(
            reply.outcome, "recordMarkdownExtraction")
        return markdownVersionFromHeader(reply.version, content: content)
    }

    /// STRATEGY CAS SAVE — the reply reconstructs the typed save outcome
    /// (committed revision + snapshot, or unchanged).
    public func saveWikiStrategy(
        name: String, instructions: String,
        expectedRevision: WikiStrategyRevision?
    ) async throws -> WikiStrategySaveOutcome {
        _ = try await ensureSession()
        let handle = try await stageUpload(Data(instructions.utf8))
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .saveWikiStrategy,
            payload: JSONEncoder().encode(DaemonSaveWikiStrategyRequest(
                name: name, instructions: handle,
                expectedRevision: expectedRevision?.rawValue)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonSaveWikiStrategyReply.self, result, "saveWikiStrategy")
        try Self.requireCommittedOutcome(reply.outcome, "saveWikiStrategy")
        return RemoteStoreMirrorMapping.coreStrategySaveOutcome(reply.result)
    }

    public func setWorkspaceIndexBody(
        workspaceID: WorkspaceID, indexBody: String, indexBaseVersion: String
    ) async throws {
        _ = try await ensureSession()
        let handle = try await stageUpload(Data(indexBody.utf8))
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .setWorkspaceIndexBody,
            payload: JSONEncoder().encode(DaemonSetWorkspaceIndexBodyRequest(
                workspaceID: workspaceID.rawValue, indexBody: handle,
                indexBaseVersion: indexBaseVersion)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonSetWorkspaceIndexBodyReply.self, result,
            "setWorkspaceIndexBody")
        try Self.requireCommittedOutcome(
            reply.outcome, "setWorkspaceIndexBody")
    }

    /// The three chunk stores encode `[Data]` as the executor's expected
    /// `[String]` base64 JSON behind ONE upload handle (each chunk is a
    /// 512 × Float32 embedding vector).
    public func storePageChunks(id: PageID, chunks: [Data]) async throws {
        _ = try await storeChunks(.storePageChunks, id: id.rawValue, chunks: chunks)
    }

    public func storeSourceChunks(id: SourceID, chunks: [Data]) async throws {
        _ = try await storeChunks(.storeSourceChunks, id: id.rawValue, chunks: chunks)
    }

    public func storeChatChunks(id: ChatID, chunks: [Data]) async throws {
        _ = try await storeChunks(.storeChatChunks, id: id.rawValue, chunks: chunks)
    }

    private func storeChunks(
        _ operation: DaemonStoreOperation, id: String, chunks: [Data]
    ) async throws -> Void {
        _ = try await ensureSession()
        let encoded = chunks.map { $0.base64EncodedString() }
        let handle = try await stageUpload(try JSONEncoder().encode(encoded))
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            operation,
            payload: JSONEncoder().encode(DaemonStorePageChunksRequest(
                id: id, chunks: handle, chunkCount: chunks.count)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonStorePageChunksReply.self, result, operation.rawValue)
        try Self.requireCommittedOutcome(reply.outcome, operation.rawValue)
    }

    public func updatePage(
        id: PageID, title: String, body: String, lastEditedBy: String?,
        provenance: [PageVersionSourceInput]
    ) async throws {
        _ = try await ensureSession()
        let bodyBytes = Data(body.utf8)
        let handle = bodyBytes.isEmpty ? nil : try await stageUpload(bodyBytes)
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .updatePage,
            payload: JSONEncoder().encode(DaemonUpdatePageRequest(
                id: id.rawValue, title: title, body: handle,
                lastEditedBy: lastEditedBy,
                provenance: provenance.map(Self.wireVersionSourceInput))),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonUpdatePageReply.self, result, "updatePage")
        try Self.requireCommittedOutcome(reply.outcome, "updatePage")
    }

    public func updateWikiIndex(body: String) async throws {
        _ = try await ensureSession()
        let handle = try await stageUpload(Data(body.utf8))
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .updateWikiIndex,
            payload: JSONEncoder().encode(DaemonUpdateWikiIndexRequest(
                body: handle)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonUpdateWikiIndexReply.self, result, "updateWikiIndex")
        try Self.requireCommittedOutcome(reply.outcome, "updateWikiIndex")
    }

    public func workspaceWritePage(
        workspaceID: WorkspaceID, pageID: PageID, title: String, body: String,
        author: String?, provenance: [PageVersionSourceInput]
    ) async throws -> PageVersionID? {
        _ = try await ensureSession()
        let bodyBytes = Data(body.utf8)
        let handle = bodyBytes.isEmpty ? nil : try await stageUpload(bodyBytes)
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .workspaceWritePage,
            payload: JSONEncoder().encode(DaemonWorkspaceWritePageRequest(
                workspaceID: workspaceID.rawValue, pageID: pageID.rawValue,
                title: title, body: handle, author: author,
                provenance: provenance.map(Self.wireVersionSourceInput))),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonWorkspaceWritePageReply.self, result, "workspaceWritePage")
        try Self.requireCommittedOutcome(reply.outcome, "workspaceWritePage")
        return reply.versionID.map { PageVersionID(rawValue: $0) }
    }

    // MARK: shared blob helpers

    /// One markdown version from an optional header + optional content
    /// handle (the head/version reads' reply shape). Instance method: the
    /// content handle downloads through the store's own ``readHandle``.
    private func markdownVersion(
        _ header: DaemonSourceMarkdownVersionHeader?,
        contentHandle: DaemonPayloadHandle?,
        operation: String
    ) async throws -> SourceMarkdownVersion? {
        guard let header else { return nil }
        guard let contentHandle else {
            throw RemoteStoreClientError.malformedReply(
                "\(operation) carried a version header with no content handle")
        }
        let bytes = try await readHandle(contentHandle)
        guard let content = String(data: bytes, encoding: .utf8) else {
            throw RemoteStoreClientError.malformedReply(
                "\(operation) content was not UTF-8")
        }
        return RemoteStoreMirrorMapping.coreMarkdownVersion(header, content: content)
    }

    private func markdownVersionFromHeader(
        _ header: DaemonSourceMarkdownVersionHeader, content: String
    ) -> SourceMarkdownVersion {
        // The blob mutators' replies carry the version HEADER only; the
        // daemon stores the submitted content verbatim, so the client
        // reconstructs the full version from what it just sent — no
        // empty-string collapse.
        RemoteStoreMirrorMapping.coreMarkdownVersion(header, content: content)
    }

    static func wireVersionSourceInput(
        _ value: PageVersionSourceInput
    ) -> DaemonPageVersionSourceInput {
        DaemonPageVersionSourceInput(
            sourceID: value.sourceID.rawValue,
            role: DaemonPageVersionSourceRole(
                rawValue: value.role.rawValue) ?? .primary)
    }

    static func wireAgentEvent(_ value: AgentEvent) -> DaemonAgentEvent {
        switch value {
        case .userText(let text):
            return .userText(text: text)
        case .systemInit(let model):
            return .systemInit(model: model)
        case .assistantText(let text):
            return .assistantText(text: text)
        case .thinking(let text):
            return .thinking(text: text)
        case .thinkingDelta(let text):
            return .thinkingDelta(text: text)
        case .assistantTextDelta(let text):
            return .assistantTextDelta(text: text)
        case .toolUse(let name, let inputSummary):
            return .toolUse(name: name, inputSummary: inputSummary)
        case .toolResult(let isError, let summary):
            return .toolResult(isError: isError, summary: summary)
        case .subagent(let subagentType, let description, let isCompletion):
            return .subagent(
                subagentType: subagentType, description: description,
                isCompletion: isCompletion)
        case .result(let isError, let text):
            return .result(isError: isError, text: text)
        case .messageStop:
            return .messageStop
        case .turnFailed(let reason):
            return .turnFailed(reason: Self.wireTurnFailureReason(reason))
        case .raw(let line):
            return .raw(line: line)
        }
    }

    static func wireTurnFailureReason(
        _ value: TurnFailureReason
    ) -> DaemonTurnFailureReason {
        switch value {
        case .stalled(let idleSeconds):
            return .stalled(idleSeconds: idleSeconds)
        case .ceilingExceeded(let totalSeconds):
            return .ceilingExceeded(totalSeconds: totalSeconds)
        case .agentError(let message):
            return .agentError(message: message)
        case .quotaExhausted(let provider, let resetTime):
            return .quotaExhausted(
                providerID: provider.rawValue, resetTime: resetTime)
        }
    }
}
#endif
