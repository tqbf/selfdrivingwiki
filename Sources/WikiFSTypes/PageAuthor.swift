import Foundation

/// Typed identity for a page-version author. The single source of truth for
/// the `agents.name` convention: `"user"`, `"chat:<id>"`, `"agent:<kind>"`,
/// `"legacy-import"` (plus `.other(rawValue)` for forward compatibility with
/// values a newer app might write). Every construction and parse site routes
/// through here — string literals for the author convention should never be
/// re-derived at a call site.
///
/// The convention itself is unchanged from the pre-typing discipline
/// (`plans/wikictl-author-provenance.md`): the bytes stored in `agents.name`
/// are byte-identical before and after this enum lands. Only how Swift builds
/// and reads them changes, so no DB migration is required.
///
/// Lives in `WikiFSTypes` (the shared leaf target) so the write seam
/// (`WikiFSCore`'s `GRDBWikiStore`), the writer helpers (`WikiFSEngine`'s
/// `AgentLauncher.authorForRun`), and the read-side UI (`WikiFS`'s
/// `ProvenancePanel`) all share one definition with no new module edge.
/// `PageAuthor.chat(_)` references `ResourceKind.chat.linkPrefix` (also
/// `WikiFSTypes`) to avoid re-hardcoding the `"chat:"` literal.
public enum PageAuthor: Equatable, Hashable, Sendable {

    /// A human user editing via the app or `wikictl`. Stored as `"user"`.
    case user

    /// A chat session writing on behalf of a conversation. Stored as
    /// `"chat:<ulid>"` — the prefix is `ResourceKind.chat.linkPrefix`
    /// (currently `"chat:"`), the suffix is the chat's ULID (resolvable
    /// via `[[chat:<ulid>]]`).
    case chat(String)

    /// A one-shot run by a named executor. Stored as `"agent:<kind>"`
    /// where `<kind>` is the executor's stage (e.g. `ingest`, `lint`,
    /// `query`, `bootstrap`).
    case agent(String)

    /// The shared pre-v39 / nil-author fallback. Stored as `"legacy-import"`.
    case legacyImport

    /// Any other stored value that doesn't match the convention (forward
    /// compatibility — e.g. a future code path that writes a model id
    /// directly). Preserved verbatim so the row's `agents.name` round-trips
    /// without data loss; classified as `.model` for `agentKind`.
    case other(String)

    // MARK: - Constants

    /// The literal stored for ``user``. Kept private — call sites should use
    /// `PageAuthor.user.rawValue` rather than re-deriving the string.
    private static let userLiteral = "user"

    /// The literal stored for ``legacyImport``.
    private static let legacyImportLiteral = "legacy-import"

    /// The `"agent:"` prefix — 6 chars. Hardcoded because there's no
    /// `ResourceKind.agent` link prefix to delegate to (one-shot runs
    /// are not wiki-linkable resources).
    private static let agentPrefix = "agent:"

    // MARK: - rawValue

    /// The canonical string stored in `agents.name`.
    public var rawValue: String {
        switch self {
        case .user:                  return Self.userLiteral
        case .chat(let id):           return ResourceKind.chat.linkPrefix! + id
        case .agent(let kind):        return Self.agentPrefix + kind
        case .legacyImport:           return Self.legacyImportLiteral
        case .other(let value):       return value
        }
    }

    // MARK: - init(rawValue:)

    /// Parse a stored `agents.name` value (or a nil `last_edited_by`).
    ///
    /// Rules:
    /// - `nil` / empty → `.legacyImport` (matches `ensurePageAuthorAgent`'s
    ///   fallback to the shared legacy agent).
    /// - `"user"` → `.user`.
    /// - `"legacy-import"` → `.legacyImport`.
    /// - `chat:` prefix (`ResourceKind.chat.linkPrefix`) → `.chat(suffix)`
    ///   — drops the 5-char `"chat:"` prefix.
    /// - `agent:` prefix → `.agent(suffix)` — drops the 6-char `"agent:"` prefix.
    /// - anything else → `.other(rawValue)` (forward compat, preserved verbatim).
    public init(rawValue value: String?) {
        guard let value, !value.isEmpty else {
            self = .legacyImport
            return
        }
        switch value {
        case Self.userLiteral:           self = .user
        case Self.legacyImportLiteral:   self = .legacyImport
        default:
            // The chat prefix is owned by ResourceKind.chat.linkPrefix
            // (currently "chat:"). Use it here too so a future change to
            // the link prefix propagates to the parse side as well as the
            // construction side.
            if let chatPrefix = ResourceKind.chat.linkPrefix,
               value.hasPrefix(chatPrefix) {
                self = .chat(String(value.dropFirst(chatPrefix.count)))
            } else if value.hasPrefix(Self.agentPrefix) {
                self = .agent(String(value.dropFirst(Self.agentPrefix.count)))
            } else {
                self = .other(value)
            }
        }
    }

    // MARK: - agentKind

    /// The `agents.kind` classification for this author. Mirrors the mapping
    /// in `GRDBWikiStore.authorKind(_:)` (which this enum replaces):
    /// - `.user` → `.human`
    /// - `.chat(_)` → `.chat`
    /// - `.agent(_)` → `.agent`
    /// - `.legacyImport` → `.software`
    /// - `.other(_)` → `.model`
    public var agentKind: AgentKind {
        switch self {
        case .user:        return .human
        case .chat:        return .chat
        case .agent:        return .agent
        case .legacyImport: return .software
        case .other:        return .model
        }
    }

    // MARK: - chatID

    /// The chat ULID when this is `.chat`, else `nil`. Replaces the
    /// `substr(a.name, 6)` SQL strip (which drops the 5-char `"chat:"`
    /// prefix at the read side) at the Swift layer.
    public var chatID: String? {
        guard case .chat(let id) = self else { return nil }
        return id
    }
}
