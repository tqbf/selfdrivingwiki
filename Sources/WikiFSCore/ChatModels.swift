import Foundation

/// Which agent surface a persisted chat came from. Mirrors the two
/// interactive query modes: Ask (read-only seatbelt) and Edit (may write the
/// wiki). A closed set so `chats.kind` round-trips predictably.
public enum ChatKind: String, Equatable, Sendable, CaseIterable {
    case ask
    case edit
}

/// One persisted agent chat (issue #119). Chats are ULID-keyed the
/// moment they are persisted — the stable resource identity every follow-up
/// surface (`[[chat:…]]` links, `chats.jsonl`, the File Provider `chats/`
/// tree) hangs off. The transcript itself lives in `chat_messages`
/// (`ChatMessage`), fetched on demand like source content.
public struct ChatSummary: Identifiable, Hashable, Sendable {
    public var id: PageID
    public var kind: ChatKind
    /// Display title, auto-derived from the first user message (elided). The
    /// resolution name for a future `[[chat:…]]` link.
    public var title: String
    public var createdAt: Date
    /// Bumped on every message append — drives most-recent-first history.
    public var updatedAt: Date
    /// Persisted message count, for the history list's subtitle.
    public var messageCount: Int

    public init(
        id: PageID, kind: ChatKind, title: String,
        createdAt: Date, updatedAt: Date, messageCount: Int
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messageCount = messageCount
    }

    /// Derive a chat title from the first user message: first line, trimmed,
    /// elided. Pure so the rule is unit-testable and shared by every caller
    /// that creates a chat.
    public static func title(fromFirstMessage message: String, maxLength: Int = 60) -> String {
        let firstLine = message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .first ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "New Chat" }
        guard trimmed.count > maxLength else { return trimmed }
        return trimmed.prefix(maxLength - 1) + "…"
    }
}

/// One persisted transcript row: a single renderable `AgentEvent`, stored
/// verbatim as JSON (`event_json`) so history re-renders through the exact
/// same pipeline as the live transcript, plus a `plainText` projection
/// (`chat_messages.text`) so future phases (FTS, `#"quote"` anchors) never
/// parse JSON.
public struct ChatMessage: Identifiable, Equatable, Sendable {
    public var id: PageID
    public var chatID: PageID
    /// Dense, 0-based per-chat ordering. Assigned by the store on append.
    public var seq: Int
    public var event: AgentEvent
    public var createdAt: Date

    public init(id: PageID, chatID: PageID, seq: Int, event: AgentEvent, createdAt: Date) {
        self.id = id
        self.chatID = chatID
        self.seq = seq
        self.event = event
        self.createdAt = createdAt
    }
}

extension AgentEvent {
    /// Whether this event is worth persisting to chat history. The stream
    /// bookkeeping cases are excluded: `.assistantTextDelta` is merged into its
    /// `.assistantText` row by the launcher before any flush, `.messageStop` is
    /// the turn-boundary marker (it *triggers* a flush), and `.raw` is
    /// undecodable debug residue.
    public var isPersistable: Bool {
        switch self {
        case .userText, .systemInit, .assistantText, .toolUse, .toolResult,
             .subagent, .result:
            return true
        case .assistantTextDelta, .messageStop, .raw:
            return false
        }
    }

    /// The `chat_messages.role` column value for this event. A coarse
    /// projection for indexing and future anchor decomposition — rendering
    /// always goes through the typed event.
    public var chatRole: String {
        switch self {
        case .userText:
            return "user"
        case .assistantText, .assistantTextDelta, .result:
            return "assistant"
        case .toolUse, .toolResult, .subagent:
            return "tool"
        case .systemInit, .messageStop, .raw:
            return "system"
        }
    }
}
