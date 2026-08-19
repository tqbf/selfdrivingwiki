#if os(macOS)
import Foundation
import Testing
import WikiDaemonContract

@Suite("Daemon queue wire", .timeLimit(.minutes(1)))
struct WikiDaemonQueueWireTests {
    @Test("success envelope round-trips version epoch state and payload")
    func successRoundTrip() throws {
        let epoch = QueueOwnershipEpoch(rawValue: 7)
        let original = QueueRPCEnvelope<QueueItemIDPayload>.success(
            QueueItemIDPayload(itemID: "item-1"),
            epoch: epoch,
            hostState: .serving)

        let data = try QueueRPCWire.encode(original)
        let decoded = try QueueRPCWire.decode(QueueItemIDPayload.self, from: data)

        #expect(decoded.version == QueueRPCEnvelope<QueueItemIDPayload>.currentVersion)
        #expect(decoded.ownershipEpoch == epoch)
        #expect(decoded.hostState == .serving)
        #expect(try decoded.requirePayload() == QueueItemIDPayload(itemID: "item-1"))
    }

    @Test("ownership failure round-trips without a normal payload")
    func ownershipFailureRoundTrip() throws {
        let epoch = QueueOwnershipEpoch(rawValue: 4)
        let ownership = QueueOwnershipTransitionError(
            epoch: epoch,
            hostState: .shutdownBlocked,
            activeItemIDs: ["item-2"])
        let original = QueueRPCEnvelope<QueueVoidPayload>.failure(
            QueueRPCError(
                code: .ownershipTransition,
                message: "Queue ownership is changing",
                ownership: ownership),
            epoch: epoch,
            hostState: .shutdownBlocked)

        let data = try QueueRPCWire.encode(original)
        let decoded = try QueueRPCWire.decode(QueueVoidPayload.self, from: data)

        #expect(decoded.payload == nil)
        #expect(decoded.error?.ownership == ownership)
        #expect(throws: QueueRPCError.self) {
            _ = try decoded.requirePayload()
        }
    }

    @Test("unsupported envelope version fails closed")
    func unsupportedVersionIsRejected() throws {
        let unsupported = QueueRPCEnvelope<QueueBoolPayload>(
            version: QueueRPCEnvelope<QueueBoolPayload>.currentVersion + 1,
            ownershipEpoch: QueueOwnershipEpoch(rawValue: 1),
            hostState: .serving,
            payload: QueueBoolPayload(value: true))
        let data = try JSONEncoder().encode(unsupported)

        #expect(throws: QueueRPCError.self) {
            _ = try QueueRPCWire.decode(QueueBoolPayload.self, from: data)
        }
    }

    @Test("ownership status round-trips matching envelope metadata")
    func ownershipStatusRoundTrip() throws {
        let epoch = QueueOwnershipEpoch(rawValue: 10)
        let payload = QueueOwnershipStatusPayload(epoch: epoch, hostState: .serving)
        let original = QueueRPCEnvelope<QueueOwnershipStatusPayload>.success(
            payload,
            epoch: epoch,
            hostState: .serving)

        let data = try QueueRPCWire.encode(original)
        let decoded = try QueueRPCWire.decode(
            QueueOwnershipStatusPayload.self,
            from: data)

        #expect(decoded.ownershipEpoch == epoch)
        #expect(decoded.hostState == .serving)
        #expect(try decoded.requirePayload() == payload)
    }

    @Test("relinquishment request round-trips through the versioned envelope")
    func relinquishmentRequestRoundTrip() throws {
        let epoch = QueueOwnershipEpoch(rawValue: 12)
        let original = QueueRPCEnvelope<QueueRelinquishmentRequest>.success(
            QueueRelinquishmentRequest(expectedEpoch: epoch),
            epoch: epoch,
            hostState: .serving)

        let data = try QueueRPCWire.encode(original)
        let decoded = try QueueRPCWire.decode(
            QueueRelinquishmentRequest.self,
            from: data)

        #expect(decoded.ownershipEpoch == epoch)
        #expect(try decoded.requirePayload().expectedEpoch == epoch)
    }

    @Test("unsupported relinquishment request version fails closed")
    func unsupportedRelinquishmentRequestVersionIsRejected() throws {
        let epoch = QueueOwnershipEpoch(rawValue: 13)
        let unsupported = QueueRPCEnvelope<QueueRelinquishmentRequest>(
            version: QueueRPCEnvelope<QueueRelinquishmentRequest>.currentVersion + 1,
            ownershipEpoch: epoch,
            hostState: .serving,
            payload: QueueRelinquishmentRequest(expectedEpoch: epoch))
        let data = try JSONEncoder().encode(unsupported)

        do {
            _ = try QueueRPCWire.decode(QueueRelinquishmentRequest.self, from: data)
            Issue.record("Expected an unsupported queue RPC version error")
        } catch {
            #expect((error as? QueueRPCError)?.code == .unsupportedVersion)
        }
    }

    @Test("relinquishment success requires all completion facts")
    func relinquishmentCompletionFacts() {
        let complete = QueueRelinquishmentSuccess(
            completedEpoch: QueueOwnershipEpoch(rawValue: 2),
            dispatchStopped: true,
            workersSettledOrRequeued: true,
            forwardingStopped: true,
            storeClosed: true)
        let incomplete = QueueRelinquishmentSuccess(
            completedEpoch: QueueOwnershipEpoch(rawValue: 2),
            dispatchStopped: true,
            workersSettledOrRequeued: false,
            forwardingStopped: true,
            storeClosed: true)

        #expect(complete.isComplete)
        #expect(incomplete.isComplete == false)
    }
}
#endif
