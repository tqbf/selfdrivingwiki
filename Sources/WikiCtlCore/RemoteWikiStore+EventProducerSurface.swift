#if os(macOS)
import Foundation
import WikiDaemonContract
import WikiFSCore
import WikiFSTypes

// MARK: - Slice-2 wired surface: event-producer family (48 operations)
//
// The event-producer family's client half (plans/daemon-only-access.md
// slice 2): every operation is a stamped mutation whose commit produces
// exactly one store event per mutation — the daemon executor preserves the
// store's `mutate(event:)` discipline, and the reply echoes the outcome +
// the emitted event(s) (observability only: the authoritative bus delivery
// arrives through the sink). The client never dispatches a mutation without
// a stamp; every reply's outcome guards the call.
//
// The event echo is intentionally NOT fed into the local bus here —
// `consume` (the sink path) dedupes and sequences; a reply echo would
// double-deliver. The `createChat` / `deleteResources` exemplars in the
// core file share this discipline.

extension RemoteWikiStore {

    // MARK: workspaces

    public func createWorkspace(
        name: String?, activityID: String?
    ) async throws -> WorkspaceID {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .createWorkspace,
            payload: JSONEncoder().encode(DaemonCreateWorkspaceRequest(
                name: name, activityID: activityID)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonCreateWorkspaceReply.self, result, "createWorkspace")
        try Self.requireCommittedOutcome(reply.outcome, "createWorkspace")
        return WorkspaceID(rawValue: reply.workspaceID)
    }

    public func abandonWorkspace(id: WorkspaceID) async throws {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .abandonWorkspace,
            payload: JSONEncoder().encode(DaemonAbandonWorkspaceRequest(
                id: id.rawValue)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonAbandonWorkspaceReply.self, result, "abandonWorkspace")
        try Self.requireCommittedOutcome(reply.outcome, "abandonWorkspace")
    }

    public func workspaceMerge(workspaceID: WorkspaceID) async throws -> [String] {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .workspaceMerge,
            payload: JSONEncoder().encode(DaemonWorkspaceMergeRequest(
                workspaceID: workspaceID.rawValue)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonWorkspaceMergeReply.self, result, "workspaceMerge")
        try Self.requireCommittedOutcome(reply.outcome, "workspaceMerge")
        return reply.mergedPageIDs
    }

    public func workspaceRefresh(workspaceID: WorkspaceID) async throws {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .workspaceRefresh,
            payload: JSONEncoder().encode(DaemonWorkspaceRefreshRequest(
                workspaceID: workspaceID.rawValue)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonWorkspaceRefreshReply.self, result, "workspaceRefresh")
        try Self.requireCommittedOutcome(reply.outcome, "workspaceRefresh")
    }

    public func workspaceResolveConflict(
        workspaceID: WorkspaceID, pageID: PageID, body: String
    ) async throws {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .workspaceResolveConflict,
            payload: JSONEncoder().encode(
                DaemonWorkspaceResolveConflictRequest(
                    workspaceID: workspaceID.rawValue, pageID: pageID.rawValue,
                    body: body)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonWorkspaceResolveConflictReply.self, result,
            "workspaceResolveConflict")
        try Self.requireCommittedOutcome(
            reply.outcome, "workspaceResolveConflict")
    }

    public func workspaceRetryMerge(workspaceID: WorkspaceID) async throws {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .workspaceRetryMerge,
            payload: JSONEncoder().encode(DaemonWorkspaceRetryMergeRequest(
                workspaceID: workspaceID.rawValue)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonWorkspaceRetryMergeReply.self, result, "workspaceRetryMerge")
        try Self.requireCommittedOutcome(reply.outcome, "workspaceRetryMerge")
    }

    public func reapStaleWorkspaces(ttl: TimeInterval) async throws -> Int {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .reapStaleWorkspaces,
            payload: JSONEncoder().encode(DaemonReapStaleWorkspacesRequest(
                ttl: ttl)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonReapStaleWorkspacesReply.self, result, "reapStaleWorkspaces")
        try Self.requireCommittedOutcome(reply.outcome, "reapStaleWorkspaces")
        return reply.reapedCount
    }

    // MARK: log

    public func appendLog(
        kind: LogEntry.Kind, title: String, note: String?
    ) async throws -> LogEntry {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .appendLog,
            payload: JSONEncoder().encode(DaemonAppendLogRequest(
                kind: DaemonLogEntry.Kind(rawValue: kind.rawValue) ?? .ingest,
                title: title, note: note)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonAppendLogReply.self, result, "appendLog")
        try Self.requireCommittedOutcome(reply.outcome, "appendLog")
        return RemoteStoreMirrorMapping.coreLogEntry(reply.entry)
    }

    // MARK: links

    public func replaceLinks(
        from pageID: PageID, parsedLinks: [ParsedLink]
    ) async throws {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .replaceLinks,
            payload: JSONEncoder().encode(DaemonReplaceLinksRequest(
                pageID: pageID.rawValue,
                parsedLinks: parsedLinks.map(
                    RemoteStoreMirrorMapping.wireParsedLink))),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonReplaceLinksReply.self, result, "replaceLinks")
        try Self.requireCommittedOutcome(reply.outcome, "replaceLinks")
    }

    // MARK: sources

    public func addBytelessSource(
        filename: String, mimeType: String?, provenance: SourceProvenance,
        role: SourceRole
    ) async throws -> SourceSummary {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .addBytelessSource,
            payload: JSONEncoder().encode(DaemonAddBytelessSourceRequest(
                filename: filename, mimeType: mimeType,
                provenance: Self.wireRequiredProvenance(provenance),
                role: DaemonSourceRole(rawValue: role.rawValue) ?? .primary)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonAddBytelessSourceReply.self, result, "addBytelessSource")
        try Self.requireCommittedOutcome(reply.outcome, "addBytelessSource")
        return Self.coreSourceSummary(reply.source)
    }

    public func ensureFetchActivity(
        provenance: SourceProvenance
    ) async throws -> String {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .ensureFetchActivity,
            payload: JSONEncoder().encode(DaemonEnsureFetchActivityRequest(
                provenance: Self.wireRequiredProvenance(provenance))),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonEnsureFetchActivityReply.self, result, "ensureFetchActivity")
        try Self.requireCommittedOutcome(reply.outcome, "ensureFetchActivity")
        return reply.activityID
    }

    public func renameSource(id: SourceID, to newDisplayName: String) async throws {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .renameSource,
            payload: JSONEncoder().encode(DaemonRenameSourceRequest(
                id: id.rawValue, to: newDisplayName)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonRenameSourceReply.self, result, "renameSource")
        try Self.requireCommittedOutcome(reply.outcome, "renameSource")
    }

    public func setSourceDisplayName(
        id: SourceID, displayName: String
    ) async throws {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .setSourceDisplayName,
            payload: JSONEncoder().encode(DaemonSetSourceDisplayNameRequest(
                id: id.rawValue, displayName: displayName)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonSetSourceDisplayNameReply.self, result,
            "setSourceDisplayName")
        try Self.requireCommittedOutcome(reply.outcome, "setSourceDisplayName")
    }

    public func markSourceIngested(id: SourceID) async throws {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .markSourceIngested,
            payload: JSONEncoder().encode(DaemonMarkSourceIngestedRequest(
                id: id.rawValue)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonMarkSourceIngestedReply.self, result, "markSourceIngested")
        try Self.requireCommittedOutcome(reply.outcome, "markSourceIngested")
    }

    /// The 1-arg fetch completion: unconditional marker (no Bool answer).
    public func markFetchComplete(sourceID: SourceID) async throws {
        _ = try await markFetchComplete(
            sourceID: sourceID, expectedContentVersionID: nil)
    }

    /// The recovery-scan variant: `false` = the active version moved on
    /// (the newer marker stays for its own scan).
    public func markFetchComplete(
        sourceID: SourceID, expectedContentVersionID: SourceVersionID
    ) async throws -> Bool {
        try await markFetchComplete(
            sourceID: sourceID, expectedContentVersionID: Optional(expectedContentVersionID))
    }

    /// The DTO-shaped private form: `expectedContentVersionID == nil`
    /// dispatches the store's 1-arg overload daemon-side (the executor's
    /// distinction), whose reply's `didAdvance` is nil.
    private func markFetchComplete(
        sourceID: SourceID, expectedContentVersionID: SourceVersionID?
    ) async throws -> Bool {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .markFetchComplete,
            payload: JSONEncoder().encode(DaemonMarkFetchCompleteRequest(
                sourceID: sourceID.rawValue,
                expectedContentVersionID: expectedContentVersionID?.rawValue)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonMarkFetchCompleteReply.self, result, "markFetchComplete")
        try Self.requireCommittedOutcome(reply.outcome, "markFetchComplete")
        return reply.didAdvance ?? false
    }

    public func setActiveMarkdown(
        sourceID: SourceID, to versionID: SourceMarkdownVersionID
    ) async throws {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .setActiveMarkdown,
            payload: JSONEncoder().encode(DaemonSetActiveMarkdownRequest(
                sourceID: sourceID.rawValue, to: versionID.rawValue)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonSetActiveMarkdownReply.self, result, "setActiveMarkdown")
        try Self.requireCommittedOutcome(reply.outcome, "setActiveMarkdown")
    }

    public func repairMIME(dryRun: Bool) async throws -> MIMERepairReport {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .repairMIME,
            payload: JSONEncoder().encode(DaemonRepairMIMERequest(dryRun: dryRun)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonRepairMIMEReply.self, result, "repairMIME")
        try Self.requireCommittedOutcome(reply.outcome, "repairMIME")
        return try RemoteStoreMirrorMapping.coreMIMERepairReport(reply.report)
    }

    // MARK: OKF setters + verifications

    public func setPageOKFStatus(
        versionID: PageVersionID, status: OKFConceptStatus?
    ) async throws {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .setPageOKFStatus,
            payload: JSONEncoder().encode(DaemonSetPageOKFStatusRequest(
                versionID: versionID.rawValue,
                status: status.map {
                    DaemonOKFConceptStatus(rawValue: $0.rawValue) ?? .draft
                })),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonSetPageOKFStatusReply.self, result, "setPageOKFStatus")
        try Self.requireCommittedOutcome(reply.outcome, "setPageOKFStatus")
    }

    public func setSourceMarkdownOKFStatus(
        versionID: SourceMarkdownVersionID, status: OKFConceptStatus?
    ) async throws {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .setSourceMarkdownOKFStatus,
            payload: JSONEncoder().encode(
                DaemonSetSourceMarkdownOKFStatusRequest(
                    versionID: versionID.rawValue,
                    status: status.map {
                        DaemonOKFConceptStatus(rawValue: $0.rawValue) ?? .draft
                    })),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonSetSourceMarkdownOKFStatusReply.self, result,
            "setSourceMarkdownOKFStatus")
        try Self.requireCommittedOutcome(
            reply.outcome, "setSourceMarkdownOKFStatus")
    }

    public func setPageOKFFreshness(
        versionID: PageVersionID, policy: OKFFreshnessPolicy?
    ) async throws {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .setPageOKFFreshness,
            payload: JSONEncoder().encode(DaemonSetPageOKFFreshnessRequest(
                versionID: versionID.rawValue,
                policy: policy.map(RemoteStoreMirrorMapping.wireFreshness))),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonSetPageOKFFreshnessReply.self, result, "setPageOKFFreshness")
        try Self.requireCommittedOutcome(reply.outcome, "setPageOKFFreshness")
    }

    public func setSourceMarkdownOKFFreshness(
        versionID: SourceMarkdownVersionID, policy: OKFFreshnessPolicy?
    ) async throws {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .setSourceMarkdownOKFFreshness,
            payload: JSONEncoder().encode(
                DaemonSetSourceMarkdownOKFFreshnessRequest(
                    versionID: versionID.rawValue,
                    policy: policy.map(RemoteStoreMirrorMapping.wireFreshness))),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonSetSourceMarkdownOKFFreshnessReply.self, result,
            "setSourceMarkdownOKFFreshness")
        try Self.requireCommittedOutcome(
            reply.outcome, "setSourceMarkdownOKFFreshness")
    }

    public func recordPageOKFVerification(
        versionID: PageVersionID,
        verifier: OKFVerifierIdentity,
        verifiedAt: Date,
        basis: OKFVerificationBasis,
        freshnessPolicy: OKFFreshnessPolicy?
    ) async throws -> OKFVerificationID {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .recordPageOKFVerification,
            payload: JSONEncoder().encode(
                DaemonRecordPageOKFVerificationRequest(
                    versionID: versionID.rawValue,
                    verifier: RemoteStoreMirrorMapping.wireVerifier(verifier),
                    verifiedAt: verifiedAt,
                    basis: RemoteStoreMirrorMapping.wireBasis(basis),
                    freshnessPolicy: freshnessPolicy.map(
                        RemoteStoreMirrorMapping.wireFreshness))),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonRecordPageOKFVerificationReply.self, result,
            "recordPageOKFVerification")
        try Self.requireCommittedOutcome(
            reply.outcome, "recordPageOKFVerification")
        return OKFVerificationID(rawValue: reply.verificationID)
    }

    public func recordSourceMarkdownOKFVerification(
        versionID: SourceMarkdownVersionID,
        verifier: OKFVerifierIdentity,
        verifiedAt: Date,
        basis: OKFVerificationBasis,
        freshnessPolicy: OKFFreshnessPolicy?
    ) async throws -> OKFVerificationID {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .recordSourceMarkdownOKFVerification,
            payload: JSONEncoder().encode(
                DaemonRecordSourceMarkdownOKFVerificationRequest(
                    versionID: versionID.rawValue,
                    verifier: RemoteStoreMirrorMapping.wireVerifier(verifier),
                    verifiedAt: verifiedAt,
                    basis: RemoteStoreMirrorMapping.wireBasis(basis),
                    freshnessPolicy: freshnessPolicy.map(
                        RemoteStoreMirrorMapping.wireFreshness))),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonRecordSourceMarkdownOKFVerificationReply.self, result,
            "recordSourceMarkdownOKFVerification")
        try Self.requireCommittedOutcome(
            reply.outcome, "recordSourceMarkdownOKFVerification")
        return OKFVerificationID(rawValue: reply.verificationID)
    }

    public func correctPageOKFVerification(
        versionID: PageVersionID,
        verificationID: OKFVerificationID,
        correctingVerifier: OKFVerifierIdentity,
        correctedAt: Date,
        reason: OKFVerificationCorrectionReason?
    ) async throws {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .correctPageOKFVerification,
            payload: JSONEncoder().encode(
                DaemonCorrectPageOKFVerificationRequest(
                    versionID: versionID.rawValue,
                    verificationID: verificationID.rawValue,
                    correctingVerifier: RemoteStoreMirrorMapping.wireVerifier(
                        correctingVerifier),
                    correctedAt: correctedAt,
                    reason: reason.map(
                        RemoteStoreMirrorMapping.wireCorrectionReason))),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonCorrectPageOKFVerificationReply.self, result,
            "correctPageOKFVerification")
        try Self.requireCommittedOutcome(
            reply.outcome, "correctPageOKFVerification")
    }

    public func correctSourceMarkdownOKFVerification(
        versionID: SourceMarkdownVersionID,
        verificationID: OKFVerificationID,
        correctingVerifier: OKFVerifierIdentity,
        correctedAt: Date,
        reason: OKFVerificationCorrectionReason?
    ) async throws {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .correctSourceMarkdownOKFVerification,
            payload: JSONEncoder().encode(
                DaemonCorrectSourceMarkdownOKFVerificationRequest(
                    versionID: versionID.rawValue,
                    verificationID: verificationID.rawValue,
                    correctingVerifier: RemoteStoreMirrorMapping.wireVerifier(
                        correctingVerifier),
                    correctedAt: correctedAt,
                    reason: reason.map(
                        RemoteStoreMirrorMapping.wireCorrectionReason))),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonCorrectSourceMarkdownOKFVerificationReply.self, result,
            "correctSourceMarkdownOKFVerification")
        try Self.requireCommittedOutcome(
            reply.outcome, "correctSourceMarkdownOKFVerification")
    }

    // MARK: pages

    public func revertPage(pageID: PageID, to versionID: PageVersionID) async throws {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .revertPage,
            payload: JSONEncoder().encode(DaemonRevertPageRequest(
                pageID: pageID.rawValue, to: versionID.rawValue)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonRevertPageReply.self, result, "revertPage")
        try Self.requireCommittedOutcome(reply.outcome, "revertPage")
    }

    public func restorePage(
        pageID: PageID, to versionID: PageVersionID
    ) async throws -> PageVersionID {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .restorePage,
            payload: JSONEncoder().encode(DaemonRestorePageRequest(
                pageID: pageID.rawValue, to: versionID.rawValue)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonRestorePageReply.self, result, "restorePage")
        try Self.requireCommittedOutcome(reply.outcome, "restorePage")
        return PageVersionID(rawValue: reply.versionID)
    }

    // MARK: bookmarks

    public func createBookmarkNode(
        parentID: BookmarkID?, position: Int, content: BookmarkNode.Content
    ) async throws -> BookmarkNode {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .createBookmarkNode,
            payload: JSONEncoder().encode(DaemonCreateBookmarkNodeRequest(
                parentID: parentID?.rawValue, position: position,
                content: RemoteStoreMirrorMapping.wireBookmarkContent(content))),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonCreateBookmarkNodeReply.self, result, "createBookmarkNode")
        try Self.requireCommittedOutcome(reply.outcome, "createBookmarkNode")
        return RemoteStoreMirrorMapping.coreBookmarkNode(reply.node)
    }

    public func renameBookmarkFolder(id: BookmarkID, to label: String) async throws {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .renameBookmarkFolder,
            payload: JSONEncoder().encode(DaemonRenameBookmarkFolderRequest(
                id: id.rawValue, to: label)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonRenameBookmarkFolderReply.self, result,
            "renameBookmarkFolder")
        try Self.requireCommittedOutcome(reply.outcome, "renameBookmarkFolder")
    }

    public func retargetBookmarkNode(
        id: BookmarkID, to content: BookmarkNode.Content
    ) async throws {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .retargetBookmarkNode,
            payload: JSONEncoder().encode(DaemonRetargetBookmarkNodeRequest(
                id: id.rawValue,
                to: RemoteStoreMirrorMapping.wireBookmarkContent(content))),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonRetargetBookmarkNodeReply.self, result,
            "retargetBookmarkNode")
        try Self.requireCommittedOutcome(reply.outcome, "retargetBookmarkNode")
    }

    public func deleteBookmarkNode(id: BookmarkID) async throws {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .deleteBookmarkNode,
            payload: JSONEncoder().encode(DaemonDeleteBookmarkNodeRequest(
                id: id.rawValue)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonDeleteBookmarkNodeReply.self, result, "deleteBookmarkNode")
        try Self.requireCommittedOutcome(reply.outcome, "deleteBookmarkNode")
    }

    public func moveBookmarkNode(
        id: BookmarkID, toParentID: BookmarkID?, position: Int
    ) async throws {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .moveBookmarkNode,
            payload: JSONEncoder().encode(DaemonMoveBookmarkNodeRequest(
                id: id.rawValue, toParentID: toParentID?.rawValue,
                position: position)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonMoveBookmarkNodeReply.self, result, "moveBookmarkNode")
        try Self.requireCommittedOutcome(reply.outcome, "moveBookmarkNode")
    }

    // MARK: chats

    public func setChatAttachments(
        chatID: ChatID, targets: [ChatAttachmentTarget]
    ) async throws {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .setChatAttachments,
            payload: JSONEncoder().encode(DaemonSetChatAttachmentsRequest(
                chatID: chatID.rawValue, targets: targets.map(Self.wireAttachmentTarget))),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonSetChatAttachmentsReply.self, result, "setChatAttachments")
        try Self.requireCommittedOutcome(reply.outcome, "setChatAttachments")
    }

    public func renameChat(id: ChatID, to title: String) async throws {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .renameChat,
            payload: JSONEncoder().encode(DaemonRenameChatRequest(
                id: id.rawValue, to: title)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonRenameChatReply.self, result, "renameChat")
        try Self.requireCommittedOutcome(reply.outcome, "renameChat")
    }

    public func setChatTitleIfEmpty(
        chatID: ChatID, title: String
    ) async throws -> Bool {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .setChatTitleIfEmpty,
            payload: JSONEncoder().encode(DaemonSetChatTitleIfEmptyRequest(
                chatID: chatID.rawValue, title: title)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonSetChatTitleIfEmptyReply.self, result, "setChatTitleIfEmpty")
        try Self.requireCommittedOutcome(reply.outcome, "setChatTitleIfEmpty")
        return reply.didWrite
    }

    public func setChatTitleIf(
        chatID: ChatID, expectedTitle: String, title: String
    ) async throws -> Bool {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .setChatTitleIf,
            payload: JSONEncoder().encode(DaemonSetChatTitleIfRequest(
                chatID: chatID.rawValue, expectedTitle: expectedTitle,
                title: title)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonSetChatTitleIfReply.self, result, "setChatTitleIf")
        try Self.requireCommittedOutcome(reply.outcome, "setChatTitleIf")
        return reply.didWrite
    }

    public func deleteChat(id: ChatID) async throws {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .deleteChat,
            payload: JSONEncoder().encode(DaemonDeleteChatRequest(id: id.rawValue)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonDeleteChatReply.self, result, "deleteChat")
        try Self.requireCommittedOutcome(reply.outcome, "deleteChat")
    }

    public func updateChatAcpSessionId(
        chatID: ChatID, acpSessionId: AcpSessionID?
    ) async throws {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .updateChatAcpSessionId,
            payload: JSONEncoder().encode(DaemonUpdateChatAcpSessionIdRequest(
                chatID: chatID.rawValue, acpSessionId: acpSessionId?.rawValue)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonUpdateChatAcpSessionIdReply.self, result,
            "updateChatAcpSessionId")
        try Self.requireCommittedOutcome(
            reply.outcome, "updateChatAcpSessionId")
    }

    public func updateChatModelOverride(
        id: ChatID, providerId: ProviderID?, modelId: ModelID?
    ) async throws {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .updateChatModelOverride,
            payload: JSONEncoder().encode(DaemonUpdateChatModelOverrideRequest(
                id: id.rawValue, providerId: providerId?.rawValue,
                modelId: modelId?.rawValue)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonUpdateChatModelOverrideReply.self, result,
            "updateChatModelOverride")
        try Self.requireCommittedOutcome(
            reply.outcome, "updateChatModelOverride")
    }

    public func updateChatModelAndThinkingSelection(
        chatID: ChatID, providerID: ProviderID?, modelID: ModelID?,
        configuredThinkingID: ChatConfigurationValueID?,
        effectiveThinkingID: ChatConfigurationValueID?
    ) async throws {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .updateChatModelAndThinkingSelection,
            payload: JSONEncoder().encode(
                DaemonUpdateChatModelAndThinkingSelectionRequest(
                    chatID: chatID.rawValue, providerID: providerID?.rawValue,
                    modelID: modelID?.rawValue,
                    configuredThinkingID: configuredThinkingID?.rawValue,
                    effectiveThinkingID: effectiveThinkingID?.rawValue)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonUpdateChatModelAndThinkingSelectionReply.self, result,
            "updateChatModelAndThinkingSelection")
        try Self.requireCommittedOutcome(
            reply.outcome, "updateChatModelAndThinkingSelection")
    }

    public func updateMessageSummary(
        chatID: ChatID, cursor: ChatTranscriptCursor, summary: String,
        kind: ChatMessageSummaryKind
    ) async throws {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .updateMessageSummary,
            payload: JSONEncoder().encode(DaemonUpdateMessageSummaryRequest(
                chatID: chatID.rawValue,
                cursor: DaemonChatTranscriptCursor(rawValue: cursor.rawValue),
                summary: summary,
                kind: DaemonChatMessageSummaryKind(
                    rawValue: kind.rawValue) ?? .defaultTruncation)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonUpdateMessageSummaryReply.self, result, "updateMessageSummary")
        try Self.requireCommittedOutcome(
            reply.outcome, "updateMessageSummary")
    }

    public func finalizeStaleDrafts(forChat chatID: ChatID) async throws {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .finalizeStaleDrafts,
            payload: JSONEncoder().encode(DaemonFinalizeStaleDraftsRequest(
                chatID: chatID.rawValue)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonFinalizeStaleDraftsReply.self, result, "finalizeStaleDrafts")
        try Self.requireCommittedOutcome(reply.outcome, "finalizeStaleDrafts")
    }

    public func cancelUnclaimedPersistedChatTurn(
        chatID: ChatID, turnID: ChatTurnID
    ) async throws -> PersistedChatTurn? {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .cancelUnclaimedPersistedChatTurn,
            payload: JSONEncoder().encode(
                DaemonCancelUnclaimedPersistedChatTurnRequest(
                    chatID: chatID.rawValue, turnID: turnID.rawValue)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonCancelUnclaimedPersistedChatTurnReply.self, result,
            "cancelUnclaimedPersistedChatTurn")
        try Self.requireCommittedOutcome(
            reply.outcome, "cancelUnclaimedPersistedChatTurn")
        return reply.turn.map(RemoteStoreMirrorMapping.corePersistedChatTurn)
    }

    public func markPersistedChatTurnProviderSubmitted(
        chatID: ChatID, turnID: ChatTurnID, claimID: ChatTurnClaimID,
        providerSessionID: AcpSessionID?, submittedAt: Date
    ) async throws -> PersistedChatTurn {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .markPersistedChatTurnProviderSubmitted,
            payload: JSONEncoder().encode(
                DaemonMarkPersistedChatTurnProviderSubmittedRequest(
                    chatID: chatID.rawValue, turnID: turnID.rawValue,
                    claimID: claimID.rawValue,
                    providerSessionID: providerSessionID?.rawValue,
                    submittedAt: submittedAt)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonMarkPersistedChatTurnProviderSubmittedReply.self, result,
            "markPersistedChatTurnProviderSubmitted")
        try Self.requireCommittedOutcome(
            reply.outcome, "markPersistedChatTurnProviderSubmitted")
        return RemoteStoreMirrorMapping.corePersistedChatTurn(reply.turn)
    }

    public func updatePersistedChatTurnUsage(
        chatID: ChatID, turnID: ChatTurnID, claimID: ChatTurnClaimID,
        usage: ChatTurnUsageValues
    ) async throws -> PersistedChatTurn {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .updatePersistedChatTurnUsage,
            payload: JSONEncoder().encode(
                DaemonUpdatePersistedChatTurnUsageRequest(
                    chatID: chatID.rawValue, turnID: turnID.rawValue,
                    claimID: claimID.rawValue,
                    usage: RemoteStoreMirrorMapping.wireUsageValues(usage))),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonUpdatePersistedChatTurnUsageReply.self, result,
            "updatePersistedChatTurnUsage")
        try Self.requireCommittedOutcome(
            reply.outcome, "updatePersistedChatTurnUsage")
        return RemoteStoreMirrorMapping.corePersistedChatTurn(reply.turn)
    }

    // MARK: renderer settings

    public func setRendererSourcePreference(
        sourceID: SourceID, preference: RendererPreferenceReference
    ) async throws {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .setRendererSourcePreference,
            payload: JSONEncoder().encode(
                DaemonSetRendererSourcePreferenceRequest(
                    sourceID: sourceID.rawValue,
                    preference: RemoteStoreMirrorMapping.wirePreference(
                        preference))),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonSetRendererSourcePreferenceReply.self, result,
            "setRendererSourcePreference")
        try Self.requireCommittedOutcome(
            reply.outcome, "setRendererSourcePreference")
    }

    public func setRendererSourcePresentation(
        sourceID: SourceID, presentation: RendererSourcePresentationMode
    ) async throws {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .setRendererSourcePresentation,
            payload: JSONEncoder().encode(
                DaemonSetRendererSourcePresentationRequest(
                    sourceID: sourceID.rawValue,
                    presentation: DaemonRendererSourcePresentationMode(
                        rawValue: presentation.rawValue) ?? .source)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonSetRendererSourcePresentationReply.self, result,
            "setRendererSourcePresentation")
        try Self.requireCommittedOutcome(
            reply.outcome, "setRendererSourcePresentation")
    }

    public func removeRendererSourcePresentation(sourceID: SourceID) async throws {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .removeRendererSourcePresentation,
            payload: JSONEncoder().encode(
                DaemonRemoveRendererSourcePresentationRequest(
                    sourceID: sourceID.rawValue)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonRemoveRendererSourcePresentationReply.self, result,
            "removeRendererSourcePresentation")
        try Self.requireCommittedOutcome(
            reply.outcome, "removeRendererSourcePresentation")
    }

    // MARK: shared value helpers

    /// The non-optional provenance the two byteless/acquisition requests
    /// carry (the optional mapper's total-shape twin).
    static func wireRequiredProvenance(
        _ value: SourceProvenance
    ) -> DaemonSourceProvenance {
        DaemonSourceProvenance(
            agentName: value.agentName,
            agentKind: value.agentKind,
            agentVersion: value.agentVersion,
            activityKind: value.activityKind,
            plan: value.plan,
            externalRef: value.externalRef,
            externalIdentity: value.externalIdentity)
    }
}
#endif
