import Foundation
import UserNotifications
import WikiFSCore
import WikiFSEngine

/// Posts macOS local notifications when queue operations (extraction,
/// ingestion, lint) reach a terminal state.
///
/// Subscribes to ``QueueEngine.events`` alongside ``QueueActivityTracker`` and
/// ``MenuBarItemController`` — the queue engine's `QueueEventBroadcaster`
/// multicasts to every subscriber, so adding a third consumer is free.
///
/// On `.completed` / `.failed` events the notifier computes a short summary via
/// ``summary(for:outcome:)`` (a pure function, unit-tested separately) and posts
/// a `UNNotificationRequest`.  `UNUserNotificationCenter` decides whether to
/// show a visible banner based on the app's Notification settings and whether
/// it is frontmost — when the app is active, notifications land silently in
/// Notification Center; when backgrounded they appear as banners (the useful
/// case for long-running ingest/extraction).
///
/// **Retention.** Like ``MenuBarItemController``, this must be held strongly —
/// the ``streamTask`` captures `self` weakly, so without a strong external owner
/// the notifier is deallocated the moment `start()` returns.  `AppDelegate`
/// owns the reference (see ``AppDelegate.operationNotifier``).
@MainActor
final class OperationNotifier {

    // MARK: - Dependencies

    private let queueEngine: QueueEngine

    /// The stream consumer task. Kept so `stop()` can cancel it.
    private var streamTask: Task<Void, Never>?

    // MARK: - Init

    init(queueEngine: QueueEngine) {
        self.queueEngine = queueEngine
    }

    // MARK: - Lifecycle

    /// Request notification authorization (fire-and-forget) and begin consuming
    /// the engine's event stream. Idempotent — safe to call once.
    func start() {
        guard streamTask == nil else { return }

        // Request authorization. Non-blocking: if the user hasn't granted
        // permission yet, the system prompt appears; if they decline the
        // notifications are silently dropped (no error). Either way the
        // stream consumer starts immediately — authorization is independent
        // of event observation.
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound])
                DebugLog.config("OperationNotifier: notification authorization granted=\(granted)")
            } catch {
                DebugLog.config("OperationNotifier: authorization request failed: \(error)")
            }
        }

        // Subscribe to engine events.
        streamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await event in self.queueEngine.events {
                self.handle(event)
            }
        }
    }

    /// Stop consuming events and cancel the stream task.
    func stop() {
        streamTask?.cancel()
        streamTask = nil
    }

    // MARK: - Event handling

    private func handle(_ event: QueueEvent) {
        switch event {
        case .completed(let item):
            post(item: item, outcome: .completed)
        case .failed(let item, let error):
            post(item: item, outcome: .failed(error))
        // Cancelled is user-initiated — not worth a notification.
        case .cancelled, .enqueued, .started, .progress, .transcript, .liveUsage,
              .usage, .runPaths, .runStateChanged, .reordered, .pendingPermission:
            break
        }
    }

    // MARK: - Notification posting

    private func post(item: QueueItem, outcome: TerminalOutcome) {
        guard let summary = Self.summary(for: item, outcome: outcome) else { return }

        let content = UNMutableNotificationContent()
        content.title = summary.title
        content.body = summary.body
        content.sound = .default

        let request = UNNotificationRequest(
            // Include the outcome in the identifier so a retried item (failed →
            // completed) gets two distinct notifications rather than replacing
            // the first.
            identifier: "queue-\(item.id)-\(outcome.identifier)",
            content: content,
            trigger: nil // Deliver immediately.
        )

        Task {
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                DebugLog.config("OperationNotifier: failed to post notification for item \(item.id): \(error)")
            }
        }
    }

    // MARK: - Summary (pure, unit-tested)

    /// The terminal outcome that drives the notification summary.
    enum TerminalOutcome: Sendable, Equatable {
        case completed
        case failed(String)
        case cancelled

        /// A short identifier for the notification request identifier.
        var identifier: String {
            switch self {
            case .completed:  return "completed"
            case .failed:     return "failed"
            case .cancelled:   return "cancelled"
            }
        }
    }

    /// A computed notification summary — title + body.
    struct Summary: Sendable, Equatable {
        let title: String
        let body: String
    }

    /// The kind of operation a queue item represents, for notification language.
    enum OperationKind: Sendable, Equatable {
        case extraction(sourceCount: Int)
        case ingestion(sourceCount: Int)
        /// `pageCount` is `nil` for whole-wiki lint (empty `lintPageIDs` array).
        case lint(pageCount: Int?)
    }

    /// Determine the operation kind from a queue item.
    nonisolated static func operationKind(for item: QueueItem) -> OperationKind {
        switch item.queue {
        case .extraction:
            return .extraction(sourceCount: item.payload.sourceIDs.count)
        case .ingestion:
            if let lintPageIDs = item.payload.lintPageIDs {
                return .lint(pageCount: lintPageIDs.isEmpty ? nil : lintPageIDs.count)
            }
            return .ingestion(sourceCount: item.payload.sourceIDs.count)
        }
    }

    /// Compute a notification title + body for a terminal queue item.
    nonisolated static func summary(for item: QueueItem, outcome: TerminalOutcome) -> Summary? {
        let kind = operationKind(for: item)

        let label: String
        switch kind {
        case .extraction: label = "Extraction"
        case .ingestion:  label = "Ingestion"
        case .lint:       label = "Lint"
        }

        let title: String
        let body: String

        switch outcome {
        case .completed:
            title = "\(label) Complete"
            body = completedBody(for: kind)
        case .failed(let error):
            title = "\(label) Failed"
            body = failedBody(for: kind, error: error)
        case .cancelled:
            // Not currently posted (handle() skips .cancelled), but kept for
            // completeness and future use.
            title = "\(label) Cancelled"
            body = cancelledBody(for: kind)
        }

        return Summary(title: title, body: body)
    }

    // MARK: - Body text helpers (private, pure)

    private nonisolated static func completedBody(for kind: OperationKind) -> String {
        switch kind {
        case .extraction(let count):
            return "\(count) file\(count == 1 ? "" : "s") processed"
        case .ingestion(let count):
            return "\(count) source\(count == 1 ? "" : "s") ingested"
        case .lint(let pageCount):
            if let pageCount {
                return "\(pageCount) page\(pageCount == 1 ? "" : "s") linted"
            } else {
                return "All pages linted"
            }
        }
    }

    private nonisolated static func failedBody(for kind: OperationKind, error: String) -> String {
        // Include a subject (count) so the user knows the scope, then the
        // error truncated to fit a notification banner.
        let subject: String
        switch kind {
        case .extraction(let count):
            subject = "\(count) file\(count == 1 ? "" : "s")"
        case .ingestion(let count):
            subject = "\(count) source\(count == 1 ? "" : "s")"
        case .lint(let pageCount):
            if let pageCount {
                subject = "\(pageCount) page\(pageCount == 1 ? "" : "s")"
            } else {
                subject = "Wiki-wide lint"
            }
        }

        let cleanError = error.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayError = cleanError.isEmpty ? "Unknown error" : cleanError

        // Truncate long errors (e.g. stack traces) to fit a notification banner.
        let maxLen = 180
        let truncated: String
        if displayError.count > maxLen {
            truncated = String(displayError.prefix(maxLen)) + "\u{2026}"
        } else {
            truncated = displayError
        }
        return "\(subject): \(truncated)"
    }

    private nonisolated static func cancelledBody(for kind: OperationKind) -> String {
        switch kind {
        case .extraction(let count):
            return "\(count) file\(count == 1 ? "" : "s") \u{2014} cancelled"
        case .ingestion(let count):
            return "\(count) source\(count == 1 ? "" : "s") \u{2014} cancelled"
        case .lint(let pageCount):
            if let pageCount {
                return "\(pageCount) page\(pageCount == 1 ? "" : "s") \u{2014} cancelled"
            } else {
                return "Wiki-wide lint \u{2014} cancelled"
            }
        }
    }
}
