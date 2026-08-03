import Foundation

/// The evidentiary relationship between an immutable page version and a
/// source. The raw values are the closed SQLite compatibility contract.
public enum PageVersionSourceRole: String, Codable, CaseIterable, Sendable {
    case primary
    case supporting
    case quoted
}

/// A persisted page-version-to-source provenance edge.
public struct PageVersionSource: Equatable, Hashable, Sendable {
    public let pageVersionID: PageVersionID
    public let sourceID: SourceID
    public let role: PageVersionSourceRole

    public init(pageVersionID: PageVersionID, sourceID: SourceID, role: PageVersionSourceRole) {
        self.pageVersionID = pageVersionID
        self.sourceID = sourceID
        self.role = role
    }
}

/// Typed source evidence supplied to a future page-version creation seam.
/// Phase 1 defines the contract; Phase 3 threads it through every writer.
public struct PageVersionSourceInput: Equatable, Hashable, Sendable {
    public let sourceID: SourceID
    public let role: PageVersionSourceRole

    public init(sourceID: SourceID, role: PageVersionSourceRole) {
        self.sourceID = sourceID
        self.role = role
    }

    /// Deterministic provenance for one agent ingest assignment. The assigned
    /// source is primary; later, distinct queue-payload sources are supporting.
    /// The queue payload is an external ordering contract, so conversion to
    /// typed inputs happens once at that boundary instead of in prompt text.
    public static func agentIngest(sourceIDs: [SourceID]) -> [Self] {
        var seen = Set<SourceID>()
        let distinct = sourceIDs.filter { seen.insert($0).inserted }
        guard let assigned = distinct.first else { return [] }
        return [Self(sourceID: assigned, role: .primary)]
            + distinct.dropFirst().map { Self(sourceID: $0, role: .supporting) }
    }
}

/// A source that prevents removal because an immutable page version cites it.
public struct ProvenanceDeletionBlocker: Equatable, Hashable, Sendable {
    public let sourceID: SourceID
    public let pageVersionID: PageVersionID
    public let pageID: PageID

    public init(sourceID: SourceID, pageVersionID: PageVersionID, pageID: PageID) {
        self.sourceID = sourceID
        self.pageVersionID = pageVersionID
        self.pageID = pageID
    }
}

/// A non-empty, persistently ordered collection of provenance deletion blockers.
public struct NonEmptyProvenanceDeletionBlockers: Equatable, Sendable {
    /// SQLite's deterministic page, version, source order. Consumers preserve
    /// this order when they present or further classify the restriction.
    public let ordered: [ProvenanceDeletionBlocker]

    /// Compatibility spelling for callers introduced before the order contract
    /// was named explicitly.
    public var values: [ProvenanceDeletionBlocker] { ordered }

    public init?(_ values: [ProvenanceDeletionBlocker]) {
        guard !values.isEmpty else { return nil }
        self.ordered = values
    }
}

/// The typed categories that can prevent destructive resource removal.
public enum ResourceDeletionRestriction: Error, Equatable, Sendable {
    case provenance(NonEmptyProvenanceDeletionBlockers)
}

/// Data-only input supplied to Issue #219's combined deletion-impact analysis.
/// Presentation and navigation remain owned by that later feature.
public enum Issue219DeletionAnalysisInput: Equatable, Sendable {
    case provenance(NonEmptyProvenanceDeletionBlockers)
}

public extension NonEmptyProvenanceDeletionBlockers {
    /// Preserves the persistence ordering and complete typed identities.
    var issue219DeletionAnalysisInput: Issue219DeletionAnalysisInput { .provenance(self) }
}

/// Rejections specific to the page-version provenance write boundary.
public enum PageVersionProvenanceWriteError: Error, Equatable, Sendable {
    case duplicateInput(sourceID: SourceID, role: PageVersionSourceRole)
    case invalidRole(rawValue: String)
    case missingSource(SourceID)
}
