import Foundation

/// An ACP agent's crash-resume session handle — the id that lets a restarted
/// agent process restore a prior conversation's context via `resumeSession` /
/// `loadSession`. Backed by the raw session-id string the external ACP SDK
/// issues (a `SessionId.value` we don't control), so it is an open set: a
/// `RawRepresentable<String>` struct, not a closed enum.
///
/// Typing it (rather than a bare `String`) means a typo cannot silently break
/// resume capability — the id space is distinct from every other string the
/// chat/queue layer carries (page ids, chat ids, wiki ids, tool-call ids).
/// Mirrors the `PageID` template: `Hashable`/`Codable`/`Sendable`/
/// `Identifiable`.
public struct AcpSessionID: Hashable, Codable, RawRepresentable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension AcpSessionID: Identifiable {
    public var id: String { rawValue }
}
