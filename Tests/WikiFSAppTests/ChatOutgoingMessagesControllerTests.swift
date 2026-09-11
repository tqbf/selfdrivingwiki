#if os(macOS)
import Foundation
import Testing
import WikiFSCore
import WikiFSEngine
@testable import WikiFS

/// Send lifecycle for the outgoing-echo controller. The submit closure is a
/// stored continuation the test resumes, so every state transition is observed
/// at the exact async boundary that produces it. Serialized and time-limited;
/// all waits are timeout-raced so a starved completion fails fast instead of
/// parking the cooperative pool (AGENTS.md #1051 rule).
@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct ChatOutgoingMessagesControllerTests {
    private struct SendError: Error, Equatable, LocalizedError {
        let message: String

        var errorDescription: String? { message }
    }

    @MainActor
    private final class SendHarness {
        /// Longer than any waitUntil deadline, so the sweeper only fires on an
        /// abandoned continuation, never in a passing run.
        static let submitWaitTimeout: Duration = .seconds(10)

        let controller = ChatOutgoingMessagesController()

        var recordedRequests: [ChatSubmitRequest] = []
        var optimisticSubmissions: [ChatTurnSubmission] = []
        var optimisticFailures: [ChatTurnID] = []
        var retargetedChatIDs: [ChatID] = []
        var restoredDrafts: [(draftText: String, attachments: [ChatAttachment])] = []
        var preflightErrors: [String?] = []
        var composerSnapshot = ChatOutgoingMessagesController.ComposerSnapshot(
            trimmedText: "", attachmentIDs: []
        )

        private var submitWaiters: [PendingSubmit] = []

        var suspendedSubmitCount: Int { submitWaiters.count }

        func installEnvironment() {
            controller.installEnvironment(.init(
                submit: { [weak self] request in
                    guard let self else { throw CancellationError() }
                    return try await self.suspendSubmitting(request)
                },
                optimisticSubmit: { [weak self] submission in
                    self?.optimisticSubmissions.append(submission)
                },
                optimisticSubmitFailed: { [weak self] turnID in
                    self?.optimisticFailures.append(turnID)
                },
                retarget: { [weak self] chatID in
                    self?.retargetedChatIDs.append(chatID)
                },
                readComposer: { [weak self] in
                    self?.composerSnapshot
                    ?? ChatOutgoingMessagesController.ComposerSnapshot(trimmedText: "", attachmentIDs: [])
                },
                restoreDraft: { [weak self] draftText, attachments in
                    self?.restoredDrafts.append((draftText, attachments))
                },
                setPreflightError: { [weak self] message in
                    self?.preflightErrors.append(message)
                }
            ))
        }

        func send(
            chatID: ChatID?,
            wireMessage: String = "Please summarize the draft",
            attachments: [ChatAttachment] = []
        ) {
            controller.send(
                chatID: chatID,
                payload: .init(
                    wireMessage: wireMessage,
                    draftText: wireMessage,
                    attachments: attachments
                ),
                makeRequest: { submission in
                    ChatSubmitRequest(
                        wikiID: WikiID(rawValue: "wiki-harness"),
                        chatID: chatID,
                        submission: submission
                    )
                }
            )
        }

        func resumeNextSubmit(with result: Result<ChatID, Error>) {
            guard let waiter = submitWaiters.first else { return }
            submitWaiters.removeFirst()
            waiter.resume(with: result)
        }

        /// Yields the main actor until `condition` holds. Bounded so a starved
        /// completion produces a fast, diagnosed failure instead of a hang.
        @discardableResult
        func waitUntil(
            timeout: Duration = .seconds(5),
            _ condition: @MainActor () -> Bool
        ) async -> Bool {
            let deadline = ContinuousClock.now + timeout
            while condition() == false {
                guard ContinuousClock.now < deadline else {
                    Issue.record("Timed out waiting for controller state change")
                    return false
                }
                await Task.yield()
            }
            return true
        }

        /// Suspend until the test resumes the submit, racing a bounded
        /// deadline: whichever fires first removes the waiter and completes the
        /// continuation exactly once, so an abandoned wait fails fast instead
        /// of parking the task forever (AGENTS.md #1051 rule).
        private func suspendSubmitting(_ request: ChatSubmitRequest) async throws -> ChatID {
            recordedRequests.append(request)
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ChatID, Error>) in
                let waiter = PendingSubmit(continuation: continuation)
                submitWaiters.append(waiter)
                Task { [weak self] in
                    try? await Task.sleep(for: Self.submitWaitTimeout)
                    self?.timeOutSubmit(waiter)
                }
            }
        }

        private func timeOutSubmit(_ waiter: PendingSubmit) {
            guard let index = submitWaiters.firstIndex(where: { $0 === waiter }) else { return }
            submitWaiters.remove(at: index)
            waiter.resume(with: .failure(SendError(message: "submit wait timed out")))
        }
    }

    /// Identity wrapper so the deadline sweeper and the test's resume path can
    /// agree on exactly-once completion of one stored continuation.
    @MainActor
    private final class PendingSubmit {
        private let continuation: CheckedContinuation<ChatID, Error>
        private var didResume = false

        init(continuation: CheckedContinuation<ChatID, Error>) {
            self.continuation = continuation
        }

        func resume(with result: Result<ChatID, Error>) {
            guard didResume == false else { return }
            didResume = true
            continuation.resume(with: result)
        }
    }

    private static let existingChatID = ChatID(rawValue: "01J" + String(repeating: "A", count: 22))
    private static let resolvedChatID = ChatID(rawValue: "01J" + String(repeating: "B", count: 22))

    private static func attachment(named displayName: String) -> ChatAttachment {
        ChatAttachment(kind: .page, itemID: "01J\(displayName)", displayName: displayName)
    }

    private static func failedMessage(_ entry: PendingOutgoingMessage?) -> String? {
        guard case .failed(let message)? = entry?.status else { return nil }
        return message
    }

    // MARK: - Echo timing and lifecycle

    @Test func echoExistsWhileSubmitIsSuspended() async {
        let harness = SendHarness()
        harness.installEnvironment()

        harness.send(chatID: nil)
        // The echo is appended synchronously, before the submit task runs.
        #expect(harness.controller.pendingOutgoing.count == 1)
        #expect(harness.controller.pendingOutgoing.first?.isSubmitting == true)
        #expect(harness.controller.pendingOutgoing.first?.wireMessage == "Please summarize the draft")

        // The submit starts and stays suspended; the echo is still the only
        // rendered copy for the whole in-flight window.
        await harness.waitUntil { harness.suspendedSubmitCount == 1 }
        #expect(harness.controller.pendingOutgoing.first?.isSubmitting == true)

        harness.resumeNextSubmit(with: .failure(SendError(message: "cleanup")))
        await harness.waitUntil { harness.preflightErrors.count == 1 }
    }

    @Test func draftSubmitRetargetsOnSuccess() async {
        let harness = SendHarness()
        harness.installEnvironment()

        harness.send(chatID: nil)
        await harness.waitUntil { harness.suspendedSubmitCount == 1 }
        #expect(harness.recordedRequests.first?.chatID == nil)
        harness.resumeNextSubmit(with: .success(Self.resolvedChatID))
        await harness.waitUntil { harness.retargetedChatIDs == [Self.resolvedChatID] }

        // Disposal is the remount's job; the entry is retained.
        #expect(harness.controller.pendingOutgoing.count == 1)
    }

    @Test func failureRetainsFailedRowAndMarksIt() async {
        let harness = SendHarness()
        harness.installEnvironment()

        harness.send(chatID: Self.existingChatID)
        #expect(harness.optimisticSubmissions.count == 1)
        await harness.waitUntil { harness.suspendedSubmitCount == 1 }
        harness.resumeNextSubmit(with: .failure(SendError(message: "daemon unreachable")))
        await harness.waitUntil {
            Self.failedMessage(harness.controller.pendingOutgoing.first) != nil
        }

        let entry = harness.controller.pendingOutgoing.first
        #expect(Self.failedMessage(entry) == "daemon unreachable")
        #expect(harness.controller.pendingOutgoing.count == 1)
        #expect(harness.optimisticFailures == [entry?.id].compactMap { $0 })
        #expect(harness.preflightErrors == ["daemon unreachable"])
    }

    @Test func failureRestoresDraftOnlyWhenComposerUntouched() async {
        let harness = SendHarness()
        harness.installEnvironment()
        let attachments = [Self.attachment(named: "Design Notes")]
        harness.controller.send(
            chatID: nil,
            payload: .init(
                wireMessage: "[[page:Design Notes]]\n\nPlease summarize the draft",
                draftText: "Please summarize the draft",
                attachments: attachments
            ),
            makeRequest: { submission in
                ChatSubmitRequest(
                    wikiID: WikiID(rawValue: "wiki-harness"),
                    chatID: nil,
                    submission: submission
                )
            }
        )
        harness.composerSnapshot = .init(trimmedText: "", attachmentIDs: [])
        await harness.waitUntil { harness.suspendedSubmitCount == 1 }
        harness.resumeNextSubmit(with: .failure(SendError(message: "boom")))
        await harness.waitUntil { harness.restoredDrafts.count == 1 }

        // The restore carries the typed draft text and the structured
        // attachments — never the wire reference syntax.
        #expect(harness.restoredDrafts.first?.draftText == "Please summarize the draft")
        #expect(harness.restoredDrafts.first?.attachments == attachments)

        // A touched composer suppresses the restore entirely; the failed row
        // stays visible.
        harness.composerSnapshot = .init(trimmedText: "user typed meanwhile", attachmentIDs: [])
        harness.send(chatID: nil)
        await harness.waitUntil { harness.suspendedSubmitCount == 1 }
        harness.resumeNextSubmit(with: .failure(SendError(message: "boom again")))
        await harness.waitUntil {
            harness.controller.pendingOutgoing.dropFirst().contains { entry in
                Self.failedMessage(entry) != nil
            }
        }
        #expect(harness.restoredDrafts.count == 1)
        #expect(harness.controller.pendingOutgoing.count == 2)
    }

    @Test func failureDoesNotRestoreOverNewAttachments() async {
        let harness = SendHarness()
        harness.installEnvironment()

        harness.send(chatID: nil)
        // Empty text, but the user added a different attachment in flight.
        harness.composerSnapshot = .init(
            trimmedText: "",
            attachmentIDs: [Self.attachment(named: "Other Page").id]
        )
        await harness.waitUntil { harness.suspendedSubmitCount == 1 }
        harness.resumeNextSubmit(with: .failure(SendError(message: "boom")))
        await harness.waitUntil { harness.preflightErrors.count == 1 }

        #expect(harness.restoredDrafts.isEmpty)
        #expect(Self.failedMessage(harness.controller.pendingOutgoing.first) == "boom")
    }

    @Test func failureIsolationOnlyMarksItsOwnTurn() async {
        let harness = SendHarness()
        harness.installEnvironment()

        harness.send(chatID: Self.existingChatID, wireMessage: "first")
        harness.send(chatID: Self.existingChatID, wireMessage: "second")
        #expect(harness.controller.pendingOutgoing.count == 2)
        await harness.waitUntil { harness.suspendedSubmitCount == 2 }

        harness.resumeNextSubmit(with: .success(Self.resolvedChatID))
        await harness.waitUntil { harness.suspendedSubmitCount == 1 }
        harness.resumeNextSubmit(with: .failure(SendError(message: "only the second fails")))
        await harness.waitUntil {
            harness.controller.pendingOutgoing.contains { Self.failedMessage($0) != nil }
        }

        let first = harness.controller.pendingOutgoing.first
        let second = harness.controller.pendingOutgoing.last
        #expect(first?.isSubmitting == true)
        #expect(Self.failedMessage(second) == "only the second fails")
    }

    @Test func newSendDoesNotRemoveUnrelatedFailures() async {
        let harness = SendHarness()
        harness.installEnvironment()

        harness.send(chatID: nil, wireMessage: "doomed")
        await harness.waitUntil { harness.suspendedSubmitCount == 1 }
        harness.resumeNextSubmit(with: .failure(SendError(message: "daemon down")))
        await harness.waitUntil { Self.failedMessage(harness.controller.pendingOutgoing.first) != nil }

        harness.send(chatID: nil, wireMessage: "next attempt")
        #expect(harness.controller.pendingOutgoing.count == 2)
        await harness.waitUntil { harness.suspendedSubmitCount == 1 }
        harness.resumeNextSubmit(with: .success(Self.resolvedChatID))
        await harness.waitUntil { harness.retargetedChatIDs.count == 1 }

        #expect(Self.failedMessage(harness.controller.pendingOutgoing.first) == "daemon down")
        #expect(harness.controller.pendingOutgoing.last?.isSubmitting == true)
    }

    // MARK: - Queue transforms

    @Test func queuedMessageRoundTripsDraftAndAttachmentsIntoOutgoingPayload() {
        let attachments = [Self.attachment(named: "Queue Page")]
        let pending = ChatOutgoingMessagesController.makePendingQueuedMessage(
            draftText: "Summarize the queue page",
            wireMessage: "[[page:Queue Page]]\n\nSummarize the queue page",
            attachments: attachments
        )

        #expect(pending.draftText == "Summarize the queue page")
        #expect(pending.preview == "Summarize the queue page")
        #expect(pending.attachments == attachments)

        let payload = ChatOutgoingMessagesController.outgoingPayload(from: pending)
        #expect(payload.wireMessage == "[[page:Queue Page]]\n\nSummarize the queue page")
        #expect(payload.draftText == "Summarize the queue page")
        #expect(payload.attachments == attachments)
    }

    @Test func recallQueuedMessageDoesNotOverwriteNonemptyComposerOrNewAttachments() {
        let attachments = [Self.attachment(named: "Recall Page")]
        let pending = ChatOutgoingMessagesController.makePendingQueuedMessage(
            draftText: "Queued question",
            wireMessage: "Queued question",
            attachments: attachments
        )

        let untouched = ChatOutgoingMessagesController.ComposerSnapshot(
            trimmedText: "", attachmentIDs: []
        )
        let restored = ChatOutgoingMessagesController.restoreQueuedMessage(pending, composer: untouched)
        #expect(restored?.draftText == "Queued question")
        #expect(restored?.attachments == attachments)

        let withTypedText = ChatOutgoingMessagesController.ComposerSnapshot(
            trimmedText: "typed meanwhile", attachmentIDs: []
        )
        #expect(ChatOutgoingMessagesController.restoreQueuedMessage(pending, composer: withTypedText) == nil)

        let withNewAttachment = ChatOutgoingMessagesController.ComposerSnapshot(
            trimmedText: "", attachmentIDs: [Self.attachment(named: "Other").id]
        )
        #expect(ChatOutgoingMessagesController.restoreQueuedMessage(pending, composer: withNewAttachment) == nil)
    }

    @Test func editQueuedMessageRestoresStructuredComposerWhenUntouched() {
        let attachments = [Self.attachment(named: "Edit Page")]
        let pending = ChatOutgoingMessagesController.makePendingQueuedMessage(
            draftText: "Edit question",
            wireMessage: "Edit question",
            attachments: attachments
        )

        let untouched = ChatOutgoingMessagesController.ComposerSnapshot(
            trimmedText: "", attachmentIDs: []
        )
        let restored = ChatOutgoingMessagesController.restoreQueuedMessage(pending, composer: untouched)
        #expect(restored?.draftText == "Edit question")
        #expect(restored?.attachments == attachments)

        let touched = ChatOutgoingMessagesController.ComposerSnapshot(
            trimmedText: "draft in progress", attachmentIDs: []
        )
        #expect(ChatOutgoingMessagesController.restoreQueuedMessage(pending, composer: touched) == nil)
    }

    @Test func queuedSendFailureRetainsRowAndRestoresStructuredComposerWhenUntouched() async {
        let harness = SendHarness()
        harness.installEnvironment()
        let attachments = [Self.attachment(named: "Queue Fail Page")]
        let pending = ChatOutgoingMessagesController.makePendingQueuedMessage(
            draftText: "Queued follow-up",
            wireMessage: "[[page:Queue Fail Page]]\n\nQueued follow-up",
            attachments: attachments
        )

        harness.controller.send(
            chatID: Self.existingChatID,
            payload: ChatOutgoingMessagesController.outgoingPayload(from: pending),
            makeRequest: { submission in
                ChatSubmitRequest(
                    wikiID: WikiID(rawValue: "wiki-harness"),
                    chatID: Self.existingChatID,
                    submission: submission
                )
            }
        )
        await harness.waitUntil { harness.suspendedSubmitCount == 1 }
        harness.resumeNextSubmit(with: .failure(SendError(message: "send failed")))
        await harness.waitUntil { harness.restoredDrafts.count == 1 }

        #expect(harness.restoredDrafts.first?.draftText == "Queued follow-up")
        #expect(harness.restoredDrafts.first?.attachments == attachments)
        #expect(Self.failedMessage(harness.controller.pendingOutgoing.first) == "send failed")
        #expect(harness.controller.pendingOutgoing.count == 1)
    }
}
#endif
