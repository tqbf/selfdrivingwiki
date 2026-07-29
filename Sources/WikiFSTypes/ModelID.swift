import Foundation

/// Stable identifier for an AI model (e.g. `"claude-opus-5"`, `"gpt-5"`), scoped
/// to a `ProviderID`. Backed by a model *name* chosen by the provider or user,
/// NOT a ULID. It is therefore an open set: a `RawRepresentable<String>`
/// struct, not a closed enum — new models ship constantly and this type must
/// not need updating when they do.
///
/// Typing it (rather than a bare `String`) means a typo cannot silently select
/// the wrong model or nil one out — the id space is distinct from every other
/// string the queue layer carries (page ids, chat ids, provider ids). Mirrors
/// the `ProviderID` template: `Hashable`/`Codable`/`Sendable`/`Identifiable`.
public struct ModelID: Hashable, Codable, RawRepresentable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension ModelID: Identifiable {
    public var id: String { rawValue }
}
