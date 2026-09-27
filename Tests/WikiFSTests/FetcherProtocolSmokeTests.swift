import Foundation
import Testing
import WikiFSTypes
import WikiFSCore
@testable import WikiFSEngine

/// AC.2 — dispatch/launch validation for fetcher packages.
///
/// The trusted-definition factory (`ExtractorPackagePluginDefinitionFactory`)
/// is the admission layer for installed package code: its fingerprint covers
/// the registration role and claims, so a role change is a different plugin.
/// The wire-level dispatch shape is pinned through
/// `ManagedExtractorProcessRequest`: a fetch envelope flips
/// `isFetcherRequest` and the request accessors read the fetch request.
///
/// Note on executor coverage: driving `ManagedExtractorProcessExecutor`
/// end-to-end requires its script-fixture harness (real subprocesses, per
/// `ManagedExtractorProcessExecutorTests`); the fetch-sequence rule the
/// executor enforces is validated directly through
/// `ExtractorProtocolSequence(isFetcherRequest: true)` (see
/// `FetcherProtocolResultTests`), which is exactly the validator the
/// executor constructs at `ManagedExtractorProcessExecutor.swift:768`.
@Suite("Fetcher dispatch and launch validation", .timeLimit(.minutes(2)))
struct FetcherProtocolSmokeTests {

    // MARK: - Fixtures

    private static func manifestJSON(
        role: String = "fetcher",
        kinds: String = "[]",
        mimeTypes: String = "[\"application/zotero\"]",
        capabilities: String = "[\"network\"]",
        protocolRevision: Int = 5
    ) -> String {
        """
        {
          "manifestRevision": 4,
          "packageID": "org.selfdrivingwiki.zotero",
          "version": "1.0.0",
          "displayName": "Zotero Attachment",
          "protocolRevision": \(protocolRevision),
          "entryPoint": "bin/zotero-extractor",
          "launch": {"mode": "runtime", "command": "uv", "arguments": ["run", "--script"]},
          "registrations": [
            {
              "id": "attachment",
              "displayName": "Zotero Attachment",
              "kinds": \(kinds),
              "mimeTypes": \(mimeTypes),
              "role": "\(role)"
            }
          ],
          "capabilities": \(capabilities),
          "files": [
            {
              "path": "bin/zotero-extractor",
              "digest": "0000000000000000000000000000000000000000000000000000000000000000"
            }
          ],
          "limits": {
            "maximumInputByteCount": 1048576,
            "maximumMarkdownOutputByteCount": 134217728,
            "maximumDurationMilliseconds": 600000,
            "maximumProgressEventCount": 64
          }
        }
        """
    }

    private static func fetcherManifest() throws -> ExtractorManifest {
        try JSONDecoder().decode(
            ExtractorManifest.self, from: Data(Self.manifestJSON().utf8))
    }

    private static func extractorManifest() throws -> ExtractorManifest {
        try JSONDecoder().decode(
            ExtractorManifest.self,
            from: Data(Self.manifestJSON(
                role: "extractor",
                kinds: "[\"pdf\"]",
                mimeTypes: "[\"application/pdf\"]").utf8))
    }

    private static func revision(for manifest: ExtractorManifest) throws -> ExtractorPackageRevisionID {
        ExtractorPackageRevisionID(
            packageID: manifest.packageID,
            version: manifest.version,
            digest: try manifest.packageDigest())
    }

    // MARK: - Trusted definition admission

    @Test func trustedDefinitionAcceptsFetcherManifest() throws {
        let manifest = try Self.fetcherManifest()
        let revision = try Self.revision(for: manifest)
        let definition = try ExtractorPackagePluginDefinitionFactory.trustedDefinition(
            revision: revision, manifest: manifest)
        // The trusted definition carries exactly the factory's own
        // fingerprint for this fetcher manifest and revision.
        let expectedFingerprint = try ExtractorPackagePluginDefinitionFactory.fingerprint(
            for: manifest, revision: revision)
        #expect(definition.fingerprint == expectedFingerprint)
    }

    @Test func fingerprintCoversRoleAndClaims() throws {
        let fetcherManifest = try Self.fetcherManifest()
        let extractorManifest = try Self.extractorManifest()
        let fetcherFingerprint = try ExtractorPackagePluginDefinitionFactory.fingerprint(
            for: fetcherManifest, revision: Self.revision(for: fetcherManifest))
        let extractorFingerprint = try ExtractorPackagePluginDefinitionFactory.fingerprint(
            for: extractorManifest, revision: Self.revision(for: extractorManifest))
        // The role (and the claims that follow it: kinds vs synthetic input
        // MIMEs) is part of the fingerprint, so flipping the role is a
        // different plugin identity.
        #expect(fetcherFingerprint != extractorFingerprint)
    }

    @Test func trustedDefinitionRejectsDigestMismatch() throws {
        let manifest = try Self.fetcherManifest()
        let mismatched = ExtractorPackageRevisionID(
            packageID: manifest.packageID,
            version: manifest.version,
            digest: try ExtractorPackageDigest(hex: String(
                repeating: "c", count: ExtractorPackageDigest.byteCount * 2)))
        #expect(throws: ProcessPackagePreparationError.identityMismatch) {
            _ = try ExtractorPackagePluginDefinitionFactory.trustedDefinition(
                revision: mismatched, manifest: manifest)
        }
    }

    @Test func fetcherManifestAtProtocolFourNeverReachesTheFactory() {
        // The manifest layer rejects a fetcher below protocol revision 5
        // before the factory can be consulted — the throw is asserted here
        // so the dispatch path cannot regress silently.
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(
                ExtractorManifest.self,
                from: Data(Self.manifestJSON(protocolRevision: 4).utf8))
        }
    }

    @Test func fetcherManifestWithoutNetworkNeverReachesTheFactory() {
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(
                ExtractorManifest.self,
                from: Data(Self.manifestJSON(capabilities: "[]").utf8))
        }
    }

    // MARK: - Managed request dispatch shape

    @Test func managedRequestWithFetchEnvelopeExposesFetchAccessors() throws {
        let manifest = try Self.fetcherManifest()
        let request = try ExtractorFetchRequest(
            requestID: ExtractorRequestID(),
            mimeType: try ExtractorMIMEType(validating: ContentTypeRegistry.zoteroAttachment),
            originalFilename: "ABCD1234",
            remoteURL: ExtractorRemoteSourceURL(
                validating: "https://api.zotero.org/users/1/items/ABCD1234/file"),
            outputPath: try ExtractorRelativePath(validating: "output/fetch/result"),
            deadlineMillisecondsSince1970: 4_102_444_800_000)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-fetcher-smoke-\(UUID().uuidString)", isDirectory: true)
        let operation = ManagedExtractorProcessRequest(
            revision: try Self.revision(for: manifest),
            manifest: manifest,
            request: .fetch(request),
            paths: ManagedExtractorProcessPaths(
                operationRoot: root,
                packageRoot: root.appendingPathComponent("package", isDirectory: true),
                homeRoot: root.appendingPathComponent("home", isDirectory: true),
                temporaryRoot: root.appendingPathComponent("tmp", isDirectory: true),
                privateCacheRoot: root.appendingPathComponent("cache", isDirectory: true)))

        // The envelope tag drives sequence validation: the executor builds
        // its ExtractorProtocolSequence with exactly these inputs.
        #expect(operation.isFetcherRequest)
        #expect(operation.protocolRevision == .v5)
        #expect(operation.requestID == request.requestID)
        #expect(operation.outputPath == request.outputPath)
        #expect(operation.deadlineMillisecondsSince1970 == request.deadlineMillisecondsSince1970)

        // The rule the executor enforces for this shape: a terminal result
        // without an explicit result type is a protocol violation.
        var sequence = ExtractorProtocolSequence(
            requestID: operation.requestID,
            expectedOutputPath: operation.outputPath,
            maximumProgressEventCount: 4,
            protocolRevision: operation.protocolRevision,
            isFetcherRequest: operation.isFetcherRequest)
        let untagged = try ExtractorResultFrame(
            requestID: operation.requestID,
            outputPath: operation.outputPath,
            markdownByteCount: 3)
        #expect(throws: ExtractorProtocolSequenceError.fetcherResultTypeMissing) {
            try sequence.consume(.result(untagged))
        }
    }
}
