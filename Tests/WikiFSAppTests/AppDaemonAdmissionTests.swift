#if os(macOS)
import Foundation
import Testing
import WikiDaemonGRPC
import WikiDaemonGRPCContract

/// Multi-connection admission + socket ownership over a REAL Unix domain
/// socket (AC.2, plans/app-daemon-wire-contract.md): a second listener
/// fails typed and never disturbs the served endpoint; stale sockets
/// recover under the guard; the full client/server path — admission,
/// capabilities, registry read, typed events, revocation — works end to
/// end; and every failure carries the versioned details code.
@Suite("App Daemon admission (live)", .serialized, .timeLimit(.minutes(4)))
struct AppDaemonAdmissionTests {

    /// A second live listener on the same container fails with the typed
    /// ownership failure and never touches the first listener's socket;
    /// the first endpoint keeps serving.
    @Test("second listener fails typed; first keeps serving")
    func secondListenerFailsTyped() async throws {
        let harness = try await TestHarness.make()
        defer { harness.stopInBackground() }

        let first = harness.listener
        #expect {
            _ = try DaemonGRPCListener(
                containerDirectory: harness.container,
                provider: harness.makeReplacementProvider(),
                onShutdown: {})
        } throws: { error in
            error is DaemonGRPCSocketError
                && (error as? DaemonGRPCSocketError)
                    == .serverAlreadyRunning(path: first.socketPath)
        }

        // Continued service after the rejected bind.
        guard let offer = harness.admissionOffer(connectionID: "after-raced-bind") else {
            Issue.record("admission refused")
            return
        }
        let client = try AppDaemonSessionClient(admission: offer.admission)
        defer { client.close() }
        try await client.bootstrap()
        _ = try await client.listWikis()
    }

    /// A socket file that outlived its guard process is provably ownerless:
    /// start() removes it under the flock and serves.
    @Test("stale socket file is recovered under the guard")
    func staleSocketRecovery() async throws {
        let container = try TestHarness.makeContainer()
        // Test-container cleanup is best-effort; a failure leaves a temp
        // dir for the next run's OS cleanup and cannot fail the assertion.
        // swiftlint:disable:next silent_try_optional
        defer { try? FileManager.default.removeItem(at: container) }

        let stalePath = try DaemonGRPCSocketPaths.socketPath(inContainer: container)
        FileManager.default.createFile(
            atPath: stalePath, contents: Data("not-a-socket".utf8))

        let harness = try await TestHarness.make(container: container)
        defer { harness.stopInBackground() }
        #expect(await DaemonGRPCListener.endpointAccepts(path: stalePath))
    }

    /// Full path: admission → capabilities → ListWikis → typed events.
    /// The in-process half of the signed smoke's read/event legs (the
    /// signed app harness exercises them through launchd separately).
    @Test("live round trip: admission, capabilities, list, events")
    func liveRoundTrip() async throws {
        let harness = try await TestHarness.make()
        defer { harness.stopInBackground() }

        guard let offer = harness.admissionOffer(connectionID: "round-trip-conn") else {
            Issue.record("admission refused")
            return
        }
        let client = try AppDaemonSessionClient(admission: offer.admission)
        defer { client.close() }

        try await client.bootstrap()
        #expect(client.authenticatedInstanceID == offer.admission.daemonInstanceID)

        let wikis = try await client.listWikis()
        #expect(wikis.wikis.count == 1)
        #expect(wikis.wikis[0].displayName == "Fixture Wiki")
        #expect(wikis.wikis[0].id.value == TestHarness.fixtureWikiID)
        #expect(!wikis.wikis[0].hasHomePageID)

        let stream = client.subscribeRegistryEvents()
        // The stream carries no replay: publish only after the server has
        // actually registered the subscription (contract ordering).
        let subscribeDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while harness.hub.subscriptionCount == 0 && ContinuousClock.now < subscribeDeadline {
            // Test-teardown/cleanup: the failure path is the assertion below.
            // swiftlint:disable:next silent_try_optional
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(harness.hub.subscriptionCount >= 1)
        harness.hub.publish(
            kind: .created,
            wikiIDRawValue: TestHarness.fixtureWikiID,
            displayName: "Fixture Wiki")

        let event = try await Self.consumeFirstEvent(
            from: stream, timeout: .seconds(5))
        #expect(event.kind == .created)
        #expect(event.wikiID.value == TestHarness.fixtureWikiID)
        #expect(event.hasDisplayName)
        #expect(event.displayName == "Fixture Wiki")
    }

    /// Missing/unknown credentials and revoked sessions fail BEFORE
    /// workload dispatch, with the versioned details code; an unserved
    /// event family is rejected before any stream exists.
    @Test("typed failures carry versioned details before dispatch")
    func typedFailuresCarryDetails() async throws {
        let harness = try await TestHarness.make()
        defer { harness.stopInBackground() }

        // 1. No valid admission credential at all.
        let anonymous = try AppDaemonSessionClient(admission: AppDaemonAdmission(
            socketPath: harness.listener.socketPath,
            bootstrapCredentialHex: "not-issued",
            daemonInstanceID: "any-instance",
            expiresAt: Date()))
        defer { anonymous.close() }
        do {
            _ = try await anonymous.listWikis()
            Issue.record("anonymous listWikis must fail")
        } catch let failure as AppDaemonFailure {
            // The client-side bootstrap gate fires before any RPC; the
            // typed code is what the contract requires (fail before
            // dispatch), instance id arrives only from server-side
            // rejections (asserted on the revoked path below).
            #expect(failure.code == .unauthenticated)
        }

        // 2. Valid admission, then revocation: the bearer stops working and
        // a LIVE subscription dies (liveness proven by an event FIRST — a
        // watchdog timeout can no longer masquerade as the outcome).
        guard let offer = harness.admissionOffer(connectionID: "revoked-conn") else {
            Issue.record("admission refused")
            return
        }
        let client = try AppDaemonSessionClient(admission: offer.admission)
        defer { client.close() }
        try await client.bootstrap()

        let liveStream = client.subscribeRegistryEvents()
        let subscribeDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while harness.hub.subscriptionCount == 0
            && ContinuousClock.now < subscribeDeadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        harness.hub.publish(
            kind: .renamed,
            wikiIDRawValue: TestHarness.fixtureWikiID,
            displayName: "Renamed")
        let live = try await Self.consumeFirstEvent(from: liveStream, timeout: .seconds(5))
        #expect(live.kind == AppDaemonRegistryEvent.Kind.renamed)

        // NOW revoke: the live stream must end (nil) or fail typed — the
        // watchdog uses its own error type, so the two are distinguishable.
        harness.store.revokeSession(connectionID: "revoked-conn")
        do {
            _ = try await withThrowingTaskGroup(of: AppDaemonRegistryEvent?.self) { group in
                group.addTask {
                    var iterator = liveStream.makeAsyncIterator()
                    return try await iterator.next()
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(5))
                    throw WatchdogTimeout()
                }
                let first = (try await group.next()) ?? nil
                group.cancelAll()
                // nil = clean server-side end (the revocation sentinel).
                #expect(
                    first == nil,
                    "expected plain stream end on revocation, got \(String(describing: first))")
            }
        } catch is WatchdogTimeout {
            Issue.record("revoked stream neither ended nor failed within 5s")
        } catch let failure as AppDaemonFailure {
            // A typed stream failure is also an acceptable outcome.
            #expect(
                failure.code == .unauthenticated || failure.code == .invalidRequest)
        } catch is CancellationError {
            // Plain end is acceptable.
        }

        do {
            _ = try await client.listWikis()
            Issue.record("revoked bearer must fail workload dispatch")
        } catch let failure as AppDaemonFailure {
            // Server-side rejection: the details carry the daemon instance.
            #expect(failure.code == .unauthenticated)
            #expect(failure.daemonInstanceID == harness.store.daemonInstanceID)
        }

        // 3. Unserved family → typed invalidRequest before the stream.
        guard let fresh = harness.admissionOffer(connectionID: "family-conn") else {
            Issue.record("admission refused")
            return
        }
        let familyClient = try AppDaemonSessionClient(admission: fresh.admission)
        defer { familyClient.close() }
        try await familyClient.bootstrap()
        do {
            // UNSPECIFIED is never served (first slice: REGISTRY only); the
            // provider must reject it before any stream exists.
            let invalidStream = familyClient.subscribeEvents(families: [.unspecified])
            var iterator = invalidStream.makeAsyncIterator()
            _ = try await iterator.next()
            Issue.record("unserved family must fail the subscription")
        } catch let failure as AppDaemonFailure {
            #expect(failure.code == .invalidRequest)
        }
    }

    // MARK: - Helpers

    private static func consumeFirstEvent(
        from stream: AsyncThrowingStream<AppDaemonRegistryEvent, Error>,
        timeout: Duration
    ) async throws -> AppDaemonRegistryEvent {
        try await withThrowingTaskGroup(of: AppDaemonRegistryEvent.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                guard let event = try await iterator.next() else {
                    throw AppDaemonFailure(
                        code: .deadlineExceeded,
                        message: "subscription ended without an event")
                }
                return event
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw AppDaemonFailure(
                    code: .deadlineExceeded, message: "no event within \(timeout)")
            }
            let first = try await group.next()
            group.cancelAll()
            guard let first else {
                throw AppDaemonFailure(code: .deadlineExceeded, message: "no task result")
            }
            return first
        }
    }
}

/// The watchdog's OWN error, distinct from every RPC outcome so a timeout
/// can never be mistaken for the behavior under test.
private struct WatchdogTimeout: Error {}

/// The live harness: one listener + provider + hub + store over a private
/// temp container, with the fixture registry reply.
private struct TestHarness {
    static let fixtureWikiID = "01HZY4WXQ8PJ7RKP3GV9X8QW2T"

    let container: URL
    let listener: DaemonGRPCListener
    let store: DaemonSessionStore
    let hub: DaemonRegistryEventHub

    static func makeContainer() throws -> URL {
        // POSIX /tmp keeps the composed g/s path short: the socket-path byte
        // limit is a real contract gate and long macOS temp paths would
        // (correctly) fail it. /tmp resolves to /private/tmp on macOS; the
        // 8-hex suffix keeps uniqueness without length.
        let suffix = String(format: "%08llx", UInt64.random(in: 0 ..< UInt64.max))
        let base = URL(fileURLWithPath: "/tmp/wg-\(suffix)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Build + start + await readiness. The registry handler serves the
    /// single fixture descriptor.
    static func make(
        container: URL? = nil
    ) async throws -> TestHarness {
        let resolved = try container ?? makeContainer()
        let hub = DaemonRegistryEventHub()
        let store = DaemonSessionStore()
        let provider = AppDaemonServiceProvider(
            store: store,
            hub: hub,
            handlers: .init(listWikis: {
                AppDaemonListWikisReply.with {
                    $0.wikis = [fixtureDescriptor()]
                }
            }))
        let listener = try DaemonGRPCListener(
            containerDirectory: resolved,
            provider: provider,
            onShutdown: { store.revokeAll(); hub.closeAll() })
        try listener.start()
        try await listener.waitUntilServing(timeout: .seconds(10))
        return TestHarness(
            container: resolved, listener: listener, store: store, hub: hub)
    }

    static func fixtureDescriptor() -> AppDaemonWikiDescriptor {
        AppDaemonWikiDescriptor.with {
            $0.id = AppDaemonWikiId.with { $0.value = fixtureWikiID }
            $0.displayName = "Fixture Wiki"
            $0.createdAt = .init(date: Date(timeIntervalSince1970: 1_700_000_000))
            $0.lastUsedAt = .init(date: Date(timeIntervalSince1970: 1_700_001_000))
        }
    }

    struct Offer {
        let admission: AppDaemonAdmission
    }

    func admissionOffer(connectionID: String) -> Offer? {
        guard let offer = store.admissionOffer(
            socketPath: listener.socketPath, connectionID: connectionID)
        else { return nil }
        return Offer(admission: AppDaemonAdmission(
            socketPath: offer.socketPath,
            bootstrapCredentialHex: offer.bootstrapCredentialHex,
            daemonInstanceID: offer.daemonInstanceID,
            expiresAt: offer.expiresAt))
    }

    /// A fresh provider sharing nothing (used to prove the SECOND listener
    /// construction fails on ownership, not on provider state).
    func makeReplacementProvider() -> AppDaemonServiceProvider {
        let providerStore = DaemonSessionStore()
        let providerHub = DaemonRegistryEventHub()
        return AppDaemonServiceProvider(
            store: providerStore, hub: providerHub,
            handlers: .init(listWikis: { AppDaemonListWikisReply() }))
    }

    func stopInBackground() {
        let listener = listener
        Task.detached(priority: .utility) {
            await listener.stop()
        }
        // Test-teardown/cleanup: the failure path is the assertion below.
        // swiftlint:disable:next silent_try_optional
        try? FileManager.default.removeItem(at: container)
    }
}
#endif
