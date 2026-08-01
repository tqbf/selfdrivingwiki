// pattern: Imperative Shell

import Foundation
import WikiFSCore
import WikiFSEngine

/// Breaks the engine/factory construction cycle while preserving the immutable
/// attempt captured by `QueueIngestionWorker`. Every access to the optional
/// handler holds `lock`; the copied handler runs after lock release.
// swiftlint:disable:next unchecked_sendable
final class TranscriptEmitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (QueueAttemptID, AgentEvent) -> Void)?

    func install(_ emit: @escaping @Sendable (QueueAttemptID, AgentEvent) -> Void) {
        lock.withLock { handler = emit }
    }

    func emit(_ attemptID: QueueAttemptID, _ event: AgentEvent) {
        let emit = lock.withLock { handler }
        emit?(attemptID, event)
    }
}
