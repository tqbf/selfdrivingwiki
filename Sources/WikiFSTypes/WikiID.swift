import Foundation

/// Stable identifier for a wiki database — the `<ulid>.sqlite` file in the App
/// Group container. Backed by a ULID string (see `ULID`).
///
/// This is a *different id space* from `PageID` (which identifies a page within
/// a wiki). A `WikiID` and a `PageID` must never be interchangeable — wrapping
/// the raw ULID in its own type makes the compiler enforce that distinction.
public struct WikiID: Hashable, Codable, RawRepresentable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension WikiID: Identifiable {
    public var id: String { rawValue }
}
