import Foundation

/// Stable identifier for a single `QueueItem` — a unit of work in the persistent
/// processing queue (extraction or ingestion). Backed by a ULID string (see
/// `ULID`), so raw values sort lexicographically in creation order.
///
/// Typing it (rather than a bare `String`) means a typo cannot silently cross
/// wire a queue item against every other string the queue layer carries (page
/// ids, chat ids, wiki ids). Mirrors the `PageID` template:
/// `Hashable`/`Codable`/`Sendable`/`Identifiable`.
public struct QueueItemID: Hashable, Codable, RawRepresentable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension QueueItemID: Identifiable {
    public var id: String { rawValue }
}
