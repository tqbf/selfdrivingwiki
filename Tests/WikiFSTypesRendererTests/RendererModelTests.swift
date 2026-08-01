import Foundation
import Testing
import WikiFSTypes

struct RendererIdentifierTests {
    @Test(arguments: ["org.example.viewer", "com.example.renderer-v2"])
    func acceptsCanonicalPackageID(_ rawValue: String) throws {
        #expect(try RendererPackageID(validating: rawValue).rawValue == rawValue)
    }

    @Test(arguments: ["Example.viewer", "org..viewer", "viewer", "org.example."])
    func rejectsMalformedPackageID(_ rawValue: String) {
        #expect(RendererPackageID(rawValue: rawValue) == nil)
    }

    @Test(arguments: ["1.2.3", "1.2.3-beta.1", "2.0.0+build.8"])
    func ordersSemanticVersions(_ rawValue: String) throws {
        #expect(try RendererPackageVersion(validating: rawValue).rawValue == rawValue)
    }

    @Test func ordersPrereleaseIdentifiersBySemanticVersionPrecedence() throws {
        let beta2 = try RendererPackageVersion(validating: "1.0.0-beta.2")
        let beta10 = try RendererPackageVersion(validating: "1.0.0-beta.10")
        let alpha = try RendererPackageVersion(validating: "1.0.0-alpha")
        let alpha1 = try RendererPackageVersion(validating: "1.0.0-alpha.1")
        let alphaBeta = try RendererPackageVersion(validating: "1.0.0-alpha.beta")
        let stable = try RendererPackageVersion(validating: "1.0.0")

        #expect(beta2 < beta10)
        #expect(alpha < alpha1)
        #expect(alpha1 < alphaBeta)
        #expect(alphaBeta < stable)
    }

    @Test func ordersBuildMetadataDeterministicallyWithoutChangingPrereleasePrecedence() throws {
        let first = try RendererPackageVersion(validating: "1.0.0+build.1")
        let second = try RendererPackageVersion(validating: "1.0.0+build.2")

        #expect(first < second)
        #expect(first != second)
        #expect((first < second) || first == second || second < first)
        #expect((first < second) == !(second < first))
    }

    @Test func rejectsLeadingZeroNumericPrereleaseButAcceptsBuildMetadata() {
        #expect(RendererPackageVersion(rawValue: "1.0.0-01") == nil)
        #expect(RendererPackageVersion(rawValue: "1.0.0+01") != nil)
    }

    @Test func rejectsInvalidIdentifierWhenDecoding() throws {
        let data = Data("\"BAD\"".utf8)
        #expect(throws: Error.self) { _ = try JSONDecoder().decode(RendererRegistrationID.self, from: data) }
    }
}

struct RendererMatcherTests {
    @Test func matchesMIMEAndSignatureWithinNamedBound() throws {
        let descriptor = try RendererFixtures.nativeDescriptor(matchers: [
            .normalizedMIME(try .init(validating: "application/pdf")),
            .boundedSignature(try .init(offset: 0, bytes: Array("%PDF".utf8))),
        ])
        #expect(descriptor.matchTier(for: try RendererFixtures.input()) == .strong)
    }

    @Test func usesExtensionOnlyWhenNoStrongMatcherExists() throws {
        let strong = try RendererFixtures.nativeDescriptor(priority: 0)
        let extensionID = try RendererRegistrationID(validating: "fallback")
        let fallback = try RendererFixtures.nativeDescriptor(
            registrationID: extensionID,
            matchers: [.extensionFallback(try .init(validating: "pdf"))],
            priority: 100
        )
        let input = try RendererFixtures.input()
        #expect(RendererResolution.matching(descriptors: [fallback, strong], input: input, hostProtocolRevision: 1).map(\.reference) == [strong.reference])
    }

    @Test func rejectsUnboundedSniffAndSignature() throws {
        #expect(throws: RendererValidationError.self) {
            _ = try RendererMatchInput(mimeType: nil, fileExtension: nil, sniffedBytes: Data(repeating: 0, count: RendererMatchingLimits.maximumSniffByteCount + 1), artifactKind: nil)
        }
        #expect(throws: RendererValidationError.self) {
            _ = try RendererSignature(offset: RendererMatchingLimits.maximumSniffByteCount, bytes: [0])
        }
    }
}

struct RendererResolutionTests {
    @Test func sortsByPriorityThenStableReferenceWithoutInputOrder() throws {
        let first = try RendererFixtures.nativeDescriptor(priority: 10)
        let second = try RendererFixtures.nativeDescriptor(registrationID: try .init(validating: "second"), priority: 10)
        let input = try RendererFixtures.input()
        let forward = RendererResolution.matching(descriptors: [second, first], input: input, hostProtocolRevision: 1)
        let reverse = RendererResolution.matching(descriptors: [first, second], input: input, hostProtocolRevision: 1)
        #expect(forward == reverse)
        #expect(forward.map(\.reference) == [second.reference, first.reference])
    }

    @Test func resolvesExactThenLogicalCompatiblePreference() throws {
        let old = try RendererFixtures.nativeDescriptor(version: try .init(validating: "1.0.0"))
        let new = try RendererFixtures.nativeDescriptor(version: try .init(validating: "2.0.0"))
        let input = try RendererFixtures.input()
        let exact = RendererResolution.preferred(descriptors: [new, old], preference: .exact(old.reference), input: input, hostProtocolRevision: 1)
        let logical = RendererResolution.preferred(descriptors: [old, new], preference: .logical(new.logicalReference), input: input, hostProtocolRevision: 1)
        #expect(exact == old)
        #expect(logical == new)
    }

    @Test func ignoresIncompatibleExactPreference() throws {
        let incompatible = try RendererFixtures.nativeDescriptor(
            compatibility: try .init(minimumProtocolRevision: 2, maximumProtocolRevision: 2)
        )
        let input = try RendererFixtures.input()
        #expect(RendererResolution.preferred(descriptors: [incompatible], preference: .exact(incompatible.reference), input: input, hostProtocolRevision: 1) == nil)
    }

    @Test func fallsBackFromUnavailableExactToLogicalPreference() throws {
        let old = try RendererFixtures.nativeDescriptor(version: try .init(validating: "1.0.0"))
        let new = try RendererFixtures.nativeDescriptor(version: try .init(validating: "2.0.0"))
        let unavailable = RendererReference(packageID: RendererFixtures.packageID, version: try .init(validating: "3.0.0"), registrationID: RendererFixtures.registrationID)
        let preference = try RendererPreference(exact: unavailable, logical: new.logicalReference)
        let input = try RendererFixtures.input()
        #expect(RendererResolution.preferred(descriptors: [old, new], preference: preference, input: input, hostProtocolRevision: 1) == new)
    }
}

struct RendererDescriptorValidationTests {
    @Test func rejectsInvalidPresentationCapabilitiesAndLimits() throws {
        let reference = RendererReference(packageID: RendererFixtures.packageID, version: RendererFixtures.version, registrationID: RendererFixtures.registrationID)
        #expect(throws: RendererValidationError.self) {
            _ = try RendererDescriptor(reference: reference, displayName: "Native", implementation: .builtIn(try .init(validating: "native")), matchers: [.artifactKind(.source)], presentations: [.web], approvedAssets: [], capabilities: [.inputRead], sizeLimits: try .init(maximumInputByteCount: 2, maximumDecodedByteCount: 1), linkPolicy: .none, accessibility: .init(supportsVoiceOver: true, supportsKeyboardNavigation: true), compatibility: try .init(minimumProtocolRevision: 1, maximumProtocolRevision: 1), priority: 0)
        }
        #expect(throws: RendererValidationError.self) {
            _ = try RendererDescriptor(reference: reference, displayName: "Network", implementation: .builtIn(try .init(validating: "native")), matchers: [.artifactKind(.source)], presentations: [.native], approvedAssets: [], capabilities: [.inputRead, .network], sizeLimits: try .init(maximumInputByteCount: 1, maximumDecodedByteCount: 1), linkPolicy: .none, accessibility: .init(supportsVoiceOver: true, supportsKeyboardNavigation: true), compatibility: try .init(minimumProtocolRevision: 1, maximumProtocolRevision: 1), priority: 0)
        }
    }
}

struct RendererPackageHashTests {
    @Test func testCanonicalEnvelopeGoldenDigestAndOrderIndependence() throws {
        let packageID = RendererFixtures.packageID
        let version = RendererFixtures.version
        let registrationID = RendererFixtures.registrationID
        let index = RendererAsset(
            path: try .init(validating: "assets/index.html"),
            digest: try .init(hex: String(repeating: "1", count: 64))
        )
        let script = RendererAsset(
            path: try .init(validating: "assets/viewer.js"),
            digest: try .init(hex: String(repeating: "2", count: 64))
        )
        let descriptor = try RendererDescriptor(
            reference: .init(packageID: packageID, version: version, registrationID: registrationID),
            displayName: "Web Viewer",
            implementation: .webPackage(.init(path: index.path)),
            matchers: [.artifactKind(.source)],
            presentations: [.web],
            approvedAssets: [script, index],
            capabilities: [.inputRead],
            sizeLimits: try .init(maximumInputByteCount: 1_024, maximumDecodedByteCount: 2_048),
            linkPolicy: .none,
            accessibility: .init(supportsVoiceOver: true, supportsKeyboardNavigation: true),
            compatibility: try .init(minimumProtocolRevision: 1, maximumProtocolRevision: 1),
            priority: 1
        )
        let first = try RendererManifest(revision: 1, packageID: packageID, version: version, descriptors: [descriptor], assets: [script, index])
        let second = try RendererManifest(revision: 1, packageID: packageID, version: version, descriptors: [descriptor], assets: [index, script])
        let firstHash = try first.packageHash()
        let secondHash = try second.packageHash()
        #expect(firstHash == secondHash)
        #expect(firstHash.hex == "67c0d25a259bc84704058493e57a409752c49a6edc888de7c0973228cd82be6a")
    }
}

struct RendererManifestValidationTests {
    @Test func rejectsDuplicatePathsRegistrationAndUnsupportedRevision() throws {
        let descriptor = try RendererFixtures.nativeDescriptor()
        #expect(throws: RendererValidationError.self) {
            _ = try RendererManifest(revision: 2, packageID: RendererFixtures.packageID, version: RendererFixtures.version, descriptors: [descriptor], assets: [])
        }
        #expect(throws: RendererValidationError.self) {
            _ = try RendererManifest(revision: 1, packageID: RendererFixtures.packageID, version: RendererFixtures.version, descriptors: [descriptor, descriptor], assets: [])
        }
    }
}
