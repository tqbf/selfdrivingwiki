#if os(macOS)
import Foundation
import Testing
@testable import WikiDaemonContract
@testable import wikid
import WikiFSCore

/// The run registry's lease state machine and capability handling
/// (plans/agent-sandbox-scoping.md §5): prepared → active → revoked with
/// idempotent revocation, owner-side renewal on a bounded lease, digest-only
/// storage, and the typed authorization errors the dispatcher surfaces.
/// Pure actor tests — no socket, no daemon, no waiting.
@Suite("Daemon run registry")
struct DaemonRunRegistryTests {

    private func makeScope(_ name: String = "Registry Wiki") -> DaemonRunScope {
        DaemonRunScope(wikiID: WikiDescriptor.make(displayName: name).id)
    }

    private func makeClasses() -> Set<DaemonRunOperationClass> {
        [.wikiRead, .wikiEdit, .wikiAcquire]
    }

    // MARK: Capability

    @Test func capabilityIs256SystemRandomBitsWithRoundTrippingPrintableForm()
        async throws
    {
        let capability = try DaemonRunCapability()
        #expect(capability.secret.count == 32)
        let decoded = try #require(DaemonRunCapability(printable: capability.printable))
        #expect(decoded == capability)

        // Two draws differ (256 random bits colliding is not a thing).
        let other = try DaemonRunCapability()
        #expect(other != capability)

        // Malformed printables are nil, never a short or oversized secret.
        #expect(DaemonRunCapability(printable: "not base64!!") == nil)
        #expect(DaemonRunCapability(printable: Data([0x01]).base64EncodedString()) == nil)
        #expect(DaemonRunCapability(printable: String(repeating: "A", count: 200)) == nil)
    }

    @Test func capabilityDescriptionIsRedacted() throws {
        let capability = try DaemonRunCapability()
        // The printable secret must not ride any description interpolation.
        #expect(!String(describing: capability).contains(capability.printable))
        #expect(!String(reflecting: capability).contains(capability.printable))
    }

    // MARK: Lifecycle: prepared → active → revoked

    @Test func preparedRunDoesNotAuthorizeUntilActivated() async throws {
        let registry = DaemonRunRegistry()
        let scope = makeScope()
        let registration = try await registry.prepareRun(
            scope: scope, operationClasses: makeClasses())
        // A prepared lease must not authorize: the child cannot jump the gun
        // between registration and the trusted owner's activation.
        await #expect(throws: DaemonDomainError.self) {
            try await registry.authorize(capability: registration.capability)
        }
        try await registry.activate(runID: registration.runID)
        let grant = try await registry.authorize(capability: registration.capability)
        #expect(grant.runID == registration.runID)
        #expect(grant.scope == scope)
        #expect(grant.operationClasses == makeClasses())
    }

    @Test func activationAndRenewalRejectInvalidTransitions() async throws {
        let registry = DaemonRunRegistry()
        let registration = try await registry.prepareRun(
            scope: makeScope(), operationClasses: makeClasses())
        let missing = DaemonRunID(rawValue: "no-such-run")
        await #expect(throws: DaemonRunLeaseError.unknownRun(missing)) {
            try await registry.activate(runID: missing)
        }
        // Double activation is not a state machine no-op — it is a caller bug.
        try await registry.activate(runID: registration.runID)
        await #expect(throws: DaemonRunLeaseError.self) {
            try await registry.activate(runID: registration.runID)
        }
        // Renewal of an unknown run is refused, not invented.
        await #expect(throws: DaemonRunLeaseError.unknownRun(missing)) {
            try await registry.renew(runID: missing)
        }
    }

    @Test func emptyOperationClassesIsRefused() async {
        let registry = DaemonRunRegistry()
        await #expect(throws: DaemonRunLeaseError.emptyOperationClasses) {
            try await registry.prepareRun(scope: makeScope(), operationClasses: [])
        }
    }

    // MARK: Revocation

    @Test func revokedCapabilityExpiresAndRevocationIsIdempotent() async throws {
        let registry = DaemonRunRegistry()
        let registration = try await registry.prepareRun(
            scope: makeScope(), operationClasses: makeClasses())
        try await registry.activate(runID: registration.runID)
        #expect(try await registry.authorize(capability: registration.capability).runID
            == registration.runID)

        await registry.revoke(runID: registration.runID)
        // Revoked is a terminal lease: "expired" authority, never invalid
        // (the reply is identical either way so lease state does not leak).
        do {
            _ = try await registry.authorize(capability: registration.capability)
            Issue.record("a revoked capability must not authorize")
        } catch let error as DaemonDomainError {
            #expect(error.code == .authorizationExpired)
        }
        // Idempotent: revoking again (and again) settles quietly.
        await registry.revoke(runID: registration.runID)
        await registry.revoke(runID: registration.runID)
        // Revoking an unknown run is also a quiet no-op (teardown paths
        // revoke unconditionally).
        await registry.revoke(runID: DaemonRunID(rawValue: "no-such-run"))
        // Renewal past revocation is refused.
        await #expect(throws: DaemonRunLeaseError.self) {
            try await registry.renew(runID: registration.runID)
        }
        do {
            _ = try await registry.authorize(capability: registration.capability)
            Issue.record("authority must stay revoked")
        } catch let error as DaemonDomainError {
            #expect(error.code == .authorizationExpired)
        }
    }

    // MARK: Bounded lease + owner-side renewal

    @Test func expiredLeaseRejectsAuthorizationUntilRenewed() async throws {
        let registry = DaemonRunRegistry()
        // A lease born expired: the owner registered it and never kept the
        // bound alive.
        let registration = try await registry.prepareRun(
            scope: makeScope(),
            operationClasses: makeClasses(),
            lifetime: .seconds(0))
        try await registry.activate(runID: registration.runID)
        do {
            _ = try await registry.authorize(capability: registration.capability)
            Issue.record("an expired lease must not authorize")
        } catch let error as DaemonDomainError {
            #expect(error.code == .authorizationExpired)
        }
        // The OWNER renews — the registry is the only path that can.
        try await registry.renew(
            runID: registration.runID,
            lifetime: .seconds(3600))
        let grant = try await registry.authorize(capability: registration.capability)
        #expect(grant.runID == registration.runID)
    }

    @Test func authorizationWindowFollowsTheRenewedExpiry() async throws {
        let registry = DaemonRunRegistry()
        let registration = try await registry.prepareRun(
            scope: makeScope(),
            operationClasses: makeClasses(),
            lifetime: .seconds(60))
        try await registry.activate(runID: registration.runID)
        // Just past the original bound: expired.
        let justAfter = Date().addingTimeInterval(61)
        do {
            _ = try await registry.authorize(
                capability: registration.capability, at: justAfter)
            Issue.record("the original bound must hold")
        } catch let error as DaemonDomainError {
            #expect(error.code == .authorizationExpired)
        }
        // Renewal moves the bound; the same instant authorizes now.
        try await registry.renew(
            runID: registration.runID,
            lifetime: .seconds(3600))
        let grant = try await registry.authorize(
            capability: registration.capability, at: justAfter)
        #expect(grant.runID == registration.runID)
    }

    // MARK: Digest storage

    @Test func registryStoresDigestNotThePrintableSecret() async throws {
        let registry = DaemonRunRegistry()
        let registration = try await registry.prepareRun(
            scope: makeScope(), operationClasses: makeClasses())
        try await registry.activate(runID: registration.runID)
        let lease = try #require(await registry.lease(for: registration.runID))

        // The lease's capability material is a digest, and the printable
        // secret appears nowhere on it.
        let expectedDigest = DaemonRunCapabilityDigest(
            printable: registration.capability.printable)
        #expect(lease.digest == expectedDigest)
        #expect(!String(describing: lease).contains(registration.capability.printable))
        #expect(!String(reflecting: lease).contains(registration.capability.printable))

        // The same printable digests identically; a different capability
        // digests differently and does not authorize the run.
        let digestAgain = DaemonRunCapabilityDigest(
            capability: try #require(DaemonRunCapability(printable: registration.capability.printable)))
        #expect(digestAgain == expectedDigest)
        do {
            _ = try await registry.authorize(capability: try DaemonRunCapability())
            Issue.record("an unregistered capability must not authorize")
        } catch let error as DaemonDomainError {
            #expect(error.code == .authorizationInvalid)
        }

        // Registration count is the only trace: exactly the runs prepared.
        #expect(await registry.runCount() == 1)
    }

    @Test func unknownOrGarbledCapabilitiesAreInvalidNotExpired() async throws {
        let registry = DaemonRunRegistry()
        do {
            _ = try await registry.authorize(
                capability: try #require(
                    DaemonRunCapability(
                        printable: Data(repeating: 0x2A, count: 32).base64EncodedString())))
            Issue.record("an unregistered capability must not authorize")
        } catch let error as DaemonDomainError {
            #expect(error.code == .authorizationInvalid)
        }
    }
}
#endif
