import Cordis
import WikiFSCore

/// One append-only batch in a chat session log.
public struct SessionEventBatch: Equatable, Sendable {
    public let chatID: ChatID
    public let events: [AgentEvent]

    public init(chatID: ChatID, events: [AgentEvent]) {
        self.chatID = chatID
        self.events = events
    }
}

/// Stable facade for appending events to the session log.
public struct SessionLogService: Sendable {
    private let appendBatch: @Sendable (SessionEventBatch) async -> Void

    public init(append: @escaping @Sendable (SessionEventBatch) async -> Void) {
        self.appendBatch = append
    }

    public func append(chatID: ChatID, events: [AgentEvent]) async {
        guard !events.isEmpty else { return }
        await appendBatch(SessionEventBatch(chatID: chatID, events: events))
    }
}

/// Stable Cordis identities for the session-log domain seam.
public enum SessionServiceKeys {
    public static let sessions = ServiceKey<SessionLogService>(label: "wiki.sessions")
}

/// Append-only session-log events consumed by projections such as chat persistence.
public enum SessionEventKeys {
    public static let appended = EventKey<SessionEventBatch, EmitMode>(
        label: "wiki.sessions.appended")
}
