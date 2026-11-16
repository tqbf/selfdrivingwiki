#if os(macOS)
import CryptoKit
import Foundation
import Testing
import WikiDaemonContract

// Round-trip contract for the store family wire primitives (plan 2a slice
// 1): every primitive encodes and decodes with associated values intact —
// payload-handle flow DTOs, the byte-budgeted cursor, mutation outcome
// semantics, the bootstrap mirrors, the exhaustive error enum (duplicate
// mirrors + every CAS detail), and a `.store` family envelope carrying a
// representative operation string.

@Suite("Daemon store wire round-trips", .timeLimit(.minutes(1)))
struct DaemonStoreWireRoundTripTests {

    private static let wikiID = "01JWIKI0000000000000000AB"
    private static let shaHex = String(repeating: "9", count: 64)

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: Operation registry

    @Test("operation registry matches the manifest partition counts")
    func registryCounts() {
        #expect(DaemonStoreOperation.allCases.count
            == DaemonStoreOperationCounts.total)
        for (family, expected) in [
            (DaemonStorePayloadFamily.small, DaemonStoreOperationCounts.small),
            (DaemonStorePayloadFamily.list, DaemonStoreOperationCounts.list),
            (DaemonStorePayloadFamily.blob, DaemonStoreOperationCounts.blob),
            (DaemonStorePayloadFamily.eventProducer,
             DaemonStoreOperationCounts.eventProducer),
            (DaemonStorePayloadFamily.stagedPayload,
             DaemonStoreOperationCounts.stagedPayload),
            (DaemonStorePayloadFamily.mutationSemantics,
             DaemonStoreOperationCounts.mutationSemantics),
            (DaemonStorePayloadFamily.reservedEvents,
             DaemonStoreOperationCounts.reservedEvents),
        ] {
            let count = DaemonStoreOperation.allCases
                .filter { $0.family == family }.count
            #expect(count == expected,
                    "\(family.rawValue) expects \(expected), registry has \(count)")
        }
        #expect(DaemonStoreOperation.allCases.filter {
            $0.family == .small || $0.family == .list || $0.family == .blob
                || $0.family == .eventProducer
        }.count == DaemonStoreOperationCounts.manifestOperations)
    }

    @Test("operation strings are unique and encode as their raw values")
    func operationStringsAreUnique() throws {
        let all = DaemonStoreOperation.allCases
        #expect(Set(all.map(\.rawValue)).count == all.count)
        let payload: DaemonStoreRequest = DaemonStoreRequest(
            wikiID: Self.wikiID,
            operation: DaemonStoreOperation.listPages.rawValue)
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(DaemonStoreRequest.self, from: data)
        #expect(decoded.operation == "listPages")
        #expect(DaemonStoreOperation(rawValue: decoded.operation) == .listPages)
    }

    @Test("reserved event-slice operation name is present in the registry")
    func reservedSinkHandshakeName() {
        #expect(DaemonStoreOperation.sinkHandshake.rawValue == "sinkHandshake")
        #expect(DaemonStoreOperation.sinkHandshake.family == .reservedEvents)
        #expect(DaemonStoreOperation.resolveOutcome.rawValue == "resolveOutcome")
        #expect(DaemonStoreOperation.sessionBootstrap.rawValue == "sessionBootstrap")
        #expect(DaemonStoreOperation.payloadRead.rawValue == "payloadRead")
    }

    // MARK: Staged payload handle flow

    @Test("payload begin flow round-trips")
    func payloadBeginRoundTrip() throws {
        let request = DaemonPayloadBeginRequest(
            declaredByteCount: 3 * DaemonStoreLimits.maxChunkBytes + 17,
            sha256Hex: Self.shaHex)
        #expect(try roundTrip(request) == request)

        let reply = DaemonPayloadBeginReply(uploadID: "01JUPLOAD0000000000000AB")
        #expect(try roundTrip(reply) == reply)
    }

    @Test("payload chunk request round-trips with real running hash")
    func payloadChunkRoundTrip() throws {
        let bytes = Data("staged chunk bytes".utf8)
        let digest = SHA256.hash(data: bytes)
        let running = digest.map { String(format: "%02x", $0) }.joined()

        let request = DaemonPayloadChunkRequest(
            uploadID: "01JUPLOAD0000000000000AB",
            orderIndex: 2,
            bytes: bytes,
            runningSHA256Hex: running)
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.bytes == bytes)
        #expect(decoded.runningSHA256Hex.count == 64)
    }

    @Test("payload commit reply round-trips handle and expiry")
    func payloadCommitRoundTrip() throws {
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let reply = DaemonPayloadCommitReply(
            handle: DaemonPayloadHandle(
                id: "01JHANDLE00000000000000AB",
                declaredByteCount: 3 * DaemonStoreLimits.maxChunkBytes + 17,
                sha256Hex: Self.shaHex),
            expiresAt: expiry)
        let decoded = try roundTrip(reply)
        #expect(decoded == reply)
        #expect(decoded.handle.declaredByteCount
            == 3 * DaemonStoreLimits.maxChunkBytes + 17)

        let commitRequest = DaemonPayloadCommitRequest(
            uploadID: "01JUPLOAD0000000000000AB")
        #expect(try roundTrip(commitRequest) == commitRequest)
    }

    @Test("payload read flow round-trips chunk slicing")
    func payloadReadRoundTrip() throws {
        let request = DaemonPayloadReadRequest(
            handleID: "01JHANDLE00000000000000AB", chunkIndex: 1)
        #expect(try roundTrip(request) == request)

        let reply = DaemonPayloadReadReply(
            totalByteCount: DaemonStoreLimits.maxChunkBytes + 40,
            chunkIndex: 1,
            chunkCount: 2,
            bytes: Data(repeating: 0x42, count: 40),
            isFinal: true)
        #expect(try roundTrip(reply) == reply)
    }

    // MARK: Cursor

    @Test("reply cursor round-trips token availability and byte accounting")
    func cursorRoundTrip() throws {
        let first = DaemonReplyCursor(
            pageToken: nil, nextAvailable: true,
            accumulatedEncodedByteCount: DaemonStoreLimits
                .listReplyBudgetEncodedBytes)
        #expect(try roundTrip(first) == first)

        let next = DaemonReplyCursor(
            pageToken: "cursor-token-7", nextAvailable: false,
            accumulatedEncodedByteCount: 517_241)
        #expect(try roundTrip(next) == next)
    }

    // MARK: Mutation outcome semantics

    @Test("mutation stamp round-trips request id and epoch")
    func stampRoundTrip() throws {
        let stamp = DaemonMutationStamp(
            requestID: "01JMUTSTAMP0000000000000AB", expectedEpoch: 12)
        #expect(try roundTrip(stamp) == stamp)
    }

    @Test(
        "resolve outcome replies round-trip for every status",
        arguments: [
            (DaemonOutcomeStatus.committed, false),
            (DaemonOutcomeStatus.joined, true),
            (DaemonOutcomeStatus.outcomeUnknown, true),
        ])
    func resolveOutcomeRoundTrip(status: DaemonOutcomeStatus, nilResult: Bool)
        throws
    {
        let request = DaemonResolveOutcomeRequest(
            wikiID: Self.wikiID,
            stamp: DaemonMutationStamp(
                requestID: "01JMUTSTAMP0000000000000AB", expectedEpoch: 12),
            operation: DaemonStoreOperation.upsertPage.rawValue,
            payloadFingerprintSHA256Hex: Self.shaHex)
        #expect(try roundTrip(request) == request)

        let reply = DaemonResolveOutcomeReply(
            status: status,
            result: nilResult ? nil : Data("{}".utf8),
            message: status == .outcomeUnknown
                ? "no cached outcome for requestID" : nil)
        let decoded = try roundTrip(reply)
        #expect(decoded == reply)
        #expect(decoded.status == status)
    }

    // MARK: Session bootstrap mirrors

    @Test("bootstrap payload round-trips mirrors and strategy snapshot")
    func bootstrapRoundTrip() throws {
        let inputs = DaemonRegisteredExtractionInputs(claims: [
            DaemonRegisteredExtractionInputs.Claim(
                kind: "pdf", mimeTypes: ["application/pdf"],
                filenameExtensions: ["pdf"], wantsAgentCleanup: true),
            DaemonRegisteredExtractionInputs.Claim(
                kind: "docx", mimeTypes: [
                    "application/vnd.openxmlformats-officedocument"
                        + ".wordprocessingml.document",
                ],
                filenameExtensions: ["docx"], wantsAgentCleanup: false),
        ])
        let rendererClaims = [
            DaemonRendererSourceClaim(
                descriptorReference: "mermaid",
                displayName: "Mermaid diagram",
                canonicalMIMEType: "text/x-mermaid",
                mimeAliases: ["text/vnd.mermaid"],
                filenameExtensions: ["mmd", "mermaid"]),
            DaemonRendererSourceClaim(
                descriptorReference: "excalidraw",
                displayName: "Excalidraw drawing",
                canonicalMIMEType: "application/vnd.excalidraw+json",
                mimeAliases: [],
                filenameExtensions: ["excalidraw"]),
        ]
        let strategy = DaemonStrategySnapshot(
            name: "House style",
            instructions: "# Strategy\nKeep pages terse.",
            revision: 4,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_123))
        let bootstrap = DaemonStoreSessionBootstrap(
            registeredExtractionInputs: inputs,
            registeredRendererSourceTypes: rendererClaims,
            changeToken: "ct-0009",
            strategySnapshot: strategy)
        #expect(try roundTrip(bootstrap) == bootstrap)

        // Default strategy: nil snapshot mirrors getWikiStrategy()'s nil.
        let defaultBootstrap = DaemonStoreSessionBootstrap(
            registeredExtractionInputs: DaemonRegisteredExtractionInputs(
                claims: []),
            registeredRendererSourceTypes: [],
            changeToken: "ct-0000",
            strategySnapshot: nil)
        #expect(try roundTrip(defaultBootstrap) == defaultBootstrap)
    }

    // MARK: Exhaustive error contract

    @Test("every error case round-trips with associated values intact")
    func errorEnumRoundTripsEveryCase() throws {
        let summary = DaemonSourceSummary(
            id: "01JSOURCE000000000000000AB",
            filename: "paper.pdf",
            ext: "pdf",
            mimeType: "application/pdf",
            byteSize: 4_194_304,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_100),
            version: 3,
            externalItemKey: "ITEMKEY1",
            externalItemTitle: "A Paper",
            displayName: "The Paper",
            role: "primary")
        let blockers = DaemonDeletionBlockers(ordered: [
            DaemonProvenanceDeletionBlocker(
                sourceID: "01JSOURCE000000000000000AB",
                pageVersionID: "01JVERSION00000000000000AB",
                pageID: "01JPAGE0000000000000000AA"),
        ])
        let errors: [DaemonStoreError] = [
            .open("database path unreadable"),
            .sqlite(code: 13, message: "database or disk is full"),
            .notFound("01JPAGE0000000000000000AA"),
            .chatNotFound("01JCHAT00000000000000000A"),
            .sourceNotFound("01JSOURCE000000000000000AB"),
            .sourceVersionNotFound("01JSRCVER000000000000000A"),
            .sourceMarkdownVersionNotFound("01JMDVER000000000000000A"),
            .noProcessedMarkdown("01JSOURCE000000000000000AB"),
            .deletionRestricted(blockers),
            .invalidBookmarkRow(id: "row-17", reason: "orphan parent"),
            .invalidRendererEventID("not-an-event-id"),
            .unexpected("invariant violated"),
            .duplicateContent(summary),
            .duplicateURL(summary),
            .pageConflict(DaemonPageConflictDetail(
                pageID: "01JPAGE0000000000000000AA",
                expectedVersionID: "01JVERSION00000000000000AB",
                actualVersionID: "01JVERSION00000000000000CD")),
            .pageCreateConflict(DaemonPageCreateConflictDetail(
                pageID: "01JPAGE0000000000000000AA",
                title: "Meeting Notes",
                actualVersionID: nil)),
            .pageExpectedTargetMissing(DaemonPageExpectedTargetMissingDetail(
                pageID: nil,
                expectedHeadVersionID: "01JVERSION00000000000000AB",
                title: "Deleted Page")),
            .strategyRevisionConflict(DaemonStrategyConflictDetail(
                expectedRevision: 4,
                currentRevision: 5,
                currentStrategy: DaemonStrategySnapshot(
                    name: "House style",
                    instructions: "# Strategy",
                    revision: 5,
                    updatedAt: Date(timeIntervalSince1970: 1_800_000_200)))),
            .sourceMarkdownConflict(DaemonSourceMarkdownConflictDetail(
                sourceID: "01JSOURCE000000000000000AB",
                expectedHead: "01JMDVER000000000000000A",
                currentHead: "01JMDVER000000000000000B")),
            .daemonUnavailable("connection refused"),
            .outcomeUnknown("requestID evicted from the outcome cache"),
        ]

        let data = try JSONEncoder().encode(errors)
        let decoded = try JSONDecoder().decode([DaemonStoreError].self, from: data)
        #expect(decoded == errors)

        // Spot-check the fidelity-critical associated values explicitly.
        guard case .duplicateContent(let existing) = decoded[12] else {
            Issue.record("expected duplicateContent at index 12")
            return
        }
        #expect(existing == summary)
        guard case .sqlite(let code, let message) = decoded[1] else {
            Issue.record("expected sqlite at index 1")
            return
        }
        #expect(code == 13)
        #expect(message == "database or disk is full")
        guard case .deletionRestricted(let carried) = decoded[8] else {
            Issue.record("expected deletionRestricted at index 8")
            return
        }
        #expect(carried.ordered == blockers.ordered)
    }

    @Test("each CAS detail mirror round-trips standalone")
    func casDetailMirrorsRoundTrip() throws {
        let pageConflict = DaemonPageConflictDetail(
            pageID: "01JPAGE0000000000000000AA",
            expectedVersionID: "01JVERSION00000000000000AB",
            actualVersionID: nil)
        #expect(try roundTrip(pageConflict) == pageConflict)

        let createConflict = DaemonPageCreateConflictDetail(
            pageID: "01JPAGE0000000000000000AA",
            title: "Meeting Notes",
            actualVersionID: "01JVERSION00000000000000CD")
        #expect(try roundTrip(createConflict) == createConflict)

        let targetMissing = DaemonPageExpectedTargetMissingDetail(
            pageID: "01JPAGE0000000000000000AA",
            expectedHeadVersionID: "01JVERSION00000000000000AB",
            title: "Renamed Away")
        #expect(try roundTrip(targetMissing) == targetMissing)

        let strategyConflict = DaemonStrategyConflictDetail(
            expectedRevision: nil,
            currentRevision: 1,
            currentStrategy: nil)
        #expect(try roundTrip(strategyConflict) == strategyConflict)

        let markdownConflict = DaemonSourceMarkdownConflictDetail(
            sourceID: "01JSOURCE000000000000000AB",
            expectedHead: "01JMDVER000000000000000A",
            currentHead: nil)
        #expect(try roundTrip(markdownConflict) == markdownConflict)
    }

    // MARK: Store-family envelope

    @Test("store-family envelope round-trips a representative operation")
    func storeEnvelopeRoundTrip() throws {
        let stamp = DaemonMutationStamp(
            requestID: "01JMUTSTAMP0000000000000AB", expectedEpoch: 3)
        let storeRequest = DaemonStoreRequest(
            wikiID: Self.wikiID,
            operation: DaemonStoreOperation.listPages.rawValue,
            stamp: stamp,
            payload: Data("{\"cursor\":null}".utf8))
        let envelope = DaemonDomainRequest(
            requestID: "store-req-1",
            family: .store,
            operation: DaemonStoreOperation.listPages.rawValue,
            payload: try DaemonStoreWire.encode(storeRequest))

        let decodedEnvelope = try DaemonDomainWire.decodeRequest(
            try DaemonDomainWire.encode(envelope))
        #expect(decodedEnvelope.family == .store)
        let decodedStoreRequest = try DaemonStoreWire.decodeRequest(
            try #require(decodedEnvelope.payload))
        #expect(decodedStoreRequest == storeRequest)
        #expect(decodedStoreRequest.stamp == stamp)
    }

    @Test("store-family reply round-trips typed error and result bytes")
    func storeReplyEnvelopeRoundTrip() throws {
        let result = DaemonStoreReply(
            result: Data("{\"pages\":[]}".utf8), error: nil)
        let successEnvelope = DaemonDomainReply.success(
            requestID: "store-reply-1",
            family: .store,
            operation: DaemonStoreOperation.listPages.rawValue,
            payload: try DaemonStoreWire.encode(result))
        let decodedSuccess = try DaemonDomainWire.decodeReply(
            try DaemonStoreFrameSizing.encodeValidatedReply(successEnvelope))
        let decodedResult = try DaemonStoreWire.decodeReply(
            try #require(decodedSuccess.payload))
        #expect(decodedResult == result)
        #expect(decodedResult.error == nil)

        let failure = DaemonStoreReply(
            result: nil,
            error: .pageConflict(DaemonPageConflictDetail(
                pageID: "01JPAGE0000000000000000AA",
                expectedVersionID: "01JVERSION00000000000000AB",
                actualVersionID: "01JVERSION00000000000000CD")))
        let failureEnvelope = DaemonDomainReply.success(
            requestID: "store-reply-2",
            family: .store,
            operation: DaemonStoreOperation.appendPageVersion.rawValue,
            payload: try DaemonStoreWire.encode(failure))
        let decodedFailure = try DaemonStoreWire.decodeReply(
            try #require(try DaemonDomainWire.decodeReply(
                try DaemonStoreFrameSizing.encodeValidatedReply(failureEnvelope))
                .payload))
        #expect(decodedFailure == failure)
        guard case .pageConflict(let detail) = decodedFailure.error else {
            Issue.record("expected pageConflict")
            return
        }
        #expect(detail.actualVersionID == "01JVERSION00000000000000CD")
    }
}
#endif
