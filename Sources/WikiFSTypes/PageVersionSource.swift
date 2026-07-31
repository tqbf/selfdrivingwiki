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
