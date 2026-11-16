#if os(macOS)
import Foundation

// Event-producer per-operation DTOs for the store family (Phase 2a slice 2,
// tmp/store-ops-manifest.md event-producer partition — 50 operations): every
// op is a commit the daemon executor must preserve exactly-one-event-per-
// commit for. Replies embed the ``DaemonMutationOutcome`` echo (stamp +
// status — exactly-once observable) plus `events`, the emitted
// ``DaemonResourceChangeEvent`` echoes (kind / id / change / seq). Most
// commits emit exactly one event, so `events` carries one element; the
// batch mutators (`deleteResources`, `reapStaleWorkspaces`,
// `workspaceMerge`) emit one per affected resource; conditional emitters
// (`setChatTitleIf`, `setChatTitleIfEmpty`, `markFetchComplete`'s
// no-advance variant, idempotent no-ops) leave `events` EMPTY — an empty
// array is the honest "committed, emitted nothing". Requests carry only
// op-specific args (wiki id + mutation stamp ride the envelope).

// MARK: - Workspaces

/// `abandonWorkspace`: set status `abandoned` + delete its `workspace_refs`.
public struct DaemonAbandonWorkspaceRequest: Codable, Equatable, Sendable {
    public let id: String
    public init(id: String) { self.id = id }
}

public struct DaemonAbandonWorkspaceReply: Codable, Equatable, Sendable {
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        outcome: DaemonMutationOutcome, events: [DaemonResourceChangeEvent]
    ) {
        self.outcome = outcome
        self.events = events
    }
}

/// `createWorkspace`: create a durable named workspace starting `open`.
public struct DaemonCreateWorkspaceRequest: Codable, Equatable, Sendable {
    public let name: String?
    public let activityID: String?
    public init(name: String?, activityID: String?) {
        self.name = name
        self.activityID = activityID
    }
}

public struct DaemonCreateWorkspaceReply: Codable, Equatable, Sendable {
    public let workspaceID: String
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        workspaceID: String, outcome: DaemonMutationOutcome,
        events: [DaemonResourceChangeEvent]
    ) {
        self.workspaceID = workspaceID
        self.outcome = outcome
        self.events = events
    }
}

/// `workspaceMerge`: fast-forward-only merge; divergence parks the workspace
/// `conflicted`. The reply lists the merged page ids; the echoes carry one
/// event per merged page (batch mutator).
public struct DaemonWorkspaceMergeRequest: Codable, Equatable, Sendable {
    public let workspaceID: String
    public init(workspaceID: String) { self.workspaceID = workspaceID }
}

public struct DaemonWorkspaceMergeReply: Codable, Equatable, Sendable {
    public let mergedPageIDs: [String]
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        mergedPageIDs: [String], outcome: DaemonMutationOutcome,
        events: [DaemonResourceChangeEvent]
    ) {
        self.mergedPageIDs = mergedPageIDs
        self.outcome = outcome
        self.events = events
    }
}

/// `workspaceRefresh`: re-base a workspace against current main (diff3 per
/// ref; conflicts park).
public struct DaemonWorkspaceRefreshRequest: Codable, Equatable, Sendable {
    public let workspaceID: String
    public init(workspaceID: String) { self.workspaceID = workspaceID }
}

public struct DaemonWorkspaceRefreshReply: Codable, Equatable, Sendable {
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        outcome: DaemonMutationOutcome, events: [DaemonResourceChangeEvent]
    ) {
        self.outcome = outcome
        self.events = events
    }
}

/// `workspaceResolveConflict`: write the resolved body as a new workspace
/// version + delete the conflict row.
public struct DaemonWorkspaceResolveConflictRequest: Codable, Equatable,
    Sendable {
    public let workspaceID: String
    public let pageID: String
    public let body: String

    public init(workspaceID: String, pageID: String, body: String) {
        self.workspaceID = workspaceID
        self.pageID = pageID
        self.body = body
    }
}

public struct DaemonWorkspaceResolveConflictReply: Codable, Equatable,
    Sendable {
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        outcome: DaemonMutationOutcome, events: [DaemonResourceChangeEvent]
    ) {
        self.outcome = outcome
        self.events = events
    }
}

/// `workspaceRetryMerge`: set a conflicted workspace back to `open` and
/// attempt the merge again.
public struct DaemonWorkspaceRetryMergeRequest: Codable, Equatable, Sendable {
    public let workspaceID: String
    public init(workspaceID: String) { self.workspaceID = workspaceID }
}

public struct DaemonWorkspaceRetryMergeReply: Codable, Equatable, Sendable {
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        outcome: DaemonMutationOutcome, events: [DaemonResourceChangeEvent]
    ) {
        self.outcome = outcome
        self.events = events
    }
}

/// `reapStaleWorkspaces`: mark stale open workspaces `abandoned`; the reply
/// carries the reaped count and one echo per reaped row (batch mutator).
public struct DaemonReapStaleWorkspacesRequest: Codable, Equatable, Sendable {
    /// Seconds of `updated_at` age past which an `open` workspace reaps.
    public let ttl: Double
    public init(ttl: Double) { self.ttl = ttl }
}

public struct DaemonReapStaleWorkspacesReply: Codable, Equatable, Sendable {
    public let reapedCount: Int
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        reapedCount: Int, outcome: DaemonMutationOutcome,
        events: [DaemonResourceChangeEvent]
    ) {
        self.reapedCount = reapedCount
        self.outcome = outcome
        self.events = events
    }
}

// MARK: - Sources

/// `addBytelessSource`: a source whose identity + v1 version carry NO blob
/// (dedup on `external_identity` among byteless sources).
public struct DaemonAddBytelessSourceRequest: Codable, Equatable, Sendable {
    public let filename: String
    public let mimeType: String?
    public let provenance: DaemonSourceProvenance
    public let role: DaemonSourceRole

    public init(
        filename: String, mimeType: String?,
        provenance: DaemonSourceProvenance, role: DaemonSourceRole
    ) {
        self.filename = filename
        self.mimeType = mimeType
        self.provenance = provenance
        self.role = role
    }
}

public struct DaemonAddBytelessSourceReply: Codable, Equatable, Sendable {
    public let source: DaemonSourceSummary
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        source: DaemonSourceSummary, outcome: DaemonMutationOutcome,
        events: [DaemonResourceChangeEvent]
    ) {
        self.source = source
        self.outcome = outcome
        self.events = events
    }
}

/// `ensureFetchActivity`: create the shared fetch activity for a website
/// snapshot (agent + activity commit first so the version FK is satisfied).
public struct DaemonEnsureFetchActivityRequest: Codable, Equatable, Sendable {
    public let provenance: DaemonSourceProvenance
    public init(provenance: DaemonSourceProvenance) {
        self.provenance = provenance
    }
}

public struct DaemonEnsureFetchActivityReply: Codable, Equatable, Sendable {
    public let activityID: String
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        activityID: String, outcome: DaemonMutationOutcome,
        events: [DaemonResourceChangeEvent]
    ) {
        self.activityID = activityID
        self.outcome = outcome
        self.events = events
    }
}

/// `markFetchComplete`: mark one fetch source `complete`. CARRIES BOTH
/// OVERLOADS losslessly: a nil `expectedContentVersionID` is the
/// unconditional (Void) overload; a value selects the recovery-scan variant.
/// The reply's `didAdvance` is nil for the unconditional overload and the
/// variant's Bool otherwise (false = the active version moved on; the newer
/// marker stays for its own scan). `events` mirrors whatever the store
/// emitted for THIS commit.
public struct DaemonMarkFetchCompleteRequest: Codable, Equatable, Sendable {
    public let sourceID: String
    public let expectedContentVersionID: String?

    public init(sourceID: String, expectedContentVersionID: String?) {
        self.sourceID = sourceID
        self.expectedContentVersionID = expectedContentVersionID
    }
}

public struct DaemonMarkFetchCompleteReply: Codable, Equatable, Sendable {
    public let didAdvance: Bool?
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        didAdvance: Bool?, outcome: DaemonMutationOutcome,
        events: [DaemonResourceChangeEvent]
    ) {
        self.didAdvance = didAdvance
        self.outcome = outcome
        self.events = events
    }
}

/// `markSourceIngested`: stamp `sources.ingested_at` (first completed ingest
/// wins — the no-rewrite rule; a repeat commit emits nothing).
public struct DaemonMarkSourceIngestedRequest: Codable, Equatable, Sendable {
    public let id: String
    public init(id: String) { self.id = id }
}

public struct DaemonMarkSourceIngestedReply: Codable, Equatable, Sendable {
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        outcome: DaemonMutationOutcome, events: [DaemonResourceChangeEvent]
    ) {
        self.outcome = outcome
        self.events = events
    }
}

/// `renameSource`: set display_name + rewrite every `[[source:<old>…]]` link
/// (transactional; fragments and aliases preserved).
public struct DaemonRenameSourceRequest: Codable, Equatable, Sendable {
    public let id: String
    public let to: String
    public init(id: String, to: String) {
        self.id = id
        self.to = to
    }
}

public struct DaemonRenameSourceReply: Codable, Equatable, Sendable {
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        outcome: DaemonMutationOutcome, events: [DaemonResourceChangeEvent]
    ) {
        self.outcome = outcome
        self.events = events
    }
}

/// `setSourceDisplayName`: set display_name WITHOUT the link-rewrite/FTS
/// overhead.
public struct DaemonSetSourceDisplayNameRequest: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

public struct DaemonSetSourceDisplayNameReply: Codable, Equatable, Sendable {
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        outcome: DaemonMutationOutcome, events: [DaemonResourceChangeEvent]
    ) {
        self.outcome = outcome
        self.events = events
    }
}

/// `repairMIME`: detect canonical MIME for active byte-bearing sources with
/// a NULL mirror (`dryRun` reports without updating).
public struct DaemonRepairMIMERequest: Codable, Equatable, Sendable {
    public let dryRun: Bool
    public init(dryRun: Bool) { self.dryRun = dryRun }
}

public struct DaemonRepairMIMEReply: Codable, Equatable, Sendable {
    public let report: DaemonMIMERepairReport
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        report: DaemonMIMERepairReport, outcome: DaemonMutationOutcome,
        events: [DaemonResourceChangeEvent]
    ) {
        self.report = report
        self.outcome = outcome
        self.events = events
    }
}

// MARK: - Processed markdown

/// `setActiveMarkdown`: nominate an existing markdown row as the active HEAD
/// (UPSERT the `source-derived` ref).
public struct DaemonSetActiveMarkdownRequest: Codable, Equatable, Sendable {
    public let sourceID: String
    public let to: String
    public init(sourceID: String, to: String) {
        self.sourceID = sourceID
        self.to = to
    }
}

public struct DaemonSetActiveMarkdownReply: Codable, Equatable, Sendable {
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        outcome: DaemonMutationOutcome, events: [DaemonResourceChangeEvent]
    ) {
        self.outcome = outcome
        self.events = events
    }
}

// MARK: - OKF trust (v52)

/// `recordPageOKFVerification`: append one page-version verification.
public struct DaemonRecordPageOKFVerificationRequest: Codable, Equatable,
    Sendable {
    public let versionID: String
    public let verifier: DaemonOKFVerifierIdentity
    public let verifiedAt: Date
    public let basis: DaemonOKFVerificationBasis
    public let freshnessPolicy: DaemonOKFFreshnessPolicy?

    public init(
        versionID: String, verifier: DaemonOKFVerifierIdentity,
        verifiedAt: Date, basis: DaemonOKFVerificationBasis,
        freshnessPolicy: DaemonOKFFreshnessPolicy?
    ) {
        self.versionID = versionID
        self.verifier = verifier
        self.verifiedAt = verifiedAt
        self.basis = basis
        self.freshnessPolicy = freshnessPolicy
    }
}

public struct DaemonRecordPageOKFVerificationReply: Codable, Equatable,
    Sendable {
    public let verificationID: String
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        verificationID: String, outcome: DaemonMutationOutcome,
        events: [DaemonResourceChangeEvent]
    ) {
        self.verificationID = verificationID
        self.outcome = outcome
        self.events = events
    }
}

/// `recordSourceMarkdownOKFVerification`: append one markdown-version
/// verification.
public struct DaemonRecordSourceMarkdownOKFVerificationRequest: Codable,
    Equatable, Sendable {
    public let versionID: String
    public let verifier: DaemonOKFVerifierIdentity
    public let verifiedAt: Date
    public let basis: DaemonOKFVerificationBasis
    public let freshnessPolicy: DaemonOKFFreshnessPolicy?

    public init(
        versionID: String, verifier: DaemonOKFVerifierIdentity,
        verifiedAt: Date, basis: DaemonOKFVerificationBasis,
        freshnessPolicy: DaemonOKFFreshnessPolicy?
    ) {
        self.versionID = versionID
        self.verifier = verifier
        self.verifiedAt = verifiedAt
        self.basis = basis
        self.freshnessPolicy = freshnessPolicy
    }
}

public struct DaemonRecordSourceMarkdownOKFVerificationReply: Codable,
    Equatable, Sendable {
    public let verificationID: String
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        verificationID: String, outcome: DaemonMutationOutcome,
        events: [DaemonResourceChangeEvent]
    ) {
        self.verificationID = verificationID
        self.outcome = outcome
        self.events = events
    }
}

/// `correctPageOKFVerification`: correct one page verification.
public struct DaemonCorrectPageOKFVerificationRequest: Codable, Equatable,
    Sendable {
    public let versionID: String
    public let verificationID: String
    public let correctingVerifier: DaemonOKFVerifierIdentity
    public let correctedAt: Date
    public let reason: DaemonOKFVerificationCorrectionReason?

    public init(
        versionID: String, verificationID: String,
        correctingVerifier: DaemonOKFVerifierIdentity, correctedAt: Date,
        reason: DaemonOKFVerificationCorrectionReason?
    ) {
        self.versionID = versionID
        self.verificationID = verificationID
        self.correctingVerifier = correctingVerifier
        self.correctedAt = correctedAt
        self.reason = reason
    }
}

public struct DaemonCorrectPageOKFVerificationReply: Codable, Equatable,
    Sendable {
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        outcome: DaemonMutationOutcome, events: [DaemonResourceChangeEvent]
    ) {
        self.outcome = outcome
        self.events = events
    }
}

/// `correctSourceMarkdownOKFVerification`: correct one markdown verification.
public struct DaemonCorrectSourceMarkdownOKFVerificationRequest: Codable,
    Equatable, Sendable {
    public let versionID: String
    public let verificationID: String
    public let correctingVerifier: DaemonOKFVerifierIdentity
    public let correctedAt: Date
    public let reason: DaemonOKFVerificationCorrectionReason?

    public init(
        versionID: String, verificationID: String,
        correctingVerifier: DaemonOKFVerifierIdentity, correctedAt: Date,
        reason: DaemonOKFVerificationCorrectionReason?
    ) {
        self.versionID = versionID
        self.verificationID = verificationID
        self.correctingVerifier = correctingVerifier
        self.correctedAt = correctedAt
        self.reason = reason
    }
}

public struct DaemonCorrectSourceMarkdownOKFVerificationReply: Codable,
    Equatable, Sendable {
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        outcome: DaemonMutationOutcome, events: [DaemonResourceChangeEvent]
    ) {
        self.outcome = outcome
        self.events = events
    }
}

/// `setPageOKFStatus`: set (or clear) a page version's concept status.
public struct DaemonSetPageOKFStatusRequest: Codable, Equatable, Sendable {
    public let versionID: String
    public let status: DaemonOKFConceptStatus?
    public init(versionID: String, status: DaemonOKFConceptStatus?) {
        self.versionID = versionID
        self.status = status
    }
}

public struct DaemonSetPageOKFStatusReply: Codable, Equatable, Sendable {
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        outcome: DaemonMutationOutcome, events: [DaemonResourceChangeEvent]
    ) {
        self.outcome = outcome
        self.events = events
    }
}

/// `setPageOKFFreshness`: set (or clear) a page version's freshness policy.
public struct DaemonSetPageOKFFreshnessRequest: Codable, Equatable, Sendable {
    public let versionID: String
    public let policy: DaemonOKFFreshnessPolicy?
    public init(versionID: String, policy: DaemonOKFFreshnessPolicy?) {
        self.versionID = versionID
        self.policy = policy
    }
}

public struct DaemonSetPageOKFFreshnessReply: Codable, Equatable, Sendable {
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        outcome: DaemonMutationOutcome, events: [DaemonResourceChangeEvent]
    ) {
        self.outcome = outcome
        self.events = events
    }
}

/// `setSourceMarkdownOKFStatus`: set (or clear) a markdown version's status.
public struct DaemonSetSourceMarkdownOKFStatusRequest: Codable, Equatable,
    Sendable {
    public let versionID: String
    public let status: DaemonOKFConceptStatus?
    public init(versionID: String, status: DaemonOKFConceptStatus?) {
        self.versionID = versionID
        self.status = status
    }
}

public struct DaemonSetSourceMarkdownOKFStatusReply: Codable, Equatable,
    Sendable {
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        outcome: DaemonMutationOutcome, events: [DaemonResourceChangeEvent]
    ) {
        self.outcome = outcome
        self.events = events
    }
}

/// `setSourceMarkdownOKFFreshness`: set (or clear) a markdown version's
/// freshness policy.
public struct DaemonSetSourceMarkdownOKFFreshnessRequest: Codable, Equatable,
    Sendable {
    public let versionID: String
    public let policy: DaemonOKFFreshnessPolicy?
    public init(versionID: String, policy: DaemonOKFFreshnessPolicy?) {
        self.versionID = versionID
        self.policy = policy
    }
}

public struct DaemonSetSourceMarkdownOKFFreshnessReply: Codable, Equatable,
    Sendable {
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        outcome: DaemonMutationOutcome, events: [DaemonResourceChangeEvent]
    ) {
        self.outcome = outcome
        self.events = events
    }
}

// MARK: - Pages

/// `replaceLinks`: replace ALL outgoing links for a page with the resolved
/// subset (unresolvable targets omitted; self-links allowed).
public struct DaemonReplaceLinksRequest: Codable, Equatable, Sendable {
    public let pageID: String
    public let parsedLinks: [DaemonParsedLink]
    public init(pageID: String, parsedLinks: [DaemonParsedLink]) {
        self.pageID = pageID
        self.parsedLinks = parsedLinks
    }
}

public struct DaemonReplaceLinksReply: Codable, Equatable, Sendable {
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        outcome: DaemonMutationOutcome, events: [DaemonResourceChangeEvent]
    ) {
        self.outcome = outcome
        self.events = events
    }
}

/// `restorePage`: restore by APPENDING a new version node reusing the
/// target's blob (history never mutated; the new node becomes HEAD).
public struct DaemonRestorePageRequest: Codable, Equatable, Sendable {
    public let pageID: String
    public let to: String
    public init(pageID: String, to: String) {
        self.pageID = pageID
        self.to = to
    }
}

public struct DaemonRestorePageReply: Codable, Equatable, Sendable {
    public let versionID: String
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        versionID: String, outcome: DaemonMutationOutcome,
        events: [DaemonResourceChangeEvent]
    ) {
        self.versionID = versionID
        self.outcome = outcome
        self.events = events
    }
}

/// `revertPage`: repoint the `page-content` ref + update the mirror body.
public struct DaemonRevertPageRequest: Codable, Equatable, Sendable {
    public let pageID: String
    public let to: String
    public init(pageID: String, to: String) {
        self.pageID = pageID
        self.to = to
    }
}

public struct DaemonRevertPageReply: Codable, Equatable, Sendable {
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        outcome: DaemonMutationOutcome, events: [DaemonResourceChangeEvent]
    ) {
        self.outcome = outcome
        self.events = events
    }
}

// MARK: - Protected deletion (batch)

/// `deleteResources`: the single deletion seam — impact recheck, provenance
/// gate, optional `.unlink` rewrites, mandatory bookmark cleanup, target
/// deletion in ONE transaction, post-commit events emitted after. Batch
/// mutator: one echo per rewritten page, removed bookmark, and actually-
/// deleted target (missing targets are idempotent no-ops with no event).
public struct DaemonDeleteResourcesRequest: Codable, Equatable, Sendable {
    public let request: DaemonResourceDeletionRequest
    public init(request: DaemonResourceDeletionRequest) {
        self.request = request
    }
}

public struct DaemonDeleteResourcesReply: Codable, Equatable, Sendable {
    public let result: DaemonResourceDeletionResult
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        result: DaemonResourceDeletionResult,
        outcome: DaemonMutationOutcome, events: [DaemonResourceChangeEvent]
    ) {
        self.result = result
        self.outcome = outcome
        self.events = events
    }
}

// MARK: - Log

/// `appendLog`: append one row to the chronological log; the reply echoes
/// the inserted entry (id assigned store-side).
public struct DaemonAppendLogRequest: Codable, Equatable, Sendable {
    public let kind: DaemonLogEntry.Kind
    public let title: String
    public let note: String?
    public init(kind: DaemonLogEntry.Kind, title: String, note: String?) {
        self.kind = kind
        self.title = title
        self.note = note
    }
}

public struct DaemonAppendLogReply: Codable, Equatable, Sendable {
    public let entry: DaemonLogEntry
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        entry: DaemonLogEntry, outcome: DaemonMutationOutcome,
        events: [DaemonResourceChangeEvent]
    ) {
        self.entry = entry
        self.outcome = outcome
        self.events = events
    }
}

// MARK: - Bookmarks

/// `createBookmarkNode`: insert a node, shifting sibling positions ≥
/// `position` up; the reply echoes the inserted node with its generated id.
public struct DaemonCreateBookmarkNodeRequest: Codable, Equatable, Sendable {
    public let parentID: String?
    public let position: Int
    public let content: DaemonBookmarkContent
    public init(
        parentID: String?, position: Int, content: DaemonBookmarkContent
    ) {
        self.parentID = parentID
        self.position = position
        self.content = content
    }
}

public struct DaemonCreateBookmarkNodeReply: Codable, Equatable, Sendable {
    public let node: DaemonBookmarkNode
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        node: DaemonBookmarkNode, outcome: DaemonMutationOutcome,
        events: [DaemonResourceChangeEvent]
    ) {
        self.node = node
        self.outcome = outcome
        self.events = events
    }
}

/// `renameBookmarkFolder`: update a folder's label (folders only).
public struct DaemonRenameBookmarkFolderRequest: Codable, Equatable, Sendable {
    public let id: String
    public let to: String
    public init(id: String, to: String) {
        self.id = id
        self.to = to
    }
}

public struct DaemonRenameBookmarkFolderReply: Codable, Equatable, Sendable {
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        outcome: DaemonMutationOutcome, events: [DaemonResourceChangeEvent]
    ) {
        self.outcome = outcome
        self.events = events
    }
}

/// `retargetBookmarkNode`: retarget a reference to a new target (folders
/// cannot be retargeted — a folder case is a typed rejection).
public struct DaemonRetargetBookmarkNodeRequest: Codable, Equatable,
    Sendable {
    public let id: String
    public let to: DaemonBookmarkContent
    public init(id: String, to: DaemonBookmarkContent) {
        self.id = id
        self.to = to
    }
}

public struct DaemonRetargetBookmarkNodeReply: Codable, Equatable, Sendable {
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        outcome: DaemonMutationOutcome, events: [DaemonResourceChangeEvent]
    ) {
        self.outcome = outcome
        self.events = events
    }
}

/// `deleteBookmarkNode`: delete a node (CASCADE removes descendants).
public struct DaemonDeleteBookmarkNodeRequest: Codable, Equatable, Sendable {
    public let id: String
    public init(id: String) { self.id = id }
}

public struct DaemonDeleteBookmarkNodeReply: Codable, Equatable, Sendable {
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        outcome: DaemonMutationOutcome, events: [DaemonResourceChangeEvent]
    ) {
        self.outcome = outcome
        self.events = events
    }
}

/// `moveBookmarkNode`: move to a new parent and/or position; siblings of
/// both parents renumber contiguously.
public struct DaemonMoveBookmarkNodeRequest: Codable, Equatable, Sendable {
    public let id: String
    public let toParentID: String?
    public let position: Int
    public init(id: String, toParentID: String?, position: Int) {
        self.id = id
        self.toParentID = toParentID
        self.position = position
    }
}

public struct DaemonMoveBookmarkNodeReply: Codable, Equatable, Sendable {
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        outcome: DaemonMutationOutcome, events: [DaemonResourceChangeEvent]
    ) {
        self.outcome = outcome
        self.events = events
    }
}

// MARK: - Chats

/// `createChat`: create a chat row. CARRIES ALL THREE OVERLOADS losslessly:
/// the 2-arg (`kind:title:`) maps to nil provider/model/thinking fields and
/// empty attachments; the provider/model overload sets the thinking fields
/// with empty attachments; the attachments overload composes the ordered
/// chip set (all rows persist in ONE transaction).
public struct DaemonCreateChatRequest: Codable, Equatable, Sendable {
    public let kind: DaemonChatKind
    public let title: String
    public let modelProviderId: String?
    public let modelId: String?
    public let configuredThinkingOptionID: String?
    public let effectiveThinkingOptionID: String?
    public let attachments: [DaemonChatAttachmentTarget]

    public init(
        kind: DaemonChatKind, title: String, modelProviderId: String?,
        modelId: String?, configuredThinkingOptionID: String?,
        effectiveThinkingOptionID: String?,
        attachments: [DaemonChatAttachmentTarget]
    ) {
        self.kind = kind
        self.title = title
        self.modelProviderId = modelProviderId
        self.modelId = modelId
        self.configuredThinkingOptionID = configuredThinkingOptionID
        self.effectiveThinkingOptionID = effectiveThinkingOptionID
        self.attachments = attachments
    }
}

public struct DaemonCreateChatReply: Codable, Equatable, Sendable {
    /// The inserted summary (id/timestamps/messageCount assigned store-side).
    public let chat: DaemonChatSummary
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        chat: DaemonChatSummary, outcome: DaemonMutationOutcome,
        events: [DaemonResourceChangeEvent]
    ) {
        self.chat = chat
        self.outcome = outcome
        self.events = events
    }
}

/// `setChatAttachments`: replace a chat's whole attachment-target set,
/// ordered, in one transaction (`.chatNotFound` when absent).
public struct DaemonSetChatAttachmentsRequest: Codable, Equatable, Sendable {
    public let chatID: String
    public let targets: [DaemonChatAttachmentTarget]
    public init(chatID: String, targets: [DaemonChatAttachmentTarget]) {
        self.chatID = chatID
        self.targets = targets
    }
}

public struct DaemonSetChatAttachmentsReply: Codable, Equatable, Sendable {
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        outcome: DaemonMutationOutcome, events: [DaemonResourceChangeEvent]
    ) {
        self.outcome = outcome
        self.events = events
    }
}

/// `renameChat`: set a chat's title (bumps `updated_at`).
public struct DaemonRenameChatRequest: Codable, Equatable, Sendable {
    public let id: String
    public let to: String
    public init(id: String, to: String) {
        self.id = id
        self.to = to
    }
}

public struct DaemonRenameChatReply: Codable, Equatable, Sendable {
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        outcome: DaemonMutationOutcome, events: [DaemonResourceChangeEvent]
    ) {
        self.outcome = outcome
        self.events = events
    }
}

/// `setChatTitleIfEmpty`: set the title ONLY when the current title is
/// empty. Conditional emitter: `didWrite == false` commits with NO event
/// (empty `events`).
public struct DaemonSetChatTitleIfEmptyRequest: Codable, Equatable, Sendable {
    public let chatID: String
    public let title: String
    public init(chatID: String, title: String) {
        self.chatID = chatID
        self.title = title
    }
}

public struct DaemonSetChatTitleIfEmptyReply: Codable, Equatable, Sendable {
    public let didWrite: Bool
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        didWrite: Bool, outcome: DaemonMutationOutcome,
        events: [DaemonResourceChangeEvent]
    ) {
        self.didWrite = didWrite
        self.outcome = outcome
        self.events = events
    }
}

/// `setChatTitleIf`: replace the title ONLY when it still equals
/// `expectedTitle` (the provisional→final upgrade). Conditional emitter
/// like `setChatTitleIfEmpty`.
public struct DaemonSetChatTitleIfRequest: Codable, Equatable, Sendable {
    public let chatID: String
    public let expectedTitle: String
    public let title: String
    public init(chatID: String, expectedTitle: String, title: String) {
        self.chatID = chatID
        self.expectedTitle = expectedTitle
        self.title = title
    }
}

public struct DaemonSetChatTitleIfReply: Codable, Equatable, Sendable {
    public let didWrite: Bool
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        didWrite: Bool, outcome: DaemonMutationOutcome,
        events: [DaemonResourceChangeEvent]
    ) {
        self.didWrite = didWrite
        self.outcome = outcome
        self.events = events
    }
}

/// `deleteChat`: delete a chat (CASCADE removes messages; missing ids are
/// idempotent no-ops with no event).
public struct DaemonDeleteChatRequest: Codable, Equatable, Sendable {
    public let id: String
    public init(id: String) { self.id = id }
}

public struct DaemonDeleteChatReply: Codable, Equatable, Sendable {
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        outcome: DaemonMutationOutcome, events: [DaemonResourceChangeEvent]
    ) {
        self.outcome = outcome
        self.events = events
    }
}

/// `updateChatAcpSessionId`: write or clear the ACP resume session id.
public struct DaemonUpdateChatAcpSessionIdRequest: Codable, Equatable,
    Sendable {
    public let chatID: String
    /// nil clears (terminal teardown / permanent resume failure).
    public let acpSessionId: String?
    public init(chatID: String, acpSessionId: String?) {
        self.chatID = chatID
        self.acpSessionId = acpSessionId
    }
}

public struct DaemonUpdateChatAcpSessionIdReply: Codable, Equatable,
    Sendable {
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        outcome: DaemonMutationOutcome, events: [DaemonResourceChangeEvent]
    ) {
        self.outcome = outcome
        self.events = events
    }
}

/// `updateChatModelOverride`: write or clear the per-chat model override
/// while preserving its thinking fields.
public struct DaemonUpdateChatModelOverrideRequest: Codable, Equatable,
    Sendable {
    public let id: String
    public let providerId: String?
    public let modelId: String?
    public init(id: String, providerId: String?, modelId: String?) {
        self.id = id
        self.providerId = providerId
        self.modelId = modelId
    }
}

public struct DaemonUpdateChatModelOverrideReply: Codable, Equatable,
    Sendable {
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        outcome: DaemonMutationOutcome, events: [DaemonResourceChangeEvent]
    ) {
        self.outcome = outcome
        self.events = events
    }
}

/// `updateChatModelAndThinkingSelection`: atomically write provider/model +
/// configured intent + effective thinking value (exactly one event).
public struct DaemonUpdateChatModelAndThinkingSelectionRequest: Codable,
    Equatable, Sendable {
    public let chatID: String
    public let providerID: String?
    public let modelID: String?
    public let configuredThinkingID: String?
    public let effectiveThinkingID: String?

    public init(
        chatID: String, providerID: String?, modelID: String?,
        configuredThinkingID: String?, effectiveThinkingID: String?
    ) {
        self.chatID = chatID
        self.providerID = providerID
        self.modelID = modelID
        self.configuredThinkingID = configuredThinkingID
        self.effectiveThinkingID = effectiveThinkingID
    }
}

public struct DaemonUpdateChatModelAndThinkingSelectionReply: Codable,
    Equatable, Sendable {
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        outcome: DaemonMutationOutcome, events: [DaemonResourceChangeEvent]
    ) {
        self.outcome = outcome
        self.events = events
    }
}

/// `updateMessageSummary`: write the cached one-line summary for one
/// transcript item (the chat row is the change-emission resource).
public struct DaemonUpdateMessageSummaryRequest: Codable, Equatable,
    Sendable {
    public let chatID: String
    public let cursor: DaemonChatTranscriptCursor
    public let summary: String
    public let kind: DaemonChatMessageSummaryKind
    public init(
        chatID: String, cursor: DaemonChatTranscriptCursor, summary: String,
        kind: DaemonChatMessageSummaryKind
    ) {
        self.chatID = chatID
        self.cursor = cursor
        self.summary = summary
        self.kind = kind
    }
}

public struct DaemonUpdateMessageSummaryReply: Codable, Equatable, Sendable {
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        outcome: DaemonMutationOutcome, events: [DaemonResourceChangeEvent]
    ) {
        self.outcome = outcome
        self.events = events
    }
}

/// `finalizeStaleDrafts`: set `is_draft=0` for all of a chat's draft rows
/// (the interrupted-turn reopen settle).
public struct DaemonFinalizeStaleDraftsRequest: Codable, Equatable, Sendable {
    public let chatID: String
    public init(chatID: String) { self.chatID = chatID }
}

public struct DaemonFinalizeStaleDraftsReply: Codable, Equatable, Sendable {
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        outcome: DaemonMutationOutcome, events: [DaemonResourceChangeEvent]
    ) {
        self.outcome = outcome
        self.events = events
    }
}

/// `cancelUnclaimedPersistedChatTurn`: atomically cancel one unclaimed
/// queued turn IN PLACE (row, ordinal, submission identity retained).
/// nil = the row is absent or no longer queued (no event).
public struct DaemonCancelUnclaimedPersistedChatTurnRequest: Codable,
    Equatable, Sendable {
    public let chatID: String
    public let turnID: String
    public init(chatID: String, turnID: String) {
        self.chatID = chatID
        self.turnID = turnID
    }
}

public struct DaemonCancelUnclaimedPersistedChatTurnReply: Codable, Equatable,
    Sendable {
    public let turn: DaemonPersistedChatTurn?
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        turn: DaemonPersistedChatTurn?, outcome: DaemonMutationOutcome,
        events: [DaemonResourceChangeEvent]
    ) {
        self.turn = turn
        self.outcome = outcome
        self.events = events
    }
}

/// `markPersistedChatTurnProviderSubmitted`: the at-most-once boundary where
/// a claimed turn is handed to the provider/runtime.
public struct DaemonMarkPersistedChatTurnProviderSubmittedRequest: Codable,
    Equatable, Sendable {
    public let chatID: String
    public let turnID: String
    public let claimID: String
    public let providerSessionID: String?
    public let submittedAt: Date

    public init(
        chatID: String, turnID: String, claimID: String,
        providerSessionID: String?, submittedAt: Date
    ) {
        self.chatID = chatID
        self.turnID = turnID
        self.claimID = claimID
        self.providerSessionID = providerSessionID
        self.submittedAt = submittedAt
    }
}

public struct DaemonMarkPersistedChatTurnProviderSubmittedReply: Codable,
    Equatable, Sendable {
    public let turn: DaemonPersistedChatTurn
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        turn: DaemonPersistedChatTurn, outcome: DaemonMutationOutcome,
        events: [DaemonResourceChangeEvent]
    ) {
        self.turn = turn
        self.outcome = outcome
        self.events = events
    }
}

/// `updatePersistedChatTurnUsage`: record one turn's observed usage.
public struct DaemonUpdatePersistedChatTurnUsageRequest: Codable, Equatable,
    Sendable {
    public let chatID: String
    public let turnID: String
    public let claimID: String
    public let usage: DaemonChatTurnUsageValues
    public init(
        chatID: String, turnID: String, claimID: String,
        usage: DaemonChatTurnUsageValues
    ) {
        self.chatID = chatID
        self.turnID = turnID
        self.claimID = claimID
        self.usage = usage
    }
}

public struct DaemonUpdatePersistedChatTurnUsageReply: Codable, Equatable,
    Sendable {
    public let turn: DaemonPersistedChatTurn
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        turn: DaemonPersistedChatTurn, outcome: DaemonMutationOutcome,
        events: [DaemonResourceChangeEvent]
    ) {
        self.turn = turn
        self.outcome = outcome
        self.events = events
    }
}

// MARK: - Renderer settings (the renderer-settings seam)

/// `setRendererSourcePreference`: persist one source's renderer preference.
public struct DaemonSetRendererSourcePreferenceRequest: Codable, Equatable,
    Sendable {
    public let sourceID: String
    public let preference: DaemonRendererPreferenceReference
    public init(
        sourceID: String, preference: DaemonRendererPreferenceReference
    ) {
        self.sourceID = sourceID
        self.preference = preference
    }
}

public struct DaemonSetRendererSourcePreferenceReply: Codable, Equatable,
    Sendable {
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        outcome: DaemonMutationOutcome, events: [DaemonResourceChangeEvent]
    ) {
        self.outcome = outcome
        self.events = events
    }
}

/// `setRendererSourcePresentation`: persist one source's reader arrangement.
public struct DaemonSetRendererSourcePresentationRequest: Codable, Equatable,
    Sendable {
    public let sourceID: String
    public let presentation: DaemonRendererSourcePresentationMode
    public init(
        sourceID: String,
        presentation: DaemonRendererSourcePresentationMode
    ) {
        self.sourceID = sourceID
        self.presentation = presentation
    }
}

public struct DaemonSetRendererSourcePresentationReply: Codable, Equatable,
    Sendable {
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        outcome: DaemonMutationOutcome, events: [DaemonResourceChangeEvent]
    ) {
        self.outcome = outcome
        self.events = events
    }
}

/// `removeRendererSourcePresentation`: clear one source's arrangement
/// (missing rows are idempotent no-ops with no event).
public struct DaemonRemoveRendererSourcePresentationRequest: Codable,
    Equatable, Sendable {
    public let sourceID: String
    public init(sourceID: String) { self.sourceID = sourceID }
}

public struct DaemonRemoveRendererSourcePresentationReply: Codable, Equatable,
    Sendable {
    public let outcome: DaemonMutationOutcome
    public let events: [DaemonResourceChangeEvent]
    public init(
        outcome: DaemonMutationOutcome, events: [DaemonResourceChangeEvent]
    ) {
        self.outcome = outcome
        self.events = events
    }
}
#endif
