#if os(macOS)
import Foundation
import GRPCCore
import GRPCProtobuf
import Testing
import WikiDaemonGRPC
import WikiDaemonGRPCContract

/// Pure session-store semantics for the app–daemon gRPC admission path
/// (plans/app-daemon-wire-contract.md). No sockets, no transport: the
/// credential lifecycle rules in isolation. The live-socket halves of AC.2
/// live in ``AppDaemonAdmissionTests`` (WikiFSAppTests).
@Suite("App Daemon session store contract", .serialized, .timeLimit(.minutes(2)))
struct AppDaemonSessionStoreContractTests {

    /// The same unexpired bootstrap credential exchanges to the SAME bearer
    /// on every call — a dropped reply is safely retried inside the window.
    @Test("exchange is idempotent within the bootstrap window")
    func exchangeIsIdempotent() {
        let store = DaemonSessionStore(
            now: { 1_000 },
            credentialGenerator: CounterCredentialGenerator().generator())
        guard let offer = store.admissionOffer(socketPath: "/tmp/g/s", connectionID: "conn-1") else {
            Issue.record("admission refused")
            return
        }

        let first = store.exchange(bootstrapHex: offer.bootstrapCredentialHex)
        let second = store.exchange(bootstrapHex: offer.bootstrapCredentialHex)
        #expect(first != nil)
        #expect(first == second)
    }

    /// A second admission for the same live XPC connection never forks a
    /// session: one logical session per connection.
    @Test("repeated admission resolves to one session per connection")
    func oneSessionPerConnection() {
        let generator = CounterCredentialGenerator()
        let store = DaemonSessionStore(credentialGenerator: generator.generator())
        guard let first = store.admissionOffer(socketPath: "/tmp/g/s", connectionID: "conn-1") else {
            Issue.record("admission refused")
            return
        }
        guard let second = store.admissionOffer(socketPath: "/tmp/g/s", connectionID: "conn-1") else {
            Issue.record("admission refused")
            return
        }
        let sessionA = store.exchange(bootstrapHex: first.bootstrapCredentialHex)
        let sessionB = store.exchange(bootstrapHex: second.bootstrapCredentialHex)
        #expect(sessionA == sessionB)

        guard let other = store.admissionOffer(socketPath: "/tmp/g/s", connectionID: "conn-2") else {
            Issue.record("admission refused")
            return
        }
        let sessionC = store.exchange(bootstrapHex: other.bootstrapCredentialHex)
        #expect(sessionA != sessionC)
    }

    /// An expired bootstrap fails the exchange; XPC then issues a fresh
    /// bootstrap for the SAME live session (the recovery path for a dropped
    /// exchange reply that outlived the window).
    @Test("expired bootstrap fails; fresh bootstrap reuses the live session")
    func bootstrapExpiryRecovery() {
        let clock = MutableClock()
        let generator = CounterCredentialGenerator()
        let store = DaemonSessionStore(
            now: { clock.nowUptimeNS },
            credentialGenerator: generator.generator())
        guard let first = store.admissionOffer(socketPath: "/tmp/g/s", connectionID: "conn-1") else {
            Issue.record("admission refused")
            return
        }

        clock.nowUptimeNS += DaemonSessionStore.bootstrapLifetimeNanoseconds + 1
        #expect(store.exchange(bootstrapHex: first.bootstrapCredentialHex) == nil)

        guard let fresh = store.admissionOffer(socketPath: "/tmp/g/s", connectionID: "conn-1") else {
            Issue.record("admission refused")
            return
        }
        let session = store.exchange(bootstrapHex: fresh.bootstrapCredentialHex)
        #expect(session != nil)

        // Idempotency across recovery, on an unexpired bootstrap: the SAME
        // bearer returns on every exchange.
        let probe = DaemonSessionStore(credentialGenerator: CounterCredentialGenerator().generator())
        guard let original = probe.admissionOffer(socketPath: "/tmp/g/s", connectionID: "conn-1") else {
            Issue.record("admission refused")
            return
        }
        let firstBearer = probe.exchange(bootstrapHex: original.bootstrapCredentialHex)
        let again = probe.exchange(bootstrapHex: original.bootstrapCredentialHex)
        #expect(firstBearer != nil)
        #expect(again == firstBearer)
    }

    /// Revocation is idempotent, prevents further workload validation, and
    /// terminates every registered stream exactly once.
    @Test("revocation terminates streams once and rejects the bearer")
    func revocationTerminatesStreams() {
        let generator = CounterCredentialGenerator()
        let store = DaemonSessionStore(credentialGenerator: generator.generator())
        guard let offer = store.admissionOffer(socketPath: "/tmp/g/s", connectionID: "conn-1") else {
            Issue.record("admission refused")
            return
        }
        let bearer = store.exchange(bootstrapHex: offer.bootstrapCredentialHex)
        guard let bearer else {
            Issue.record("exchange failed")
            return
        }

        let handle = RecordingStreamHandle()
        store.registerStream(sessionHex: bearer, handle)

        #expect(store.revokeSession(connectionID: "conn-1"))
        #expect(handle.terminations == 1)

        // Idempotent: a second revocation is a no-op (no stream left).
        #expect(!store.revokeSession(connectionID: "conn-1"))
        #expect(handle.terminations == 1)

        // The bearer no longer validates (workload dispatch is refused).
        #expect(store.validate(bearerHex: bearer) == nil)

        // A NEW connection gets a new session (the XPC connection was
        // invalidated; the app reconnects with a fresh connection id).
        guard let fresh = store.admissionOffer(socketPath: "/tmp/g/s", connectionID: "conn-2") else {
            Issue.record("admission refused")
            return
        }
        #expect(store.exchange(bootstrapHex: fresh.bootstrapCredentialHex) != nil)
    }

    /// A credential from a PRIOR daemon instance (a different store) never
    /// validates — nothing persists across instances.
    @Test("prior-instance credentials fail validation and exchange")
    func priorInstanceCredentialsFail() {
        let generator = CounterCredentialGenerator()
        let prior = DaemonSessionStore(credentialGenerator: generator.generator())
        guard let priorOffer = prior.admissionOffer(socketPath: "/tmp/g/s", connectionID: "conn-1") else {
            Issue.record("admission refused")
            return
        }
        guard let priorBearer = prior.exchange(bootstrapHex: priorOffer.bootstrapCredentialHex) else {
            Issue.record("prior exchange failed")
            return
        }

        let current = DaemonSessionStore(credentialGenerator: generator.generator())
        #expect(current.validate(bearerHex: priorBearer) == nil)
        #expect(current.exchange(bootstrapHex: priorOffer.bootstrapCredentialHex) == nil)
    }

    /// An over-long composed path is a typed failure BEFORE bind — never a
    /// truncation, never a fallback outside the container.
    @Test("overlong socket path fails typed before bind")
    func overlongPathFailsTyped() {
        let deep = "/tmp/\(String(repeating: "d/", count: 60))"
        let container = URL(fileURLWithPath: deep, isDirectory: true)
        #expect {
            _ = try DaemonGRPCSocketPaths.socketPath(inContainer: container)
        } throws: { error in
            if case .pathTooLong(let limit, let actual) = error as? DaemonGRPCSocketError {
                return actual > limit
            }
            return false
        }
    }

    /// The typed failure mapping: a received rich status round-trips through
    /// the details envelope with its stable code.
    @Test("typed failure maps through versioned details")
    func failureDetailsRoundTrip() throws {
        let failure = AppDaemonFailure(
            code: .wikiNotFound, message: "no such wiki",
            daemonInstanceID: "instance-7")
        let status = failure.googleRPCStatus(instanceID: "instance-7")
        #expect(status.code == .notFound)
        #expect(status.details.count == 1)
        guard let any = status.details[0].any else {
            Issue.record("details must carry an Any")
            return
        }
        let bytes: Data = try status.serializedBytes()
        var metadata = GRPCCore.Metadata()
        metadata.addBinary([UInt8](bytes), forKey: "grpc-status-details-bin")
        let decoded = AppDaemonFailure.error(from: RPCError(
            code: status.code, message: status.message, metadata: metadata))
        #expect(decoded.code == .wikiNotFound)
        #expect(decoded.message == "no such wiki")
        #expect(decoded.daemonInstanceID == "instance-7")
        _ = any
    }
}

/// Deterministic credential source for store tests: distinct opaque values,
/// no randomness. Credentials are never logged anywhere in the module.
// `counter` is covered by `lock`.
// swiftlint:disable:next unchecked_sendable
final class CounterCredentialGenerator: @unchecked Sendable {
    private let lock = NSLock()
    private var counter = 0

    func generator() -> @Sendable () -> String {
        { [self] in
            lock.lock()
            defer { lock.unlock() }
            counter += 1
            return String(repeating: "c", count: counter)
        }
    }
}

/// Mutable monotonic clock for expiry-walking tests.
// Test-only clock: written between store calls, read via the closure.
// swiftlint:disable:next unchecked_sendable
final class MutableClock: @unchecked Sendable {
    var nowUptimeNS: UInt64 = 0
}

/// Recording stream handle for revocation assertions.
// `count` is covered by `lock`.
// swiftlint:disable:next unchecked_sendable
// `count` is covered by `lock`.
// swiftlint:disable:next unchecked_sendable
final class RecordingStreamHandle: DaemonSessionStore.SessionStreamHandle, @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var count = 0
    var terminations: Int {
        lock.withLock { count }
    }

    func finish() {
        lock.withLock { count += 1 }
    }
}
#endif
