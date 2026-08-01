import Foundation

// pattern: Functional Core

public enum RendererPreferenceReference: Codable, Hashable, Sendable {
    case exact(RendererReference)
    case logical(LogicalRendererReference)
}

/// A persisted preference can retain a logical choice while a user temporarily
/// pins one exact version. Resolution falls through when that exact version is
/// unavailable or incompatible.
public struct RendererPreference: Codable, Hashable, Sendable {
    public let exact: RendererReference?
    public let logical: LogicalRendererReference?

    public init(exact: RendererReference?, logical: LogicalRendererReference?) throws {
        guard exact != nil || logical != nil else { throw RendererValidationError.emptyPreference }
        self.exact = exact
        self.logical = logical
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            exact: container.decodeIfPresent(RendererReference.self, forKey: .exact),
            logical: container.decodeIfPresent(LogicalRendererReference.self, forKey: .logical)
        )
    }
}

/// Pure deterministic resolver shared by future registry snapshots.
public enum RendererResolution {
    public static func matching(
        descriptors: [RendererDescriptor],
        input: RendererMatchInput,
        hostProtocolRevision: Int
    ) -> [RendererDescriptor] {
        let compatible = descriptors.filter { $0.compatibility.supports(hostProtocolRevision: hostProtocolRevision) }
        let strong = compatible.filter { $0.matchTier(for: input) == .strong }
        let candidates = strong.isEmpty ? compatible.filter { $0.matchTier(for: input) == .extensionFallback } : strong
        return candidates.sorted { $0.stableTieBreakKey < $1.stableTieBreakKey }
    }

    /// Exact pins win when compatible and installed. Logical preferences choose the
    /// greatest compatible semantic version and then the documented stable key.
    public static func preferred(
        descriptors: [RendererDescriptor],
        preference: RendererPreferenceReference?,
        input: RendererMatchInput,
        hostProtocolRevision: Int
    ) -> RendererDescriptor? {
        let matches = matching(descriptors: descriptors, input: input, hostProtocolRevision: hostProtocolRevision)
        guard let preference else { return matches.first }
        switch preference {
        case let .exact(reference):
            return matches.first(where: { $0.reference == reference })
        case let .logical(reference):
            let logical = matches.filter { $0.logicalReference == reference }
            return logical.sorted(by: logicalOrdering).first
        }
    }

    public static func preferred(
        descriptors: [RendererDescriptor],
        preference: RendererPreference?,
        input: RendererMatchInput,
        hostProtocolRevision: Int
    ) -> RendererDescriptor? {
        let matches = matching(descriptors: descriptors, input: input, hostProtocolRevision: hostProtocolRevision)
        guard let preference else { return matches.first }
        if let exact = preference.exact, let descriptor = matches.first(where: { $0.reference == exact }) {
            return descriptor
        }
        guard let logical = preference.logical else { return nil }
        return matches.filter { $0.logicalReference == logical }.sorted(by: logicalOrdering).first
    }

    private static func logicalOrdering(_ lhs: RendererDescriptor, _ rhs: RendererDescriptor) -> Bool {
        let precedence = lhs.reference.version.semanticPrecedence(comparedTo: rhs.reference.version)
        if precedence != .orderedSame { return precedence == .orderedDescending }
        return lhs.stableTieBreakKey < rhs.stableTieBreakKey
    }
}
