import Foundation

/// Stable identifier for a runtime-exposed chat configuration option.
public struct ChatConfigurationOptionID: Hashable, Codable, RawRepresentable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}
