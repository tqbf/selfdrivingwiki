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

    @Test func buildMetadataDoesNotChangeSemanticPrecedence() throws {
        let first = try RendererPackageVersion(validating: "1.0.0+build.1")
        let second = try RendererPackageVersion(validating: "1.0.0+build.2")

        #expect(first.semanticPrecedence(comparedTo: second) == .orderedSame)
        #expect(first != second)
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
    @Test(arguments: ["/absolute", "assets/../viewer.js", "assets//viewer.js", "assets\\viewer.js", "./viewer.js"])
    func rejectsInvalidRelativePaths(_ rawValue: String) {
        #expect(RendererRelativePath(rawValue: rawValue) == nil)
    }

    @Test(arguments: ["Application/PDF", "application", "application/", "application/pdf; charset=utf-8"])
    func rejectsMalformedMIMETypes(_ rawValue: String) {
        #expect(RendererMIMEType(rawValue: rawValue) == nil)
    }

    @Test(arguments: [".pdf", "PDF", "pdf-x", ""])
    func rejectsMalformedFileExtensions(_ rawValue: String) {
        #expect(RendererFileExtension(rawValue: rawValue) == nil)
    }

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

    @Test func distinguishesSignatureOffsetFallbackAndNoMatchTiers() throws {
        let signature = try RendererFixtures.nativeDescriptor(matchers: [.boundedSignature(try .init(offset: 1, bytes: [0x50]))])
        let fallback = try RendererFixtures.nativeDescriptor(registrationID: try .init(validating: "fallback-tier"), matchers: [.extensionFallback(try .init(validating: "pdf"))])
        let signedInput = try RendererMatchInput(mimeType: nil, fileExtension: nil, sniffedBytes: Data([0x00, 0x50]), artifactKind: nil)
        let fallbackInput = try RendererMatchInput(mimeType: nil, fileExtension: try .init(validating: "pdf"), sniffedBytes: Data(), artifactKind: nil)
        let noMatchInput = try RendererMatchInput(mimeType: nil, fileExtension: nil, sniffedBytes: Data(), artifactKind: nil)
        #expect(signature.matchTier(for: signedInput) == .strong)
        #expect(fallback.matchTier(for: fallbackInput) == .extensionFallback)
        #expect(signature.matchTier(for: noMatchInput) == nil)
    }
}

struct RendererResolutionTests {
    @Test func rejectsEmptyPreference() {
        #expect(throws: RendererValidationError.self) {
            _ = try RendererPreference(exact: nil, logical: nil)
        }
    }

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

    @Test func resolvesEqualSemanticVersionsWithStableDescriptorTieBreak() throws {
        let first = try RendererFixtures.nativeDescriptor(version: try .init(validating: "1.0.0+build.1"))
        let second = try RendererFixtures.nativeDescriptor(version: try .init(validating: "1.0.0+build.2"))
        let input = try RendererFixtures.input()
        let preference = RendererPreferenceReference.logical(first.logicalReference)

        let forward = RendererResolution.preferred(descriptors: [second, first], preference: preference, input: input, hostProtocolRevision: 1)
        let reverse = RendererResolution.preferred(descriptors: [first, second], preference: preference, input: input, hostProtocolRevision: 1)

        #expect(first.reference.version.semanticPrecedence(comparedTo: second.reference.version) == .orderedSame)
        #expect(forward == first)
        #expect(reverse == first)
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

    @Test func rejectsCompoundPreferenceWithDifferentPackageOrRegistrationIdentity() throws {
        let exact = RendererReference(packageID: RendererFixtures.packageID, version: RendererFixtures.version, registrationID: RendererFixtures.registrationID)
        let otherPackage = try RendererPackageID(validating: "org.example.other")
        let otherRegistration = try RendererRegistrationID(validating: "other")
        #expect(throws: RendererValidationError.mismatchedPreferenceIdentity) {
            _ = try RendererPreference(exact: exact, logical: .init(packageID: otherPackage, registrationID: exact.registrationID))
        }
        #expect(throws: RendererValidationError.mismatchedPreferenceIdentity) {
            _ = try RendererPreference(exact: exact, logical: .init(packageID: exact.packageID, registrationID: otherRegistration))
        }
    }
}

struct RendererDescriptorValidationTests {
    @Test func rejectsNonpositiveInputSizeLimit() {
        #expect(throws: RendererValidationError.self) {
            _ = try RendererSizeLimits(maximumInputByteCount: 0, maximumDecodedByteCount: 1)
        }
    }

    @Test func rejectsDecodedSizeBelowInputSizeLimit() {
        #expect(throws: RendererValidationError.self) {
            _ = try RendererSizeLimits(maximumInputByteCount: 2, maximumDecodedByteCount: 1)
        }
    }

    @Test func rejectsInvalidCompatibilityBounds() throws {
        #expect(throws: RendererValidationError.self) {
            _ = try RendererCompatibility(minimumProtocolRevision: 0, maximumProtocolRevision: 1)
        }
        #expect(throws: RendererValidationError.self) {
            _ = try RendererCompatibility(minimumProtocolRevision: 2, maximumProtocolRevision: 1)
        }
        let compatibility = try RendererCompatibility(minimumProtocolRevision: 2, maximumProtocolRevision: 4)
        #expect(compatibility.supports(hostProtocolRevision: 2))
        #expect(compatibility.supports(hostProtocolRevision: 4))
        #expect(compatibility.supports(hostProtocolRevision: 1) == false)
        #expect(compatibility.supports(hostProtocolRevision: 5) == false)
    }

    @Test func enforcesLinkPolicyCapabilityPairs() throws {
        let reference = RendererReference(packageID: RendererFixtures.packageID, version: RendererFixtures.version, registrationID: RendererFixtures.registrationID)
        let limits = try RendererSizeLimits(maximumInputByteCount: 1, maximumDecodedByteCount: 1)
        let compatibility = try RendererCompatibility(minimumProtocolRevision: 1, maximumProtocolRevision: 1)

        #expect(throws: RendererValidationError.self) {
            _ = try RendererDescriptor(reference: reference, displayName: "Links", implementation: .builtIn(.pdf), matchers: [.artifactKind(.source)], presentations: [.native], approvedAssets: [], capabilities: [.inputRead], sizeLimits: limits, linkPolicy: .userActivatedExternal, accessibility: .init(supportsVoiceOver: true, supportsKeyboardNavigation: true), compatibility: compatibility, priority: 0)
        }
        #expect(throws: RendererValidationError.self) {
            _ = try RendererDescriptor(reference: reference, displayName: "No links", implementation: .builtIn(.pdf), matchers: [.artifactKind(.source)], presentations: [.native], approvedAssets: [], capabilities: [.inputRead, .externalLink], sizeLimits: limits, linkPolicy: .none, accessibility: .init(supportsVoiceOver: true, supportsKeyboardNavigation: true), compatibility: compatibility, priority: 0)
        }
    }

    @Test func rejectsNativeDescriptorWithWebPresentation() throws {
        let reference = RendererReference(packageID: RendererFixtures.packageID, version: RendererFixtures.version, registrationID: RendererFixtures.registrationID)
        #expect(throws: RendererValidationError.self) {
            _ = try RendererDescriptor(reference: reference, displayName: "Native", implementation: .builtIn(.pdf), matchers: [.artifactKind(.source)], presentations: [.web], approvedAssets: [], capabilities: [.inputRead], sizeLimits: try .init(maximumInputByteCount: 1, maximumDecodedByteCount: 1), linkPolicy: .none, accessibility: .init(supportsVoiceOver: true, supportsKeyboardNavigation: true), compatibility: try .init(minimumProtocolRevision: 1, maximumProtocolRevision: 1), priority: 0)
        }
    }

    @Test func rejectsForbiddenNetworkCapability() throws {
        let reference = RendererReference(packageID: RendererFixtures.packageID, version: RendererFixtures.version, registrationID: RendererFixtures.registrationID)
        #expect(throws: RendererValidationError.self) {
            _ = try RendererDescriptor(reference: reference, displayName: "Network", implementation: .builtIn(.pdf), matchers: [.artifactKind(.source)], presentations: [.native], approvedAssets: [], capabilities: [.inputRead, .network], sizeLimits: try .init(maximumInputByteCount: 1, maximumDecodedByteCount: 1), linkPolicy: .none, accessibility: .init(supportsVoiceOver: true, supportsKeyboardNavigation: true), compatibility: try .init(minimumProtocolRevision: 1, maximumProtocolRevision: 1), priority: 0)
        }
    }

    @Test func rejectsDuplicateDescriptorAssetPath() throws {
        let asset = RendererAsset(path: try .init(validating: "assets/index.html"), digest: try .init(hex: String(repeating: "1", count: 64)))
        #expect(throws: RendererValidationError.duplicateAsset(asset.path)) {
            _ = try RendererFixtures.webDescriptor(assets: [asset, asset])
        }
    }

    @Test func preservesWebImplementationAssetsAccessibilityAndConstraintEnums() throws {
        let index = RendererAsset(path: try .init(validating: "assets/index.html"), digest: try .init(hex: String(repeating: "3", count: 64)))
        let script = RendererAsset(path: try .init(validating: "assets/viewer.js"), digest: try .init(hex: String(repeating: "4", count: 64)))
        let implementation = RendererImplementation.webPackage(.init(path: index.path))
        let accessibility = RendererAccessibility(supportsVoiceOver: true, supportsKeyboardNavigation: false)
        let decoded = try JSONDecoder().decode(RendererImplementation.self, from: JSONEncoder().encode(implementation))
        #expect(decoded == implementation)
        #expect(index < script)
        #expect(try JSONDecoder().decode(RendererAccessibility.self, from: JSONEncoder().encode(accessibility)) == accessibility)
        #expect(RendererArtifactKind.allCases == [.source, .markdown, .image, .binary])
        #expect(RendererPresentation.allCases == [.native, .web])
        #expect(RendererCapability.allCases.contains(.externalLink))
        #expect(RendererLinkPolicy.userActivatedExternal != .none)
    }
}

struct RendererPackageHashTests {
    @Test func canonicalEnvelopeGoldenDigestAndOrderIndependence() throws {
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
            capabilities: [.inputRead, .externalLink],
            sizeLimits: try .init(maximumInputByteCount: 1_024, maximumDecodedByteCount: 2_048),
            linkPolicy: .userActivatedExternal,
            accessibility: .init(supportsVoiceOver: true, supportsKeyboardNavigation: true),
            compatibility: try .init(minimumProtocolRevision: 1, maximumProtocolRevision: 1),
            priority: 1
        )
        let first = try RendererManifest(revision: 1, packageID: packageID, version: version, descriptors: [descriptor], assets: [script, index])
        let second = try RendererManifest(revision: 1, packageID: packageID, version: version, descriptors: [descriptor], assets: [index, script])
        let firstHash = try first.packageHash()
        let secondHash = try second.packageHash()
        #expect(firstHash == secondHash)
        #expect(firstHash.hex == "84457b45f850cb5e6347b026c8c1135c27d32af329fb17f0d5d7b09afdc80fc6")
    }

    @Test func canonicalHashIsIndependentOfMultiMemberSetConstructionOrder() throws {
        let index = RendererAsset(path: try .init(validating: "assets/index.html"), digest: try .init(hex: String(repeating: "a", count: 64)))
        let first = try RendererFixtures.webDescriptor(assets: [index], matchers: [.artifactKind(.source), .normalizedMIME(try .init(validating: "application/pdf")), .extensionFallback(try .init(validating: "pdf"))])
        let second = try RendererDescriptor(reference: first.reference, displayName: first.displayName, implementation: first.implementation, matchers: Array(first.matchers.reversed()), presentations: Set([.web]), approvedAssets: first.approvedAssets, capabilities: Set([.inputRead]), sizeLimits: first.sizeLimits, linkPolicy: first.linkPolicy, accessibility: first.accessibility, compatibility: first.compatibility, priority: first.priority)
        let firstManifest = try RendererManifest(revision: 1, packageID: RendererFixtures.packageID, version: RendererFixtures.version, descriptors: [first], assets: [index])
        let secondManifest = try RendererManifest(revision: 1, packageID: RendererFixtures.packageID, version: RendererFixtures.version, descriptors: [second], assets: [index])
        #expect(try firstManifest.packageHash() == secondManifest.packageHash())
        #expect(try firstManifest.canonicalJSON() == secondManifest.canonicalJSON())
    }

    @Test func canonicalHashIsIndependentAcrossFreshProcesses() throws {
        let forward = try fixtureHash(order: "forward")
        let reverse = try fixtureHash(order: "reverse")
        #expect(forward == reverse)
    }

    private func fixtureHash(order: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let buildDirectory = root.appendingPathComponent(".build", isDirectory: true)
        let enumerator = try #require(FileManager.default.enumerator(at: buildDirectory, includingPropertiesForKeys: [.isRegularFileKey]))
        let fixture = try #require((enumerator.allObjects as? [URL])?.first(where: {
            $0.lastPathComponent == "RendererHashFixture" && FileManager.default.isExecutableFile(atPath: $0.path)
        }))
        let process = Process()
        process.executableURL = fixture
        process.arguments = [order]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        try #require(process.terminationStatus == 0, "renderer hash fixture failed:\n\(text)")
        return try #require(text.split(separator: "\n").last.map(String.init))
    }
}

struct RendererManifestValidationTests {
    @Test func rejectsEmptyPackageRegistrationList() throws {
        #expect(throws: RendererValidationError.emptyManifest) {
            _ = try RendererManifest(revision: 1, packageID: RendererFixtures.packageID, version: RendererFixtures.version, descriptors: [], assets: [])
        }
    }

    @Test func rejectsBuiltInDescriptorInPackageManifest() throws {
        #expect(throws: RendererValidationError.packageManifestContainsBuiltIn(.pdf)) {
            _ = try RendererManifest(revision: 1, packageID: RendererFixtures.packageID, version: RendererFixtures.version, descriptors: [try RendererFixtures.nativeDescriptor()], assets: [])
        }
    }

    @Test func rejectsUnknownBuiltInIdentity() throws {
        #expect(BuiltInRendererID(rawValue: "untrusted") == nil)
        #expect(throws: Error.self) { _ = try JSONDecoder().decode(BuiltInRendererID.self, from: Data("\"untrusted\"".utf8)) }
    }

    @Test func rejectsDuplicateManifestAssetPath() throws {
        let asset = RendererAsset(path: try .init(validating: "assets/index.html"), digest: try .init(hex: String(repeating: "1", count: 64)))
        let descriptor = try RendererFixtures.webDescriptor(assets: [asset])
        #expect(throws: RendererValidationError.duplicatePath(asset.path)) {
            _ = try RendererManifest(revision: 1, packageID: RendererFixtures.packageID, version: RendererFixtures.version, descriptors: [descriptor], assets: [asset, asset])
        }
    }

    @Test func rejectsDescriptorAssetOutsideManifestAssets() throws {
        let descriptorAsset = RendererAsset(path: try .init(validating: "assets/index.html"), digest: try .init(hex: String(repeating: "1", count: 64)))
        let manifestAsset = RendererAsset(path: try .init(validating: "assets/viewer.js"), digest: try .init(hex: String(repeating: "2", count: 64)))
        let descriptor = try RendererFixtures.webDescriptor(assets: [descriptorAsset])
        #expect(throws: RendererValidationError.manifestAssetNotApproved(descriptorAsset.path)) {
            _ = try RendererManifest(revision: 1, packageID: RendererFixtures.packageID, version: RendererFixtures.version, descriptors: [descriptor], assets: [manifestAsset])
        }
    }

    @Test func rejectsDuplicateRegistrationUnsupportedRevisionAndIdentityMismatch() throws {
        let descriptor = try RendererFixtures.nativeDescriptor()
        #expect(throws: RendererValidationError.self) {
            _ = try RendererManifest(revision: 2, packageID: RendererFixtures.packageID, version: RendererFixtures.version, descriptors: [descriptor], assets: [])
        }
        #expect(throws: RendererValidationError.self) {
            _ = try RendererManifest(revision: 1, packageID: RendererFixtures.packageID, version: RendererFixtures.version, descriptors: [descriptor, descriptor], assets: [])
        }
        #expect(throws: RendererValidationError.self) {
            _ = try RendererManifest(revision: 1, packageID: RendererFixtures.packageID, version: try .init(validating: "2.0.0"), descriptors: [descriptor], assets: [])
        }
    }
}

struct RendererStableOrderingTests {
    @Test func ordersPriorityBeforeCanonicalStableTieBreakKey() throws {
        let high = try RendererFixtures.nativeDescriptor(registrationID: try .init(validating: "high"), priority: 10)
        let low = try RendererFixtures.nativeDescriptor(registrationID: try .init(validating: "low"), priority: 1)
        #expect(high.stableTieBreakKey < low.stableTieBreakKey)
        #expect(RendererMatchTier.extensionFallback < .strong)
    }
}
