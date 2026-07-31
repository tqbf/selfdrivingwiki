// pattern: Imperative Shell

import Foundation
import WebKit

struct ChatTranscriptRenderRevision: Hashable, Sendable {
    let rawValue: Int
}

enum ChatTranscriptRenderAcknowledgementOutcome: String, Hashable, Sendable {
    case success
    case missingRow
    case error
    case undefined
    case javaScriptException
    case timeout
}

struct ChatTranscriptRenderAcknowledgement: Hashable, Sendable {
    let kind: ChatTranscriptRenderCommandKind
    let revision: ChatTranscriptRenderRevision
    let rowID: ChatDisplayRowID?
    let outcome: ChatTranscriptRenderAcknowledgementOutcome
}

enum ChatTranscriptRendererAnomaly: Hashable, Sendable {
    case invalidAcknowledgement(expected: ChatTranscriptRenderCommandKind, received: ChatTranscriptRenderCommandKind)
    case staleAcknowledgement(expected: ChatTranscriptRenderRevision, received: ChatTranscriptRenderRevision)
    case rowMismatch(expected: ChatDisplayRowID?, received: ChatDisplayRowID?)
    case failedAcknowledgement(ChatTranscriptRenderAcknowledgementOutcome)
}

/// Serializes typed DOM mutations. A command changes the acknowledged snapshot
/// only after WebKit returns the matching acknowledgement.
@MainActor
final class ChatTranscriptRenderExecutor {
    enum State: Hashable, Sendable {
        case idle
        case applying(ChatTranscriptRenderCommand, ChatTranscriptRenderRevision)
        case awaitingReload
    }

    typealias Mutation = @MainActor (
        ChatTranscriptRenderCommand,
        ChatTranscriptRenderRevision,
        @escaping @MainActor (ChatTranscriptRenderAcknowledgement) -> Void
    ) -> Void

    private let mutate: Mutation
    private let reportAnomaly: @MainActor (ChatTranscriptRendererAnomaly) -> Void
    private var acknowledgedSnapshot: ChatTranscriptRenderSnapshot?
    private var desiredSnapshot: ChatTranscriptRenderSnapshot?
    private var reloadSnapshot: ChatTranscriptRenderSnapshot?
    private var nextRevision = 0
    private var reloadRevision: ChatTranscriptRenderRevision?
    private var recoveryReloadAttempted = false
    private var requiresRecoveryReload = false

    private(set) var state: State = .idle

    init(
        mutate: @escaping Mutation,
        reportAnomaly: @escaping @MainActor (ChatTranscriptRendererAnomaly) -> Void
    ) {
        self.mutate = mutate
        self.reportAnomaly = reportAnomaly
    }

    func submit(_ snapshot: ChatTranscriptRenderSnapshot) {
        desiredSnapshot = snapshot
        drain()
    }

    /// Called by the WebKit navigation delegate only after a controlled shell
    /// reload has finished. The returned snapshot is frozen for that mutation.
    func beginReloadMutation() -> (snapshot: ChatTranscriptRenderSnapshot, revision: ChatTranscriptRenderRevision)? {
        guard case .awaitingReload = state,
              let desiredSnapshot,
              let reloadRevision
        else { return nil }
        reloadSnapshot = desiredSnapshot
        state = .applying(.reload(desiredSnapshot), reloadRevision)
        return (desiredSnapshot, reloadRevision)
    }

    func acknowledge(_ acknowledgement: ChatTranscriptRenderAcknowledgement) {
        let expected: (command: ChatTranscriptRenderCommand, revision: ChatTranscriptRenderRevision)?
        switch state {
        case .idle:
            return
        case .applying(let command, let revision):
            expected = (command, revision)
        case .awaitingReload:
            guard let reloadRevision else { return }
            expected = (.reload(reloadSnapshot ?? desiredSnapshot ?? ChatTranscriptRenderSnapshot(
                context: .init(transcriptID: nil), rows: []
            )), reloadRevision)
        }
        guard let expected else { return }
        guard acknowledgement.revision == expected.revision else {
            reportAnomaly(.staleAcknowledgement(expected: expected.revision, received: acknowledgement.revision))
            return
        }
        guard acknowledgement.kind == expected.command.kind else {
            reportAnomaly(.invalidAcknowledgement(expected: expected.command.kind, received: acknowledgement.kind))
            scheduleRecovery(after: expected.command)
            return
        }
        guard acknowledgement.rowID == expected.command.rowID else {
            reportAnomaly(.rowMismatch(expected: expected.command.rowID, received: acknowledgement.rowID))
            scheduleRecovery(after: expected.command)
            return
        }
        guard acknowledgement.outcome == .success else {
            reportAnomaly(.failedAcknowledgement(acknowledgement.outcome))
            scheduleRecovery(after: expected.command)
            return
        }

        switch expected.command {
        case .reload(let snapshot):
            acknowledgedSnapshot = reloadSnapshot ?? snapshot
            reloadSnapshot = nil
        default:
            acknowledgedSnapshot = applying(expected.command, to: acknowledgedSnapshot)
        }
        state = .idle
        reloadRevision = nil
        recoveryReloadAttempted = false
        drain()
    }

    private func drain() {
        guard case .idle = state, let desiredSnapshot else { return }
        let command: ChatTranscriptRenderCommand
        if requiresRecoveryReload {
            requiresRecoveryReload = false
            recoveryReloadAttempted = true
            command = .reload(desiredSnapshot)
        } else {
            guard let first = ChatTranscriptRenderPlanner.commands(
                previous: acknowledgedSnapshot,
                desired: desiredSnapshot
            ).first else { return }
            command = first
        }
        let revision = makeRevision()
        if case .reload = command {
            state = .awaitingReload
            reloadRevision = revision
        } else {
            state = .applying(command, revision)
        }
        mutate(command, revision) { [weak self] acknowledgement in
            self?.acknowledge(acknowledgement)
        }
    }

    private func scheduleRecovery(after command: ChatTranscriptRenderCommand) {
        state = .idle
        reloadRevision = nil
        reloadSnapshot = nil
        guard case .reload = command else {
            if !recoveryReloadAttempted {
                requiresRecoveryReload = true
                drain()
            }
            return
        }
        // One controlled reload already ran. Keep the latest desired snapshot
        // for a future explicit update, but do not enter a reload loop.
    }

    private func makeRevision() -> ChatTranscriptRenderRevision {
        nextRevision += 1
        return ChatTranscriptRenderRevision(rawValue: nextRevision)
    }

    private func applying(
        _ command: ChatTranscriptRenderCommand,
        to snapshot: ChatTranscriptRenderSnapshot?
    ) -> ChatTranscriptRenderSnapshot? {
        guard let snapshot else { return nil }
        var updatedRows = snapshot.rows
        switch command {
        case .reload(let replacement):
            return replacement
        case .append(let rows):
            updatedRows.append(contentsOf: rows)
        case .insert(let row, let before):
            guard let index = updatedRows.firstIndex(where: { $0.id == before }) else { return nil }
            updatedRows.insert(row, at: index)
        case .replace(let row):
            guard let index = updatedRows.firstIndex(where: { $0.id == row.id }) else { return nil }
            updatedRows[index] = row
        case .remove(let rowID):
            guard let index = updatedRows.firstIndex(where: { $0.id == rowID }) else { return nil }
            updatedRows.remove(at: index)
        }
        return ChatTranscriptRenderSnapshot(context: snapshot.context, rows: updatedRows)
    }
}

/// Result of one bounded WebKit evaluation. `undefined` is distinct from a
/// JavaScript exception because mutation functions must return an acknowledgement.
@MainActor
enum ChatTranscriptJavaScriptResult {
    case success(Any)
    case undefined
    case javaScriptException(String)
    case timeout
}

@MainActor
private final class ChatTranscriptJavaScriptCompletion {
    private var continuation: CheckedContinuation<ChatTranscriptJavaScriptResult, Never>?

    init(_ continuation: CheckedContinuation<ChatTranscriptJavaScriptResult, Never>) {
        self.continuation = continuation
    }

    func resolve(_ result: ChatTranscriptJavaScriptResult) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: result)
    }
}

@MainActor
extension WKWebView {
    func chatTranscriptJavaScriptResult(
        _ script: String,
        timeout: Duration = ChatTranscriptRenderMetrics.javaScriptTimeout
    ) async -> ChatTranscriptJavaScriptResult {
        await withCheckedContinuation { continuation in
            let completion = ChatTranscriptJavaScriptCompletion(continuation)
            evaluateJavaScript(script) { result, error in
                if let error {
                    completion.resolve(.javaScriptException(error.localizedDescription))
                } else if let result {
                    completion.resolve(.success(result))
                } else {
                    completion.resolve(.undefined)
                }
            }
            Task { @MainActor in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                completion.resolve(.timeout)
            }
        }
    }
}

enum ChatTranscriptRenderMetrics {
    static let javaScriptTimeout: Duration = .seconds(15)
}
