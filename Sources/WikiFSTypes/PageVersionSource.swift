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
    public let values: [ProvenanceDeletionBlocker]

    public init?(_ values: [ProvenanceDeletionBlocker]) {
        guard !values.isEmpty else { return nil }
        self.values = values
    }
}

/// The typed categories that can prevent destructive resource removal.
public enum ResourceDeletionRestriction: Error, Equatable, Sendable {
    case provenance(NonEmptyProvenanceDeletionBlockers)
}

/// Rejections specific to the page-version provenance write boundary.
public enum PageVersionProvenanceWriteError: Error, Equatable, Sendable {
    case duplicateInput(sourceID: SourceID, role: PageVersionSourceRole)
    case invalidRole(rawValue: String)
    case missingSource(SourceID)
}
