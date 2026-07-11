import Foundation

/// Graph-model Phase 1 value types: the immutable, content-addressed **blob**,
/// the PROV-DM **agent** / **activity** provenance substrate, and the append-only
/// **source version** chain. See `plans/graph-model-and-versioning.md` §4.1–4.3.

/// An immutable, content-addressed object (git's "blob"). The bytes are NOT
/// held here — they live in the `blobs` table and are read on demand via the
/// hash. The value type carries only the identity (hash) and the size (a
/// denormalized convenience that mirrors `blobs.byte_size`).
///
/// Identical bytes hash to one row, ever (`INSERT OR IGNORE`): re-ingesting an
/// unchanged source adds zero blob bytes. See §4.1.
public struct Blob: Equatable, Sendable {
    /// Lowercase hex SHA-256 of the content — the primary key of `blobs`.
    public let hash: String
    /// `blobs.byte_size` (content length in bytes).
    public let byteSize: Int

    public init(hash: String, byteSize: Int) {
        self.hash = hash
        self.byteSize = byteSize
    }
}

/// A PROV-DM **Agent** (§4.7) — the responsible party behind an activity.
/// `kind ∈ {software, person, organization}`. An extraction names its backend
/// here (`pdf2md`, `claude-opus-4-8`, …) so "everything this agent produced" is
/// a join, not a string scan.
public struct ProvenanceAgent: Equatable, Sendable {
    public let id: String
    public let kind: String
    public let name: String
    /// Tool/model version (`0.3.1`, a model-card id), if known.
    public let version: String?
    /// Provider identity, model-card URL, … (PROV `external_ref`).
    public let externalRef: String?

    public init(id: String, kind: String, name: String,
                version: String? = nil, externalRef: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.version = version
        self.externalRef = externalRef
    }
}

/// A PROV-DM **Activity** (§4.7) — something that happened: a fetch, an
/// extraction, an edit, an import. `wasAssociatedWith` the agent via
/// `agentID`. `wasGeneratedBy` lives on the version row.
public struct ProvenanceActivity: Equatable, Sendable {
    public let id: String
    public let kind: String
    /// `wasAssociatedWith` — the agent responsible for this activity.
    public let agentID: String
    public let externalRef: String?
    public let startedAt: Date
    /// PROV `endTime`; a single-shot fetch sets it equal to `startedAt`.
    public let endedAt: Date?

    public init(id: String, kind: String, agentID: String,
                externalRef: String? = nil, startedAt: Date, endedAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.agentID = agentID
        self.externalRef = externalRef
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

/// One version in the append-only **content** version chain for a source
/// (§4.2). ULID-sorted: the active version is the `source-content` ref target
/// (or `MAX(id)` when no ref row exists — the default-active rule, §4.3).
///
/// `blobHash == nil` marks a **byteless** source (e.g. a YouTube video whose
/// working material is a derived transcript); `sourceContent` returns empty
/// `Data()` for those and never throws.
public struct SourceVersion: Equatable, Sendable {
    public let id: String
    public let sourceID: PageID
    /// `wasDerivedFrom` — the previous version's id; nil for v1.
    public let parentID: String?
    /// The content blob's hash; nil = byteless/external.
    public let blobHash: String?
    public let mimeType: String?
    /// `wasGeneratedBy` — the activity that produced this version.
    public let activityID: String?
    /// The canonical external identity (e.g. a YouTube video id).
    public let externalIdentity: String?
    /// Generation time (PROV `generatedAtTime`).
    public let fetchedAt: Date

    public init(id: String, sourceID: PageID, parentID: String?,
                blobHash: String?, mimeType: String?, activityID: String?,
                externalIdentity: String?, fetchedAt: Date) {
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

/// The kind of pointer a `refs` row holds (§4.3). Phase 1 ships `sourceContent`;
/// Phase 2 adds `sourceDerived` (the active extraction alternative). The
/// `version_id` a ref points at is polymorphic on `kind` and therefore carries no
/// FK (single-writer invariant: only `recordMarkdownExtraction`,
/// `setActiveMarkdown`, and `revertProcessedMarkdown` write `source-derived`).
public enum RefKind: String, Sendable {
    /// Active content version (`source_versions.id`).
    case sourceContent = "source-content"
    /// Active extraction alternative (`source_markdown_versions.id`).
    case sourceDerived = "source-derived"
    /// Active page-content version (`page_versions.id`). W0 (PR #312).
    case pageContent = "page-content"
}

/// A summary of one page version in the append-only chain (W0, PR #312).
/// Mirrors `SourceVersion` but for page bodies.
public struct PageVersionSummary: Equatable, Sendable {
    public let id: String
    public let pageID: PageID
    /// The previous version's id; nil for the root version.
    public let parentID: String?
    /// Non-nil when this version is a merge commit (W2+; nil in W0).
    public let mergeParentID: String?
    public let blobHash: String
    public let title: String
    public let activityID: String?
    public let savedAt: Date

    public init(id: String, pageID: PageID, parentID: String?,
                mergeParentID: String?, blobHash: String, title: String,
                activityID: String?, savedAt: Date) {
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

/// Thrown by `appendPageVersion` when a CAS check fails: another writer
/// committed a new version after the caller loaded the page, so the caller's
/// `expectedHeadVersionID` is stale. Carries the actual current head so the
/// caller can re-load and retry (W0, PR #312).
public struct PageConflictError: Error, Equatable {
    public let pageID: PageID
    public let expectedVersionID: String
    public let actualVersionID: String?

    public init(pageID: PageID, expectedVersionID: String, actualVersionID: String?) {
        self.pageID = pageID
        self.expectedVersionID = expectedVersionID
        self.actualVersionID = actualVersionID
    }
}
