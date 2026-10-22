#if os(macOS)
// Fault injection at the `DaemonWorkloadClient` XPC-reply seam (#1428).
//
// The production bug: `withTimeout` raced its operation against a timer in a
// task group, but the operation waited for the daemon's XPC reply in a plain
// checked continuation. When a reply never arrived (or arrived after the
// timeout), group cancellation could not finish the suspended child, the
// group could never return, and the 30 s timeout was never delivered to the
// caller — wedging the app's serial daemon-event loop with zero log output.
//
// These tests replace the daemon proxy with a stub that drops, delays, or
// answers the `queueOwnershipStatus` reply — the exact call whose lost reply
// wedged the incident — and pin the contract that made recovery possible:
//
// 1. a never-replying proxy must surface the timeout error promptly,
// 2. a reply arriving after the timeout must be absorbed (exactly one
//    resume — a double resume traps at runtime — and later calls work),
// 3. a normal reply delivers its value,
// 4. cancelling the caller releases the pending wait.
//
// Suite discipline per AGENTS.md #1051: `.serialized` + aggressive
// `.timeLimit`s, and every scenario is bounded by construction through a
// short injected `xpcTimeout` (never by waiting on the 30 s default).

import Foundation
import Testing
import WikiDaemonContract
@testable import WikiCtlCore

@Suite(.serialized, .timeLimit(.minutes(2)))
struct DaemonWorkloadClientTimeoutTests {

    /// Short injected per-call bound so scenarios finish in well under a
    /// second of waiting. Production uses `DaemonWorkloadClient.defaultTimeout`.
    private static let testTimeout: TimeInterval = 0.5

    /// Generous wall-clock ceiling for "the timeout was delivered promptly" —
    /// catches a regression to the pre-fix behavior (never returns) without
    /// being load-sensitive.
    private static let promptDeliveryCeiling: Duration = .seconds(10)

    /// A daemon proxy whose `queueOwnershipStatus` reply is fully controlled
    /// by the test. Every other contract method answers with empty data so an
    /// unexpected invocation fails loudly (decode error) instead of hanging.
    private final class FaultInjectionDaemonProxy: NSObject, WikiDaemonProtocol {

        enum OwnershipBehavior {
            /// Answer `queueOwnershipStatus` synchronously with fixed data.
            case replyImmediately(Data)
            /// Capture the reply closure and never answer — the test delivers
            /// it later via ``deliverCapturedOwnershipReply(_:)``.
            case captureForManualDelivery
        }

        private let lock = NSLock()
        private var behavior: OwnershipBehavior
        private var capturedReply: ((Data) -> Void)?

        init(behavior: OwnershipBehavior) {
            self.behavior = behavior
        }

        func setBehavior(_ newBehavior: OwnershipBehavior) {
            lock.lock()
            behavior = newBehavior
            lock.unlock()
        }

        /// Fire the captured reply exactly once. Returns `false` if nothing
        /// was captured (e.g. no request was ever sent).
        @discardableResult
        func deliverCapturedOwnershipReply(_ data: Data) -> Bool {
            lock.lock()
            let reply = capturedReply
            capturedReply = nil
            lock.unlock()
            reply?(data)
            return reply != nil
        }

        func queueOwnershipStatus(reply: @escaping (Data) -> Void) {
            lock.lock()
            switch behavior {
            case .replyImmediately(let data):
                lock.unlock()
                reply(data)
            case .captureForManualDelivery:
                capturedReply = reply
                lock.unlock()
            }
        }

        // The remaining contract methods are outside the fault-injection
        // surface; answering with empty data yields a catchable decode error.

        func search(request: Data, reply: @escaping (Data) -> Void) { reply(Data()) }
        func listWikis(reply: @escaping (Data) -> Void) { reply(Data()) }
        func createWiki(name: String, reply: @escaping (Data?) -> Void) { reply(nil) }
        func deleteWiki(id: String, reply: @escaping (Bool) -> Void) { reply(false) }
        func renameWiki(id: String, name: String, reply: @escaping (Bool) -> Void) { reply(false) }
        func resolveWiki(selector: String, reply: @escaping (Data?) -> Void) { reply(nil) }
        func openStore(wikiID: String, reply: @escaping (Bool) -> Void) { reply(false) }
        func closeStore(wikiID: String, reply: @escaping () -> Void) { reply() }
        func changeToken(wikiID: String, reply: @escaping (String) -> Void) { reply("") }
        func runSignedExtractorProbe(request: Data, reply: @escaping (Data) -> Void) { reply(Data()) }
        func registerEventSink(_ sink: WikiDaemonEventSink) {}
        func queueSnapshot(reply: @escaping (Data) -> Void) { reply(Data()) }
        func enqueueItem(request: Data, reply: @escaping (Data) -> Void) { reply(Data()) }
        func cancelItem(id: String, reply: @escaping (Data) -> Void) { reply(Data()) }
        func cancelAllInFlight(reply: @escaping (Data) -> Void) { reply(Data()) }
        func retryItem(id: String, reply: @escaping (Data) -> Void) { reply(Data()) }
        func pauseQueue(queue: String, reply: @escaping (Data) -> Void) { reply(Data()) }
        func resumeQueue(queue: String, reply: @escaping (Data) -> Void) { reply(Data()) }
        func haltQueue(queue: String, reply: @escaping (Data) -> Void) { reply(Data()) }
        func reorderItem(id: String, beforeItemID: String?, reply: @escaping (Data) -> Void) { reply(Data()) }
        func hasActiveWork(wikiID: String, reply: @escaping (Data) -> Void) { reply(Data()) }
        func waitForCompletion(id: String, reply: @escaping (Data) -> Void) { reply(Data()) }
        func loadTranscript(itemID: String, reply: @escaping (Data) -> Void) { reply(Data()) }
        func loadAllActivitySnapshots(reply: @escaping (Data) -> Void) { reply(Data()) }
        func loadQueueReport(itemID: String, reply: @escaping (Data) -> Void) { reply(Data()) }
        func loadQueueReportSummaries(itemIDs: Data, reply: @escaping (Data) -> Void) { reply(Data()) }
        func relinquishQueue(request: Data, reply: @escaping (Data) -> Void) { reply(Data()) }
        func startChat(request: Data, reply: @escaping (Data) -> Void) { reply(Data()) }
        func submitChatTurn(request: Data, reply: @escaping (Data) -> Void) { reply(Data()) }
        func continueChat(request: Data, reply: @escaping (Data) -> Void) { reply(Data()) }
        func sendChatMessage(request: Data, reply: @escaping (Data) -> Void) { reply(Data()) }
        func stopChat(request: Data, reply: @escaping () -> Void) { reply() }
        func chatSessionState(request: Data, reply: @escaping (Data) -> Void) { reply(Data()) }
        func chatDiagnosticSnapshot(request: Data, reply: @escaping (Data) -> Void) { reply(Data()) }
        func resetChatDiagnostics(request: Data, reply: @escaping (Data) -> Void) { reply(Data()) }
        func resolveChatPermission(request: Data, reply: @escaping () -> Void) { reply() }
        func setChatConfigOption(request: Data, reply: @escaping (Data) -> Void) { reply(Data()) }
    }

    private func makeOwnershipReplyData(epoch: UInt64 = 7) throws -> Data {
        let ownershipEpoch = QueueOwnershipEpoch(rawValue: epoch)
        let payload = QueueOwnershipStatusPayload(epoch: ownershipEpoch, hostState: .serving)
        return try QueueRPCWire.encode(
            QueueRPCEnvelope<QueueOwnershipStatusPayload>.success(
                payload,
                epoch: ownershipEpoch,
                hostState: .serving))
    }

    /// The incident: the daemon's reply never arrives. `withTimeout` must
    /// deliver its timeout error to the caller promptly. On the pre-fix code
    /// this call never returned — the task-group child hung on the abandoned
    /// continuation — so this test doubles as the reproduction: unfixed code
    /// hits the `.timeLimit` with the call still suspended.
    @Test(.timeLimit(.minutes(1)))
    func neverReplyingProxyTimesOutAndCallerObservesTheError() async throws {
        let proxy = FaultInjectionDaemonProxy(behavior: .captureForManualDelivery)
        let client = DaemonWorkloadClient(proxy: proxy, xpcTimeout: Self.testTimeout)

        let clock = ContinuousClock()
        let started = clock.now
        do {
            _ = try await client.queueOwnershipStatus()
            Issue.record("queueOwnershipStatus must throw when the proxy never replies")
            return
        } catch let error as DaemonXPCError {
            guard case .timeout = error else {
                Issue.record("expected DaemonXPCError.timeout, got \(error)")
                return
            }
        } catch {
            Issue.record("expected DaemonXPCError.timeout, got \(type(of: error)): \(error)")
            return
        }
        let elapsed = clock.now - started
        #expect(
            elapsed < Self.promptDeliveryCeiling,
            "timeout must be delivered promptly, took \(elapsed)")
    }

    /// A reply that arrives after the timeout was already delivered must be
    /// absorbed safely: exactly one resume (a second resume traps the
    /// process), the late value discarded, and the client keeps working.
    @Test(.timeLimit(.minutes(1)))
    func lateReplyAfterTimeoutIsAbsorbedAndLaterCallsWork() async throws {
        let proxy = FaultInjectionDaemonProxy(behavior: .captureForManualDelivery)
        let client = DaemonWorkloadClient(proxy: proxy, xpcTimeout: Self.testTimeout)

        // First call times out.
        do {
            _ = try await client.queueOwnershipStatus()
            Issue.record("expected the first call to time out")
            return
        } catch let error as DaemonXPCError {
            guard case .timeout = error else {
                Issue.record("expected DaemonXPCError.timeout, got \(error)")
                return
            }
        } catch {
            Issue.record("expected DaemonXPCError.timeout, got \(type(of: error)): \(error)")
            return
        }

        // The lost reply shows up late — this is where the pre-fix code was
        // one duplicate resume away from a trap and the fixed code must
        // silently discard it.
        let delivered = proxy.deliverCapturedOwnershipReply(try makeOwnershipReplyData())
        #expect(delivered, "the stub should still be holding the reply closure")

        // Give any latent misuse a scheduling beat; a double resume would trap
        // here and take the whole suite down.
        try await Task.sleep(for: .milliseconds(50))

        // The same client must serve a fresh call normally.
        let lateReplyData = try makeOwnershipReplyData(epoch: 9)
        proxy.setBehavior(.replyImmediately(lateReplyData))
        let payload = try await client.queueOwnershipStatus()
        #expect(payload.epoch == QueueOwnershipEpoch(rawValue: 9))
        #expect(payload.hostState == .serving)
    }

    /// Control: a proxy that answers normally delivers its value through the
    /// timeout wrapper untouched.
    @Test(.timeLimit(.minutes(1)))
    func immediatelyReplyingProxyDeliversTheValue() async throws {
        let proxy = FaultInjectionDaemonProxy(
            behavior: .replyImmediately(try makeOwnershipReplyData()))
        let client = DaemonWorkloadClient(proxy: proxy, xpcTimeout: Self.testTimeout)

        let payload = try await client.queueOwnershipStatus()
        #expect(payload.epoch == QueueOwnershipEpoch(rawValue: 7))
        #expect(payload.hostState == .serving)
    }

    /// The mechanism that lets the timeout race return at all: cancelling the
    /// caller must release the pending reply wait (with `CancellationError`)
    /// instead of suspending forever. The 30 s default is used here on
    /// purpose — if cancellation leaked, only the `.timeLimit` would end it.
    @Test(.timeLimit(.minutes(1)))
    func cancellingTheCallerReleasesThePendingReplyWait() async throws {
        let proxy = FaultInjectionDaemonProxy(behavior: .captureForManualDelivery)
        let client = DaemonWorkloadClient(proxy: proxy, xpcTimeout: DaemonWorkloadClient.defaultTimeout)

        let task = Task {
            try await client.queueOwnershipStatus()
        }
        // Let the call reach its reply wait before cancelling.
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("cancelled queueOwnershipStatus must not return a value")
        } catch {
            #expect(error is CancellationError, "expected CancellationError, got \(error)")
        }
    }
}
#endif
