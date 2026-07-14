import Foundation

/// Which agent surface a persisted chat came from. There is now ONE chat kind
/// — `.edit`, a write-capable chat (the agent may write the wiki). The former
/// read-only Ask mode has been removed; the `chats.kind` column is retained
/// (vestigial until a future always-ask/yolo distinction) and every row is
/// `.edit`. A closed set so `chats.kind` round-trips predictably.
public enum ChatKind: String, Equatable, Sendable, CaseIterable {
    case edit
}

/// One persisted agent chat (issue #119). Chats are ULID-keyed the
/// moment they are persisted — the stable resource identity every follow-up
/// surface (`[[chat:…]]` links, `chats.jsonl`, the File Provider `chats/`
/// tree) hangs off. The transcript itself lives in `chat_messages`
/// (`ChatMessage`), fetched on demand like source content. All chats are
/// write-capable (`.edit`); the read-only Ask mode has been removed.
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
    /// One-line summary of the model's first response, generated on chat
    /// completion (issue #411). `nil` for chats that haven't been summarized
    /// yet (existing chats after migration, or chats whose `finish()` never
    /// fired). The sidebar shows this when present, falling back to the
    /// relative timestamp.
    public var summary: String?
    /// When the summary was written, for staleness display. `nil` alongside
    /// `summary`.
    public var summaryAt: Date?

    public init(
        id: PageID, kind: ChatKind, title: String,
        createdAt: Date, updatedAt: Date, messageCount: Int,
        summary: String? = nil, summaryAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messageCount = messageCount
        self.summary = summary
        self.summaryAt = summaryAt
    }

    /// Derive a chat title from the first user message: first line, trimmed,
    /// elided. Pure so the rule is unit-testable and shared by every caller
    /// that creates a chat. Strips leading `[[page:…]]` / `[[source:…]]` /
    /// `[[chat:…]]` attachment reference lines (prepended by `sendMessage`
    /// when sidebar items are dragged into the chat, issue #385) so the title
    /// is the user's actual question, not the first attachment's wikilink.
    public static func title(fromFirstMessage message: String, maxLength: Int = 60) -> String {
        let stripped = Self.stripAttachmentRefs(from: message)
        let firstLine = stripped
            .components(separatedBy: .newlines)
            .first ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "New Chat" }
        guard trimmed.count > maxLength else { return trimmed }
        return trimmed.prefix(maxLength - 1) + "…"
    }

    /// Derive a one-line summary from the model's first assistant response
    /// (issue #411). Extracts the first sentence, elided to `maxLength` using
    /// the same `prefix(maxLength - 1) + "…"` rule as `title(fromFirstMessage:)`.
    /// Pure so the extraction logic is unit-testable without a live agent.
    ///
    /// Unlike `title(fromFirstMessage:)`, this does NOT strip `[[…]]`
    /// attachment refs — those are prepended to *user* messages, not assistant
    /// responses. The sentence boundary is `. `, `!\n`, or `?\n`; if none is
    /// found the full (trimmed) text is used as the extract.
    public static func summaryExtract(from assistantText: String, maxLength: Int = 60) -> String {
        let trimmed = assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Find the first sentence boundary: period+space, or !/? at end of line.
        let extract: String
        if let range = trimmed.range(of: #"\. |[!?]\n"#, options: .regularExpression) {
            // Include the boundary punctuation in the extract.
            var end = range.upperBound
            // If we matched ". ", step back to include the period but not the space.
            if trimmed[range] == ". " {
                end = trimmed.index(before: end) // include the period
            }
            extract = String(trimmed[..<end])
        } else {
            extract = trimmed
        }

        guard extract.count > maxLength else { return extract }
        return String(extract.prefix(maxLength - 1)) + "…"
    }

    /// Remove leading `[[page:…]]` / `[[source:…]]` / `[[chat:…]]` wikilink
    /// lines so the title reflects the user's question, not the attachment
    /// references (issue #385).
    private static func stripAttachmentRefs(from text: String) -> String {
        var remaining = text[...]
        while let range = remaining.range(of: #"\[\[(?:page|source|chat):[^\]]+\]\]"#,
                                           options: .regularExpression),
              range.lowerBound == remaining.startIndex {
            remaining = remaining[range.upperBound...]
            if remaining.first == "\n" { remaining = remaining.dropFirst() }
        }
        return String(remaining).trimmingCharacters(in: .whitespacesAndNewlines)
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
             .subagent, .result, .turnFailed:
        case .userText, .systemInit, .assistantText, .thinking, .toolUse, .toolResult,
             .subagent, .result:
            return true
        case .assistantTextDelta, .thinkingDelta, .messageStop, .raw:
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
        case .assistantText, .assistantTextDelta, .thinking, .result:
            return "assistant"
        case .toolUse, .toolResult, .subagent:
            return "tool"
        case .systemInit, .messageStop, .raw, .turnFailed:
        case .systemInit, .messageStop, .raw, .thinkingDelta:
            return "system"
        }
    }
}
