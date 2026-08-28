import Foundation
import WikiFSTypes

/// One persisted route selection: a typed extraction route and the version-free
/// extractor reference chosen for it.
///
/// Records live in `ExtractionConfig.routeExtractors` as a deterministically
/// sorted array — not a string-keyed dictionary — so the persisted order is
/// canonical and duplicate route keys (possible in hand-edited files) remain
/// representable and resolvable instead of silently colliding in JSON.
public struct ExtractorRouteSelectionRecord: Codable, Hashable, Sendable, Comparable {
    public let route: ExtractorRouteID
    public let extractor: ExtractionBackendReference

    public init(route: ExtractorRouteID, extractor: ExtractionBackendReference) {
        self.route = route
        self.extractor = extractor
    }

    /// Total order: route first, then the canonical JSON encoding of the
    /// extractor reference as the tie-break, so two records for the same route
    /// have a stable winner independent of their original array positions.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.route != rhs.route { return lhs.route < rhs.route }
        return Self.canonicalJSON(lhs) < Self.canonicalJSON(rhs)
    }

    /// Canonical JSON of one record — the deterministic tie-break for records
    /// sharing a route. Encoding of this pure value type cannot fail; the empty
    /// fallback is unreachable and exists only for totality.
    fileprivate static func canonicalJSON(_ record: Self) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = DebugLog.trying("ExtractorRouteSelectionRecord canonicalJSON", operation: { try encoder.encode(record) }) else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }
}

public extension Array where Element == ExtractorRouteSelectionRecord {
    /// Deterministic normalization for persisted route records: sort into the
    /// canonical route order, then keep exactly one record per route — the
    /// canonically-greatest record wins, so the order records appear in inside a
    /// hand-edited file cannot change which selection survives.
    ///
    /// Returns the normalized array plus the number of dropped duplicates so the
    /// decode seam can emit one bounded diagnostic instead of one per record.
    func normalizedForPersistence() -> (records: Self, droppedDuplicates: Int) {
        let sortedRecords = sorted()
        var result: Self = []
        result.reserveCapacity(sortedRecords.count)
        var dropped = 0
        for record in sortedRecords {
            if let last = result.last, last.route == record.route {
                // Canonical sort order puts the greater record later, so the
                // incoming record always replaces the earlier duplicate.
                result[result.count - 1] = record
                dropped += 1
            } else {
                result.append(record)
            }
        }
        return (result, dropped)
    }
}
