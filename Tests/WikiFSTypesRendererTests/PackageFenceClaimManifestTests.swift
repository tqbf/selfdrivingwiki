import Foundation
import Testing
@testable import WikiFSTypes

/// Manifest-level fence-claim validation: revision gating, uniqueness, the
/// disclosureRow role requirement, MIME validity, and canonical-byte stability
/// for claim-less manifests (whose reviewed package hashes must not move).
struct PackageFenceClaimManifestTests {
    private func manifest(
        revision: Int = RendererManifestRevision.current,
        descriptor: RendererDescriptor
    ) throws -> RendererManifest {
        try RendererManifest(
            revision: revision,
            packageID: descriptor.reference.packageID,
            version: descriptor.reference.version,
            descriptors: [descriptor],
            assets: descriptor.approvedAssets)
    }

    // MARK: - Decode

    @Test func revision2ManifestDecodesClaims() throws {
        let expectedClaim = try RendererFixtures.fenceClaim()
        let json = """
        {
          "revision": 2,
          "packageID": "org.example.viewer",
          "version": "1.2.3",
          "descriptors": [
            {
              "reference": {
                "packageID": "org.example.viewer",
                "version": "1.2.3",
                "registrationID": "viewer"
              },
              "displayName": "Example Web Viewer",
              "implementation": { "webPackage": { "_0": { "path": "index.html" } } },
              "matchers": [{ "artifactKind": { "_0": "source" } }],
              "presentations": ["web"],
              "supportedEmbeddingRoles": ["disclosureRow"],
              "fenceClaims": [
                { "alias": "d2", "inlineMIMEType": "text/plain" }
              ],
              "approvedAssets": [
                { "path": "index.html", "digest": "0000000000000000000000000000000000000000000000000000000000000000" }
              ],
              "capabilities": ["inputRead"],
              "sizeLimits": { "maximumInputByteCount": 1024, "maximumDecodedByteCount": 2048 },
              "linkPolicy": "none",
              "accessibility": { "supportsVoiceOver": true, "supportsKeyboardNavigation": true },
              "compatibility": { "minimumProtocolRevision": 1, "maximumProtocolRevision": 1 },
              "priority": 0
            }
          ],
          "assets": [
            { "path": "index.html", "digest": "0000000000000000000000000000000000000000000000000000000000000000" }
          ]
        }
        """
        let decoded = try JSONDecoder().decode(RendererManifest.self, from: Data(json.utf8))
        let claims = try #require(decoded.descriptors.first?.fenceClaims)
        #expect(claims == [expectedClaim])
        #expect(decoded.descriptors.first?.hasFenceClaims == true)
    }

    @Test func claimlessManifestDecodesToNoClaims() throws {
        let descriptor = try RendererFixtures.webDescriptor(explicitEmbeddingRoles: true)
        let decoded = try manifest(descriptor: descriptor)
        #expect(decoded.descriptors.first?.fenceClaims.isEmpty == true)
        #expect(decoded.descriptors.first?.hasFenceClaims == false)
    }

    @Test func invalidClaimMIMEFailsDecode() {
        let json = """
        {
          "revision": 2,
          "packageID": "org.example.viewer",
          "version": "1.2.3",
          "descriptors": [],
          "assets": []
        }
        """
        _ = json // structural sanity only; MIME rejection is exercised below
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(
                RendererFenceClaim.self,
                from: Data(#"{"alias": "d2", "inlineMIMEType": "not a mime"}"#.utf8))
        }
    }

    // MARK: - Revision gating (fail closed)

    @Test func revision1ManifestWithClaimsFailsClosed() throws {
        let descriptor = try RendererFixtures.webDescriptor(
            embeddingRoles: [.disclosureRow],
            fenceClaims: [RendererFixtures.fenceClaim()])
        #expect(throws: RendererValidationError.fenceClaimsRequireCurrentRevision) {
            try manifest(revision: RendererManifestRevision.legacy, descriptor: descriptor)
        }
    }

    @Test func revision2ManifestWithClaimsIsAccepted() throws {
        let descriptor = try RendererFixtures.webDescriptor(
            explicitEmbeddingRoles: true,
            fenceClaims: [RendererFixtures.fenceClaim()])
        _ = try manifest(descriptor: descriptor)
    }

    // MARK: - Uniqueness and roles

    @Test func duplicateClaimsInsideOneDescriptorAreRejected() {
        #expect(throws: RendererValidationError.duplicateFenceClaim(
            try! RendererFenceAlias(validating: "d2"))) {
            _ = try RendererFixtures.webDescriptor(
                embeddingRoles: [.disclosureRow],
                fenceClaims: [
                    RendererFixtures.fenceClaim(alias: "d2", mime: "text/plain"),
                    RendererFixtures.fenceClaim(alias: "d2", mime: "application/json"),
                ])
        }
    }

    @Test func duplicateClaimsAcrossDescriptorsAreRejected() throws {
        let first = try RendererFixtures.webDescriptor(
            registrationID: try RendererRegistrationID(validating: "viewer"),
            explicitEmbeddingRoles: true,
            fenceClaims: [RendererFixtures.fenceClaim()])
        let second = try RendererFixtures.webDescriptor(
            registrationID: try RendererRegistrationID(validating: "viewer2"),
            explicitEmbeddingRoles: true,
            fenceClaims: [RendererFixtures.fenceClaim()])
        #expect(throws: RendererValidationError.duplicateFenceClaim(
            try RendererFenceAlias(validating: "d2"))) {
            try RendererManifest(
                revision: RendererManifestRevision.current,
                packageID: first.reference.packageID,
                version: first.reference.version,
                descriptors: [first, second],
                assets: first.approvedAssets)
        }
    }

    @Test func claimWithoutDisclosureRowRoleIsRejected() {
        #expect(throws: RendererValidationError.fenceClaimMissingDisclosureRole(
            try! RendererFenceAlias(validating: "d2"))) {
            _ = try RendererFixtures.webDescriptor(
                embeddingRoles: [.inlineContent],
                explicitEmbeddingRoles: true,
                fenceClaims: [RendererFixtures.fenceClaim()])
        }
    }

    // MARK: - Canonical-byte stability

    @Test func claimlessCanonicalJSONOmitsTheFenceClaimsKey() throws {
        let descriptor = try RendererFixtures.webDescriptor(explicitEmbeddingRoles: true)
        let canonical = try manifest(descriptor: descriptor).canonicalJSON()
        let text = String(decoding: canonical, as: UTF8.self)
        #expect(text.contains("fenceClaims") == false)
    }

    @Test func claimedCanonicalJSONCarriesSortedClaimsAndStableHash() throws {
        let descriptor = try RendererFixtures.webDescriptor(
            explicitEmbeddingRoles: true,
            fenceClaims: [
                RendererFixtures.fenceClaim(alias: "zzz"),
                RendererFixtures.fenceClaim(alias: "d2"),
            ])
        let canonical = try manifest(descriptor: descriptor).canonicalJSON()
        let text = String(decoding: canonical, as: UTF8.self)
        #expect(text.contains(#""fenceClaims":[{"alias":"d2""#))
        // Sorting is deterministic: the same manifest always hashes the same.
        let again = try manifest(descriptor: descriptor).canonicalJSON()
        #expect(canonical == again)
    }

    @Test func addingClaimsChangesThePackageHash() throws {
        // The reviewed identity contract: bytes changed ⇒ hash changed ⇒ the
        // reviewed version must bump (this is why Excalidraw moved to 1.0.4).
        let without = try manifest(
            descriptor: RendererFixtures.webDescriptor(explicitEmbeddingRoles: true))
        let with = try manifest(
            descriptor: RendererFixtures.webDescriptor(
                explicitEmbeddingRoles: true,
                fenceClaims: [RendererFixtures.fenceClaim()]))
        #expect(try without.packageHash() != with.packageHash())
    }
}
