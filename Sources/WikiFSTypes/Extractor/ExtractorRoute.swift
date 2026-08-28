import Foundation

// pattern: Functional Core

/// One byte-extraction route: the `ExtractorKind` operation family plus the
/// normalized `ExtractorMIMEType` of the input that route converts.
///
/// Route identity is deliberately its own type, distinct from every namespace it
/// is assembled from:
///
/// - `ExtractorKind` is the manifest/protocol operation family (`.pdf`, `.html`)
///   and stays exactly that — a route adds the MIME dimension.
/// - `ExtractionBackendKind` / `ExtractionBackend` (WikiFSMarkdown) is the
///   engine-adapter namespace — which backend runs, not which input it accepts.
/// - `ContentCapabilities.ExtractionPath` is source-classification policy — how
///   a source is routed to an extraction path, not a persisted selection key.
///
/// MIME is the authoritative input identity: filename extensions stay
/// registration matching hints and are not part of the persisted route. Order is
/// deterministic (kind raw value, then MIME raw value) so persisted route
/// collections encode identically on every machine.
public struct ExtractorRouteID: Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public let kind: ExtractorKind
    public let mimeType: ExtractorMIMEType

    private enum CodingKeys: String, CodingKey { case kind, mimeType }

    public init(kind: ExtractorKind, mimeType: ExtractorMIMEType) {
        self.kind = kind
        self.mimeType = mimeType
    }

    /// Builds a route from a caller-supplied MIME string, normalizing surrounding
    /// whitespace and case before validation. Returns `nil` when the normalized
    /// string is still not a valid MIME type.
    public init?(normalizing kind: ExtractorKind, mimeTypeString: String) {
        let normalized = mimeTypeString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let mimeType = ExtractorMIMEType(rawValue: normalized) else { return nil }
        self.init(kind: kind, mimeType: mimeType)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try container.decode(ExtractorKind.self, forKey: .kind)
        self.mimeType = try container.decode(ExtractorMIMEType.self, forKey: .mimeType)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(mimeType, forKey: .mimeType)
    }

    /// Kind raw value first, then MIME raw value — the total order every
    /// persisted route collection is sorted by.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
        return lhs.mimeType < rhs.mimeType
    }

    public var description: String { "\(kind.rawValue) \(mimeType.rawValue)" }
}

public extension ExtractorRouteID {
    /// The PDF document route — the only PDF route current registrations and
    /// execution support.
    static let canonicalPDF = ExtractorRouteID.validatedCanonical(kind: .pdf, mimeTypeString: "application/pdf")

    /// The HTML document route — the only HTML route current registrations and
    /// execution support.
    static let canonicalHTML = ExtractorRouteID.validatedCanonical(kind: .html, mimeTypeString: "text/html")

    /// True for the two routes host execution supports today. Future package
    /// registrations may declare other MIME types; displaying and resolving them
    /// is the route table's job, while execution adapters for new kinds remain
    /// separate work.
    var isCanonical: Bool { self == .canonicalPDF || self == .canonicalHTML }

    private static func validatedCanonical(kind: ExtractorKind, mimeTypeString: String) -> ExtractorRouteID {
        guard let route = ExtractorRouteID(normalizing: kind, mimeTypeString: mimeTypeString) else {
            preconditionFailure("canonical route literal must be a valid MIME type: \(kind.rawValue) \(mimeTypeString)")
        }
        return route
    }
}
