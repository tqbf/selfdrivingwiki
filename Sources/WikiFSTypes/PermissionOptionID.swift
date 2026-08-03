import Foundation

/// Stable identifier for one selectable permission option.
public struct PermissionOptionID: Hashable, Codable, RawRepresentable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension PermissionOptionID: Identifiable {
    public var id: String { rawValue }
}
