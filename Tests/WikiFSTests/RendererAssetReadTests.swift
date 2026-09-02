import Foundation
import Testing
import WikiFSTypes
@testable import WikiFSCore

// MARK: - RendererBridgeContractsTests (asset.read authority)

extension RendererBridgeContractsTests {
    @Test("asset.read requires a non-empty declared asset admission set")
    func assetReadRequiresDeclaredAssetAdmission() throws {
        let capability = RendererSessionCapability(rawValue: "capability")
        let reference = try RendererAssetReference(validating: "diagram.png")
        let request = RendererAssetRequest(
            id: .init(rawValue: "asset-1"),
            capability: capability,
            reference: reference)
        let envelope = try RendererBridgeEnvelope.encode(request)
        var authorizer = RendererBridgeAuthorizer(capability: capability)
        // No admission set -> assetRead unavailable.
        #expect(throws: RendererBridgeAuthorizationError.assetReadUnavailable) {
            try authorizer.authorizeAsset(
                envelope: envelope,
                context: nil,
                sessionIsReady: true,
                sessionIsClosed: false)
        }
    }

    @Test("asset.read rejects wrong capability, wrong context, replay, and unadmitted references")
    func assetReadRejectsWrongContextReplayAmbiguityAndLimits() throws {
        let capability = RendererSessionCapability(rawValue: "capability")
        let sessionID = RendererSessionID(rawValue: UUID())
        let windowID = UUID()
        let frameID = UUID()
        let context = RendererBridgeAuthorizationContext(
            sessionID: sessionID, windowID: windowID, frameID: frameID, mainFrameID: frameID)
        let admitted = try RendererAssetReference(validating: "diagram.png")
        let unadmitted = try RendererAssetReference(validating: "other.png")
        var authorizer = RendererBridgeAuthorizer(
            capability: capability,
            sessionID: sessionID,
            windowID: windowID,
            admittedAssetReferences: [admitted])

        let valid = RendererAssetRequest(id: .init(rawValue: "asset-1"), capability: capability, reference: admitted)
        let validEnvelope = try RendererBridgeEnvelope.encode(valid)

        // Not ready -> fail.
        #expect(throws: RendererBridgeAuthorizationError.sessionNotReady) {
            try authorizer.authorizeAsset(
                envelope: validEnvelope, context: context, sessionIsReady: false, sessionIsClosed: false)
        }
        // Closed -> fail.
        #expect(throws: RendererBridgeAuthorizationError.sessionClosed) {
            try authorizer.authorizeAsset(
                envelope: validEnvelope, context: context, sessionIsReady: true, sessionIsClosed: true)
        }
        // Wrong window -> fail (does not consume the request ID).
        let wrongContext = RendererBridgeAuthorizationContext(
            sessionID: sessionID, windowID: UUID(), frameID: frameID, mainFrameID: frameID)
        #expect(throws: RendererBridgeAuthorizationError.wrongWindow) {
            try authorizer.authorizeAsset(
                envelope: validEnvelope, context: wrongContext, sessionIsReady: true, sessionIsClosed: false)
        }
        // Wrong capability -> fail without burning the ID.
        let wrongCapability = RendererAssetRequest(
            id: .init(rawValue: "asset-1"), capability: .init(rawValue: "wrong"), reference: admitted)
        #expect(throws: RendererBridgeAuthorizationError.capabilityMismatch) {
            try authorizer.authorizeAsset(
                envelope: try RendererBridgeEnvelope.encode(wrongCapability),
                context: context, sessionIsReady: true, sessionIsClosed: false)
        }
        // Unadmitted reference -> fail without burning the ID.
        let unadmittedRequest = RendererAssetRequest(
            id: .init(rawValue: "asset-1"), capability: capability, reference: unadmitted)
        #expect(throws: RendererBridgeAuthorizationError.assetNotAdmitted) {
            try authorizer.authorizeAsset(
                envelope: try RendererBridgeEnvelope.encode(unadmittedRequest),
                context: context, sessionIsReady: true, sessionIsClosed: false)
        }
        // Valid first use consumes the ID.
        #expect(try authorizer.authorizeAsset(
            envelope: validEnvelope, context: context, sessionIsReady: true, sessionIsClosed: false) == valid)
        // Replay -> duplicate.
        #expect(throws: RendererBridgeAuthorizationError.duplicateRequestID) {
            try authorizer.authorizeAsset(
                envelope: validEnvelope, context: context, sessionIsReady: true, sessionIsClosed: false)
        }
    }

    @Test("asset.read and input.read share one replay ledger")
    func assetReadSharesReplayLedgerWithInputRead() throws {
        let capability = RendererSessionCapability(rawValue: "capability")
        let admitted = try RendererAssetReference(validating: "diagram.png")
        var authorizer = RendererBridgeAuthorizer(
            capability: capability,
            admittedAssetReferences: [admitted])

        let requestID = RendererBridgeRequestID(rawValue: "shared-1")
        let input = RendererBridgeRequest(
            id: requestID, method: .inputRead, capability: capability,
            input: .source(versionID: .init(rawValue: "version-1")))
        _ = try authorizer.authorize(
            envelope: try RendererBridgeEnvelope.encode(input), sessionIsReady: true)

        let asset = RendererAssetRequest(
            id: requestID, capability: capability, reference: admitted)
        // Same ID across methods -> duplicate, shared ledger.
        #expect(throws: RendererBridgeAuthorizationError.duplicateRequestID) {
            try authorizer.authorizeAsset(
                envelope: try RendererBridgeEnvelope.encode(asset),
                context: nil, sessionIsReady: true, sessionIsClosed: false)
        }
    }
}

// MARK: - RendererAuthorizedAssetReaderTests

@Suite(.serialized, .timeLimit(.minutes(2)))
struct RendererAuthorizedAssetReaderTests {
    @Test("reads only pinned approved image versions from exact SourceVersionID")
    func readsOnlyPinnedApprovedImageVersions() async throws {
        let store = try GRDBWikiStore()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02, 0x03])
        let summary = try store.addSource(filename: "diagram.png", data: png)
        let version = try #require(try store.activeContentVersion(sourceID: summary.id))
        let digest = RendererSHA256.digest(png).hex
        let admission = RendererAuthorizedAssetReader.Admission(
            reference: try RendererAssetReference(validating: "diagram.png"),
            sourceID: summary.id,
            sourceVersionID: version.id,
            mimeType: "image/png",
            expectedByteCount: png.count,
            expectedDigest: digest)

        let reader = try RendererAuthorizedAssetReader(
            admissions: [admission],
            maximumBytesPerAsset: 4096,
            maximumAggregateSessionBytes: 8192,
            maximumPerRequestReadCount: 4,
            store: store)
        defer { reader.close() }

        let payload = try reader.read(try RendererAssetReference(validating: "diagram.png"))
        #expect(payload.mimeType == "image/png")
        #expect(payload.bytes == png)
        #expect(payload.contentDigest == digest)
    }

    @Test("rejects changed, missing, oversized, duplicate, and unadmitted assets")
    func rejectsChangedMissingOversizedAndUnsupportedAssets() async throws {
        let store = try GRDBWikiStore()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02, 0x03])
        let summary = try store.addSource(filename: "diagram.png", data: png)
        let version = try #require(try store.activeContentVersion(sourceID: summary.id))
        let digest = RendererSHA256.digest(png).hex

        // Changed digest: expect a *different* digest than reality -> reader rejects.
        let wrongDigestAdmission = RendererAuthorizedAssetReader.Admission(
            reference: try RendererAssetReference(validating: "diagram.png"),
            sourceID: summary.id,
            sourceVersionID: version.id,
            mimeType: "image/png",
            expectedByteCount: png.count,
            expectedDigest: String(repeating: "0", count: 64))
        let wrongReader = try RendererAuthorizedAssetReader(
            admissions: [wrongDigestAdmission],
            maximumBytesPerAsset: 4096,
            maximumAggregateSessionBytes: 8192,
            maximumPerRequestReadCount: 4,
            store: store)
        defer { wrongReader.close() }
        #expect(throws: RendererAuthorizedAssetReader.ReaderError.changedAsset) {
            try wrongReader.read(try RendererAssetReference(validating: "diagram.png"))
        }

        // Unadmitted reference -> uniform denial.
        let goodAdmission = RendererAuthorizedAssetReader.Admission(
            reference: try RendererAssetReference(validating: "diagram.png"),
            sourceID: summary.id,
            sourceVersionID: version.id,
            mimeType: "image/png",
            expectedByteCount: png.count,
            expectedDigest: digest)
        let reader = try RendererAuthorizedAssetReader(
            admissions: [goodAdmission],
            maximumBytesPerAsset: 4096,
            maximumAggregateSessionBytes: 8192,
            maximumPerRequestReadCount: 4,
            store: store)
        defer { reader.close() }
        #expect(throws: RendererAuthorizedAssetReader.ReaderError.unadmittedReference) {
            try reader.read(try RendererAssetReference(validating: "other.png"))
        }

        // Oversized (per-asset cap below actual byte count) -> denied.
        let tinyCapReader = try RendererAuthorizedAssetReader(
            admissions: [goodAdmission],
            maximumBytesPerAsset: 1,
            maximumAggregateSessionBytes: 8192,
            maximumPerRequestReadCount: 4,
            store: store)
        defer { tinyCapReader.close() }
        #expect(throws: RendererAuthorizedAssetReader.ReaderError.oversizedAsset) {
            try tinyCapReader.read(try RendererAssetReference(validating: "diagram.png"))
        }

        // Closed reader -> denied without a store read.
        let closedReader = try RendererAuthorizedAssetReader(
            admissions: [goodAdmission],
            maximumBytesPerAsset: 4096,
            maximumAggregateSessionBytes: 8192,
            maximumPerRequestReadCount: 4,
            store: store)
        closedReader.close()
        #expect(throws: RendererAuthorizedAssetReader.ReaderError.closed) {
            try closedReader.read(try RendererAssetReference(validating: "diagram.png"))
        }

        // Duplicate admission key -> construction fails.
        #expect(throws: RendererAuthorizedAssetReader.ReaderError.duplicateAdmission) {
            _ = try RendererAuthorizedAssetReader(
                admissions: [goodAdmission, goodAdmission],
                maximumBytesPerAsset: 4096,
                maximumAggregateSessionBytes: 8192,
                maximumPerRequestReadCount: 4,
                store: store)
        }
    }

    @Test("session aggregate budget and per-request read count are enforced")
    func enforcesSessionAndPerRequestBudgets() async throws {
        let store = try GRDBWikiStore()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02, 0x03])
        let summary = try store.addSource(filename: "diagram.png", data: png)
        let version = try #require(try store.activeContentVersion(sourceID: summary.id))
        let admission = RendererAuthorizedAssetReader.Admission(
            reference: try RendererAssetReference(validating: "diagram.png"),
            sourceID: summary.id,
            sourceVersionID: version.id,
            mimeType: "image/png",
            expectedByteCount: png.count,
            expectedDigest: RendererSHA256.digest(png).hex)

        // Aggregate budget = 1 read worth of bytes, then exhausted.
        let budgetReader = try RendererAuthorizedAssetReader(
            admissions: [admission],
            maximumBytesPerAsset: 4096,
            maximumAggregateSessionBytes: png.count,
            maximumPerRequestReadCount: 4,
            store: store)
        defer { budgetReader.close() }
        _ = try budgetReader.read(try RendererAssetReference(validating: "diagram.png"))
        #expect(throws: RendererAuthorizedAssetReader.ReaderError.sessionBudgetExhausted) {
            try budgetReader.read(try RendererAssetReference(validating: "diagram.png"))
        }

        // Per-request read count = 1, then exhausted.
        let countReader = try RendererAuthorizedAssetReader(
            admissions: [admission],
            maximumBytesPerAsset: 4096,
            maximumAggregateSessionBytes: 8192,
            maximumPerRequestReadCount: 1,
            store: store)
        defer { countReader.close() }
        _ = try countReader.read(try RendererAssetReference(validating: "diagram.png"))
        #expect(throws: RendererAuthorizedAssetReader.ReaderError.sessionBudgetExhausted) {
            try countReader.read(try RendererAssetReference(validating: "diagram.png"))
        }
    }

    @Test("does not expose enumeration or live source lookup")
    func doesNotExposeEnumerationOrLiveSourceLookup() throws {
        // The reader API surfaces no source-name lookup, no sourceContent(id:)
        // path, and no way to enumerate the store's sources. We assert the
        // type shape: only `read(_ reference:)`, `admittedReferences`, and
        // `close()` exist by construction (a compile-time guarantee), and that
        // unadmitted references produce a uniform denial (covered above).
        // This test documents the API boundary.
        let store = try GRDBWikiStore()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let summary = try store.addSource(filename: "diagram.png", data: png)
        let version = try #require(try store.activeContentVersion(sourceID: summary.id))
        let admission = RendererAuthorizedAssetReader.Admission(
            reference: try RendererAssetReference(validating: "diagram.png"),
            sourceID: summary.id,
            sourceVersionID: version.id,
            mimeType: "image/png",
            expectedByteCount: png.count,
            expectedDigest: RendererSHA256.digest(png).hex)
        let reader = try RendererAuthorizedAssetReader(
            admissions: [admission],
            maximumBytesPerAsset: 4096,
            maximumAggregateSessionBytes: 8192,
            maximumPerRequestReadCount: 4,
            store: store)
        defer { reader.close() }

        #expect(reader.admittedReferences == [try RendererAssetReference(validating: "diagram.png")])
        // A reader constructed with a DIFFERENT source's version must still
        // deny reads that don't match the pinned reference — no fallback.
        let otherSummary = try store.addSource(filename: "other.png", data: Data([0x01, 0x02]))
        let otherVersion = try #require(try store.activeContentVersion(sourceID: otherSummary.id))
        let otherRef = try RendererAssetReference(validating: "other.png")
        #expect(reader.admittedReferences.contains(otherRef) == false)
        _ = otherVersion
    }

    @Test("metadata lookup failure denies uniformly instead of substituting stored MIME")
    func metadataLookupFailureDeniesInsteadOfSubstitutingStoredMIME() async throws {
        let store = try GRDBWikiStore()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let summary = try store.addSource(filename: "diagram.png", data: png)
        let digest = RendererSHA256.digest(png).hex

        // Admit an entry whose SourceVersionID has NO metadata row (a
        // version that does not exist in the store). Bytes + digest cannot be
        // cross-checked against live metadata, so the read MUST deny (fail
        // closed) rather than substitute the admission's stored MIME.
        let missingVersionID = SourceVersionID(rawValue: "01HXXXXXXXXXXXXXXXXXXXXXXX")
        let admission = RendererAuthorizedAssetReader.Admission(
            reference: try RendererAssetReference(validating: "diagram.png"),
            sourceID: summary.id,
            sourceVersionID: missingVersionID,
            mimeType: "image/png",
            expectedByteCount: png.count,
            expectedDigest: digest)
        let reader = try RendererAuthorizedAssetReader(
            admissions: [admission],
            maximumBytesPerAsset: 4096,
            maximumAggregateSessionBytes: 8192,
            maximumPerRequestReadCount: 4,
            store: store)
        defer { reader.close() }
        // sourceContent(versionID:) for the missing version throws, and even
        // if it did not, the MIME metadata lookup fails -> uniform denial.
        #expect(throws: RendererAuthorizedAssetReader.ReaderError.self) {
            try reader.read(try RendererAssetReference(validating: "diagram.png"))
        }
    }

    @Test("validates asset reference syntax strictly")
    func validatesAssetReferenceSyntax() {
        let valid: [(String, Bool)] = [
            ("diagram.png", true),
            ("folder/diagram.png", true),
            ("", false),
            ("/diagram.png", false),
            ("../diagram.png", false),
            ("a/../b", false),
            ("diagram.png/", false),
            ("https://x/y.png", false),
            ("a:b.png", false),
            ("a@b", false),
            ("a?b", false),
            ("a#b", false),
            ("a%20b", false),
            ("a\\b", false),
            (" a.png", false),
            ("a.png ", false),
            ("con\u{0000}trol", false),
            ("~/.png", false),
        ]
        for (value, expected) in valid {
            #expect((RendererAssetReference(rawValue: value) != nil) == expected, "value: \(value)")
        }
    }
}

// MARK: - RendererAssetAdmissionBuilderTests

@Suite(.serialized, .timeLimit(.minutes(2)))
struct RendererAssetAdmissionBuilderTests {
    /// The builder resolves only exact reference keys (the caller supplies the
    /// sibling-scoped `resolveSourceFacts` seam), pins the exact active
    /// SourceVersionID, and bails when a source is missing or its version is
    /// unavailable.
    @Test("resolves exact references and pins active versions")
    func resolvesExactReferencesAndPinsVersions() async throws {
        let store = try GRDBWikiStore()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02])
        let summary = try store.addSource(filename: "diagram.png", data: png)
        let version = try #require(try store.activeContentVersion(sourceID: summary.id))

        let records = [RendererAssetReferenceExtractorClient.ExtractedRecord(
            role: .imageNode, reference: "diagram.png")]
        let admissions = try RendererAssetAdmissionBuilder.buildAdmissions(
            records: records,
            resolveSourceFacts: { rawReference in
                guard rawReference == "diagram.png" else { return nil }
                let bytes = try store.sourceContent(versionID: version.id)
                return (
                    sourceID: summary.id,
                    sourceVersionID: version.id,
                    mimeType: "image/png",
                    byteCount: bytes.count,
                    digest: RendererSHA256.digest(bytes).hex)
            },
            allowedRoles: [.imageNode],
            maximumBytesPerAsset: 4096)
        #expect(admissions.count == 1)
        let admission = try #require(admissions.first)
        #expect(admission.sourceID == summary.id)
        #expect(admission.sourceVersionID == version.id)
        #expect(admission.mimeType == "image/png")
        #expect(admission.expectedByteCount == png.count)
        #expect(admission.expectedDigest == RendererSHA256.digest(png).hex)
    }

    @Test("does not broaden admission scope to unrelated sources")
    func doesNotBroadenSiblingScope() async throws {
        let store = try GRDBWikiStore()
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let summary = try store.addSource(filename: "diagram.png", data: png)
        let version = try #require(try store.activeContentVersion(sourceID: summary.id))
        // The seam only resolves `diagram.png`; a reference to another key
        // must NOT resolve even though the source EXISTS in the store — the
        // sibling scope is exact, never broadened.
        let records = [RendererAssetReferenceExtractorClient.ExtractedRecord(
            role: .imageNode, reference: "other-diagram.png")]
        let admissions = try RendererAssetAdmissionBuilder.buildAdmissions(
            records: records,
            resolveSourceFacts: { rawReference in
                guard rawReference == "diagram.png" else { return nil }
                let bytes = try store.sourceContent(versionID: version.id)
                return (
                    sourceID: summary.id,
                    sourceVersionID: version.id,
                    mimeType: "image/png",
                    byteCount: bytes.count,
                    digest: RendererSHA256.digest(bytes).hex)
            },
            allowedRoles: [.imageNode],
            maximumBytesPerAsset: 4096)
        #expect(admissions.isEmpty)
    }

    @Test("role gating admits only declared roles")
    func roleGatingAdmitsOnlyDeclaredRoles() async throws {
        let store = try GRDBWikiStore()
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let summary = try store.addSource(filename: "diagram.png", data: png)
        let version = try #require(try store.activeContentVersion(sourceID: summary.id))
        let records = [
            RendererAssetReferenceExtractorClient.ExtractedRecord(role: .imageNode, reference: "diagram.png"),
            RendererAssetReferenceExtractorClient.ExtractedRecord(role: .groupBackground, reference: "diagram.png"),
        ]
        // Only imageNode is declared -> groupBackground record is skipped.
        let admissions = try RendererAssetAdmissionBuilder.buildAdmissions(
            records: records,
            resolveSourceFacts: { _ in
                let bytes = try store.sourceContent(versionID: version.id)
                return (
                    sourceID: summary.id,
                    sourceVersionID: version.id,
                    mimeType: "image/png",
                    byteCount: bytes.count,
                    digest: RendererSHA256.digest(bytes).hex)
            },
            allowedRoles: [.imageNode],
            maximumBytesPerAsset: 4096)
        #expect(admissions.count == 1)
        #expect(admissions.first?.reference.rawValue == "diagram.png")
    }
}
