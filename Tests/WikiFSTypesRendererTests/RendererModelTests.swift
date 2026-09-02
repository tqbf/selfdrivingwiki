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
    @Test func absentPreferenceKeepsTheHostOwnedSourceDefault() throws {
        let descriptor = try RendererFixtures.nativeDescriptor()
        let input = try RendererFixtures.input()
        #expect(RendererResolution.preferred(
            descriptors: [descriptor],
            preference: Optional<RendererPreferenceReference>.none,
            input: input,
            hostProtocolRevision: 1) == nil)
    }

    @Test func absentCompoundPreferenceKeepsTheHostOwnedSourceDefault() throws {
        let descriptor = try RendererFixtures.nativeDescriptor()
        let input = try RendererFixtures.input()
        let preference: RendererPreference? = nil

        #expect(RendererResolution.preferred(
            descriptors: [descriptor],
            preference: preference,
            input: input,
            hostProtocolRevision: 1) == nil)
    }

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

struct RendererPhase3PortableTests {
    @Test func offsetBearingTimestampRejectsZAndAcceptsNumericOffset() throws {
        #expect(RFC3339Timestamp(rawValue: "2026-08-04T12:34:56Z") == nil)
        let timestamp = try RFC3339Timestamp(validating: "2026-08-04T12:34:56+00:00")
        #expect(timestamp.rawValue.hasSuffix("+00:00"))
    }

    @Test func envelopePayloadRoundTrip() throws {
        let packageID = try RendererPackageID(validating: "org.example.viewer")
        let version = try RendererPackageVersion(validating: "1.2.3")
        let payload = WikiStoreChangeEvent.rendererSettings(
            .machineInstallStateChanged(packageID: packageID, version: version)
        )
        let record = try PersistedWikiStoreChangeRecord(
            eventID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            sequence: 42,
            scope: .machine(try RendererMachineScopeID(validating: "machine.example")),
            payload: payload,
            committedAt: try RFC3339Timestamp(validating: "2026-08-04T12:34:56+00:00")
        )
        let decoded = try JSONDecoder().decode(PersistedWikiStoreChangeRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded == record)
    }

    @Test func envelopeResourcePayloadRoundTripUsesSameDiscriminatedEvent() throws {
        let payload = WikiStoreChangeEvent.resource(ResourceChangeEvent(
            wikiID: WikiID(rawValue: "wiki-event-contract"),
            kind: .source,
            id: "source-1",
            change: .updated,
            seq: 7
        ))
        let record = try PersistedWikiStoreChangeRecord(
            eventID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            sequence: 43,
            scope: .wiki(WikiID(rawValue: "wiki-event-contract")),
            payload: payload,
            committedAt: try RFC3339Timestamp(validating: "2026-08-04T12:34:56+00:00")
        )

        let decoded = try JSONDecoder().decode(PersistedWikiStoreChangeRecord.self, from: JSONEncoder().encode(record))

        #expect(decoded == record)
    }

    @Test("Source presentation events round-trip in the current settings payload version")
    func sourcePresentationEventsRoundTripAtCurrentPayloadVersion() throws {
        let sourceID = SourceID(rawValue: "01J00000000000000000000000")
        let timestamp = try RFC3339Timestamp(validating: "2026-08-04T12:34:56+00:00")
        let events: [RendererSettingsChangeEvent] = [
            .sourcePresentationSet(sourceID: sourceID, presentation: .split),
            .sourcePresentationRemoved(sourceID: sourceID),
        ]

        for (index, event) in events.enumerated() {
            let record = try PersistedWikiStoreChangeRecord(
                eventID: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(index + 3)")!,
                sequence: UInt64(index + 44),
                scope: .wiki(WikiID(rawValue: "wiki-event-contract")),
                payload: .rendererSettings(event),
                committedAt: timestamp
            )

            #expect(record.schemaVersion == 1)
            #expect(try JSONDecoder().decode(
                PersistedWikiStoreChangeRecord.self,
                from: JSONEncoder().encode(record)
            ) == record)
        }
    }

    @Test("Legacy v1 settings payloads remain decodable inside a v1 record envelope")
    func legacyV1SettingsPayloadsRemainDecodable() throws {
        let packageID = try RendererPackageID(validating: "org.example.viewer")
        let data = Data("""
        {
          "schemaVersion": 1,
          "eventID": "00000000-0000-0000-0000-000000000005",
          "sequence": 46,
          "scope": { "wiki": { "_0": "wiki-event-contract" } },
          "payload": {
            "rendererSettings": {
              "_0": {
                "wikiEnablementSet": {
                  "packageID": "org.example.viewer",
                  "isEnabled": true
                }
              }
            }
          },
          "committedAt": "2026-08-04T12:34:56+00:00"
        }
        """.utf8)

        let record = try JSONDecoder().decode(PersistedWikiStoreChangeRecord.self, from: data)
        #expect(record.schemaVersion == 1)
        #expect(record.payload == .rendererSettings(.wikiEnablementSet(packageID: packageID, isEnabled: true)))
    }

    @Test("Unsupported record envelope versions reject before their payload decodes")
    func unsupportedRecordEnvelopeVersionRejectsBeforePayloadDecodes() throws {
        let data = Data("""
        {
          "schemaVersion": 99,
          "eventID": "00000000-0000-0000-0000-000000000006",
          "sequence": 47,
          "scope": { "wiki": { "_0": "wiki-event-contract" } },
          "payload": { "unrecognizedPayload": {} },
          "committedAt": { "rawValue": "2026-08-04T12:34:56+00:00" }
        }
        """.utf8)

        do {
            _ = try JSONDecoder().decode(PersistedWikiStoreChangeRecord.self, from: data)
            Issue.record("Expected an unsupported persisted record version error.")
        } catch let error as RendererValidationError {
            #expect(error == .unsupportedManifestRevision(99))
        } catch {
            Issue.record("Expected schema version validation before payload decoding, got: \(error)")
        }
    }

    @Test("Unsupported renderer settings payload versions reject before their event decodes")
    func unsupportedRendererSettingsPayloadVersionRejectsBeforeEventDecodes() throws {
        let event = RendererSettingsChangeEvent.sourcePresentationSet(
            sourceID: SourceID(rawValue: "01J00000000000000000000000"),
            presentation: .split
        )
        let record = try PersistedWikiStoreChangeRecord(
            eventID: UUID(uuidString: "00000000-0000-0000-0000-000000000007")!,
            sequence: 48,
            scope: .wiki(WikiID(rawValue: "wiki-event-contract")),
            payload: .rendererSettings(event),
            committedAt: try RFC3339Timestamp(validating: "2026-08-04T12:34:56+00:00")
        )
        var envelope = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any]
        )
        var payload = try #require(envelope["payload"] as? [String: Any])
        var rendererSettings = try #require(payload["rendererSettings"] as? [String: Any])
        var settingsPayload = try #require(rendererSettings["_0"] as? [String: Any])
        settingsPayload["schemaVersion"] = 99
        settingsPayload["event"] = ["unrecognizedEvent": [:]]
        rendererSettings["_0"] = settingsPayload
        payload["rendererSettings"] = rendererSettings
        envelope["payload"] = payload

        let data = try JSONSerialization.data(withJSONObject: envelope)
        do {
            _ = try JSONDecoder().decode(PersistedWikiStoreChangeRecord.self, from: data)
            Issue.record("Expected an unsupported renderer settings payload version error.")
        } catch let error as RendererValidationError {
            #expect(error == .unsupportedManifestRevision(99))
        } catch {
            Issue.record("Expected settings payload validation before event decoding, got: \(error)")
        }
    }

    @Test func namedPolicyDefaultsMatchApprovedPhase3Timing() {
        let policy = RendererEventPolicy.phase3Default
        #expect(policy.heartbeatInterval == 10)
        #expect(policy.leaseExpiry == 45)
        #expect(policy.clockSkewSafetyMargin == 15)
        #expect(policy.cleanRetirementSafetyInterval == 5 * 60)
        #expect(policy.lockAcquisitionTimeout == 30)
        #expect(policy.orderedDrainBatchLimit == 256)
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

struct RendererHostNavigationManifestTests {
    private func declaration(
        _ kinds: Set<RendererHostNavigationTargetKind> = [.page, .source, .namedContent]
    ) throws -> RendererHostNavigationDeclaration {
        try .init(allowedTargetKinds: kinds)
    }

    private func descriptor(
        capabilities: Set<RendererCapability> = [.inputRead, .hostNavigation],
        hostNavigation: RendererHostNavigationDeclaration? = nil
    ) throws -> RendererDescriptor {
        try RendererFixtures.webDescriptor(
            explicitEmbeddingRoles: true,
            capabilities: capabilities,
            hostNavigation: hostNavigation ?? declaration())
    }

    private func manifest(revision: Int, descriptor: RendererDescriptor) throws -> RendererManifest {
        try RendererManifest(
            revision: revision,
            packageID: descriptor.reference.packageID,
            version: descriptor.reference.version,
            descriptors: [descriptor],
            assets: descriptor.approvedAssets)
    }

    @Test func revision4CanonicalizesDeclaredTargetKindsDeterministically() throws {
        let descriptor = try descriptor(hostNavigation: declaration([.source, .namedContent, .page]))
        let value = try manifest(revision: RendererManifestRevision.hostNavigation, descriptor: descriptor)
        let canonical = try value.canonicalJSON()
        let text = String(decoding: canonical, as: UTF8.self)

        #expect(value.revision == 4)
        #expect(descriptor.capabilities.contains(.hostNavigation))
        #expect(descriptor.hostNavigation?.allowedTargetKinds == [.page, .source, .namedContent])
        #expect(text.contains(#""allowedTargetKinds":["namedContent","page","source"]"#))
        #expect(try value.canonicalJSON() == canonical)
        #expect(try value.packageHash() == value.packageHash())
    }

    @Test func preRevision4NavigationFailsClosed() throws {
        let descriptor = try descriptor()
        for revision in RendererManifestRevision.legacy ... RendererManifestRevision.fenceValidation {
            #expect(throws: RendererValidationError.hostNavigationRequiresRevision4) {
                try manifest(revision: revision, descriptor: descriptor)
            }
        }
    }

    @Test func capabilityAndDeclarationMustBePaired() throws {
        #expect(throws: RendererValidationError.hostNavigationCapabilityRequiresDeclaration) {
            let asset = RendererFixtures.webAsset()
            _ = try RendererDescriptor(
                reference: .init(
                    packageID: RendererFixtures.packageID,
                    version: RendererFixtures.version,
                    registrationID: RendererFixtures.registrationID),
                displayName: "Web",
                implementation: .webPackage(.init(path: asset.path)),
                matchers: [.artifactKind(.source)],
                presentations: [.web],
                supportedEmbeddingRoles: [.disclosureRow],
                hasExplicitEmbeddingRoles: true,
                approvedAssets: [asset],
                capabilities: [.inputRead, .hostNavigation],
                sizeLimits: try .init(maximumInputByteCount: 1_024, maximumDecodedByteCount: 1_024),
                linkPolicy: .none,
                accessibility: .init(supportsVoiceOver: true, supportsKeyboardNavigation: true),
                compatibility: try .init(minimumProtocolRevision: 1, maximumProtocolRevision: 1),
                priority: 0)
        }
        #expect(throws: RendererValidationError.hostNavigationDeclarationRequiresCapability) {
            _ = try RendererFixtures.webDescriptor(
                explicitEmbeddingRoles: true,
                capabilities: [.inputRead],
                hostNavigation: try declaration())
        }
        #expect(throws: RendererValidationError.emptyHostNavigationDeclaration) {
            _ = try declaration([])
        }
    }

    @Test func builtInNavigationDeclarationIsRejected() throws {
        #expect(throws: RendererValidationError.hostNavigationRequiresWebPackage) {
            _ = try RendererDescriptor(
                reference: .init(
                    packageID: RendererFixtures.packageID,
                    version: RendererFixtures.version,
                    registrationID: RendererFixtures.registrationID),
                displayName: "Native",
                implementation: .builtIn(.pdf),
                matchers: [.normalizedMIME(try .init(validating: "application/pdf"))],
                presentations: [.native],
                approvedAssets: [],
                capabilities: [.inputRead, .hostNavigation],
                hostNavigation: declaration([.page]),
                sizeLimits: try .init(maximumInputByteCount: 1_024, maximumDecodedByteCount: 1_024),
                linkPolicy: .none,
                accessibility: .init(supportsVoiceOver: true, supportsKeyboardNavigation: true),
                compatibility: try .init(minimumProtocolRevision: 1, maximumProtocolRevision: 1),
                priority: 0)
        }
    }

    @Test func unknownCapabilityAndTargetKindFailDecode() {
        let capability = Data(#"\"arbitraryNavigation\""#.utf8)
        let target = Data(#"\"filesystemPath\""#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(RendererCapability.self, from: capability)
        }
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(RendererHostNavigationTargetKind.self, from: target)
        }
    }

    @Test func descriptorEncodingOmitsAbsentNavigationDeclaration() throws {
        let descriptor = try RendererFixtures.webDescriptor(explicitEmbeddingRoles: true)
        let text = String(decoding: try JSONEncoder().encode(descriptor), as: UTF8.self)
        #expect(text.contains("hostNavigation") == false)
    }
}

struct RendererAssetReadManifestTests {
    private func declaration(
        extractorAsset: RendererRelativePath? = nil,
        entryFunction: String = "__sdw_extract_canvas_assets",
        roles: Set<RendererAssetRole> = [.imageNode, .groupBackground],
        mimes: Set<RendererMIMEType>? = nil,
        count: Int = 64,
        input: Int = 128 * 1_024,
        output: Int = 128 * 1_024,
        seconds: Int = 5,
        perAsset: Int = 8 * 1_024 * 1_024,
        aggregate: Int = 32 * 1_024 * 1_024
    ) throws -> RendererAssetReadDeclaration {
        let resolvedExtractor: RendererRelativePath
        if let extractorAsset {
            resolvedExtractor = extractorAsset
        } else {
            resolvedExtractor = try RendererRelativePath(validating: "extractor.js")
        }
        return try RendererAssetReadDeclaration(
            allowedRoles: roles,
            allowedMIMETypes: mimes ?? [try .init(validating: "image/png"), try .init(validating: "image/jpeg")],
            maximumExtractedReferenceCount: count,
            maximumExtractorInputBytes: input,
            maximumExtractorOutputBytes: output,
            maximumExtractorExecutionSeconds: seconds,
            maximumBytesPerAsset: perAsset,
            maximumAggregateSessionBytes: aggregate,
            extractorAsset: resolvedExtractor,
            extractorEntryFunction: entryFunction)
    }

    private func descriptor(
        capabilities: Set<RendererCapability> = [.inputRead, .assetRead],
        assetRead: RendererAssetReadDeclaration? = nil,
        assets: [RendererAsset] = [RendererFixtures.webAsset(), RendererFixtures.webAsset(path: "extractor.js")]
    ) throws -> RendererDescriptor {
        try RendererFixtures.webDescriptor(
            assets: assets,
            explicitEmbeddingRoles: true,
            capabilities: capabilities,
            assetRead: assetRead ?? declaration())
    }

    private func manifest(revision: Int, descriptor: RendererDescriptor) throws -> RendererManifest {
        try RendererManifest(
            revision: revision,
            packageID: descriptor.reference.packageID,
            version: descriptor.reference.version,
            descriptors: [descriptor],
            assets: descriptor.approvedAssets)
    }

    @Test func revision5CanonicalizesAssetReadDeclarationDeterministically() throws {
        let declaration = try declaration(
            roles: [.groupBackground, .imageNode],
            mimes: [try .init(validating: "image/jpeg"), try .init(validating: "image/png")])
        let descriptor = try descriptor(assetRead: declaration)
        let value = try manifest(revision: RendererManifestRevision.assetRead, descriptor: descriptor)
        let canonical = try value.canonicalJSON()
        let text = String(decoding: canonical, as: UTF8.self)

        #expect(value.revision == 5)
        #expect(descriptor.capabilities.contains(RendererCapability.assetRead))
        let allowedRoles = try #require(descriptor.assetRead?.allowedRoles)
        #expect(allowedRoles == [.imageNode, .groupBackground])
        #expect(text.contains(#""allowedRoles":["groupBackground","imageNode"]"#))
        #expect(text.contains(#""allowedMIMETypes":["image/jpeg","image/png"]"#))
        #expect(text.contains(#""extractorEntryFunction":"__sdw_extract_canvas_assets""#))
        #expect(try value.canonicalJSON() == canonical)
    }

    @Test func preRevision5AssetReadFailsClosed() throws {
        let descriptor = try descriptor()
        for revision in RendererManifestRevision.legacy ... RendererManifestRevision.hostNavigation {
            #expect(throws: RendererValidationError.assetReadRequiresRevision5) {
                try manifest(revision: revision, descriptor: descriptor)
            }
        }
    }

    @Test func assetReadRequiresCapabilityAndDeclarationPairing() throws {
        #expect(throws: RendererValidationError.assetReadCapabilityRequiresDeclaration) {
            _ = try RendererFixtures.webDescriptor(
                explicitEmbeddingRoles: true,
                capabilities: [.inputRead, .assetRead])
        }
        #expect(throws: RendererValidationError.assetReadDeclarationRequiresCapability) {
            _ = try RendererFixtures.webDescriptor(
                explicitEmbeddingRoles: true,
                capabilities: [.inputRead],
                assetRead: try declaration())
        }
    }

    @Test func assetReadIsWebPackageOnly() throws {
        #expect(throws: RendererValidationError.assetReadRequiresWebPackage) {
            _ = try RendererDescriptor(
                reference: .init(
                    packageID: RendererFixtures.packageID,
                    version: RendererFixtures.version,
                    registrationID: RendererFixtures.registrationID),
                displayName: "Native",
                implementation: .builtIn(.pdf),
                matchers: [.normalizedMIME(try .init(validating: "application/pdf"))],
                presentations: [.native],
                approvedAssets: [],
                capabilities: [.inputRead, .assetRead],
                assetRead: try declaration(),
                sizeLimits: try .init(maximumInputByteCount: 1_024, maximumDecodedByteCount: 1_024),
                linkPolicy: .none,
                accessibility: .init(supportsVoiceOver: true, supportsKeyboardNavigation: true),
                compatibility: try .init(minimumProtocolRevision: 1, maximumProtocolRevision: 1),
                priority: 0)
        }
    }

    @Test func extractorAssetMustBeApprovedByDescriptor() throws {
        // The extractor asset is NOT in the descriptor's approved set.
        let entry = RendererFixtures.webAsset()
        let declaration = try declaration(extractorAsset: try .init(validating: "missing.js"))
        let missing = try RendererRelativePath(validating: "missing.js")
        #expect(throws: RendererValidationError.extractorAssetNotApproved(missing)) {
            _ = try RendererFixtures.webDescriptor(
                assets: [entry],
                explicitEmbeddingRoles: true,
                capabilities: [.inputRead, .assetRead],
                assetRead: declaration)
        }
    }

    @Test func rejectsEmptyInvalidAndOversizedDeclarations() throws {
        // Empty role set fails closed.
        #expect(throws: RendererValidationError.emptyAssetReadDeclaration) {
            _ = try declaration(roles: [])
        }
        // Empty MIME set fails closed.
        #expect(throws: RendererValidationError.emptyAssetReadDeclaration) {
            _ = try declaration(mimes: [])
        }
        // Unknown MIME type fails closed.
        #expect(throws: RendererValidationError.unsupportedAssetMIMEType) {
            _ = try declaration(mimes: [try .init(validating: "application/pdf")])
        }
        // Zero entry-function fails closed (not an identifier).
        #expect(throws: Error.self) {
            _ = try declaration(entryFunction: "")
        }
        // Reserved word entry function fails closed.
        #expect(throws: Error.self) {
            _ = try declaration(entryFunction: "null")
        }
        // Ceiling overshoot fails closed.
        #expect(throws: Error.self) {
            _ = try declaration(count: RendererAssetReadLimits.maximumExtractedReferenceCount + 1)
        }
        #expect(throws: Error.self) {
            _ = try declaration(input: RendererAssetReadLimits.maximumExtractorInputBytes + 1)
        }
        #expect(throws: Error.self) {
            _ = try declaration(perAsset: RendererAssetReadLimits.maximumBytesPerAsset + 1)
        }
        #expect(throws: Error.self) {
            _ = try declaration(aggregate: RendererAssetReadLimits.maximumAggregateSessionBytes + 1)
        }
    }
}

struct RendererModelTests {
    @Test func reviewedRevision2And3PackageHashesRemainStable() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtures: [(path: String, revision: Int, hash: String)] = [
            ("RendererPackages/Excalidraw/manifest.json", RendererManifestRevision.fenceClaims,
             "7580e5195a43ee677a795c2a4591c3dcebf528d3dbfadba7001f659e9c328999"),
            ("RendererPackages/Mermaid/manifest.json", RendererManifestRevision.fenceValidation,
             "714bb2a23a33bbe45ab9507137c2784d844fee32220ae6248ea78a60e2acda6f"),
        ]
        for fixture in fixtures {
            let data = try Data(contentsOf: root.appendingPathComponent(fixture.path))
            let manifest = try JSONDecoder().decode(RendererManifest.self, from: data)
            #expect(manifest.revision == fixture.revision)
            #expect(try manifest.packageHash().hex == fixture.hash)
            #expect(manifest.descriptors.allSatisfy {
                $0.compatibility.supports(hostProtocolRevision: RendererRegistrySnapshotDefaults.hostProtocolRevision)
            })
        }
    }

    @Test func reviewedRevision4PackageHashRemainsStable() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        // The on-disk package is 1.1.0 (revision 5). Its package hash is a
        // stability contract: adding a manifest revision or changing assets
        // must produce a NEW immutable version and never mutate an existing
        // reviewed package hash. The prior 1.0.1 (revision 4) package hash
        // `8b4ba221c48a3232d4e5355c64170b3da942f003fd7072747712922def9d576d`
        // is preserved in repository history, not on disk.
        let data = try Data(contentsOf: root.appendingPathComponent("RendererPackages/JSONCanvas/manifest.json"))
        let manifest = try JSONDecoder().decode(RendererManifest.self, from: data)
        #expect(manifest.revision == RendererManifestRevision.current)
        #expect(try manifest.packageHash().hex == "64b5ce26748e876bc11ab4c450641ada61bda31bab8a03ace77124e1abeddb97")
        #expect(manifest.descriptors.allSatisfy {
            $0.compatibility.supports(hostProtocolRevision: RendererRegistrySnapshotDefaults.hostProtocolRevision)
        })
    }
}
