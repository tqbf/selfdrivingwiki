import Foundation

/// Stable identifier for a configured agent provider — the backend that runs a
/// queue item or agent run. Backed by a provider *name* (e.g. `"claude-acp"`,
/// `"gemini"`, a user-chosen id from `agent-providers.json`), NOT a ULID. It is
/// therefore an open set: a `RawRepresentable<String>` struct, not a closed enum.
///
/// Typing it (rather than a bare `String`) means a typo cannot silently select
/// the wrong backend or nil out a provider — the id space is distinct from every
/// other string the queue layer carries (page ids, chat ids, wiki ids). Mirrors
/// the `PageID` template: `Hashable`/`Codable`/`Sendable`/`Identifiable`.
public struct ProviderID: Hashable, Codable, RawRepresentable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension ProviderID: Identifiable {
    public var id: String { rawValue }
}

extension ProviderID {
    /// Reserved built-in id for the in-process Apple Intelligence backend
    /// (Foundation Models, `SystemLanguageModel`). NOT an entry in
    /// `agent-providers.json` — it names no configured provider, resolves to
    /// no ACP command, and needs no credential. Pinning it as the
    /// `"summarizer"` stage pin selects `MessageSummarizer.Mode.appleIntelligence`
    /// (see `MessageSummarizer.mode(for:)` and
    /// `plans/apple-intelligence-summarizer.md`); every generic
    /// `provider(forStage:)` resolution must be guarded by that mode check,
    /// never resolved through the configured-provider table.
    public static let appleIntelligence = ProviderID(rawValue: "apple-intelligence")
}
