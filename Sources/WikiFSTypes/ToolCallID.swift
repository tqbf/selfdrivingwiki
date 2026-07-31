import Foundation

/// Stable identifier for one tool invocation within a chat transcript or
/// permission request lifecycle.
///
/// The raw value comes from provider-side string ids that the app does not
/// control, so this remains an open string namespace.
public struct ToolCallID: Hashable, Sendable, RawRepresentable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension ToolCallID: Identifiable {
    public var id: String { rawValue }
}
