#if os(macOS)
import Foundation
import WikiDaemonContract
import WikiFSCore
import WikiFSTypes

// MARK: - Client-side mirror mappings (the executor's inverses)
//
// Slice 2 of plans/daemon-only-access.md. Every mapping here is the exact
// inverse of the daemon executor's `DaemonStoreMirrorMapping`
// (Sources/wikid/DaemonStoreCommandExecutor.swift): core values in for
// request encoding, core values out for reply decoding, associated values
// intact — deliberate collapses: NONE. The contract module stays
// dependency-free, so the wire mirrors live there and these mappings bridge
// to the core types.
//
// Enum mirrors share raw values with the domain, so enum mappings are total
// with the same fallback the executor uses. Identity strings the core types
// validate (package producers, OKF verifier identities) reconstruct through
// the core throwing initializers: a malformed value is a typed rejection,
// never a silent default.

enum RemoteStoreMirrorMapping {

    // MARK: sources

    static func coreSourceVersion(_ value: DaemonSourceVersion) -> SourceVersion {
        SourceVersion(
            id: SourceVersionID(rawValue: value.id),
            sourceID: SourceID(rawValue: value.sourceID),
            parentID: value.parentID.map(SourceVersionID.init(rawValue:)),
            blobHash: value.blobHash,
            mimeType: value.mimeType,
            activityID: value.activityID,
            externalIdentity: value.externalIdentity,
            fetchedAt: value.fetchedAt)
    }

    static func coreSourceOrigin(_ value: DaemonSourceOrigin) -> SourceOrigin {
        SourceOrigin(
            versionID: SourceVersionID(rawValue: value.versionID),
            agentName: value.agentName,
            agentKind: value.agentKind,
            activityKind: value.activityKind,
            plan: value.plan,
            externalRef: value.externalRef,
            externalIdentity: value.externalIdentity,
            runTitle: value.runTitle,
            fetchedAt: value.fetchedAt)
    }

    // MARK: extraction provenance

    static func coreExtractionProvenance(
        _ value: DaemonExtractionProvenance
    ) throws -> ExtractionProvenance {
        ExtractionProvenance(
            markdownVersionID: SourceMarkdownVersionID(
                rawValue: value.markdownVersionID),
            sourceID: SourceID(rawValue: value.sourceID),
            origin: SourceMarkdownOrigin(rawValue: value.origin.rawValue)
                ?? .extraction,
            producer: try value.producer.map(coreProducer),
            providerID: value.providerID.map(ProviderID.init(rawValue:)),
            modelID: value.modelID.map(ModelID.init(rawValue:)),
            toolVersion: value.toolVersion,
            createdAt: value.createdAt,
            sourceVersionID: value.sourceVersionID.map(
                SourceVersionID.init(rawValue:)))
    }

    /// Reverse producer mapping. `.hostSpeech` is a typed rejection: the wire
    /// mirror carries the acquisition fetcher as ONE identity string (the
    /// registration id), but the core producer needs the fetcher's exact
    /// package identity the mirror dropped — the daemon never emits it, and
    /// an honest reconstruction does not exist without a contract change.
    static func coreProducer(
        _ value: DaemonExtractionProducer
    ) throws -> ExtractionProducer {
        switch value {
        case .backend(let rawBackend):
            guard let backend = ExtractionBackend(rawValue: rawBackend) else {
                throw WikiStoreError.unexpected(
                    "producer backend is not a known ExtractionBackend raw "
                        + "value: \(rawBackend)")
            }
            return .backend(backend)
        case .tool(let rawTool):
            guard let tool = ExtractionTool(rawValue: rawTool) else {
                throw WikiStoreError.unexpected(
                    "producer tool is not a known ExtractionTool raw value: "
                        + rawTool)
            }
            return .tool(tool)
        case .legacy(let rawTechnique):
            return .legacy(rawTechnique: rawTechnique)
        case .installedPackage(let package):
            return .installedPackage(try corePackageProducer(package))
        case .hostSpeech:
            throw WikiStoreError.unexpected(
                "the host-speech producer mirror carries the acquisition "
                    + "fetcher as one identity string without the exact "
                    + "package identity the core producer requires")
        }
    }

    /// Reverse package-identity reconstruction (the mirror carries the exact
    /// immutable identity fields): total except for validation failures.
    static func corePackageProducer(
        _ value: DaemonExtractorPackageProducer
    ) throws -> ExtractorPackageExecutionProvenance {
        func validated<T>(_ build: () throws -> T, _ what: String,
                          _ raw: String) throws -> T {
            do {
                return try build()
            } catch {
                throw WikiStoreError.unexpected(
                    "package producer carries an invalid \(what): \(raw)"
                        + " - " + String(describing: error))
            }
        }
        let packageID = try validated(
            { try ExtractorPackageID(validating: value.packageID) },
            "package id", value.packageID)
        let version = try validated(
            { try ExtractorPackageVersion(validating: value.version) },
            "package version", value.version)
        let digest = try validated(
            { try ExtractorPackageDigest(hex: value.digestHex) },
            "package digest", value.digestHex)
        let registrationID = try validated(
            { try ExtractorRegistrationID(validating: value.registrationID) },
            "registration id", value.registrationID)
        guard let rawRevision = Int(value.protocolRevision),
              let protocolRevision = ExtractorProtocolRevision(
                rawValue: rawRevision) else {
            throw WikiStoreError.unexpected(
                "package producer carries an invalid protocol revision: "
                    + value.protocolRevision)
        }
        let reportedMetadata: ExtractorReportedMetadata
        do {
            reportedMetadata = try ExtractorReportedMetadata(
                toolName: value.reportedMetadata.toolName,
                toolVersion: value.reportedMetadata.toolVersion,
                modelName: value.reportedMetadata.modelName,
                modelVersion: value.reportedMetadata.modelVersion,
                language: value.reportedMetadata.language,
                transcriptGenerated: value.reportedMetadata.transcriptGenerated)
        } catch {
            throw WikiStoreError.unexpected(
                "package producer carries invalid reported metadata: "
                    + String(describing: error))
        }
        return ExtractorPackageExecutionProvenance(
            revision: ExtractorPackageRevisionID(
                packageID: packageID, version: version, digest: digest),
            registrationID: registrationID,
            protocolRevision: protocolRevision,
            reportedMetadata: reportedMetadata)
    }

    // MARK: extraction alternatives (header + bulk content handle)

    /// Rebuild one alternative from its wire header and its full content
    /// (the `[versionID: content]` handle the daemon committed before
    /// paginating). The header's wrapped-version fields plus the content
    /// reassemble the core `SourceMarkdownVersion` exactly.
    static func coreAlternative(
        _ header: DaemonExtractionAlternative, content: String
    ) throws -> ExtractionAlternative {
        let version = coreMarkdownVersion(header.version, content: content)
        return ExtractionAlternative(
            version: version,
            backendDisplayName: header.backendDisplayName,
            agentName: header.agentName,
            modelVersion: header.modelVersion,
            package: try header.package.map(corePackageProducer),
            charCount: header.charCount,
            isActive: header.isActive)
    }

    /// One markdown version from its wire header + bulk content.
    static func coreMarkdownVersion(
        _ header: DaemonSourceMarkdownVersionHeader, content: String
    ) -> SourceMarkdownVersion {
        SourceMarkdownVersion(
            id: SourceMarkdownVersionID(rawValue: header.id),
            sourceID: SourceID(rawValue: header.sourceID),
            parentID: header.parentID.map(SourceMarkdownVersionID.init(rawValue:)),
            content: content,
            origin: SourceMarkdownOrigin(rawValue: header.origin.rawValue)
                ?? .extraction,
            note: header.note,
            createdAt: header.createdAt,
            activityID: header.activityID,
            sourceVersionID: header.sourceVersionID.map(
                SourceVersionID.init(rawValue:)),
            blobHash: header.blobHash,
            mimeType: header.mimeType,
            technique: header.technique)
    }

    // MARK: chats

    static func coreChatMessage(_ value: DaemonChatMessage) -> ChatMessage {
        ChatMessage(
            id: PageID(rawValue: value.id),
            chatID: ChatID(rawValue: value.chatID),
            seq: value.seq,
            event: coreAgentEvent(value.event),
            createdAt: value.createdAt,
            isDraft: value.isDraft)
    }

    static func coreAgentEvent(_ value: DaemonAgentEvent) -> AgentEvent {
        switch value {
        case .userText(let text):
            return .userText(text)
        case .systemInit(let model):
            return .systemInit(model: model)
        case .assistantText(let text):
            return .assistantText(text)
        case .thinking(let text):
            return .thinking(text)
        case .thinkingDelta(let text):
            return .thinkingDelta(text)
        case .assistantTextDelta(let text):
            return .assistantTextDelta(text)
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
            return .turnFailed(reason: coreTurnFailureReason(reason))
        case .raw(let line):
            return .raw(line)
        }
    }

    static func coreTurnFailureReason(
        _ value: DaemonTurnFailureReason
    ) -> TurnFailureReason {
        switch value {
        case .stalled(let idleSeconds):
            return .stalled(idleSeconds: idleSeconds)
        case .ceilingExceeded(let totalSeconds):
            return .ceilingExceeded(totalSeconds: totalSeconds)
        case .agentError(let message):
            return .agentError(message)
        case .quotaExhausted(let providerID, let resetTime):
            return .quotaExhausted(
                provider: ProviderID(rawValue: providerID), resetTime: resetTime)
        }
    }

    static func coreChatUsageSummary(
        _ value: DaemonChatUsageSummary
    ) -> ChatUsageSummary {
        ChatUsageSummary(
            latestTurn: value.latestTurn.map(coreChatTurnUsage),
            inputTokens: value.inputTokens,
            outputTokens: value.outputTokens,
            thoughtTokens: value.thoughtTokens,
            cacheReadTokens: value.cacheReadTokens,
            cacheWriteTokens: value.cacheWriteTokens,
            cost: value.cost,
            currency: value.currency)
    }

    static func coreChatTurnUsage(_ value: DaemonChatTurnUsage) -> ChatTurnUsage {
        ChatTurnUsage(
            turnID: ChatTurnID(rawValue: value.turnID),
            providerID: value.providerID.map(ProviderID.init(rawValue:)),
            modelID: value.modelID.map(ModelID.init(rawValue:)),
            startedAt: value.startedAt,
            finishedAt: value.finishedAt,
            state: ChatTurnPersistenceState(rawValue: value.state.rawValue)
                ?? .queued,
            inputTokens: value.inputTokens,
            outputTokens: value.outputTokens,
            thoughtTokens: value.thoughtTokens,
            cacheReadTokens: value.cacheReadTokens,
            cacheWriteTokens: value.cacheWriteTokens,
            cost: value.cost,
            currency: value.currency)
    }

    static func corePersistedChatTurn(
        _ value: DaemonPersistedChatTurn
    ) -> PersistedChatTurn {
        PersistedChatTurn(
            chatID: ChatID(rawValue: value.chatID),
            ordinal: value.ordinal,
            submission: coreTurnSubmission(value.submission),
            editedAt: value.editedAt,
            state: ChatTurnPersistenceState(rawValue: value.state.rawValue)
                ?? .queued,
            claimID: value.claimID.map(ChatTurnClaimID.init(rawValue:)),
            claimedAt: value.claimedAt,
            providerSubmittedAt: value.providerSubmittedAt,
            providerSessionID: value.providerSessionID.map(
                AcpSessionID.init(rawValue:)),
            terminalMessage: value.terminalMessage,
            providerID: value.providerID.map(ProviderID.init(rawValue:)),
            modelID: value.modelID.map(ModelID.init(rawValue:)),
            finishedAt: value.finishedAt,
            usage: coreUsageValues(value.usage))
    }

    static func coreTurnSubmission(
        _ value: DaemonChatTurnSubmission
    ) -> ChatTurnSubmission {
        ChatTurnSubmission(
            commandID: ChatCommandID(rawValue: value.commandID),
            turnID: ChatTurnID(rawValue: value.turnID),
            userText: value.userText,
            contextReferences: value.contextReferences.map { reference in
                switch reference {
                case .page(let id):
                    return .page(PageID(rawValue: id))
                case .source(let id):
                    return .source(SourceID(rawValue: id))
                case .chat(let id):
                    return .chat(ChatID(rawValue: id))
                }
            },
            submittedAt: value.submittedAt)
    }

    static func coreUsageValues(
        _ value: DaemonChatTurnUsageValues
    ) -> ChatTurnUsageValues {
        ChatTurnUsageValues(
            inputTokens: value.inputTokens,
            outputTokens: value.outputTokens,
            thoughtTokens: value.thoughtTokens,
            cacheReadTokens: value.cacheReadTokens,
            cacheWriteTokens: value.cacheWriteTokens,
            cost: value.cost,
            currency: value.currency)
    }

    static func coreAttachmentTarget(
        _ value: DaemonChatAttachmentTarget
    ) -> ChatAttachmentTarget {
        switch value {
        case .page(let id):
            return .page(PageID(rawValue: id))
        case .source(let id):
            return .source(SourceID(rawValue: id))
        case .chat(let id):
            return .chat(ChatID(rawValue: id))
        }
    }

    static func coreTranscriptCursor(
        _ value: DaemonChatTranscriptCursor
    ) -> ChatTranscriptCursor {
        ChatTranscriptCursor(rawValue: value.rawValue)
    }

    /// Typed transcript items (mirror → core) — same mapping the executor
    /// uses for requests, reused for the persisted-transcript reads.
    static func coreTranscriptItem(
        _ value: DaemonChatTranscriptItem
    ) -> ChatTranscriptItem {
        switch value {
        case .message(let item):
            return .message(ChatTranscriptMessageItem(
                messageID: ChatMessageID(rawValue: item.messageID),
                turnID: ChatTurnID(rawValue: item.turnID),
                role: ChatTranscriptMessageRole(
                    rawValue: item.role.rawValue) ?? .user,
                text: item.text, createdAt: item.createdAt))
        case .toolCall(let item):
            return .toolCall(ChatTranscriptToolCallItem(
                toolCallID: ToolCallID(rawValue: item.toolCallID),
                turnID: ChatTurnID(rawValue: item.turnID),
                toolName: item.toolName,
                status: ChatToolCallStatus(
                    rawValue: item.status.rawValue) ?? .pending,
                detail: item.detail, output: item.output,
                permissionRequestID: item.permissionRequestID.map(
                    PermissionRequestID.init(rawValue:)),
                updatedAt: item.updatedAt))
        case .systemNotice(let item):
            return .systemNotice(ChatTranscriptSystemNoticeItem(
                noticeID: ChatTranscriptNoticeID(rawValue: item.noticeID),
                turnID: item.turnID.map(ChatTurnID.init(rawValue:)),
                kind: ChatSystemNoticeKind(
                    rawValue: item.kind.rawValue) ?? .session,
                title: item.title, message: item.message,
                createdAt: item.createdAt))
        case .turnFailure(let item):
            return .turnFailure(ChatTranscriptTurnFailureItem(
                failureID: ChatTranscriptFailureID(rawValue: item.failureID),
                turnID: ChatTurnID(rawValue: item.turnID),
                category: ChatTurnFailureCategory(
                    rawValue: item.category.rawValue) ?? .runtimeError,
                message: item.message, createdAt: item.createdAt))
        }
    }

    static func corePersistedTranscriptItem(
        _ value: DaemonPersistedChatTranscriptItem
    ) -> PersistedChatTranscriptItem {
        PersistedChatTranscriptItem(
            cursor: coreTranscriptCursor(value.cursor),
            item: coreTranscriptItem(value.item),
            projectedEventJSON: value.projectedEventJSON,
            projectedPlainText: value.projectedPlainText,
            createdAt: value.createdAt,
            summary: value.summary)
    }

    // MARK: pages

    static func corePageVersionSummary(
        _ value: DaemonPageVersionSummary
    ) -> PageVersionSummary {
        PageVersionSummary(
            id: PageVersionID(rawValue: value.id),
            pageID: PageID(rawValue: value.pageID),
            parentID: value.parentID.map(PageVersionID.init(rawValue:)),
            mergeParentID: value.mergeParentID.map(PageVersionID.init(rawValue:)),
            blobHash: value.blobHash,
            title: value.title,
            activityID: value.activityID,
            savedAt: value.savedAt)
    }

    static func coreCitedPage(_ value: DaemonCitedPage) -> CitedPage {
        CitedPage(
            pageID: PageID(rawValue: value.pageID), title: value.title)
    }

    static func corePageOrigin(_ value: DaemonPageOrigin) -> PageOrigin {
        PageOrigin(
            versionID: PageVersionID(rawValue: value.versionID),
            title: value.title,
            blobHash: value.blobHash,
            agentName: PageAuthor(rawValue: value.agentName.rawValue),
            agentKind: AgentKind(rawValue: value.agentKind),
            activityKind: ActivityKind(rawValue: value.activityKind),
            plan: value.plan,
            externalRef: value.externalRef,
            runTitle: value.runTitle,
            savedAt: value.savedAt)
    }

    // MARK: strategy

    static func coreStrategySnapshot(
        _ value: DaemonStrategySnapshot
    ) -> WikiStrategy {
        WikiStrategy(
            name: value.name,
            instructions: value.instructions,
            revision: WikiStrategyRevision(rawValue: value.revision),
            updatedAt: value.updatedAt)
    }

    static func coreWikiStrategyState(
        _ value: DaemonWikiStrategyState
    ) -> WikiStrategyState {
        WikiStrategyState(
            strategy: value.strategy.map(coreStrategySnapshot),
            revision: value.revision.map(WikiStrategyRevision.init(rawValue:)))
    }

    static func coreStrategySaveOutcome(
        _ value: DaemonWikiStrategySaveOutcome
    ) -> WikiStrategySaveOutcome {
        switch value {
        case .saved(let revision, let strategy):
            return .saved(
                revision: WikiStrategyRevision(rawValue: revision),
                strategy: strategy.map(coreStrategySnapshot))
        case .unchanged:
            return .unchanged
        }
    }

    // MARK: workspaces

    static func coreWorkspaceSummary(
        _ value: DaemonWorkspaceSummary
    ) -> WorkspaceSummary {
        WorkspaceSummary(
            id: WorkspaceID(rawValue: value.id),
            name: value.name,
            status: WorkspaceStatus(rawValue: value.status.rawValue) ?? .open,
            activityID: value.activityID,
            createdAt: value.createdAt,
            updatedAt: value.updatedAt)
    }

    static func coreWorkspaceRef(_ value: DaemonWorkspaceRef) -> WorkspaceRef {
        WorkspaceRef(
            workspaceID: WorkspaceID(rawValue: value.workspaceID),
            ownerID: PageID(rawValue: value.ownerID),
            baseVersionID: value.baseVersionID.map(PageVersionID.init(rawValue:)),
            versionID: value.versionID.map(PageVersionID.init(rawValue:)),
            blobHash: value.blobHash,
            title: value.title,
            updatedAt: value.updatedAt)
    }

    static func coreWorkspaceConflict(
        _ value: DaemonWorkspaceConflict
    ) -> WorkspaceConflict {
        WorkspaceConflict(
            workspaceID: WorkspaceID(rawValue: value.workspaceID),
            pageID: PageID(rawValue: value.pageID),
            baseVersionID: value.baseVersionID.map(PageVersionID.init(rawValue:)),
            mainVersionID: value.mainVersionID.map(PageVersionID.init(rawValue:)),
            workspaceTarget: coreWorkspaceConflictTarget(value.workspaceTarget),
            createdAt: value.createdAt)
    }

    static func coreWorkspaceConflictTarget(
        _ value: DaemonWorkspaceConflictTarget
    ) -> WorkspaceConflict.Target {
        switch value {
        case .pageVersion(let id):
            return .pageVersion(PageVersionID(rawValue: id))
        case .stagedBlob(let hash):
            return .stagedBlob(hash)
        }
    }

    // MARK: log + bookmarks

    static func coreLogEntry(_ value: DaemonLogEntry) -> LogEntry {
        LogEntry(
            id: PageID(rawValue: value.id),
            timestamp: value.timestamp,
            kind: LogEntry.Kind(rawValue: value.kind.rawValue) ?? .ingest,
            title: value.title,
            note: value.note)
    }

    static func coreBookmarkNode(_ value: DaemonBookmarkNode) -> BookmarkNode {
        BookmarkNode(
            id: BookmarkID(rawValue: value.id),
            parentID: value.parentID.map(BookmarkID.init(rawValue:)),
            position: value.position,
            content: coreBookmarkContent(value.content),
            createdAt: value.createdAt,
            updatedAt: value.updatedAt)
    }

    static func coreBookmarkContent(
        _ value: DaemonBookmarkContent
    ) -> BookmarkNode.Content {
        switch value {
        case .folder(let label):
            return .folder(label: label)
        case .page(let id):
            return .page(PageID(rawValue: id))
        case .source(let id):
            return .source(SourceID(rawValue: id))
        case .chat(let id):
            return .chat(ChatID(rawValue: id))
        }
    }

    // MARK: renderer settings

    static func coreRendererSourcePreference(
        _ value: DaemonRendererSourcePreference
    ) throws -> RendererSourcePreference {
        RendererSourcePreference(
            sourceID: SourceID(rawValue: value.sourceID),
            preference: try corePreference(value.preference),
            updatedAt: try coreRFC3339Timestamp(
                value.updatedAtRFC3339, operation: "rendererSourcePreference"))
    }

    static func coreRendererSourcePresentation(
        _ value: DaemonRendererSourcePresentation
    ) throws -> RendererSourcePresentation {
        RendererSourcePresentation(
            sourceID: SourceID(rawValue: value.sourceID),
            presentation: RendererSourcePresentationMode(
                rawValue: value.presentation.rawValue) ?? .source,
            updatedAt: try coreRFC3339Timestamp(
                value.updatedAtRFC3339,
                operation: "rendererSourcePresentation"))
    }

    /// The core RFC 3339 timestamp validates its offset-bearing format; a
    /// malformed wire value is a typed reconstruction failure.
    static func coreRFC3339Timestamp(
        _ raw: String, operation: String
    ) throws -> RFC3339Timestamp {
        guard let timestamp = RFC3339Timestamp(rawValue: raw) else {
            throw WikiStoreError.unexpected(
                "\(operation) reply carries a malformed RFC 3339 timestamp: "
                    + raw)
        }
        return timestamp
    }

    /// Reverse preference reference: the core identity initializers parse,
    /// so a malformed string is a typed rejection (the executor mirrors this
    /// validation daemon-side).
    static func corePreference(
        _ value: DaemonRendererPreferenceReference
    ) throws -> RendererPreferenceReference {
        func packageID(_ raw: String) throws -> RendererPackageID {
            guard let id = RendererPackageID(rawValue: raw) else {
                throw WikiStoreError.unexpected(
                    "renderer preference carries an invalid package id: " + raw)
            }
            return id
        }
        func registrationID(_ raw: String) throws -> RendererRegistrationID {
            guard let id = RendererRegistrationID(rawValue: raw) else {
                throw WikiStoreError.unexpected(
                    "renderer preference carries an invalid registration id: "
                        + raw)
            }
            return id
        }
        switch value {
        case .exact(let reference):
            guard let version = RendererPackageVersion(
                rawValue: reference.version) else {
                throw WikiStoreError.unexpected(
                    "renderer preference carries an invalid package version: "
                        + reference.version)
            }
            return .exact(RendererReference(
                packageID: try packageID(reference.packageID),
                version: version,
                registrationID: try registrationID(reference.registrationID)))
        case .logical(let reference):
            return .logical(LogicalRendererReference(
                packageID: try packageID(reference.packageID),
                registrationID: try registrationID(reference.registrationID)))
        }
    }

    /// Core → wire bridge input. `.inlineArtifact` is a typed rejection: the
    /// block-id mirror carries no parser ordinal (see the executor's
    /// `coreRendererInput` — the same limitation binds both directions).
    static func wireRendererInput(
        _ value: RendererBridgeInput
    ) throws -> DaemonRendererBridgeInput {
        switch value {
        case .source(let versionID):
            return .source(versionID: versionID.rawValue)
        case .markdown(let versionID):
            return .markdown(versionID: versionID.rawValue)
        case .inlineArtifact:
            throw WikiStoreError.unexpected(
                "rendererInputByteCount(.inlineArtifact) is not served over "
                    + "the wire yet: the block-id mirror carries no parser "
                    + "ordinal to reconstruct the validated artifact")
        }
    }

    // MARK: embed descriptors

    static func coreSourceEmbedDescriptor(
        _ value: DaemonSourceEmbedDescriptor
    ) -> SourceEmbedDescriptor {
        SourceEmbedDescriptor(
            id: SourceID(rawValue: value.id),
            mimeType: value.mimeType,
            externalIdentity: value.externalIdentity,
            agentName: value.agentName,
            planURL: value.planURL)
    }

    // MARK: vacuum reports + MIME repair

    static func coreBlobVacuumReport(
        _ value: DaemonBlobVacuumReport
    ) -> BlobVacuumReport {
        BlobVacuumReport(
            orphanCount: value.orphanCount,
            bytesReclaimed: value.bytesReclaimed,
            applied: value.applied)
    }

    static func coreActivityVacuumReport(
        _ value: DaemonActivityVacuumReport
    ) -> ActivityVacuumReport {
        ActivityVacuumReport(
            orphanCount: value.orphanCount, applied: value.applied)
    }

    static func corePageVersionVacuumReport(
        _ value: DaemonPageVersionVacuumReport
    ) -> PageVersionVacuumReport {
        PageVersionVacuumReport(
            deletedCount: value.deletedCount, applied: value.applied)
    }

    static func coreMIMERepairReport(
        _ value: DaemonMIMERepairReport
    ) throws -> MIMERepairReport {
        MIMERepairReport(
            scannedCount: value.scannedCount,
            repairableCount: value.repairableCount,
            updatedCount: value.updatedCount,
            skippedBytelessCount: value.skippedBytelessCount,
            skippedInconclusiveCount: value.skippedInconclusiveCount,
            applied: value.applied,
            items: try value.items.map(coreMIMERepairItem))
    }

    static func coreMIMERepairItem(
        _ value: DaemonMIMERepairItem
    ) throws -> MIMERepairItem {
        MIMERepairItem(
            sourceID: SourceID(rawValue: value.sourceID),
            sourceVersionID: SourceVersionID(rawValue: value.sourceVersionID),
            filename: value.filename,
            nullState: MIMERepairNullState(
                rawValue: value.nullState.rawValue) ?? .neither,
            oldSourceMIMEType: value.oldSourceMIMEType,
            oldVersionMIMEType: value.oldVersionMIMEType,
            newMIMEType: value.newMIMEType,
            detection: try coreDetectionResult(value.detection),
            status: MIMERepairStatus(rawValue: value.status.rawValue)
                ?? .inconclusive,
            updated: value.updated)
    }

    /// Detection-result reconstruction bridges through the core type's
    /// public Codable conformance: the wire mirror's field names and enum
    /// raw values are IDENTICAL to the core shapes by wire-format
    /// construction (that is why the mirror exists), so the mirror's JSON
    /// decodes directly as the core value. This is also the only honest
    /// route — `ContentTypeConflict` exposes no cross-module memberwise
    /// init. A raw value the core enum does not know is a typed decode
    /// failure, never a silent default.
    static func coreDetectionResult(
        _ value: DaemonContentTypeDetectionResult
    ) throws -> ContentTypeDetectionResult {
        let mirrorJSON = try JSONEncoder().encode(value)
        do {
            return try JSONDecoder().decode(
                ContentTypeDetectionResult.self, from: mirrorJSON)
        } catch {
            throw WikiStoreError.unexpected(
                "MIME repair detection result could not be reconstructed: "
                    + String(describing: error))
        }
    }

    // MARK: OKF trust (mirror → core)

    /// Reverse verifier mapping: the core initializer PARSES the raw identity
    /// string, so the mirror's kind/name/version fields must agree with the
    /// parse — a mismatch is a typed rejection, never a silent
    /// reinterpretation.
    static func coreVerifier(
        _ value: DaemonOKFVerifierIdentity
    ) throws -> OKFVerifierIdentity {
        let parsed: OKFVerifierIdentity
        do {
            parsed = try OKFVerifierIdentity(value.rawValue)
        } catch {
            throw WikiStoreError.unexpected(
                "OKF verifier identity is not parseable: \(value.rawValue)")
        }
        let mirrorKind = OKFVerifierIdentity.Kind(
            rawValue: value.kind.rawValue) ?? .process
        guard parsed.kind == mirrorKind, parsed.name == value.name,
              parsed.version == value.version else {
            throw WikiStoreError.unexpected(
                "OKF verifier mirror fields disagree with the parsed raw "
                    + "identity \(value.rawValue)")
        }
        return parsed
    }

    static func coreBasis(_ value: DaemonOKFVerificationBasis) -> OKFVerificationBasis {
        // The core basis stamps its own current version at construction;
        // the wire's version field is diagnostic only.
        OKFVerificationBasis(
            kind: OKFVerificationBasisKind(
                rawValue: value.kind.rawValue) ?? .sourceChecked,
            evidence: value.evidence.map { reference in
                switch reference {
                case .source(let id):
                    return .source(SourceID(rawValue: id))
                case .external(let url):
                    return .external(URL(string: url) ?? URL(fileURLWithPath: "/"))
                }
            },
            note: value.note)
    }

    static func coreFreshness(_ value: DaemonOKFFreshnessPolicy) -> OKFFreshnessPolicy {
        switch value {
        case .fixed(let date):
            return .fixed(date)
        case .ttl(let seconds, let anchor):
            switch anchor {
            case .generated:
                return .ttl(seconds: seconds, anchor: .generated)
            case .verification(let id):
                return .ttl(seconds: seconds, anchor: .verification(
                    OKFVerificationID(rawValue: id)))
            case .recordedVerification:
                return .ttl(seconds: seconds, anchor: .recordedVerification)
            }
        }
    }

    static func coreCorrectionReason(
        _ value: DaemonOKFVerificationCorrectionReason
    ) -> OKFVerificationCorrectionReason {
        OKFVerificationCorrectionReason(reason: value.reason)
    }

    static func coreVerificationEvent(
        _ value: DaemonOKFVerificationEvent
    ) throws -> OKFVerificationEvent {
        OKFVerificationEvent(
            id: OKFVerificationID(rawValue: value.id),
            by: try coreVerifier(value.by),
            verifiedAt: value.verifiedAt,
            basis: coreBasis(value.basis),
            removedAt: value.removedAt,
            correctionActivityID: value.correctionActivityID.map(
                OKFActivityID.init(rawValue:)),
            correctedBy: try value.correctedBy.map(coreVerifier),
            correctionReason: value.correctionReason.map(coreCorrectionReason))
    }

    static func coreOKFConceptMetadata(
        _ value: DaemonOKFConceptMetadata
    ) throws -> OKFConceptMetadata {
        OKFConceptMetadata(
            status: value.status.map {
                OKFConceptStatus(rawValue: $0.rawValue) ?? .draft
            },
            staleAfter: value.staleAfter,
            freshnessPolicy: value.freshnessPolicy.map(coreFreshness),
            verifications: try value.verifications.map(coreVerificationEvent),
            projectionRevision: value.projectionRevision)
    }

    // MARK: OKF trust (core → wire, the request direction)

    static func wireVerifier(
        _ value: OKFVerifierIdentity
    ) -> DaemonOKFVerifierIdentity {
        DaemonOKFVerifierIdentity(
            rawValue: value.rawValue,
            kind: DaemonOKFVerifierKind(rawValue: value.kind.rawValue) ?? .process,
            name: value.name, version: value.version)
    }

    static func wireBasis(
        _ value: OKFVerificationBasis
    ) -> DaemonOKFVerificationBasis {
        DaemonOKFVerificationBasis(
            version: value.version,
            kind: DaemonOKFVerificationBasisKind(
                rawValue: value.kind.rawValue) ?? .sourceChecked,
            evidence: value.evidence.map { reference in
                switch reference {
                case .source(let id):
                    return .source(id: id.rawValue)
                case .external(let url):
                    return .external(url: url.absoluteString)
                }
            },
            note: value.note)
    }

    static func wireFreshness(
        _ value: OKFFreshnessPolicy
    ) -> DaemonOKFFreshnessPolicy {
        switch value {
        case .fixed(let date):
            return .fixed(date: date)
        case .ttl(let seconds, let anchor):
            return .ttl(seconds: seconds, anchor: wireFreshnessAnchor(anchor))
        }
    }

    static func wireFreshnessAnchor(
        _ value: OKFFreshnessAnchor
    ) -> DaemonOKFFreshnessAnchor {
        switch value {
        case .generated:
            return .generated
        case .verification(let id):
            return .verification(id: id.rawValue)
        case .recordedVerification:
            return .recordedVerification
        }
    }

    static func wireCorrectionReason(
        _ value: OKFVerificationCorrectionReason
    ) -> DaemonOKFVerificationCorrectionReason {
        DaemonOKFVerificationCorrectionReason(
            version: value.version, reason: value.reason)
    }

    // MARK: request-direction value wiring (core → wire)

    static func wireParsedLink(_ value: ParsedLink) -> DaemonParsedLink {
        DaemonParsedLink(
            linkType: DaemonParsedLinkType(
                rawValue: value.linkType.rawValue) ?? .page,
            target: value.target,
            fragment: value.fragment,
            linkText: value.linkText,
            isEmbed: value.isEmbed,
            versionPin: value.versionPin)
    }

    static func wireBookmarkContent(
        _ value: BookmarkNode.Content
    ) -> DaemonBookmarkContent {
        switch value {
        case .folder(let label):
            return .folder(label: label)
        case .page(let id):
            return .page(id: id.rawValue)
        case .source(let id):
            return .source(id: id.rawValue)
        case .chat(let id):
            return .chat(id: id.rawValue)
        }
    }

    static func wirePreference(
        _ value: RendererPreferenceReference
    ) -> DaemonRendererPreferenceReference {
        switch value {
        case .exact(let reference):
            return .exact(DaemonRendererReference(
                packageID: reference.packageID.rawValue,
                version: reference.version.rawValue,
                registrationID: reference.registrationID.rawValue))
        case .logical(let reference):
            return .logical(DaemonLogicalRendererReference(
                packageID: reference.packageID.rawValue,
                registrationID: reference.registrationID.rawValue))
        }
    }

    static func wireTurnSubmission(
        _ value: ChatTurnSubmission
    ) -> DaemonChatTurnSubmission {
        DaemonChatTurnSubmission(
            commandID: value.commandID.rawValue,
            turnID: value.turnID.rawValue,
            userText: value.userText,
            contextReferences: value.contextReferences.map { reference in
                switch reference {
                case .page(let id):
                    return .page(id: id.rawValue)
                case .source(let id):
                    return .source(id: id.rawValue)
                case .chat(let id):
                    return .chat(id: id.rawValue)
                }
            },
            submittedAt: value.submittedAt)
    }

    static func wireUsageValues(
        _ value: ChatTurnUsageValues
    ) -> DaemonChatTurnUsageValues {
        DaemonChatTurnUsageValues(
            inputTokens: value.inputTokens,
            outputTokens: value.outputTokens,
            thoughtTokens: value.thoughtTokens,
            cacheReadTokens: value.cacheReadTokens,
            cacheWriteTokens: value.cacheWriteTokens,
            cost: value.cost,
            currency: value.currency)
    }

    static func wireTranscriptItem(
        _ value: ChatTranscriptItem
    ) -> DaemonChatTranscriptItem {
        switch value {
        case .message(let item):
            return .message(DaemonChatTranscriptMessageItem(
                messageID: item.messageID.rawValue,
                turnID: item.turnID.rawValue,
                role: DaemonChatTranscriptMessageRole(
                    rawValue: item.role.rawValue) ?? .user,
                text: item.text, createdAt: item.createdAt))
        case .toolCall(let item):
            return .toolCall(DaemonChatTranscriptToolCallItem(
                toolCallID: item.toolCallID.rawValue,
                turnID: item.turnID.rawValue,
                toolName: item.toolName,
                status: DaemonChatToolCallStatus(
                    rawValue: item.status.rawValue) ?? .pending,
                detail: item.detail, output: item.output,
                permissionRequestID: item.permissionRequestID?.rawValue,
                updatedAt: item.updatedAt))
        case .systemNotice(let item):
            return .systemNotice(DaemonChatTranscriptSystemNoticeItem(
                noticeID: item.noticeID.rawValue,
                turnID: item.turnID?.rawValue,
                kind: DaemonChatSystemNoticeKind(
                    rawValue: item.kind.rawValue) ?? .session,
                title: item.title, message: item.message,
                createdAt: item.createdAt))
        case .turnFailure(let item):
            return .turnFailure(DaemonChatTranscriptTurnFailureItem(
                failureID: item.failureID.rawValue,
                turnID: item.turnID.rawValue,
                category: DaemonChatTurnFailureCategory(
                    rawValue: item.category.rawValue) ?? .runtimeError,
                message: item.message, createdAt: item.createdAt))
        }
    }

    static func wirePackageProducer(
        _ value: ExtractorPackageExecutionProvenance
    ) -> DaemonExtractorPackageProducer {
        DaemonExtractorPackageProducer(
            packageID: value.packageID,
            version: value.version,
            digestHex: value.digest,
            registrationID: value.registrationID.rawValue,
            protocolRevision: String(value.protocolRevision.rawValue),
            reportedMetadata: DaemonExtractorReportedMetadata(
                toolName: value.reportedMetadata.toolName,
                toolVersion: value.reportedMetadata.toolVersion,
                modelName: value.reportedMetadata.modelName,
                modelVersion: value.reportedMetadata.modelVersion,
                language: value.reportedMetadata.language,
                transcriptGenerated: value.reportedMetadata.transcriptGenerated))
    }

    static func wireProducer(
        _ value: ExtractionProducer
    ) -> DaemonExtractionProducer {
        switch value {
        case .backend(let backend):
            return .backend(rawBackend: backend.rawValue)
        case .tool(let tool):
            return .tool(rawTool: tool.rawValue)
        case .legacy(let rawTechnique):
            return .legacy(rawTechnique: rawTechnique)
        case .installedPackage(let package):
            return .installedPackage(wirePackageProducer(package))
        case .hostSpeech(let hostSpeech):
            return .hostSpeech(DaemonExtractionHostSpeechProducer(
                engine: hostSpeech.engine,
                localeID: hostSpeech.localeID,
                acquisitionFetcher: hostSpeech.acquisitionFetcher
                    .registrationID.rawValue))
        }
    }

    static func wireHostSpeechProducer(
        _ value: ExtractionHostSpeechProducer
    ) -> DaemonExtractionHostSpeechProducer {
        DaemonExtractionHostSpeechProducer(
            engine: value.engine,
            localeID: value.localeID,
            acquisitionFetcher: value.acquisitionFetcher.registrationID.rawValue)
    }

    // MARK: staged embedding-work JSON (the executor's private shape)

    /// The `[{id: String, text: String}]` items the three
    /// missing-embedding-work replies stage behind one handle. Mirrors the
    /// executor's private `EmbeddingWorkItem` JSON shape exactly.
    static func coreEmbeddingWork<ID: RawRepresentable>(
        _ data: Data, idOf: (String) -> ID
    ) throws -> [(id: ID, text: String)] where ID.RawValue == String {
        let items = try JSONDecoder().decode(
            [EmbeddingWorkItem].self, from: data)
        return items.map { (id: idOf($0.id), text: $0.text) }
    }
}

/// File-scope: the staged embedding-work JSON item (a nested type cannot
/// live inside a generic function).
private struct EmbeddingWorkItem: Decodable {
    let id: String
    let text: String
}
#endif
