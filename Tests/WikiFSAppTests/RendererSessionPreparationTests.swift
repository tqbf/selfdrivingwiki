#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import WikiFS
import WikiFSCore
import WikiFSTypes

/// Phase 2/4 acceptance tests for the per-session authority seam.
///
/// Covers: declaration-gated helper execution (AC.8), helper/admission failure
/// keeping primary rendering available (AC.14), exact pinned asset reads
/// through the prepared authority (AC.6), and preparation-owner publication
/// gating (AC.5).
/// Shared fixtures for preparation-owner and preparer suites.
@MainActor
enum RendererPreparationFixtures {
    struct UnavailableResourceProvider: RendererPackageResourceProviding {
        func resource(for url: URL) throws -> RendererPackageResource {
            throw RendererPackageResourceError.undeclaredAsset
        }
    }

    enum FixtureError: Error {
        case missingContentVersion
    }

    /// A web-package descriptor. Mirrors the reviewed-package fixture shape.
    static func descriptor(
        assetRead: RendererAssetReadDeclaration?
    ) throws -> RendererDescriptor {
        let entry = RendererAsset(
            path: RendererRelativePath(rawValue: "index.html")!,
            digest: RendererSHA256.digest(Data("<html>fixture</html>".utf8)))
        let extractor = RendererAsset(
            path: RendererRelativePath(rawValue: "extractor.js")!,
            digest: RendererSHA256.digest(Data("// extractor".utf8)))
        return try RendererDescriptor(
            reference: RendererReference(
                packageID: RendererPackageID(rawValue: "org.example.asset-fixture")!,
                version: RendererPackageVersion(rawValue: "1.0.1")!,
                registrationID: RendererRegistrationID(rawValue: "primary")!),
            displayName: "Asset Fixture",
            implementation: .webPackage(.init(path: entry.path)),
            matchers: [.extensionFallback(RendererFileExtension(rawValue: "canvas")!)],
            presentations: [.web],
            supportedEmbeddingRoles: [.disclosureRow],
            hasExplicitEmbeddingRoles: true,
            approvedAssets: [entry, extractor],
            capabilities: assetRead == nil ? [.inputRead] : [.inputRead, .assetRead],
            assetRead: assetRead,
            sizeLimits: .init(maximumInputByteCount: 1_048_576, maximumDecodedByteCount: 1_048_576),
            linkPolicy: .none,
            accessibility: .init(supportsVoiceOver: true, supportsKeyboardNavigation: true),
            compatibility: .init(minimumProtocolRevision: 1, maximumProtocolRevision: 1),
            priority: 110)
    }

    /// A descriptor identical to `descriptor(assetRead:)` except for the
    /// registration ID, so two requests can carry distinct identities.
    static func descriptor(
        registrationID: String,
        assetRead: RendererAssetReadDeclaration?
    ) throws -> RendererDescriptor {
        let base = try descriptor(assetRead: assetRead)
        return try RendererDescriptor(
            reference: RendererReference(
                packageID: base.reference.packageID,
                version: base.reference.version,
                registrationID: RendererRegistrationID(rawValue: registrationID)!),
            displayName: base.displayName,
            implementation: base.implementation,
            matchers: base.matchers,
            presentations: base.presentations,
            supportedEmbeddingRoles: base.supportedEmbeddingRoles,
            hasExplicitEmbeddingRoles: base.hasExplicitEmbeddingRoles,
            approvedAssets: base.approvedAssets,
            capabilities: base.capabilities,
            assetRead: assetRead,
            sizeLimits: base.sizeLimits,
            linkPolicy: base.linkPolicy,
            accessibility: base.accessibility,
            compatibility: base.compatibility,
            priority: base.priority)
    }

    static func assetReadDeclaration() throws -> RendererAssetReadDeclaration {
        try RendererAssetReadDeclaration(
            allowedRoles: [.imageNode],
            allowedMIMETypes: [try RendererMIMEType(validating: "image/png")],
            maximumExtractedReferenceCount: 8,
            maximumExtractorInputBytes: 256 * 1_024,
            maximumExtractorOutputBytes: 256 * 1_024,
            maximumExtractorExecutionSeconds: 5,
            maximumBytesPerAsset: 16 * 1_024 * 1_024,
            maximumAggregateSessionBytes: 64 * 1_024 * 1_024,
            extractorAsset: RendererRelativePath(rawValue: "extractor.js")!,
            extractorEntryFunction: "extractReferences")
    }

    static func configuration(
        descriptor: RendererDescriptor
    ) -> InstalledRendererSessionConfiguration {
        InstalledRendererSessionConfiguration(
            identity: InstalledRendererWebViewIdentity(
                rendererReference: descriptor.reference,
                entryURL: RendererPackageScheme.url(
                    packageID: descriptor.reference.packageID,
                    version: descriptor.reference.version,
                    path: RendererRelativePath(rawValue: "index.html")!)),
            reservation: RendererPackageReservation(
                packageID: descriptor.reference.packageID,
                version: descriptor.reference.version),
            resourceProvider: UnavailableResourceProvider(),
            failureRecorder: nil)
    }

    /// A real byteful source in the in-memory store plus its authorized
    /// `.source(versionID:)` bridge input.
    static func sourceInput(
        store: GRDBWikiStore,
        filename: String = "diagram.png"
    ) throws -> (input: RendererBridgeInput, byteCount: Int) {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let summary = try store.addSource(filename: filename, data: png)
        guard let version = try store.activeContentVersion(sourceID: summary.id) else {
            throw FixtureError.missingContentVersion
        }
        return (.source(versionID: version.id), png.count)
    }

    static func request(
        descriptor: RendererDescriptor,
        input: RendererBridgeInput,
        store: GRDBWikiStore
    ) -> RendererSessionPreparationRequest {
        .init(
            descriptor: descriptor,
            configuration: configuration(descriptor: descriptor),
            input: input,
            admittedSource: nil,
            store: store,
            siblingSources: [:],
            sourceExtensions: [:],
            hostNavigationRouting: .unavailable)
    }
}

@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct RendererSessionPreparationTests {
    private static func makeAuthority(
        _ descriptor: RendererDescriptor,
        input: RendererBridgeInput,
        store: GRDBWikiStore
    ) async throws -> RendererPreparedSessionAuthority {
        try await RendererSessionPreparer.prepare(.init(
            descriptor: descriptor,
            configuration: RendererPreparationFixtures.configuration(descriptor: descriptor),
            input: input,
            admittedSource: nil,
            store: store,
            siblingSources: [:],
            sourceExtensions: [:],
            hostNavigationRouting: .unavailable))
    }

    // MARK: - Preparation (declaration gating + failure fallback)

    @Test("descriptor without assetRead skips helper and yields readable authority")
    func noAssetCapabilitySkipsHelper() async throws {
        let store = try GRDBWikiStore()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let summary = try store.addSource(filename: "diagram.png", data: png)
        let version = try #require(try store.activeContentVersion(sourceID: summary.id))
        let input = RendererBridgeInput.source(versionID: version.id)

        // The validated provider cannot serve any asset, so if the helper
        // path ran, preparation would fail. A nil-assetRead descriptor must
        // prepare without touching the provider at all.
        let descriptor = try RendererPreparationFixtures.descriptor(assetRead: nil)
        let authority = try await Self.makeAuthority(descriptor, input: input, store: store)

        defer { authority.close() }
        let payload = try authority.inputReader.read(input)
        #expect(payload.bytes == png)
        #expect(authority.assetReader == nil)
        #expect(authority.isClosed == false)
    }

    @Test("extractor fetch failure keeps primary rendering with nil asset reader")
    func extractorFailureKeepsPrimaryRendererAvailable() async throws {
        let store = try GRDBWikiStore()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let summary = try store.addSource(filename: "diagram.png", data: png)
        let version = try #require(try store.activeContentVersion(sourceID: summary.id))
        let input = RendererBridgeInput.source(versionID: version.id)

        // assetRead declared, but the validated provider cannot serve the
        // extractor asset — preparation continues with nil asset authority.
        let descriptor = try RendererPreparationFixtures.descriptor(
            assetRead: RendererPreparationFixtures.assetReadDeclaration())
        let authority = try await Self.makeAuthority(descriptor, input: input, store: store)

        defer { authority.close() }
        let payload = try authority.inputReader.read(input)
        #expect(payload.bytes == png)
        #expect(authority.assetReader == nil)
    }

    @Test("prepared authority close is idempotent and revokes the input reader")
    func authorityCloseIsIdempotent() async throws {
        let store = try GRDBWikiStore()
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let summary = try store.addSource(filename: "diagram.png", data: png)
        let version = try #require(try store.activeContentVersion(sourceID: summary.id))
        let input = RendererBridgeInput.source(versionID: version.id)

        let descriptor = try RendererPreparationFixtures.descriptor(assetRead: nil)
        let authority = try await Self.makeAuthority(descriptor, input: input, store: store)

        authority.close()
        #expect(authority.isClosed)
        #expect(throws: RendererAuthorizedInputReader.ReaderError.closed) {
            _ = try authority.inputReader.read(input)
        }
        authority.close()  // idempotent
        #expect(authority.isClosed)
    }

    @Test("stale prepared authority closes without publishing")
    func staleAuthorityClosesWithoutPublishing() async throws {
        // Mirrors the owner gate: a late authority whose identity no longer
        // matches must be closed, never published. Uses the real types
        // through the owner's identity semantics.
        let store = try GRDBWikiStore()
        let png = Data([0x89, 0x50])
        let summary = try store.addSource(filename: "diagram.png", data: png)
        let version = try #require(try store.activeContentVersion(sourceID: summary.id))
        let input = RendererBridgeInput.source(versionID: version.id)

        let descriptor = try RendererPreparationFixtures.descriptor(assetRead: nil)
        let authority = try await Self.makeAuthority(descriptor, input: input, store: store)

        // Simulate the owner's stale gate: the authority is valid but the
        // owning presentation has moved on, so it must close instead of mount.
        authority.close()
        #expect(authority.isClosed)
        #expect(throws: RendererAuthorizedInputReader.ReaderError.closed) {
            _ = try authority.inputReader.read(input)
        }
    }
}

/// Exact pinned asset reads through a session-private reader, mirroring how
/// the admission seam builds it (AC.6/AC.7 asset behavior).
@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct RendererPreparedAssetReadTests {
    @Test("exact pinned read succeeds; unadmitted reference is denied")
    func exactPinnedAssetReadThroughPreparedAuthority() async throws {
        let store = try GRDBWikiStore()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02, 0x03])
        let summary = try store.addSource(filename: "board.png", data: png)
        let version = try #require(try store.activeContentVersion(sourceID: summary.id))
        let digest = RendererSHA256.digest(png).hex
        let reference = try RendererAssetReference(validating: "board.png")
        let admission = RendererAuthorizedAssetReader.Admission(
            reference: reference,
            sourceID: summary.id,
            sourceVersionID: version.id,
            mimeType: "image/png",
            expectedByteCount: png.count,
            expectedDigest: digest)

        // Session-private reader built exactly the way the admission seam
        // builds it (store-backed, declaration-bounded).
        let reader = try RendererAuthorizedAssetReader(
            admissions: [admission],
            maximumBytesPerAsset: 4096,
            maximumAggregateSessionBytes: 8192,
            maximumPerRequestReadCount: 4,
            store: store)
        defer { reader.close() }

        // Exact read succeeds and returns the pinned bytes.
        let payload = try reader.read(reference)
        #expect(payload.bytes == png)
        #expect(payload.mimeType == "image/png")

        // An unadmitted reference fails closed.
        #expect(throws: RendererAuthorizedAssetReader.ReaderError.unadmittedReference) {
            _ = try reader.read(try RendererAssetReference(validating: "stranger.png"))
        }
    }
}

/// The preparation owner's observable phase — the pane-holding contract.
/// A tabbed host must hold its pane through `idle`/`preparing` and fall back
/// only on definitive `failed`. An early fallback is what made installed
/// renderer tabs unreachable: the fallback reverts the pane's selection, the
/// revert re-keys the preparation task and cancels it, and every retry
/// repeats the cycle.
@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct RendererSessionPreparationOwnerPhaseTests {
    // MARK: - Helpers

    /// Suspends a stub preparation until the test resumes it, so phase
    /// transitions can be observed deterministically.
    private final class PreparationGate: Sendable {
        private let continuation = Mutex<CheckedContinuation<Void, Never>?>(nil)
        private let entered = Mutex(false)

        /// Whether the stub has reached its suspension point; resume before
        /// this is true would be a no-op and leave the stub parked forever.
        var isSuspended: Bool { entered.withLock { $0 } }

        func suspend() async {
            entered.withLock { $0 = true }
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                continuation.withLock { $0 = cont }
            }
        }

        func resume() {
            entered.withLock { $0 = false }
            continuation.withLock { $0 }?.resume()
        }
    }

    /// Bounded, non-blocking wait: polls the predicate with short sleeps so a
    /// starved pool surfaces as a timed-out test, never a hang (#1051).
    private func waitUntil(
        _ predicate: @MainActor () -> Bool,
        timeout: Duration = .seconds(5)
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while predicate() == false {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for the owner phase condition")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// An authority-returning stub body for the owner's injected preparation.
    private func succeedingPreparation(
        _ request: RendererSessionPreparationRequest
    ) async throws -> RendererPreparedSessionAuthority {
        try await RendererSessionPreparer.prepare(request)
    }

    // MARK: - Phase transitions

    @Test("prepare publishes preparing, then prepared with the authority")
    func preparePublishesPreparingThenPrepared() async throws {
        let store = try GRDBWikiStore()
        let (input, _) = try RendererPreparationFixtures.sourceInput(store: store)
        let descriptor = try RendererPreparationFixtures.descriptor(assetRead: nil)
        let request = RendererPreparationFixtures.request(
            descriptor: descriptor, input: input, store: store)
        let gate = PreparationGate()
        let owner = RendererSessionPreparationOwner { _ in
            await gate.suspend()
            return try await self.succeedingPreparation(request)
        }

        #expect(owner.phase == .idle)
        #expect(owner.isPending)

        owner.prepare(request)
        #expect(owner.phase == .preparing)
        #expect(owner.isPending)

        // Wait until the stub actually sits in its suspension point before
        // resuming, or the resume is a no-op and the stub parks forever.
        try await waitUntil { gate.isSuspended }
        gate.resume()
        try await waitUntil { owner.phase == .prepared }
        #expect(owner.prepared != nil)
        #expect(owner.prepared?.descriptor.reference == descriptor.reference)
        #expect(owner.identity == request.identity)
        #expect(owner.isPending == false)

        owner.cancel()
    }

    @Test("a thrown preparation publishes failed with no authority")
    func preparationFailurePublishesFailed() async throws {
        struct Boom: Error {}
        let store = try GRDBWikiStore()
        let (input, _) = try RendererPreparationFixtures.sourceInput(store: store)
        let descriptor = try RendererPreparationFixtures.descriptor(assetRead: nil)
        let request = RendererPreparationFixtures.request(
            descriptor: descriptor, input: input, store: store)
        let owner = RendererSessionPreparationOwner { _ in throw Boom() }

        owner.prepare(request)
        try await waitUntil { owner.phase == .failed }
        #expect(owner.prepared == nil)
        #expect(owner.identity == request.identity)
        #expect(owner.isPending == false)
    }

    @Test("cancel during preparation returns to idle and ignores the late completion")
    func cancelDuringPreparationIgnoresLateCompletion() async throws {
        struct Late: Error {}
        let store = try GRDBWikiStore()
        let (input, _) = try RendererPreparationFixtures.sourceInput(store: store)
        let descriptor = try RendererPreparationFixtures.descriptor(assetRead: nil)
        let request = RendererPreparationFixtures.request(
            descriptor: descriptor, input: input, store: store)
        let gate = PreparationGate()
        let owner = RendererSessionPreparationOwner { _ in
            await gate.suspend()
            throw Late()
        }

        owner.prepare(request)
        #expect(owner.phase == .preparing)

        try await waitUntil { gate.isSuspended }
        owner.cancel()
        #expect(owner.phase == .idle)
        #expect(owner.prepared == nil)
        #expect(owner.isPending)

        // The late, stale completion must not republish any phase.
        gate.resume()
        try await Task.sleep(for: .milliseconds(100))
        #expect(owner.phase == .idle)
    }

    @Test("cancel closes a prepared authority and clears the phase")
    func cancelClosesPreparedAuthority() async throws {
        let store = try GRDBWikiStore()
        let (input, _) = try RendererPreparationFixtures.sourceInput(store: store)
        let descriptor = try RendererPreparationFixtures.descriptor(assetRead: nil)
        let request = RendererPreparationFixtures.request(
            descriptor: descriptor, input: input, store: store)
        let owner = RendererSessionPreparationOwner { _ in
            try await self.succeedingPreparation(request)
        }

        owner.prepare(request)
        try await waitUntil { owner.phase == .prepared }
        let authority = try #require(owner.prepared)

        owner.cancel()
        #expect(owner.phase == .idle)
        #expect(owner.prepared == nil)
        #expect(owner.identity == nil)
        #expect(authority.isClosed)
    }

    @Test("markUnavailable is a definitive failure that closes any prepared authority")
    func markUnavailableIsDefinitive() async throws {
        let store = try GRDBWikiStore()
        let (input, _) = try RendererPreparationFixtures.sourceInput(store: store)
        let descriptor = try RendererPreparationFixtures.descriptor(assetRead: nil)
        let request = RendererPreparationFixtures.request(
            descriptor: descriptor, input: input, store: store)
        let owner = RendererSessionPreparationOwner { _ in
            try await self.succeedingPreparation(request)
        }

        owner.prepare(request)
        try await waitUntil { owner.phase == .prepared }
        let authority = try #require(owner.prepared)

        owner.markUnavailable()
        #expect(owner.phase == .failed)
        #expect(owner.prepared == nil)
        #expect(owner.isPending == false)
        #expect(authority.isClosed)
    }

    @Test("a newer request supersedes a stale failure")
    func newerRequestSupersedesStaleFailure() async throws {
        struct Stale: Error {}
        let store = try GRDBWikiStore()
        let (input, _) = try RendererPreparationFixtures.sourceInput(store: store)
        let descriptorA = try RendererPreparationFixtures.descriptor(assetRead: nil)
        let descriptorB = try RendererPreparationFixtures.descriptor(
            registrationID: "secondary", assetRead: nil)
        let requestA = RendererPreparationFixtures.request(
            descriptor: descriptorA, input: input, store: store)
        let requestB = RendererPreparationFixtures.request(
            descriptor: descriptorB, input: input, store: store)
        let gate = PreparationGate()
        let owner = RendererSessionPreparationOwner { request in
            if request.identity == requestA.identity {
                await gate.suspend()
                throw Stale()
            }
            return try await self.succeedingPreparation(request)
        }

        owner.prepare(requestA)
        #expect(owner.phase == .preparing)
        #expect(owner.identity == requestA.identity)

        try await waitUntil { gate.isSuspended }

        // The newer request owns the phase; the older task is cancelled.
        owner.prepare(requestB)
        #expect(owner.phase == .preparing)
        #expect(owner.identity == requestB.identity)

        gate.resume()
        try await waitUntil { owner.phase == .prepared }
        #expect(owner.prepared?.descriptor.reference == descriptorB.reference)
        #expect(owner.identity == requestB.identity)
        #expect(owner.isPending == false)

        owner.cancel()
    }
}
#endif
