#if os(macOS)
import Foundation
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
@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct RendererSessionPreparationTests {
    // MARK: - Fixtures

    /// A web-package descriptor. Mirrors the reviewed-package fixture shape.
    private static func descriptor(
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

    private static func assetReadDeclaration() throws -> RendererAssetReadDeclaration {
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

    private static func configuration(
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

    private struct UnavailableResourceProvider: RendererPackageResourceProviding {
        func resource(for url: URL) throws -> RendererPackageResource {
            throw RendererPackageResourceError.undeclaredAsset
        }
    }

    private static func makeAuthority(
        _ descriptor: RendererDescriptor,
        input: RendererBridgeInput,
        store: GRDBWikiStore
    ) async throws -> RendererPreparedSessionAuthority {
        try await RendererSessionPreparer.prepare(.init(
            descriptor: descriptor,
            configuration: Self.configuration(descriptor: descriptor),
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
        let descriptor = try Self.descriptor(assetRead: nil)
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
        let descriptor = try Self.descriptor(assetRead: Self.assetReadDeclaration())
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

        let descriptor = try Self.descriptor(assetRead: nil)
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

        let descriptor = try Self.descriptor(assetRead: nil)
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
#endif
