import Foundation
import Testing
@testable import WikiFSTypes

/// Manifest-level fence-validation declarations (revision 3): decode, the
/// fail-closed revision gate, declaration asset/entry-function rules, and
/// canonical-byte stability for claim-less and validation-less manifests
/// (whose reviewed package hashes must not move).
struct PackageFenceValidationManifestTests {
    private let enginePath = try! RendererRelativePath(validating: "engine.js")
    private let wrapperPath = try! RendererRelativePath(validating: "wrapper.js")

    private func declaration(
        engine: RendererRelativePath? = nil,
        wrapper: RendererRelativePath? = nil,
        entry: String = "__sdw_validate_fence"
    ) throws -> RendererFenceValidationDeclaration {
        try RendererFenceValidationDeclaration(
            engineAssetPath: engine ?? enginePath,
            wrapperAssetPath: wrapper ?? wrapperPath,
            entryFunction: entry)
    }

    /// A web descriptor whose approved assets cover the engine and wrapper.
    private func webDescriptor(
        claims: [RendererFenceClaim]
    ) throws -> RendererDescriptor {
        let engineAsset = RendererAsset(path: enginePath, digest: RendererFixtures.zeroDigest)
        let wrapperAsset = RendererAsset(path: wrapperPath, digest: RendererFixtures.zeroDigest)
        let entryAsset = RendererFixtures.webAsset()
        return try RendererDescriptor(
            reference: .init(
                packageID: RendererFixtures.packageID,
                version: RendererFixtures.version,
                registrationID: RendererFixtures.registrationID),
            displayName: "Example Web Viewer",
            implementation: .webPackage(.init(path: entryAsset.path)),
            matchers: [.artifactKind(.source)],
            presentations: [.web],
            supportedEmbeddingRoles: [.disclosureRow],
            hasExplicitEmbeddingRoles: true,
            fenceClaims: claims,
            approvedAssets: [engineAsset, wrapperAsset, entryAsset],
            capabilities: [.inputRead],
            sizeLimits: try .init(maximumInputByteCount: 1_024, maximumDecodedByteCount: 2_048),
            linkPolicy: .none,
            accessibility: .init(supportsVoiceOver: true, supportsKeyboardNavigation: true),
            compatibility: try .init(minimumProtocolRevision: 1, maximumProtocolRevision: 1),
            priority: 0)
    }

    private func manifest(
        revision: Int,
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

    @Test func revision3ManifestDecodesValidationDeclaration() throws {
        let expected = try declaration()
        let json = """
        {
          "revision": 3,
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
                {
                  "alias": "mermaid",
                  "inlineMIMEType": "text/mermaid",
                  "validation": {
                    "engineAssetPath": "engine.js",
                    "wrapperAssetPath": "wrapper.js",
                    "entryFunction": "__sdw_validate_fence"
                  }
                }
              ],
              "approvedAssets": [
                { "path": "engine.js", "digest": "0000000000000000000000000000000000000000000000000000000000000000" },
                { "path": "wrapper.js", "digest": "0000000000000000000000000000000000000000000000000000000000000000" },
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
            { "path": "engine.js", "digest": "0000000000000000000000000000000000000000000000000000000000000000" },
            { "path": "wrapper.js", "digest": "0000000000000000000000000000000000000000000000000000000000000000" },
            { "path": "index.html", "digest": "0000000000000000000000000000000000000000000000000000000000000000" }
          ]
        }
        """
        let decoded = try JSONDecoder().decode(RendererManifest.self, from: Data(json.utf8))
        let claim = try #require(decoded.descriptors.first?.fenceClaims.first)
        #expect(claim.validation == expected)
        #expect(claim.hasValidation == true)
        #expect(decoded.descriptors.first?.hasFenceValidation == true)
    }

    @Test func absentValidationKeyDecodesToNil() throws {
        let json = #"{"alias": "d2", "inlineMIMEType": "text/plain"}"#
        let claim = try JSONDecoder().decode(RendererFenceClaim.self, from: Data(json.utf8))
        #expect(claim.validation == nil)
        #expect(claim.hasValidation == false)
    }

    // MARK: - Revision gating (fail closed)

    @Test func revision3ManifestWithValidationIsAccepted() throws {
        let descriptor = try webDescriptor(claims: [
            RendererFixtures.fenceClaim(alias: "mermaid", mime: "text/mermaid", validation: try declaration()),
        ])
        _ = try manifest(revision: RendererManifestRevision.current, descriptor: descriptor)
    }

    @Test func revision2ManifestWithValidationFailsClosed() throws {
        let descriptor = try webDescriptor(claims: [
            RendererFixtures.fenceClaim(alias: "mermaid", mime: "text/mermaid", validation: try declaration()),
        ])
        #expect(throws: RendererValidationError.fenceValidationRequiresCurrentRevision) {
            try manifest(revision: RendererManifestRevision.fenceClaims, descriptor: descriptor)
        }
    }

    @Test func revision1ManifestWithValidationFailsClosed() throws {
        let descriptor = try webDescriptor(claims: [
            RendererFixtures.fenceClaim(alias: "mermaid", mime: "text/mermaid", validation: try declaration()),
        ])
        // Revision 1 fails on the validation gate before the claims gate.
        #expect(throws: RendererValidationError.fenceValidationRequiresCurrentRevision) {
            try manifest(revision: RendererManifestRevision.legacy, descriptor: descriptor)
        }
    }

    // MARK: - Declaration rules

    @Test func nonDistinctEngineAndWrapperPathsAreRejected() {
        #expect(throws: RendererValidationError.fenceValidationAssetsNotDistinct) {
            _ = try declaration(engine: enginePath, wrapper: enginePath)
        }
    }

    @Test func malformedEntryFunctionIsRejected() {
        #expect(throws: RendererValidationError.fenceValidationEntryFunctionInvalid) {
            _ = try declaration(entry: "__sdw.validate.fence") // dotted: not one identifier
        }
        #expect(throws: RendererValidationError.fenceValidationEntryFunctionInvalid) {
            _ = try declaration(entry: "1invalid") // leading digit
        }
        #expect(throws: RendererValidationError.fenceValidationEntryFunctionInvalid) {
            _ = try declaration(entry: "") // empty
        }
        #expect(throws: RendererValidationError.fenceValidationEntryFunctionInvalid) {
            _ = try declaration(entry: "validate fence") // whitespace
        }
    }

    @Test func entryFunctionGrammarAcceptsIdentifiers() throws {
        #expect(RendererFenceValidationDeclaration.isValidEntryFunction("__sdw_validate_fence"))
        #expect(RendererFenceValidationDeclaration.isValidEntryFunction("$validate"))
        #expect(RendererFenceValidationDeclaration.isValidEntryFunction("_private"))
        #expect(RendererFenceValidationDeclaration.isValidEntryFunction("validateFence2"))
        #expect(RendererFenceValidationDeclaration.isValidEntryFunction("not-an-identifier") == false)
        #expect(try declaration(entry: "validateFence2").entryFunction == "validateFence2")
    }

    @Test func unapprovedValidationAssetIsRejected() throws {
        let unapproved = try RendererRelativePath(validating: "not-approved.js")
        #expect(throws: RendererValidationError.fenceValidationAssetNotApproved(unapproved)) {
            _ = try webDescriptor(claims: [
                RendererFixtures.fenceClaim(
                    alias: "mermaid",
                    mime: "text/mermaid",
                    validation: try declaration(engine: unapproved)),
            ])
        }
    }

    @Test func wrapperUnapprovedIsAlsoRejected() throws {
        let unapproved = try RendererRelativePath(validating: "rogue-wrapper.js")
        #expect(throws: RendererValidationError.fenceValidationAssetNotApproved(unapproved)) {
            _ = try webDescriptor(claims: [
                RendererFixtures.fenceClaim(
                    alias: "mermaid",
                    mime: "text/mermaid",
                    validation: try declaration(wrapper: unapproved)),
            ])
        }
    }

    // MARK: - Canonical-byte stability

    @Test func validationlessCanonicalJSONOmitsTheValidationKey() throws {
        // A claim without validation keeps the revision-3 canonical shape
        // byte-identical to the revision-2 claim shape.
        let descriptor = try webDescriptor(claims: [
            RendererFixtures.fenceClaim(alias: "mermaid", mime: "text/mermaid"),
        ])
        let canonical = try manifest(
            revision: RendererManifestRevision.current,
            descriptor: descriptor).canonicalJSON()
        let text = String(decoding: canonical, as: UTF8.self)
        #expect(text.contains("validation") == false)
    }

    @Test func claimlessCanonicalJSONOmitsTheFenceClaimsKey() throws {
        let descriptor = try webDescriptor(claims: [])
        let canonical = try manifest(
            revision: RendererManifestRevision.current,
            descriptor: descriptor).canonicalJSON()
        let text = String(decoding: canonical, as: UTF8.self)
        #expect(text.contains("fenceClaims") == false)
        #expect(text.contains("validation") == false)
    }

    @Test func revision3CanonicalJSONIsDeterministicAndHashable() throws {
        let descriptor = try webDescriptor(claims: [
            RendererFixtures.fenceClaim(alias: "mermaid", mime: "text/mermaid", validation: try declaration()),
        ])
        let validated = try manifest(revision: RendererManifestRevision.current, descriptor: descriptor)
        let first = try validated.canonicalJSON()
        let second = try validated.canonicalJSON()
        #expect(first == second)
        #expect(try validated.packageHash() == validated.packageHash())
        let text = String(decoding: first, as: UTF8.self)
        #expect(text.contains(#""validation":{"engineAssetPath":"engine.js""#))
        #expect(text.contains(#""entryFunction":"__sdw_validate_fence""#))
    }

    @Test func revision2CanonicalBytesAreUnchangedByTheRevisionBump() throws {
        // The V2 path must stay byte-for-byte identical: reviewed revision-2
        // package hashes (Excalidraw 1.0.5 pins) must not move.
        let descriptor = try webDescriptor(claims: [])
        let validated = try manifest(revision: RendererManifestRevision.fenceClaims, descriptor: descriptor)
        let json = try String(decoding: validated.canonicalJSON(), as: UTF8.self)
        // The descriptor shape (roles + sorted claims) routes through the
        // unchanged CanonicalRendererDescriptorV2.
        #expect(json.contains(#""revision":2"#))
        #expect(json.contains("supportedEmbeddingRoles"))
        #expect(try validated.packageHash() == validated.packageHash())
    }

    @Test func addingValidationChangesThePackageHash() throws {
        let withoutValidation = try webDescriptor(claims: [
            RendererFixtures.fenceClaim(alias: "mermaid", mime: "text/mermaid"),
        ])
        let withValidation = try webDescriptor(claims: [
            RendererFixtures.fenceClaim(alias: "mermaid", mime: "text/mermaid", validation: try declaration()),
        ])
        let without = try manifest(revision: RendererManifestRevision.current, descriptor: withoutValidation)
        let with = try manifest(revision: RendererManifestRevision.current, descriptor: withValidation)
        #expect(try without.packageHash() != with.packageHash())
    }
}
