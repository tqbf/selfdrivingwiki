import Foundation

/// Stable identifier for one runtime-exposed chat configuration value.
public struct ChatConfigurationValueID: Hashable, Codable, RawRepresentable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}
