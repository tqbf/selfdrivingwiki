import Foundation

/// The `agents.kind` taxonomy — who/what performed an activity in the PROV
/// graph (`activities` → `agents`). Stored verbatim in the `agents.kind`
/// TEXT column (no DB migration; values are byte-identical to the prior
/// string-discipline scheme).
///
/// Single source of truth: every site that classifies an author string
/// (`GRDBWikiStore.authorKind(_:)` at the write seam) or renders an
/// `agentKind` read from a `PageOrigin`/`SourceOrigin` row should route
/// through this enum rather than re-deriving the mapping inline.
///
/// Lives in `WikiFSTypes` (the shared leaf target) so the store
/// (`WikiFSCore`), the agent runtime (`WikiFSEngine`), and the UI
/// (`WikiFS`) all see one definition with no new module edge.
///
/// Not declared `: String` (RawRepresentable) deliberately — the synthesised
/// fallible `init?(rawValue: String)` would clash with the non-failable
/// `init(rawValue: String?)` parse-with-fallback signature at call sites
/// that pass a non-optional `String` (#797). `rawValue` is exposed as a
/// manual computed property mirroring the `PageAuthor` pattern; `CaseIterable`
/// is honoured without RawRepresentable (the two conformances are independent).
public enum AgentKind: Equatable, Hashable, Sendable, CaseIterable {

    /// A human user editing via the app or `wikictl` (`agents.name = "user"`).
    case human
    /// A chat session writing on behalf of a conversation (`agents.name = "chat:<id>"`).
    case chat
    /// A one-shot run by a named executor (`agents.name = "agent:<kind>"`
    /// — ingest / lint / query / bootstrap).
    case agent
    /// The shared `legacy-import` agent — pre-v39 rows and nil-author
    /// leaks (`agents.name = "legacy-import"`). Kept as the soft default
    /// for unknown kinds so historical rows still render.
    case software
    /// A model-id author (e.g. `claude-sonnet-4-5-20250929`) — recorded
    /// when an explicit model id was threaded as the author.
    case model

    /// The canonical string stored in `agents.kind`.
    public var rawValue: String {
        switch self {
        case .human:    return "human"
        case .chat:     return "chat"
        case .agent:    return "agent"
        case .software: return "software"
        case .model:    return "model"
        }
    }

    /// Parse a stored `agents.kind` value. `nil`/empty/unknown → `.software`
    /// (the historical default for the shared `legacy-import` agent — a
    /// pre-v39 row with `kind = "software"` is the existing degraded state,
    /// and `ensurePageAuthorAgent` falls back to that same agent).
    public init(rawValue value: String?) {
        guard let value, !value.isEmpty else {
            self = .software
            return
        }
        switch value {
        case "human":    self = .human
        case "chat":     self = .chat
        case "agent":    self = .agent
        case "software": self = .software
        case "model":    self = .model
        default:         self = .software
        }
    }
}
