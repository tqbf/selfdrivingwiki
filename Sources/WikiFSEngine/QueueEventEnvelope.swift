import Foundation
import WikiFSCore

/// A Codable envelope for streaming `QueueEvent`s over XPC. The daemon's
/// `QueueEngine` emits `QueueEvent`s; the daemon wraps each into this envelope,
/// JSON-encodes it, and pushes it to the app's `WikiDaemonEventSink`. The app
/// decodes and re-emits as a `QueueEvent` onto a local `AsyncStream`.
///
/// Not all fields are populated for every `kind` — each event kind fills the
/// relevant fields and leaves the rest nil. The `toQueueEvent()` method
/// reconstructs the original `QueueEvent` from the populated fields.
public struct QueueEventEnvelope: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case enqueued, started, completed, failed, cancelled, reordered
        case progress, transcript, usage, liveUsage
        case runPaths, runStateChanged, pendingPermission
    }

    public let kind: Kind
    public let item: QueueItem?
    public let itemID: QueueItem.ID?
    public let error: String?
    public let line: String?
    public let agentEventData: Data?
    public let usageData: Data?
    public let logURL: URL?
    public let debugURL: URL?
    public let queue: QueueKind?
    public let runState: QueueRunState?
    public let pendingPermissionJSON: String?

    public init(kind: Kind, item: QueueItem? = nil, itemID: QueueItem.ID? = nil,
                error: String? = nil, line: String? = nil,
                agentEventData: Data? = nil, usageData: Data? = nil,
                logURL: URL? = nil, debugURL: URL? = nil,
                queue: QueueKind? = nil, runState: QueueRunState? = nil,
                pendingPermissionJSON: String? = nil) {
        self.kind = kind
        self.item = item
        self.itemID = itemID
        self.error = error
        self.line = line
        self.agentEventData = agentEventData
        self.usageData = usageData
        self.logURL = logURL
        self.debugURL = debugURL
        self.queue = queue
        self.runState = runState
        self.pendingPermissionJSON = pendingPermissionJSON
    }

    /// Wrap a `QueueEvent` into an envelope for XPC transmission.
    public init?(from event: QueueEvent) {
        switch event {
        case .enqueued(let item):
            self.init(kind: .enqueued, item: item)
        case .started(let item):
            self.init(kind: .started, item: item)
        case .completed(let item):
            self.init(kind: .completed, item: item)
        case .failed(let item, let error):
            self.init(kind: .failed, item: item, error: error)
        case .cancelled(let item):
            self.init(kind: .cancelled, item: item)
        case .reordered(let item):
            self.init(kind: .reordered, item: item)
        case .progress(let id, let line):
            self.init(kind: .progress, itemID: id, line: line)
        case .transcript(let id, let agentEvent):
            let data = try? JSONEncoder().encode(agentEvent)
            self.init(kind: .transcript, itemID: id, agentEventData: data)
        case .usage(let id, let usage):
            let data = try? JSONEncoder().encode(usage)
            self.init(kind: .usage, itemID: id, usageData: data)
        case .liveUsage(let id, let usage):
            let data = try? JSONEncoder().encode(usage)
            self.init(kind: .liveUsage, itemID: id, usageData: data)
        case .runPaths(let id, let logURL, let debugURL):
            self.init(kind: .runPaths, itemID: id, logURL: logURL, debugURL: debugURL)
        case .runStateChanged(let queue, let state):
            self.init(kind: .runStateChanged, queue: queue, runState: state)
        case .pendingPermission(let id, let permission):
            let json: String? = permission.map { perm in
                let dict: [String: Any] = [
                    "toolCallId": perm.toolCallId,
                    "title": perm.title as Any,
                    "toolName": perm.toolName as Any,
                    "inputSummary": perm.inputSummary as Any
                ]
                return (try? JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: dict))).flatMap { value in
                    (try? JSONSerialization.data(withJSONObject: value)).flatMap { String(data: $0, encoding: .utf8) }
                } ?? "{}"
            }
            self.init(kind: .pendingPermission, itemID: id, pendingPermissionJSON: json)
        }
    }

    /// Reconstruct the `QueueEvent` from the envelope.
    public func toQueueEvent() -> QueueEvent? {
        switch kind {
        case .enqueued:
            guard let item else { return nil }
            return .enqueued(item)
        case .started:
            guard let item else { return nil }
            return .started(item)
        case .completed:
            guard let item else { return nil }
            return .completed(item)
        case .failed:
            guard let item else { return nil }
            return .failed(item, error: error ?? "")
        case .cancelled:
            guard let item else { return nil }
            return .cancelled(item)
        case .reordered:
            guard let item else { return nil }
            return .reordered(item)
        case .progress:
            guard let itemID, let line else { return nil }
            return .progress(itemID, line: line)
        case .transcript:
            guard let itemID, let agentEventData,
                  let event = try? JSONDecoder().decode(AgentEvent.self, from: agentEventData) else { return nil }
            return .transcript(itemID, event)
        case .usage:
            guard let itemID, let usageData,
                  let usage = try? JSONDecoder().decode(SessionUsage.self, from: usageData) else { return nil }
            return .usage(itemID, usage)
        case .liveUsage:
            guard let itemID, let usageData,
                  let usage = try? JSONDecoder().decode(SessionUsage.self, from: usageData) else { return nil }
            return .liveUsage(itemID, usage)
        case .runPaths:
            guard let itemID else { return nil }
            return .runPaths(itemID, logURL: logURL, debugURL: debugURL)
        case .runStateChanged:
            guard let queue, let runState else { return nil }
            return .runStateChanged(queue: queue, state: runState)
        case .pendingPermission:
            guard let itemID else { return nil }
            return .pendingPermission(itemID, nil)
        }
    }
}
