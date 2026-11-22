#if os(macOS)  // File Provider extension — macOS-only (FileProvider framework)
import Foundation
import WikiDaemonContract
import WikiFSCore

/// Mirror → core reconstruction for the projection family's values. The
/// contract module is dependency-free, so every WikiFSCore shape crosses the
/// wire as its contract mirror; this file rebuilds the core values the tree
/// logic consumes. Field semantics match one-to-one; unknown raw enum
/// strings fall back to the store-family's established defaults (extraction
/// origin, primary role, edit chat kind) rather than throwing — the wire is
/// same-build on both ends, so a miss is already a contract-test failure.
enum DaemonProjectionMirrors {

    // MARK: pages

    static func core(_ page: DaemonWikiPage) -> WikiPage {
        WikiPage(
            id: PageID(rawValue: page.id), title: page.title, slug: page.slug,
            bodyMarkdown: page.bodyMarkdown, createdAt: page.createdAt,
            updatedAt: page.updatedAt, version: page.version,
            createdBy: page.createdBy, lastEditedBy: page.lastEditedBy)
    }

    // MARK: sources

    static func core(_ source: DaemonSourceSummary) -> SourceSummary {
        SourceSummary(
            id: SourceID(rawValue: source.id), filename: source.filename,
            ext: source.ext, mimeType: source.mimeType,
            byteSize: source.byteSize, createdAt: source.createdAt,
            updatedAt: source.updatedAt, version: source.version,
            externalItemKey: source.externalItemKey,
            externalItemTitle: source.externalItemTitle,
            displayName: source.displayName,
            role: SourceRole(rawValue: source.role) ?? .primary)
    }

    static func core(_ origin: DaemonSourceOrigin) -> SourceOrigin {
        SourceOrigin(
            versionID: SourceVersionID(rawValue: origin.versionID),
            agentName: origin.agentName, agentKind: origin.agentKind,
            activityKind: origin.activityKind, plan: origin.plan,
            externalRef: origin.externalRef,
            externalIdentity: origin.externalIdentity,
            runTitle: origin.runTitle, fetchedAt: origin.fetchedAt)
    }

    static func core(_ row: DaemonSourceIndexRow) -> IndexGenerators.SourceIndexRow {
        IndexGenerators.SourceIndexRow(
            id: row.id, filename: row.filename, ext: row.ext, mime: row.mime,
            byteSize: row.byteSize, createdAt: row.createdAt,
            updatedAt: row.updatedAt, version: row.version,
            displayName: row.displayName, hasMarkdown: row.hasMarkdown)
    }

    static func core(_ version: DaemonSourceMarkdownVersionMirror) -> SourceMarkdownVersion {
        SourceMarkdownVersion(
            id: SourceMarkdownVersionID(rawValue: version.id),
            sourceID: SourceID(rawValue: version.sourceID),
            parentID: version.parentID.map(SourceMarkdownVersionID.init(rawValue:)),
            content: version.content,
            origin: SourceMarkdownOrigin(rawValue: version.origin) ?? .extraction,
            note: version.note, createdAt: version.createdAt,
            activityID: version.activityID,
            sourceVersionID: version.sourceVersionID.map(SourceVersionID.init(rawValue:)),
            blobHash: version.blobHash, mimeType: version.mimeType,
            technique: version.technique)
    }

    static func core(_ link: DaemonPageSourceLink) -> PageSourceLink {
        PageSourceLink(
            pageID: PageID(rawValue: link.pageID),
            sourceID: SourceID(rawValue: link.sourceID),
            linkText: link.linkText,
            role: PageSourceLinkRole(rawValue: link.role) ?? .cite)
    }

    // MARK: links

    static func coreLinkRow(_ row: DaemonLinkRow) -> IndexGenerators.LinkRow {
        IndexGenerators.LinkRow(
            from: row.from, to: row.to, linkText: row.linkText, type: row.type)
    }

    // MARK: chats

    static func core(_ chat: DaemonChatSummary) -> ChatSummary {
        ChatSummary(
            id: ChatID(rawValue: chat.id),
            kind: ChatKind(rawValue: chat.kind.rawValue) ?? .edit,
            title: chat.title, createdAt: chat.createdAt,
            updatedAt: chat.updatedAt, messageCount: chat.messageCount,
            acpSessionId: chat.acpSessionId.map(AcpSessionID.init(rawValue:)),
            modelProviderId: chat.modelProviderId.map(ProviderID.init(rawValue:)),
            modelId: chat.modelId.map(ModelID.init(rawValue:)),
            configuredThinkingOptionID: chat.configuredThinkingOptionID
                .map(ChatConfigurationValueID.init(rawValue:)),
            effectiveThinkingOptionID: chat.effectiveThinkingOptionID
                .map(ChatConfigurationValueID.init(rawValue:)))
    }

    static func core(_ message: DaemonChatMessage) throws -> ChatMessage {
        ChatMessage(
            id: PageID(rawValue: message.id),
            chatID: ChatID(rawValue: message.chatID),
            seq: message.seq,
            event: coreAgentEvent(message.event),
            createdAt: message.createdAt,
            isDraft: message.isDraft)
    }

    /// Mirror → core for the agent-event family the transcript renderer
    /// consumes. Deliberate local copy of WikiCtlCore's reconstruction: the
    /// extension module cannot import WikiCtlCore (it drags the engine into
    /// the appex), and the mapping is pure value-shape code.
    private static func coreAgentEvent(_ value: DaemonAgentEvent) -> AgentEvent {
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

    private static func coreTurnFailureReason(
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

    // MARK: log / index / bookmarks

    static func core(_ entry: DaemonLogEntry) -> LogEntry {
        LogEntry(
            id: PageID(rawValue: entry.id), timestamp: entry.timestamp,
            kind: LogEntry.Kind(rawValue: entry.kind.rawValue) ?? .ingest,
            title: entry.title, note: entry.note)
    }

    static func core(_ node: DaemonBookmarkNode) throws -> BookmarkNode {
        let content: BookmarkNode.Content
        switch node.content {
        case .folder(let label):
            content = .folder(label: label)
        case .page(let id):
            content = .page(PageID(rawValue: id))
        case .source(let id):
            content = .source(SourceID(rawValue: id))
        case .chat(let id):
            content = .chat(ChatID(rawValue: id))
        }
        return BookmarkNode(
            id: BookmarkID(rawValue: node.id),
            parentID: node.parentID.map(BookmarkID.init(rawValue:)),
            position: node.position, content: content,
            createdAt: node.createdAt, updatedAt: node.updatedAt)
    }

    // MARK: OKF trust metadata

    static func core(_ value: DaemonPageOKFTrustMetadata) throws -> PageOKFTrustMetadata {
        PageOKFTrustMetadata(
            pageID: PageID(rawValue: value.pageID),
            versionID: PageVersionID(rawValue: value.versionID),
            metadata: try DaemonStoreOKFMirrors.core(value.metadata))
    }

    static func core(_ value: DaemonSourceMarkdownOKFTrustMetadata) throws -> SourceMarkdownOKFTrustMetadata {
        SourceMarkdownOKFTrustMetadata(
            sourceID: SourceID(rawValue: value.sourceID),
            versionID: SourceMarkdownVersionID(rawValue: value.versionID),
            metadata: try DaemonStoreOKFMirrors.core(value.metadata))
    }
}

/// Mirror → core for the OKF trust family. Deliberate local copy of
/// WikiCtlCore's reconstruction (the extension module cannot import
/// WikiCtlCore): the core verifier initializer PARSES the raw identity
/// string, so a mirror whose fields disagree with the parse is a typed
/// rejection, never a silent reinterpretation.
enum DaemonStoreOKFMirrors {

    static func core(_ value: DaemonOKFConceptMetadata) throws -> OKFConceptMetadata {
        OKFConceptMetadata(
            status: value.status.map {
                OKFConceptStatus(rawValue: $0.rawValue) ?? .draft
            },
            staleAfter: value.staleAfter,
            freshnessPolicy: value.freshnessPolicy.map(coreFreshness),
            verifications: try value.verifications.map(coreVerificationEvent),
            projectionRevision: value.projectionRevision)
    }

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

    static func coreCorrectionReason(
        _ value: DaemonOKFVerificationCorrectionReason
    ) -> OKFVerificationCorrectionReason {
        OKFVerificationCorrectionReason(reason: value.reason)
    }
}
#endif
