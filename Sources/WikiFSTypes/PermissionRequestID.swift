import Foundation

/// Stable identifier for one pending permission request.
public struct PermissionRequestID: Hashable, Codable, RawRepresentable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension PermissionRequestID: Identifiable {
    public var id: String { rawValue }
}
