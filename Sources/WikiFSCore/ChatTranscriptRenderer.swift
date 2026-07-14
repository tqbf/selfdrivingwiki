import Foundation

/// Pure, deterministic rendering of a persisted chat as a readable Markdown
/// transcript — the bytes the File Provider projects at
/// `chats/by-id/<ULID>.md` (and `chats/by-name/<title>__<ULID>.md`).
///
/// The body STAYS literal `[[…]]` in page/source bodies; this renderer is for
/// the read-only mount projection only (an agent or human running
/// `cat chats/by-id/…` sees a human-readable chat transcript, not raw JSON).
///
/// Each persistable `AgentEvent` becomes a `## Role` section with the event's
/// `plainText` as the body. Events with empty `plainText` (`.messageStop`,
/// `.assistantTextDelta` — neither is persisted, but the renderer is defensive)
/// are skipped. The `ChatSummary` metadata (kind, message count, timestamps)
/// appears in a blockquote after the title.
public enum ChatTranscriptRenderer {

    /// Render `summary` + `messages` as a Markdown transcript string.
    /// Deterministic: same inputs → identical bytes (dates are formatted to
    /// the second, so two renders within one second produce the same output).
    public static func render(summary: ChatSummary, messages: [ChatMessage]) -> String {
        var out = "# \(summary.title)\n\n"
        out += "> **Messages:** \(summary.messageCount)\n"
        out += "> **Created:** \(formatDate(summary.createdAt))  ·  **Updated:** \(formatDate(summary.updatedAt))\n\n"
        out += "---\n\n"

        for message in messages {
            let (header, body) = section(for: message.event)
            guard !body.isEmpty else { continue }
            out += "## \(header)\n\n"
            out += "\(body)\n\n"
        }
        return out
    }

    /// Map one `AgentEvent` to a `(section header, body text)` pair. The header
    /// is a human-readable role label; the body is the event's `plainText`
    /// (which already strips icons/colors/layout). Events with empty
    /// `plainText` yield an empty body and are skipped by the caller.
    private static func section(for event: AgentEvent) -> (header: String, body: String) {
        switch event {
        case .userText(let text):
            return ("User", text)
        case .systemInit(let model):
            return ("System", "Session started · \(model)")
        case .assistantText(let text):
            return ("Assistant", text)
        case .toolUse(let name, let inputSummary):
            let body = inputSummary.isEmpty ? name : "\(name) — \(inputSummary)"
            return ("Tool Use", body)
        case .toolResult(let isError, let summary):
            let body = summary.isEmpty ? (isError ? "(error)" : "(ok)") : summary
            return ("Tool Result", isError ? "⚠️ \(body)" : body)
        case .subagent(let subagentType, let description, let isCompletion):
            let verb = isCompletion ? "digested" : "reading"
            let body = description.isEmpty
                ? "\(subagentType) \(verb)"
                : "\(subagentType) \(verb) — \(description)"
            return ("Subagent", body)
        case .result(let isError, let text):
            let header = isError ? "Failed" : "Result"
            let body = text.isEmpty ? header : text
            return (header, body)
        case .assistantTextDelta, .messageStop, .raw:
            return ("", "")
        case .turnFailed(let reason):
            return ("Turn Failed", reason.description)
        }
    }

    /// Format a `Date` as `yyyy-MM-dd HH:mm` (readable, second-precision, no
    /// timezone suffix — the mount is local-only). Uses a static formatter for
    /// performance.
    private static func formatDate(_ date: Date) -> String {
        Self.dateFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}
