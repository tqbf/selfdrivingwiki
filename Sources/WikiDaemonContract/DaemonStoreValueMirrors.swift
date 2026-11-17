#if os(macOS)
import Foundation

// Contract-local mirrors of the WikiFSCore domain values the store family's
// per-operation DTOs carry (Phase 2a slice 2). This module stays
// dependency-free: every WikiFSCore value crosses as its own mirror with
// identical field semantics. Conventions (continuing slice 1):
//
// - IDs cross as their raw ULID / raw-value strings (``DaemonSourceSummary``'s
//   convention); each id namespace keeps its own FIELD name so a page id can
//   never be mistaken for a source id.
// - Domain enums mirror as contract enums with raw values byte-identical to
//   the domain raw values, so mapping is total and reversible.
// - Sets cross as deterministically sorted arrays; the sort is stated on the
//   field so the executor and client agree.
// - Oversized byte/string payloads (page bodies, markdown content, source
//   bytes, chunk arrays, embedding-work batches, index bodies) do NOT ride
//   inline: the DTO references a ``DaemonPayloadHandle`` and carries the byte
//   count so the client can reassemble and verify. Small metadata rides
//   inline. Bounded-inline exceptions are documented on the field.
// - Mutator replies embed ``DaemonMutationOutcome`` (the stamp + status echo)
//   and, where the commit emits, the ``DaemonResourceChangeEvent`` echo, so
//   exactly-once semantics and the emitted sequence are observable on the
//   reply itself.
//
// Like every file in this module: Foundation-only leaf, no WikiFSCore /
// WikiFSImports import, `#if os(macOS)` throughout.

// MARK: - Mutation outcome echo

/// The outcome echo every mutator reply carries: the admission stamp the
/// winning (or joined) submission presented, and the status that explains how
/// this reply relates to it (`committed` = this submission executed;
/// `joined` = an identical in-flight duplicate). Exactly-once observable on
/// the reply itself, without a second `resolveOutcome` round trip.
public struct DaemonMutationOutcome: Codable, Equatable, Sendable {
    public let stamp: DaemonMutationStamp
    public let status: DaemonOutcomeStatus

    public init(stamp: DaemonMutationStamp, status: DaemonOutcomeStatus) {
        self.stamp = stamp
        self.status = status
    }
}

/// Mirror of `ResourceChangeEvent` minus `wikiID` (the envelope already scopes
/// every store operation to one wiki, so the echo does not repeat it): the
/// kind, resource id, change kind, and monotonic sequence the model consumers
/// reconcile through. `kind` is `ResourceKind`'s raw value and `change` is
/// `ChangeKind`'s raw value; an unknown future kind decodes as the raw string
/// it carries.
public struct DaemonResourceChangeEvent: Codable, Equatable, Sendable {
    /// `ResourceKind` raw value; nil mirrors the core value's optional kind.
    public let kind: String?
    /// The resource's id as its raw string (the event's `id` verbatim).
    public let id: String
    /// `ChangeKind` raw value (`created` / `updated` / `deleted`).
    public let change: String
    /// The emitting bus's monotonic sequence (the changeToken watermark feed).
    public let seq: UInt64

    public init(kind: String?, id: String, change: String, seq: UInt64) {
        self.kind = kind
        self.id = id
        self.change = change
        self.seq = seq
    }
}

// MARK: - Pages

/// Mirror of `PageSortOrder` (raw values match the case names).
public enum DaemonPageSortOrder: String, Codable, Equatable, Sendable,
    CaseIterable {
    case lastUpdated
    case newestFirst
    case titleAZ
}

/// Mirror of `WikiPageSummary` (the sidebar/history page descriptor).
public struct DaemonPageSummary: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let updatedAt: Date
    public let createdAt: Date

    public init(id: String, title: String, updatedAt: Date, createdAt: Date) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.createdAt = createdAt
    }
}

/// Mirror of `WikiPage` WITHOUT `bodyMarkdown` — the body is oversized and
/// crosses via a ``DaemonPayloadHandle`` beside this metadata. The client
/// reassembles the core value from metadata + body bytes.
public struct DaemonPageMetadata: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let slug: String
    public let createdAt: Date
    public let updatedAt: Date
    public let version: Int
    /// Which agent/model created the page; nil mirrors the core optional.
    public let createdBy: String?
    /// Which agent/model last edited the page; nil mirrors the core optional.
    public let lastEditedBy: String?

    public init(
        id: String, title: String, slug: String, createdAt: Date,
        updatedAt: Date, version: Int, createdBy: String?,
        lastEditedBy: String?
    ) {
        self.id = id
        self.title = title
        self.slug = slug
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.version = version
        self.createdBy = createdBy
        self.lastEditedBy = lastEditedBy
    }
}

/// Mirror of `PageVersionSourceRole` (the SQLite compatibility raw values).
public enum DaemonPageVersionSourceRole: String, Codable, Equatable, Sendable,
    CaseIterable {
    case primary
    case supporting
    case quoted
}

/// Mirror of `PageVersionSourceInput` — typed source evidence supplied to a
/// page-version write.
public struct DaemonPageVersionSourceInput: Codable, Equatable, Sendable {
    public let sourceID: String
    public let role: DaemonPageVersionSourceRole

    public init(sourceID: String, role: DaemonPageVersionSourceRole) {
        self.sourceID = sourceID
        self.role = role
    }
}

/// Mirror of `PageVersionSource` — one persisted provenance edge.
public struct DaemonPageVersionSource: Codable, Equatable, Sendable {
    public let pageVersionID: String
    public let sourceID: String
    public let role: DaemonPageVersionSourceRole

    public init(
        pageVersionID: String, sourceID: String,
        role: DaemonPageVersionSourceRole
    ) {
        self.pageVersionID = pageVersionID
        self.sourceID = sourceID
        self.role = role
    }
}

/// Mirror of `CitedPage` — a page whose provenance cites a queried source.
public struct DaemonCitedPage: Codable, Equatable, Sendable {
    public let pageID: String
    /// The live title; nil when the page row has vanished (degrade honestly).
    public let title: String?

    public init(pageID: String, title: String?) {
        self.pageID = pageID
        self.title = title
    }
}

/// Mirror of `PageVersionSummary` — one node in a page's version chain.
public struct DaemonPageVersionSummary: Codable, Equatable, Sendable {
    public let id: String
    public let pageID: String
    public let parentID: String?
    public let mergeParentID: String?
    public let blobHash: String
    public let title: String
    public let activityID: String?
    public let savedAt: Date

    public init(
        id: String, pageID: String, parentID: String?, mergeParentID: String?,
        blobHash: String, title: String, activityID: String?, savedAt: Date
    ) {
        self.id = id
        self.pageID = pageID
        self.parentID = parentID
        self.mergeParentID = mergeParentID
        self.blobHash = blobHash
        self.title = title
        self.activityID = activityID
        self.savedAt = savedAt
    }
}

/// Mirror of `PageAuthor` — the typed author convention (`agents.name`).
/// Carries the raw string verbatim so unknown/future values round-trip
/// without data loss.
public struct DaemonPageAuthor: Codable, Equatable, Hashable, Sendable {
    /// The canonical `agents.name` string (`user`, `chat:<id>`,
    /// `agent:<kind>`, `legacy-import`, or any other stored value verbatim).
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Mirror of `PageOrigin` — the read-side provenance of one page version.
/// `agentName` mirrors the core `PageAuthor` enum as its raw convention
/// string; `agentKind` / `activityKind` mirror `AgentKind` / `ActivityKind`
/// raw values (unknown values cross verbatim and degrade daemon-side).
public struct DaemonPageOrigin: Codable, Equatable, Sendable {
    public let versionID: String
    public let title: String
    public let blobHash: String?
    public let agentName: DaemonPageAuthor
    /// `AgentKind` raw value (`human` / `chat` / `agent` / `software` /
    /// `model`).
    public let agentKind: String
    /// `ActivityKind` raw value (`import` / `edit` / any stored value).
    public let activityKind: String
    public let plan: String?
    public let externalRef: String?
    public let runTitle: String?
    public let savedAt: Date

    public init(
        versionID: String, title: String, blobHash: String?,
        agentName: DaemonPageAuthor, agentKind: String, activityKind: String,
        plan: String?, externalRef: String?, runTitle: String?, savedAt: Date
    ) {
        self.versionID = versionID
        self.title = title
        self.blobHash = blobHash
        self.agentName = agentName
        self.agentKind = agentKind
        self.activityKind = activityKind
        self.plan = plan
        self.externalRef = externalRef
        self.runTitle = runTitle
        self.savedAt = savedAt
    }
}

/// Mirror of `ParsedLink.LinkType` (raw values match).
public enum DaemonParsedLinkType: String, Codable, Equatable, Sendable,
    CaseIterable {
    case page
    case source
    case chat
}

/// Mirror of `ParsedLink` — one outgoing wiki-link to replace.
public struct DaemonParsedLink: Codable, Equatable, Sendable {
    public let linkType: DaemonParsedLinkType
    /// Prefix-stripped, whitespace-collapsed target (BASE only).
    public let target: String
    /// Everything after the first `#`, verbatim; nil when none.
    public let fragment: String?
    /// Alias verbatim (never prefix-stripped).
    public let linkText: String
    /// True for `![[source:…]]` embeds (source-only).
    public let isEmbed: Bool
    /// The digits of a trailing `@vN` pin; nil when unpinned.
    public let versionPin: String?

    public init(
        linkType: DaemonParsedLinkType, target: String, fragment: String?,
        linkText: String, isEmbed: Bool, versionPin: String?
    ) {
        self.linkType = linkType
        self.target = target
        self.fragment = fragment
        self.linkText = linkText
        self.isEmbed = isEmbed
        self.versionPin = versionPin
    }
}

/// Mirror of `PageWriteExpectation` — the expected-state contract for one
/// composed page write. `expectedHead` carries the raw page-version ULID.
public enum DaemonPageWriteExpectation: Codable, Equatable, Sendable {
    case unrestricted
    case expectedHead(versionID: String)
    case expectedAbsence
}

/// Mirror of `PageUpsert.Outcome` — the composed write's result.
public struct DaemonPageUpsertOutcome: Codable, Equatable, Sendable {
    public let id: String
    public let didCreate: Bool

    public init(id: String, didCreate: Bool) {
        self.id = id
        self.didCreate = didCreate
    }
}

// MARK: - Protected deletion

/// Mirror of `ResourceDeletionTarget` — the case tag keeps the two id
/// namespaces apart on the wire.
public enum DaemonResourceDeletionTarget: Codable, Equatable, Sendable {
    case page(id: String)
    case source(id: String)
}

/// Mirror of `ResourceDeletionLinkPolicy`.
public enum DaemonResourceDeletionLinkPolicy: String, Codable, Equatable,
    Sendable, CaseIterable {
    case preserve
    case unlink
}

/// Mirror of `ResourceDeletionRequest`. The core `Set` crosses as an array in
/// the canonical deterministic order (pages before sources, raw ULID
/// ascending within each kind — `ResourceDeletionTarget.sorted`).
public struct DaemonResourceDeletionRequest: Codable, Equatable, Sendable {
    public let targets: [DaemonResourceDeletionTarget]
    public let linkPolicy: DaemonResourceDeletionLinkPolicy

    public init(
        targets: [DaemonResourceDeletionTarget],
        linkPolicy: DaemonResourceDeletionLinkPolicy
    ) {
        self.targets = targets
        self.linkPolicy = linkPolicy
    }
}

/// Mirror of `DeletionLinkingPage`.
public struct DaemonDeletionLinkingPage: Codable, Equatable, Sendable {
    public let pageID: String
    public let title: String?

    public init(pageID: String, title: String?) {
        self.pageID = pageID
        self.title = title
    }
}

/// Mirror of `DeletionBookmarkImpact`.
public struct DaemonDeletionBookmarkImpact: Codable, Equatable, Sendable {
    public let nodeID: String
    public let folderPath: String

    public init(nodeID: String, folderPath: String) {
        self.nodeID = nodeID
        self.folderPath = folderPath
    }
}

/// Mirror of `DeletionImpact` — what references the deletion targets.
/// Blockers reuse slice 1's ``DaemonProvenanceDeletionBlocker``. Every
/// collection is in the core's deterministic order.
public struct DaemonDeletionImpact: Codable, Equatable, Sendable {
    public let linkingPages: [DaemonDeletionLinkingPage]
    public let bookmarks: [DaemonDeletionBookmarkImpact]
    public let provenanceBlockers: [DaemonProvenanceDeletionBlocker]
    public let incomingLinkCount: Int

    public init(
        linkingPages: [DaemonDeletionLinkingPage],
        bookmarks: [DaemonDeletionBookmarkImpact],
        provenanceBlockers: [DaemonProvenanceDeletionBlocker],
        incomingLinkCount: Int
    ) {
        self.linkingPages = linkingPages
        self.bookmarks = bookmarks
        self.provenanceBlockers = provenanceBlockers
        self.incomingLinkCount = incomingLinkCount
    }
}

/// Mirror of `ResourceDeletionResult` — the post-commit outcome of one
/// protected deletion, everything in the core's deterministic order.
public struct DaemonResourceDeletionResult: Codable, Equatable, Sendable {
    public let deletedTargets: [DaemonResourceDeletionTarget]
    public let rewrittenPageIDs: [String]
    public let removedBookmarkIDs: [String]
    public let incomingLinkCount: Int

    public init(
        deletedTargets: [DaemonResourceDeletionTarget],
        rewrittenPageIDs: [String], removedBookmarkIDs: [String],
        incomingLinkCount: Int
    ) {
        self.deletedTargets = deletedTargets
        self.rewrittenPageIDs = rewrittenPageIDs
        self.removedBookmarkIDs = removedBookmarkIDs
        self.incomingLinkCount = incomingLinkCount
    }
}

// MARK: - Sources

/// Mirror of `SourceVersion` — one node in a source's content chain.
public struct DaemonSourceVersion: Codable, Equatable, Sendable {
    public let id: String
    public let sourceID: String
    public let parentID: String?
    /// nil = byteless/external.
    public let blobHash: String?
    public let mimeType: String?
    public let activityID: String?
    public let externalIdentity: String?
    public let fetchedAt: Date

    public init(
        id: String, sourceID: String, parentID: String?, blobHash: String?,
        mimeType: String?, activityID: String?, externalIdentity: String?,
        fetchedAt: Date
    ) {
        self.id = id
        self.sourceID = sourceID
        self.parentID = parentID
        self.blobHash = blobHash
        self.mimeType = mimeType
        self.activityID = activityID
        self.externalIdentity = externalIdentity
        self.fetchedAt = fetchedAt
    }
}

/// Mirror of `SourceOrigin` — a source's read-side origin provenance.
public struct DaemonSourceOrigin: Codable, Equatable, Sendable {
    public let versionID: String
    public let agentName: String
    /// `AgentKind` raw value (degrades to `"software"` core-side).
    public let agentKind: String
    public let activityKind: String
    public let plan: String?
    public let externalRef: String?
    public let externalIdentity: String?
    public let runTitle: String?
    public let fetchedAt: Date

    public init(
        versionID: String, agentName: String, agentKind: String,
        activityKind: String, plan: String?, externalRef: String?,
        externalIdentity: String?, runTitle: String?, fetchedAt: Date
    ) {
        self.versionID = versionID
        self.agentName = agentName
        self.agentKind = agentKind
        self.activityKind = activityKind
        self.plan = plan
        self.externalRef = externalRef
        self.externalIdentity = externalIdentity
        self.runTitle = runTitle
        self.fetchedAt = fetchedAt
    }
}

/// Mirror of `SourceFetchState` (raw values match the column spec).
public enum DaemonSourceFetchState: String, Codable, Equatable, Sendable,
    CaseIterable {
    case pending
    case formatJobPending = "formatJobPending"
    case complete
}

/// Mirror of `SourceRole` (raw values match).
public enum DaemonSourceRole: String, Codable, Equatable, Sendable,
    CaseIterable {
    case primary
    case media
}

/// Mirror of `SourceProvenance` — the PROV-DM descriptor threaded into
/// `addSource` / `appendContentVersion` / `ensureFetchActivity`.
public struct DaemonSourceProvenance: Codable, Equatable, Sendable {
    public let agentName: String
    public let agentKind: String
    public let agentVersion: String?
    public let activityKind: String
    public let plan: String?
    public let externalRef: String?
    public let externalIdentity: String?

    public init(
        agentName: String, agentKind: String, agentVersion: String?,
        activityKind: String, plan: String?, externalRef: String?,
        externalIdentity: String?
    ) {
        self.agentName = agentName
        self.agentKind = agentKind
        self.agentVersion = agentVersion
        self.activityKind = activityKind
        self.plan = plan
        self.externalRef = externalRef
        self.externalIdentity = externalIdentity
    }
}

/// Mirror of `SourceIngestMetadata` — neutral external item metadata.
public struct DaemonSourceIngestMetadata: Codable, Equatable, Sendable {
    public let externalItemID: String?
    public let externalItemTitle: String?

    public init(externalItemID: String?, externalItemTitle: String?) {
        self.externalItemID = externalItemID
        self.externalItemTitle = externalItemTitle
    }
}

/// Mirror of `SourceMarkdownOrigin` (raw values match the column).
public enum DaemonSourceMarkdownOrigin: String, Codable, Equatable, Sendable,
    CaseIterable {
    case extraction
    case user
    case revert
    case source
    case transcript
}

/// Mirror of `SourceMarkdownVersion` WITHOUT `content` — the full-text body
/// is oversized and crosses via a ``DaemonPayloadHandle`` beside this header.
public struct DaemonSourceMarkdownVersionHeader: Codable, Equatable, Sendable {
    public let id: String
    public let sourceID: String
    public let parentID: String?
    public let origin: DaemonSourceMarkdownOrigin
    public let note: String?
    public let createdAt: Date
    public let activityID: String?
    public let sourceVersionID: String?
    public let blobHash: String?
    public let mimeType: String
    public let technique: String?

    public init(
        id: String, sourceID: String, parentID: String?,
        origin: DaemonSourceMarkdownOrigin, note: String?, createdAt: Date,
        activityID: String?, sourceVersionID: String?, blobHash: String?,
        mimeType: String, technique: String?
    ) {
        self.id = id
        self.sourceID = sourceID
        self.parentID = parentID
        self.origin = origin
        self.note = note
        self.createdAt = createdAt
        self.activityID = activityID
        self.sourceVersionID = sourceVersionID
        self.blobHash = blobHash
        self.mimeType = mimeType
        self.technique = technique
    }
}

/// Mirror of `ExtractorReportedMetadata` — a package's self-reported provenance.
public struct DaemonExtractorReportedMetadata: Codable, Equatable, Sendable {
    public let toolName: String?
    public let toolVersion: String?
    public let modelName: String?
    public let modelVersion: String?
    public let language: String?
    public let transcriptGenerated: Bool?

    public init(
        toolName: String?, toolVersion: String?, modelName: String?,
        modelVersion: String?, language: String?, transcriptGenerated: Bool?
    ) {
        self.toolName = toolName
        self.toolVersion = toolVersion
        self.modelName = modelName
        self.modelVersion = modelVersion
        self.language = language
        self.transcriptGenerated = transcriptGenerated
    }
}

/// Mirror of `ExtractorPackageExecutionProvenance` — the exact immutable
/// identity of one installed extractor package revision. The revision's
/// package id / version / digest cross as their raw strings (the digest as
/// lowercase hex).
public struct DaemonExtractorPackageProducer: Codable, Equatable, Sendable {
    public let packageID: String
    public let version: String
    /// The revision digest, lowercase hex.
    public let digestHex: String
    public let registrationID: String
    /// `ExtractorProtocolRevision` raw value.
    public let protocolRevision: String
    public let reportedMetadata: DaemonExtractorReportedMetadata

    public init(
        packageID: String, version: String, digestHex: String,
        registrationID: String, protocolRevision: String,
        reportedMetadata: DaemonExtractorReportedMetadata
    ) {
        self.packageID = packageID
        self.version = version
        self.digestHex = digestHex
        self.registrationID = registrationID
        self.protocolRevision = protocolRevision
        self.reportedMetadata = reportedMetadata
    }
}

/// Mirror of `ExtractionHostSpeechProducer` — the typed host-speech identity.
public struct DaemonExtractionHostSpeechProducer: Codable, Equatable, Sendable {
    public let engine: String
    public let localeID: String
    public let acquisitionFetcher: String

    public init(engine: String, localeID: String, acquisitionFetcher: String) {
        self.engine = engine
        self.localeID = localeID
        self.acquisitionFetcher = acquisitionFetcher
    }
}

/// Mirror of `ExtractionProducer` — the producer recovered from (or declared
/// for) a markdown version. `backend` / `tool` carry the closed-set raw
/// values (`ExtractionBackend` / `ExtractionTool`); `legacy` carries the raw
/// technique; package and host-speech carry their full mirrors.
public enum DaemonExtractionProducer: Codable, Equatable, Sendable {
    case backend(rawBackend: String)
    case tool(rawTool: String)
    case legacy(rawTechnique: String?)
    case installedPackage(DaemonExtractorPackageProducer)
    case hostSpeech(DaemonExtractionHostSpeechProducer)
}

/// Mirror of `ExtractionProvenance` — the typed read projection over one
/// markdown version's PROV records.
public struct DaemonExtractionProvenance: Codable, Equatable, Sendable {
    public let markdownVersionID: String
    public let sourceID: String
    public let origin: DaemonSourceMarkdownOrigin
    /// nil = legacy data supplied neither an activity nor a technique.
    public let producer: DaemonExtractionProducer?
    public let providerID: String?
    public let modelID: String?
    public let toolVersion: String?
    public let createdAt: Date
    public let sourceVersionID: String?

    public init(
        markdownVersionID: String, sourceID: String,
        origin: DaemonSourceMarkdownOrigin,
        producer: DaemonExtractionProducer?, providerID: String?,
        modelID: String?, toolVersion: String?, createdAt: Date,
        sourceVersionID: String?
    ) {
        self.markdownVersionID = markdownVersionID
        self.sourceID = sourceID
        self.origin = origin
        self.producer = producer
        self.providerID = providerID
        self.modelID = modelID
        self.toolVersion = toolVersion
        self.createdAt = createdAt
        self.sourceVersionID = sourceVersionID
    }
}

/// Mirror of `ExtractionAlternative` — one compare/nominate row. The wrapped
/// version's content crosses via a handle beside the alternative (the
/// alternative mirror carries the header only).
public struct DaemonExtractionAlternative: Codable, Equatable, Sendable {
    public let version: DaemonSourceMarkdownVersionHeader
    public let backendDisplayName: String
    public let agentName: String
    public let modelVersion: String?
    public let package: DaemonExtractorPackageProducer?
    public let charCount: Int
    public let isActive: Bool

    public init(
        version: DaemonSourceMarkdownVersionHeader,
        backendDisplayName: String, agentName: String, modelVersion: String?,
        package: DaemonExtractorPackageProducer?, charCount: Int,
        isActive: Bool
    ) {
        self.version = version
        self.backendDisplayName = backendDisplayName
        self.agentName = agentName
        self.modelVersion = modelVersion
        self.package = package
        self.charCount = charCount
        self.isActive = isActive
    }
}

/// Mirror of `SourceEmbedDescriptor` — one byteless source's provider embed.
public struct DaemonSourceEmbedDescriptor: Codable, Equatable, Sendable {
    public let id: String
    public let mimeType: String?
    public let externalIdentity: String?
    public let agentName: String?
    public let planURL: String?

    public init(
        id: String, mimeType: String?, externalIdentity: String?,
        agentName: String?, planURL: String?
    ) {
        self.id = id
        self.mimeType = mimeType
        self.externalIdentity = externalIdentity
        self.agentName = agentName
        self.planURL = planURL
    }
}

// MARK: - Content detection + MIME repair

/// Mirror of `DeclaredMIMEOrigin`.
public enum DaemonDeclaredMIMEOrigin: String, Codable, Equatable, Sendable,
    CaseIterable {
    case httpResponse
    case localUTI
    case trustedGenerated
}

/// Mirror of `DeclaredMIME`.
public struct DaemonDeclaredMIME: Codable, Equatable, Sendable {
    public let value: String
    public let origin: DaemonDeclaredMIMEOrigin

    public init(value: String, origin: DaemonDeclaredMIMEOrigin) {
        self.value = value
        self.origin = origin
    }
}

/// Mirror of `ContentTypeDetectionHints`.
public struct DaemonContentTypeDetectionHints: Codable, Equatable, Sendable {
    public let declaredMIME: DaemonDeclaredMIME?
    public let filenameExtension: String?
    public let utiMIME: String?

    public init(
        declaredMIME: DaemonDeclaredMIME?, filenameExtension: String?,
        utiMIME: String?
    ) {
        self.declaredMIME = declaredMIME
        self.filenameExtension = filenameExtension
        self.utiMIME = utiMIME
    }
}

/// Mirror of `ContentTypeConfidence` (the raw Int values match exactly).
public enum DaemonContentTypeConfidence: Int, Codable, Equatable, Sendable {
    case fallback = 10
    case declared = 20
    case probable = 30
    case high = 40
}

/// Mirror of `ContentTypeEvidenceOrigin`.
public enum DaemonContentTypeEvidenceOrigin: String, Codable, Equatable,
    Sendable, CaseIterable {
    case binarySignature
    case structuredBytes
    case utf8Text
    case httpResponse
    case trustedGenerated
    case uti
    case filenameExtension
}

/// Mirror of `ContentTypeEvidence`.
public struct DaemonContentTypeEvidence: Codable, Equatable, Sendable {
    public let origin: DaemonContentTypeEvidenceOrigin
    public let mimeType: String
    public let confidence: DaemonContentTypeConfidence
    public let detail: String?

    public init(
        origin: DaemonContentTypeEvidenceOrigin, mimeType: String,
        confidence: DaemonContentTypeConfidence, detail: String?
    ) {
        self.origin = origin
        self.mimeType = mimeType
        self.confidence = confidence
        self.detail = detail
    }
}

/// Mirror of `ContentTypeConflictKind`.
public enum DaemonContentTypeConflictKind: String, Codable, Equatable,
    Sendable, CaseIterable {
    case disagreement
    case trustedGeneratedMismatch
}

/// Mirror of `ContentTypeConflict`.
public struct DaemonContentTypeConflict: Codable, Equatable, Sendable {
    public let kind: DaemonContentTypeConflictKind
    public let chosenMIMEType: String
    public let conflictingEvidence: DaemonContentTypeEvidence

    public init(
        kind: DaemonContentTypeConflictKind, chosenMIMEType: String,
        conflictingEvidence: DaemonContentTypeEvidence
    ) {
        self.kind = kind
        self.chosenMIMEType = chosenMIMEType
        self.conflictingEvidence = conflictingEvidence
    }
}

/// Mirror of `ContentArtifactKind`.
public enum DaemonContentArtifactKind: String, Codable, Equatable, Sendable,
    CaseIterable {
    case jsonCanvas

    /// The mirror's sole case, exposed for total mappings in files the
    /// artifact-kind source guard does not allowlist (policy-side code
    /// must not name the kind).
    public static var sole: DaemonContentArtifactKind { .allCases[0] }
}

/// Mirror of `ContentTypeDetectionResult`.
public struct DaemonContentTypeDetectionResult: Codable, Equatable, Sendable {
    public let normalizedMIMEType: String?
    public let evidence: [DaemonContentTypeEvidence]
    public let confidence: DaemonContentTypeConfidence?
    public let conflicts: [DaemonContentTypeConflict]
    public let structuredArtifactKind: DaemonContentArtifactKind?

    public init(
        normalizedMIMEType: String?, evidence: [DaemonContentTypeEvidence],
        confidence: DaemonContentTypeConfidence?,
        conflicts: [DaemonContentTypeConflict],
        structuredArtifactKind: DaemonContentArtifactKind?
    ) {
        self.normalizedMIMEType = normalizedMIMEType
        self.evidence = evidence
        self.confidence = confidence
        self.conflicts = conflicts
        self.structuredArtifactKind = structuredArtifactKind
    }
}

/// Mirror of `MIMERepairNullState`.
public enum DaemonMIMERepairNullState: String, Codable, Equatable, Sendable,
    CaseIterable {
    case sourceOnly
    case activeVersionOnly
    case both
    case neither
}

/// Mirror of `MIMERepairStatus`.
public enum DaemonMIMERepairStatus: String, Codable, Equatable, Sendable,
    CaseIterable {
    case detectorRepair
    case packageAliasNormalization
    case canonicalNoOp
    case conflict
    case ambiguity
    case byteless
    case inconclusive
}

/// Mirror of `MIMERepairItem`.
public struct DaemonMIMERepairItem: Codable, Equatable, Sendable {
    public let sourceID: String
    public let sourceVersionID: String
    public let filename: String
    public let nullState: DaemonMIMERepairNullState
    public let oldSourceMIMEType: String?
    public let oldVersionMIMEType: String?
    public let newMIMEType: String?
    public let detection: DaemonContentTypeDetectionResult
    public let status: DaemonMIMERepairStatus
    public let updated: Bool

    public init(
        sourceID: String, sourceVersionID: String, filename: String,
        nullState: DaemonMIMERepairNullState, oldSourceMIMEType: String?,
        oldVersionMIMEType: String?, newMIMEType: String?,
        detection: DaemonContentTypeDetectionResult,
        status: DaemonMIMERepairStatus, updated: Bool
    ) {
        self.sourceID = sourceID
        self.sourceVersionID = sourceVersionID
        self.filename = filename
        self.nullState = nullState
        self.oldSourceMIMEType = oldSourceMIMEType
        self.oldVersionMIMEType = oldVersionMIMEType
        self.newMIMEType = newMIMEType
        self.detection = detection
        self.status = status
        self.updated = updated
    }
}

/// Mirror of `MIMERepairReport`.
public struct DaemonMIMERepairReport: Codable, Equatable, Sendable {
    public let scannedCount: Int
    public let repairableCount: Int
    public let updatedCount: Int
    public let skippedBytelessCount: Int
    public let skippedInconclusiveCount: Int
    public let applied: Bool
    public let items: [DaemonMIMERepairItem]

    public init(
        scannedCount: Int, repairableCount: Int, updatedCount: Int,
        skippedBytelessCount: Int, skippedInconclusiveCount: Int,
        applied: Bool, items: [DaemonMIMERepairItem]
    ) {
        self.scannedCount = scannedCount
        self.repairableCount = repairableCount
        self.updatedCount = updatedCount
        self.skippedBytelessCount = skippedBytelessCount
        self.skippedInconclusiveCount = skippedInconclusiveCount
        self.applied = applied
        self.items = items
    }
}

/// Mirror of `BlobVacuumReport`.
public struct DaemonBlobVacuumReport: Codable, Equatable, Sendable {
    public let orphanCount: Int
    public let bytesReclaimed: Int
    public let applied: Bool

    public init(orphanCount: Int, bytesReclaimed: Int, applied: Bool) {
        self.orphanCount = orphanCount
        self.bytesReclaimed = bytesReclaimed
        self.applied = applied
    }
}

/// Mirror of `ActivityVacuumReport`.
public struct DaemonActivityVacuumReport: Codable, Equatable, Sendable {
    public let orphanCount: Int
    public let applied: Bool

    public init(orphanCount: Int, applied: Bool) {
        self.orphanCount = orphanCount
        self.applied = applied
    }
}

/// Mirror of `PageVersionVacuumReport`.
public struct DaemonPageVersionVacuumReport: Codable, Equatable, Sendable {
    public let deletedCount: Int
    public let applied: Bool

    public init(deletedCount: Int, applied: Bool) {
        self.deletedCount = deletedCount
        self.applied = applied
    }
}

// MARK: - Wiki strategy

/// Mirror of `WikiStrategyState` — the committed strategy + revision read
/// atomically. Reuses slice 1's ``DaemonStrategySnapshot`` (bounded inline:
/// instructions ≤ `WikiStrategy.instructionsUTF8ByteLimit` = 32 KiB).
public struct DaemonWikiStrategyState: Codable, Equatable, Sendable {
    /// nil = the wiki uses the Default strategy.
    public let strategy: DaemonStrategySnapshot?
    /// `WikiStrategyRevision.rawValue`; nil = no row has ever been written.
    public let revision: Int64?

    public init(strategy: DaemonStrategySnapshot?, revision: Int64?) {
        self.strategy = strategy
        self.revision = revision
    }
}

/// Mirror of `WikiStrategySaveOutcome`. `saved` carries the advanced revision
/// and the committed strategy (nil when the save reset to Default, leaving a
/// tombstone row).
public enum DaemonWikiStrategySaveOutcome: Codable, Equatable, Sendable {
    case saved(revision: Int64, strategy: DaemonStrategySnapshot?)
    case unchanged
}

// MARK: - Renderer preferences

/// Mirror of `RendererReference` — pin to one immutable renderer registration.
public struct DaemonRendererReference: Codable, Equatable, Sendable {
    public let packageID: String
    public let version: String
    public let registrationID: String

    public init(
        packageID: String, version: String, registrationID: String
    ) {
        self.packageID = packageID
        self.version = version
        self.registrationID = registrationID
    }
}

/// Mirror of `LogicalRendererReference` — a preference that can resolve to a
/// compatible package version.
public struct DaemonLogicalRendererReference: Codable, Equatable, Sendable {
    public let packageID: String
    public let registrationID: String

    public init(packageID: String, registrationID: String) {
        self.packageID = packageID
        self.registrationID = registrationID
    }
}

/// Mirror of `RendererPreferenceReference`.
public enum DaemonRendererPreferenceReference: Codable, Equatable, Sendable {
    case exact(DaemonRendererReference)
    case logical(DaemonLogicalRendererReference)
}

/// Mirror of `RendererSourcePreference`. `updatedAt` is the
/// `RFC3339Timestamp` raw string (offset-bearing RFC3339, validated
/// daemon-side).
public struct DaemonRendererSourcePreference: Codable, Equatable, Sendable {
    public let sourceID: String
    public let preference: DaemonRendererPreferenceReference
    public let updatedAtRFC3339: String

    public init(
        sourceID: String, preference: DaemonRendererPreferenceReference,
        updatedAtRFC3339: String
    ) {
        self.sourceID = sourceID
        self.preference = preference
        self.updatedAtRFC3339 = updatedAtRFC3339
    }
}

/// Mirror of `RendererSourcePresentationMode`.
public enum DaemonRendererSourcePresentationMode: String, Codable, Equatable,
    Sendable, CaseIterable {
    case source
    case rendered
    case split
}

/// Mirror of `RendererSourcePresentation`.
public struct DaemonRendererSourcePresentation: Codable, Equatable, Sendable {
    public let sourceID: String
    public let presentation: DaemonRendererSourcePresentationMode
    public let updatedAtRFC3339: String

    public init(
        sourceID: String, presentation: DaemonRendererSourcePresentationMode,
        updatedAtRFC3339: String
    ) {
        self.sourceID = sourceID
        self.presentation = presentation
        self.updatedAtRFC3339 = updatedAtRFC3339
    }
}

/// Mirror of `RendererEmbeddedContent.InlineArtifact` — a host-owned inline
/// artifact a bridge input may name. Bounded inline: one fenced block's bytes
/// (the digest is recomputed daemon-side, so integrity is verifiable).
public struct DaemonRendererInlineArtifact: Codable, Equatable, Sendable {
    public let pageID: String
    public let pageVersionID: String
    /// `MarkdownBlockID` raw value.
    public let blockID: String
    /// `RendererFenceAlias` raw value.
    public let fenceAlias: String
    /// `RendererMIMEType` raw value.
    public let mimeType: String
    /// `RendererSHA256Digest` raw value (lowercase hex).
    public let digest: String
    public let bytes: Data

    public init(
        pageID: String, pageVersionID: String, blockID: String,
        fenceAlias: String, mimeType: String, digest: String, bytes: Data
    ) {
        self.pageID = pageID
        self.pageVersionID = pageVersionID
        self.blockID = blockID
        self.fenceAlias = fenceAlias
        self.mimeType = mimeType
        self.digest = digest
        self.bytes = bytes
    }
}

/// Mirror of `RendererBridgeInput` — the only bridge input targets.
public enum DaemonRendererBridgeInput: Codable, Equatable, Sendable {
    case source(versionID: String)
    case markdown(versionID: String)
    case inlineArtifact(DaemonRendererInlineArtifact)
}

// MARK: - Workspaces

/// Mirror of `WorkspaceStatus`.
public enum DaemonWorkspaceStatus: String, Codable, Equatable, Sendable,
    CaseIterable {
    case open
    case merging
    case merged
    case conflicted
    case abandoned
}

/// Mirror of `WorkspaceSummary`.
public struct DaemonWorkspaceSummary: Codable, Equatable, Sendable {
    public let id: String
    public let name: String?
    public let status: DaemonWorkspaceStatus
    public let activityID: String?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: String, name: String?, status: DaemonWorkspaceStatus,
        activityID: String?, createdAt: Date, updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.activityID = activityID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Mirror of `WorkspaceRef` — one page-overlay row.
public struct DaemonWorkspaceRef: Codable, Equatable, Sendable {
    public let workspaceID: String
    public let ownerID: String
    public let baseVersionID: String?
    public let versionID: String?
    public let blobHash: String?
    public let title: String?
    public let updatedAt: Date

    public init(
        workspaceID: String, ownerID: String, baseVersionID: String?,
        versionID: String?, blobHash: String?, title: String?, updatedAt: Date
    ) {
        self.workspaceID = workspaceID
        self.ownerID = ownerID
        self.baseVersionID = baseVersionID
        self.versionID = versionID
        self.blobHash = blobHash
        self.title = title
        self.updatedAt = updatedAt
    }
}

/// Mirror of `WorkspaceConflict.Target` — the workspace-side version the
/// conflict carries.
public enum DaemonWorkspaceConflictTarget: Codable, Equatable, Sendable {
    case pageVersion(id: String)
    case stagedBlob(hash: String)
}

/// Mirror of `WorkspaceConflict`.
public struct DaemonWorkspaceConflict: Codable, Equatable, Sendable {
    public let workspaceID: String
    public let pageID: String
    public let baseVersionID: String?
    public let mainVersionID: String?
    public let workspaceTarget: DaemonWorkspaceConflictTarget
    public let createdAt: Date

    public init(
        workspaceID: String, pageID: String, baseVersionID: String?,
        mainVersionID: String?,
        workspaceTarget: DaemonWorkspaceConflictTarget, createdAt: Date
    ) {
        self.workspaceID = workspaceID
        self.pageID = pageID
        self.baseVersionID = baseVersionID
        self.mainVersionID = mainVersionID
        self.workspaceTarget = workspaceTarget
        self.createdAt = createdAt
    }
}

// MARK: - Log + wiki index

/// Mirror of `LogEntry` — one append-only log row.
public struct DaemonLogEntry: Codable, Equatable, Sendable {
    /// `LogEntry.Kind` raw value (`ingest` / `query` / `lint`).
    public enum Kind: String, Codable, Equatable, Sendable, CaseIterable {
        case ingest
        case query
        case lint
    }

    public let id: String
    public let timestamp: Date
    public let kind: Kind
    public let title: String
    public let note: String?

    public init(
        id: String, timestamp: Date, kind: Kind, title: String, note: String?
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.title = title
        self.note = note
    }
}

/// Mirror of `WikiIndex` WITHOUT `body` — the curated catalog document's body
/// is unbounded and crosses via a ``DaemonPayloadHandle`` beside this header.
public struct DaemonWikiIndexMetadata: Codable, Equatable, Sendable {
    public let updatedAt: Date
    public let version: Int

    public init(updatedAt: Date, version: Int) {
        self.updatedAt = updatedAt
        self.version = version
    }
}

// MARK: - Bookmarks

/// Mirror of `BookmarkNode.Content` — the case tag keeps the id namespaces
/// apart on the wire.
public enum DaemonBookmarkContent: Codable, Equatable, Sendable {
    case folder(label: String)
    case page(id: String)
    case source(id: String)
    case chat(id: String)
}

/// Mirror of `BookmarkNode` — one row of the bookmark tree (flat; parents
/// precede children).
public struct DaemonBookmarkNode: Codable, Equatable, Sendable {
    public let id: String
    public let parentID: String?
    public let position: Int
    public let content: DaemonBookmarkContent
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: String, parentID: String?, position: Int,
        content: DaemonBookmarkContent, createdAt: Date, updatedAt: Date
    ) {
        self.id = id
        self.parentID = parentID
        self.position = position
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Chats

/// Mirror of `ChatKind`.
public enum DaemonChatKind: String, Codable, Equatable, Sendable, CaseIterable {
    case edit
}

/// Mirror of `ChatSummary`.
public struct DaemonChatSummary: Codable, Equatable, Sendable {
    public let id: String
    public let kind: DaemonChatKind
    public let title: String
    public let createdAt: Date
    public let updatedAt: Date
    public let messageCount: Int
    public let acpSessionId: String?
    public let modelProviderId: String?
    public let modelId: String?
    public let configuredThinkingOptionID: String?
    public let effectiveThinkingOptionID: String?

    public init(
        id: String, kind: DaemonChatKind, title: String, createdAt: Date,
        updatedAt: Date, messageCount: Int, acpSessionId: String?,
        modelProviderId: String?, modelId: String?,
        configuredThinkingOptionID: String?,
        effectiveThinkingOptionID: String?
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messageCount = messageCount
        self.acpSessionId = acpSessionId
        self.modelProviderId = modelProviderId
        self.modelId = modelId
        self.configuredThinkingOptionID = configuredThinkingOptionID
        self.effectiveThinkingOptionID = effectiveThinkingOptionID
    }
}

/// Mirror of `ChatAttachmentTarget`.
public enum DaemonChatAttachmentTarget: Codable, Equatable, Sendable {
    case page(id: String)
    case source(id: String)
    case chat(id: String)
}

/// Mirror of `TurnFailureReason` — the structured reason a turn failed.
public enum DaemonTurnFailureReason: Codable, Equatable, Sendable {
    case stalled(idleSeconds: Double)
    case ceilingExceeded(totalSeconds: Double)
    case agentError(message: String)
    case quotaExhausted(providerID: String, resetTime: Date?)
}

/// Mirror of `AgentEvent` — one renderable agent event, all cases with
/// associated values intact. Case names and payload semantics match the core
/// enum; `.raw` carries undecodable text verbatim.
public enum DaemonAgentEvent: Codable, Equatable, Sendable {
    case userText(text: String)
    case systemInit(model: String)
    case assistantText(text: String)
    case thinking(text: String)
    case thinkingDelta(text: String)
    case assistantTextDelta(text: String)
    case toolUse(name: String, inputSummary: String)
    case toolResult(isError: Bool, summary: String?)
    case subagent(
        subagentType: String, description: String, isCompletion: Bool)
    case result(isError: Bool, text: String)
    case messageStop
    case turnFailed(reason: DaemonTurnFailureReason)
    case raw(line: String)
}

/// Mirror of `ChatMessage`.
public struct DaemonChatMessage: Codable, Equatable, Sendable {
    public let id: String
    public let chatID: String
    /// Dense, 0-based per-chat ordering (assigned by the store on append).
    public let seq: Int
    public let event: DaemonAgentEvent
    public let createdAt: Date
    public let isDraft: Bool

    public init(
        id: String, chatID: String, seq: Int, event: DaemonAgentEvent,
        createdAt: Date, isDraft: Bool
    ) {
        self.id = id
        self.chatID = chatID
        self.seq = seq
        self.event = event
        self.createdAt = createdAt
        self.isDraft = isDraft
    }
}

/// Mirror of `ChatMessageSummaryKind` (raw values match the column spec).
public enum DaemonChatMessageSummaryKind: String, Codable, Equatable, Sendable,
    CaseIterable {
    case defaultTruncation = "default"
    case model = "model"
}

/// Mirror of `ChatTranscriptCursor` — the monotonic per-chat transcript
/// cursor (Int64 raw value).
public struct DaemonChatTranscriptCursor: Codable, Equatable, Sendable {
    public let rawValue: Int64

    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }
}

/// Mirror of `ChatContextReference`.
public enum DaemonChatContextReference: Codable, Equatable, Sendable {
    case page(id: String)
    case source(id: String)
    case chat(id: String)
}

/// Mirror of `ChatTurnSubmission` — one durable user turn before provider
/// prompt shaping.
public struct DaemonChatTurnSubmission: Codable, Equatable, Sendable {
    public let commandID: String
    public let turnID: String
    public let userText: String
    public let contextReferences: [DaemonChatContextReference]
    public let submittedAt: Date

    public init(
        commandID: String, turnID: String, userText: String,
        contextReferences: [DaemonChatContextReference], submittedAt: Date
    ) {
        self.commandID = commandID
        self.turnID = turnID
        self.userText = userText
        self.contextReferences = contextReferences
        self.submittedAt = submittedAt
    }
}

/// Mirror of `ChatTurnPersistenceState`.
public enum DaemonChatTurnPersistenceState: String, Codable, Equatable,
    Sendable, CaseIterable {
    case queued
    case claimed
    case providerSubmitted
    case completed
    case cancelled
    case failed
}

/// Mirror of `ChatTurnUsageValues` — the mutable usage subset.
public struct DaemonChatTurnUsageValues: Codable, Equatable, Sendable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let thoughtTokens: Int?
    public let cacheReadTokens: Int?
    public let cacheWriteTokens: Int?
    public let cost: Decimal?
    public let currency: String?

    public init(
        inputTokens: Int?, outputTokens: Int?, thoughtTokens: Int?,
        cacheReadTokens: Int?, cacheWriteTokens: Int?, cost: Decimal?,
        currency: String?
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.thoughtTokens = thoughtTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.cost = cost
        self.currency = currency
    }
}

/// Mirror of `ChatTurnUsage` — the full usage record for one turn.
public struct DaemonChatTurnUsage: Codable, Equatable, Sendable {
    public let turnID: String
    public let providerID: String?
    public let modelID: String?
    public let startedAt: Date?
    public let finishedAt: Date?
    public let state: DaemonChatTurnPersistenceState
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let thoughtTokens: Int?
    public let cacheReadTokens: Int?
    public let cacheWriteTokens: Int?
    public let cost: Decimal?
    public let currency: String?

    public init(
        turnID: String, providerID: String?, modelID: String?,
        startedAt: Date?, finishedAt: Date?,
        state: DaemonChatTurnPersistenceState, inputTokens: Int?,
        outputTokens: Int?, thoughtTokens: Int?, cacheReadTokens: Int?,
        cacheWriteTokens: Int?, cost: Decimal?, currency: String?
    ) {
        self.turnID = turnID
        self.providerID = providerID
        self.modelID = modelID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.state = state
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.thoughtTokens = thoughtTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.cost = cost
        self.currency = currency
    }
}

/// Mirror of `ChatUsageSummary` — aggregate durable usage for one chat.
public struct DaemonChatUsageSummary: Codable, Equatable, Sendable {
    public let latestTurn: DaemonChatTurnUsage?
    public let inputTokens: Int
    public let outputTokens: Int
    public let thoughtTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int
    public let cost: Decimal?
    public let currency: String?

    public init(
        latestTurn: DaemonChatTurnUsage?, inputTokens: Int, outputTokens: Int,
        thoughtTokens: Int, cacheReadTokens: Int, cacheWriteTokens: Int,
        cost: Decimal?, currency: String?
    ) {
        self.latestTurn = latestTurn
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.thoughtTokens = thoughtTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.cost = cost
        self.currency = currency
    }
}

/// Mirror of `PersistedChatTurn` — one durable turn row.
public struct DaemonPersistedChatTurn: Codable, Equatable, Sendable {
    public let chatID: String
    public let ordinal: Int
    public let submission: DaemonChatTurnSubmission
    public let editedAt: Date?
    public let state: DaemonChatTurnPersistenceState
    public let claimID: String?
    public let claimedAt: Date?
    public let providerSubmittedAt: Date?
    public let providerSessionID: String?
    public let terminalMessage: String?
    public let providerID: String?
    public let modelID: String?
    public let finishedAt: Date?
    public let usage: DaemonChatTurnUsageValues

    public init(
        chatID: String, ordinal: Int, submission: DaemonChatTurnSubmission,
        editedAt: Date?, state: DaemonChatTurnPersistenceState,
        claimID: String?, claimedAt: Date?, providerSubmittedAt: Date?,
        providerSessionID: String?, terminalMessage: String?,
        providerID: String?, modelID: String?, finishedAt: Date?,
        usage: DaemonChatTurnUsageValues
    ) {
        self.chatID = chatID
        self.ordinal = ordinal
        self.submission = submission
        self.editedAt = editedAt
        self.state = state
        self.claimID = claimID
        self.claimedAt = claimedAt
        self.providerSubmittedAt = providerSubmittedAt
        self.providerSessionID = providerSessionID
        self.terminalMessage = terminalMessage
        self.providerID = providerID
        self.modelID = modelID
        self.finishedAt = finishedAt
        self.usage = usage
    }
}

/// Mirror of `ChatTranscriptMessageRole`.
public enum DaemonChatTranscriptMessageRole: String, Codable, Equatable,
    Sendable, CaseIterable {
    case user
    case assistant
    case reasoning
}

/// Mirror of `ChatToolCallStatus`.
public enum DaemonChatToolCallStatus: String, Codable, Equatable, Sendable,
    CaseIterable {
    case pending
    case running
    case completed
    case failed
    case cancelled
}

/// Mirror of `ChatTurnFailureCategory`.
public enum DaemonChatTurnFailureCategory: String, Codable, Equatable,
    Sendable, CaseIterable {
    case cancelled
    case interrupted
    case runtimeError
    case permissionDenied
    case transportError
}

/// Mirror of `ChatSystemNoticeKind`.
public enum DaemonChatSystemNoticeKind: String, Codable, Equatable, Sendable,
    CaseIterable {
    case session
    case recovery
    case queue
    case diagnostics
}

/// Mirror of `ChatTranscriptMessageItem`.
public struct DaemonChatTranscriptMessageItem: Codable, Equatable, Sendable {
    public let messageID: String
    public let turnID: String
    public let role: DaemonChatTranscriptMessageRole
    public let text: String
    public let createdAt: Date

    public init(
        messageID: String, turnID: String,
        role: DaemonChatTranscriptMessageRole, text: String, createdAt: Date
    ) {
        self.messageID = messageID
        self.turnID = turnID
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}

/// Mirror of `ChatTranscriptToolCallItem`.
public struct DaemonChatTranscriptToolCallItem: Codable, Equatable, Sendable {
    public let toolCallID: String
    public let turnID: String
    public let toolName: String
    public let status: DaemonChatToolCallStatus
    public let detail: String?
    public let output: String?
    public let permissionRequestID: String?
    public let updatedAt: Date

    public init(
        toolCallID: String, turnID: String, toolName: String,
        status: DaemonChatToolCallStatus, detail: String?, output: String?,
        permissionRequestID: String?, updatedAt: Date
    ) {
        self.toolCallID = toolCallID
        self.turnID = turnID
        self.toolName = toolName
        self.status = status
        self.detail = detail
        self.output = output
        self.permissionRequestID = permissionRequestID
        self.updatedAt = updatedAt
    }
}

/// Mirror of `ChatTranscriptSystemNoticeItem`.
public struct DaemonChatTranscriptSystemNoticeItem: Codable, Equatable,
    Sendable {
    public let noticeID: String
    public let turnID: String?
    public let kind: DaemonChatSystemNoticeKind
    public let title: String
    public let message: String
    public let createdAt: Date

    public init(
        noticeID: String, turnID: String?, kind: DaemonChatSystemNoticeKind,
        title: String, message: String, createdAt: Date
    ) {
        self.noticeID = noticeID
        self.turnID = turnID
        self.kind = kind
        self.title = title
        self.message = message
        self.createdAt = createdAt
    }
}

/// Mirror of `ChatTranscriptTurnFailureItem`.
public struct DaemonChatTranscriptTurnFailureItem: Codable, Equatable,
    Sendable {
    public let failureID: String
    public let turnID: String
    public let category: DaemonChatTurnFailureCategory
    public let message: String
    public let createdAt: Date

    public init(
        failureID: String, turnID: String,
        category: DaemonChatTurnFailureCategory, message: String,
        createdAt: Date
    ) {
        self.failureID = failureID
        self.turnID = turnID
        self.category = category
        self.message = message
        self.createdAt = createdAt
    }
}

/// Mirror of `ChatTranscriptItem` — the durable transcript vocabulary.
public enum DaemonChatTranscriptItem: Codable, Equatable, Sendable {
    case message(DaemonChatTranscriptMessageItem)
    case toolCall(DaemonChatTranscriptToolCallItem)
    case systemNotice(DaemonChatTranscriptSystemNoticeItem)
    case turnFailure(DaemonChatTranscriptTurnFailureItem)
}

/// Mirror of `PersistedChatTranscriptItem`.
public struct DaemonPersistedChatTranscriptItem: Codable, Equatable, Sendable {
    public let cursor: DaemonChatTranscriptCursor
    public let item: DaemonChatTranscriptItem
    public let projectedEventJSON: String?
    public let projectedPlainText: String
    public let createdAt: Date
    public let summary: String?

    public init(
        cursor: DaemonChatTranscriptCursor,
        item: DaemonChatTranscriptItem, projectedEventJSON: String?,
        projectedPlainText: String, createdAt: Date, summary: String?
    ) {
        self.cursor = cursor
        self.item = item
        self.projectedEventJSON = projectedEventJSON
        self.projectedPlainText = projectedPlainText
        self.createdAt = createdAt
        self.summary = summary
    }
}

/// Mirror of `ChatTranscriptPage` — one typed transcript page plus the
/// high-water checkpoint visible at read time.
public struct DaemonChatTranscriptPage: Codable, Equatable, Sendable {
    public let items: [DaemonPersistedChatTranscriptItem]
    public let checkpoint: DaemonChatTranscriptCursor
    public let nextCursor: DaemonChatTranscriptCursor?

    public init(
        items: [DaemonPersistedChatTranscriptItem],
        checkpoint: DaemonChatTranscriptCursor,
        nextCursor: DaemonChatTranscriptCursor?
    ) {
        self.items = items
        self.checkpoint = checkpoint
        self.nextCursor = nextCursor
    }
}

// MARK: - OKF trust

/// Mirror of `OKFConceptStatus`.
public enum DaemonOKFConceptStatus: String, Codable, Equatable, Sendable,
    CaseIterable {
    case draft
    case stable
    case deprecated
}

/// Mirror of `OKFVerifierIdentity.Kind`.
public enum DaemonOKFVerifierKind: String, Codable, Equatable, Sendable,
    CaseIterable {
    case human
    case process
    case producer
}

/// Mirror of `OKFVerifierIdentity` — the parsed verifier identity.
public struct DaemonOKFVerifierIdentity: Codable, Equatable, Sendable {
    /// The validated raw identity string (`human:<name>` / `process:<name>` /
    /// `<producer>/<version>`).
    public let rawValue: String
    public let kind: DaemonOKFVerifierKind
    public let name: String
    public let version: String?

    public init(
        rawValue: String, kind: DaemonOKFVerifierKind, name: String,
        version: String?
    ) {
        self.rawValue = rawValue
        self.kind = kind
        self.name = name
        self.version = version
    }
}

/// Mirror of `OKFVerificationBasisKind` (raw values match).
public enum DaemonOKFVerificationBasisKind: String, Codable, Equatable,
    Sendable, CaseIterable {
    case humanReview = "human-review"
    case sourceChecked = "source-checked"
    case externalRevalidation = "external-revalidation"
}

/// Mirror of `OKFEvidenceReference`.
public enum DaemonOKFEvidenceReference: Codable, Equatable, Sendable {
    case source(id: String)
    /// The absolute URL string of the external evidence.
    case external(url: String)
}

/// Mirror of `OKFVerificationBasis`.
public struct DaemonOKFVerificationBasis: Codable, Equatable, Sendable {
    public let version: Int
    public let kind: DaemonOKFVerificationBasisKind
    public let evidence: [DaemonOKFEvidenceReference]
    public let note: String?

    public init(
        version: Int, kind: DaemonOKFVerificationBasisKind,
        evidence: [DaemonOKFEvidenceReference], note: String?
    ) {
        self.version = version
        self.kind = kind
        self.evidence = evidence
        self.note = note
    }
}

/// Mirror of `OKFVerificationCorrectionReason`.
public struct DaemonOKFVerificationCorrectionReason: Codable, Equatable,
    Sendable {
    public let version: Int
    public let reason: String

    public init(version: Int, reason: String) {
        self.version = version
        self.reason = reason
    }
}

/// Mirror of `OKFFreshnessAnchor`.
public enum DaemonOKFFreshnessAnchor: Codable, Equatable, Sendable {
    case generated
    case verification(id: String)
    /// Valid only while recording a verification in the same transaction.
    case recordedVerification
}

/// Mirror of `OKFFreshnessPolicy`.
public enum DaemonOKFFreshnessPolicy: Codable, Equatable, Sendable {
    case fixed(date: Date)
    case ttl(seconds: Int64, anchor: DaemonOKFFreshnessAnchor)
}

/// Mirror of `OKFVerificationEvent` — one verification (active or removed).
public struct DaemonOKFVerificationEvent: Codable, Equatable, Sendable {
    public let id: String
    public let by: DaemonOKFVerifierIdentity
    public let verifiedAt: Date
    public let basis: DaemonOKFVerificationBasis
    public let removedAt: Date?
    public let correctionActivityID: String?
    public let correctedBy: DaemonOKFVerifierIdentity?
    public let correctionReason: DaemonOKFVerificationCorrectionReason?

    public init(
        id: String, by: DaemonOKFVerifierIdentity, verifiedAt: Date,
        basis: DaemonOKFVerificationBasis, removedAt: Date?,
        correctionActivityID: String?,
        correctedBy: DaemonOKFVerifierIdentity?,
        correctionReason: DaemonOKFVerificationCorrectionReason?
    ) {
        self.id = id
        self.by = by
        self.verifiedAt = verifiedAt
        self.basis = basis
        self.removedAt = removedAt
        self.correctionActivityID = correctionActivityID
        self.correctedBy = correctedBy
        self.correctionReason = correctionReason
    }
}

/// Mirror of `OKFConceptMetadata` — the exact-version OKF trust metadata.
public struct DaemonOKFConceptMetadata: Codable, Equatable, Sendable {
    public let status: DaemonOKFConceptStatus?
    public let staleAfter: Date?
    public let freshnessPolicy: DaemonOKFFreshnessPolicy?
    /// Sorted by `(verifiedAt, id)` — the core initializer's order.
    public let verifications: [DaemonOKFVerificationEvent]
    public let projectionRevision: Int64

    public init(
        status: DaemonOKFConceptStatus?, staleAfter: Date?,
        freshnessPolicy: DaemonOKFFreshnessPolicy?,
        verifications: [DaemonOKFVerificationEvent], projectionRevision: Int64
    ) {
        self.status = status
        self.staleAfter = staleAfter
        self.freshnessPolicy = freshnessPolicy
        self.verifications = verifications
        self.projectionRevision = projectionRevision
    }
}

/// Mirror of `PageOKFTrustMetadata`.
public struct DaemonPageOKFTrustMetadata: Codable, Equatable, Sendable {
    public let pageID: String
    public let versionID: String
    public let metadata: DaemonOKFConceptMetadata

    public init(
        pageID: String, versionID: String,
        metadata: DaemonOKFConceptMetadata
    ) {
        self.pageID = pageID
        self.versionID = versionID
        self.metadata = metadata
    }
}

/// Mirror of `SourceMarkdownOKFTrustMetadata`.
public struct DaemonSourceMarkdownOKFTrustMetadata: Codable, Equatable,
    Sendable {
    public let sourceID: String
    public let versionID: String
    public let metadata: DaemonOKFConceptMetadata

    public init(
        sourceID: String, versionID: String,
        metadata: DaemonOKFConceptMetadata
    ) {
        self.sourceID = sourceID
        self.versionID = versionID
        self.metadata = metadata
    }
}
#endif
