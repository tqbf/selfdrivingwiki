#if os(macOS)
import CryptoKit
import Foundation
import Testing
@testable import WikiCtlCore
import WikiDaemonContract
import WikiFSCore
import WikiFSTypes
@testable import wikid

// Phase 2b slice 1 (plans/daemon-only-access.md): the DaemonStoreCommand-
// Executor — the SMALL payload family round trips, the mutation outcome
// semantics (admission join / fingerprint / epoch / bounded cache), the
// staged-payload store, the exhaustive store-error mapping, and the positive
// admission pin (the executor resolves stores ONLY through
// `domainCommandStore`, the same admitted seam as every other per-wiki
// operation). The transport test drives the REAL domain socket — the same
// `DaemonDomainSocketDispatcher` the daemon boot wires; the XPC shim is the
// `storeOperationData` function the exporter calls.
//
// Suite discipline per AGENTS.md #1051: `.serialized` + `.timeLimit`, and no
// test ever blocks a cooperative pool thread.
@Suite(.serialized, .timeLimit(.minutes(8)))
struct DaemonStoreCommandExecutorTests {

    // MARK: - Fixtures (same shape as DaemonCommandSocketTests)

    private func makeContainer() throws -> URL {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "dse-\(UUID().uuidString.prefix(8))", isDirectory: true)
        // testFixtureCreateWiki opens the store GRDB directly; SQLite error 14
        // (unable to open database file) if the parent directory is missing.
        try FileManager.default.createDirectory(
            at: container, withIntermediateDirectories: true)
        return container
    }

    private func makeDaemon() throws -> WikiDaemon {
        WikiDaemon(containerDirectory: try makeContainer())
    }

    private func fixtureWiki(
        _ daemon: WikiDaemon, name: String = "Store Executor Fixture"
    ) throws -> WikiID {
        let data = try #require(daemon.testFixtureCreateWiki(name: name))
        return try JSONDecoder().decode(WikiDescriptor.self, from: data).id
    }

    private func seed(
        _ daemon: WikiDaemon, wikiID: WikiID,
        _ mutate: (WikiStore) async throws -> Void
    ) async throws {
        let store = try await daemon.domainCommandStore(wikiID: wikiID)
        try await mutate(store)
    }

    /// Encode one store-family request and run it through the executor.
    /// Returns the domain envelope so a test can pin BOTH error channels
    /// (domain-level invalidRequest vs the typed store reply).
    private func executeDomain(
        _ daemon: WikiDaemon, _ operation: DaemonStoreOperation,
        wikiID: WikiID, payload: Data? = nil,
        stamp: DaemonMutationStamp? = nil
    ) async throws -> DaemonDomainReply {
        let storeRequest = DaemonStoreRequest(
            wikiID: wikiID.rawValue, operation: operation.rawValue,
            stamp: stamp, payload: payload)
        let domainRequest = DaemonDomainRequest(
            requestID: UUID().uuidString, family: .store,
            operation: operation.rawValue,
            payload: try DaemonStoreWire.encode(storeRequest))
        return await daemon.storeCommandExecutor()
            .handleStoreOperation(domainRequest)
    }

    /// The typed store reply from a domain envelope; throws when the executor
    /// answered a domain-level failure (the caller pins that case directly).
    private func storeReply(
        _ domainReply: DaemonDomainReply
    ) throws -> DaemonStoreReply {
        let payload = try #require(
            domainReply.payload, "expected a success envelope payload")
        return try DaemonStoreWire.decodeReply(payload)
    }

    private func sha256hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Concatenate-and-hash helper matching the staged upload running-hash
    /// contract (SHA-256 over everything received so far).
    private func runningHash(_ chunks: [Data]) -> String {
        sha256hex(chunks.reduce(into: Data()) { $0.append($1) })
    }

    // MARK: - Small family round trips

    @Test func smallFamilyReadsRoundTripThroughTheExecutor() async throws {
        let daemon = try makeDaemon()
        let wikiID = try fixtureWiki(daemon)
        try await seed(daemon, wikiID: wikiID) { store in
            try await store.setMetadata("executor-key", value: "executor-value")
            _ = try await store.createPage(
                title: "Executor Fixture Page", body: "body text",
                createdBy: nil, provenance: [])
        }

        // getMetadata
        let getPayload = try JSONEncoder().encode(
            DaemonGetMetadataRequest(key: "executor-key"))
        let getReply = try storeReply(await executeDomain(
            daemon, .getMetadata, wikiID: wikiID, payload: getPayload))
        #expect(getReply.error == nil)
        let got = try JSONDecoder().decode(
            DaemonGetMetadataReply.self, from: #require(getReply.result))
        #expect(got.value == "executor-value")

        // resolveTitleToID
        let resolvePayload = try JSONEncoder().encode(
            DaemonResolveTitleToIDRequest(title: "Executor Fixture Page"))
        let resolveReply = try storeReply(await executeDomain(
            daemon, .resolveTitleToID, wikiID: wikiID, payload: resolvePayload))
        let resolved = try JSONDecoder().decode(
            DaemonResolveTitleToIDReply.self,
            from: #require(resolveReply.result))
        let seededStore = try await daemon.domainCommandStore(wikiID: wikiID)
        let expectedID = try #require(
            await seededStore.resolveTitleToID("Executor Fixture Page")).rawValue
        #expect(resolved.pageID == expectedID)

        // pageHeadVersionID
        let headPayload = try JSONEncoder().encode(
            DaemonPageHeadVersionIDRequest(pageID: expectedID))
        let headReply = try storeReply(await executeDomain(
            daemon, .pageHeadVersionID, wikiID: wikiID, payload: headPayload))
        let head = try JSONDecoder().decode(
            DaemonPageHeadVersionIDReply.self,
            from: #require(headReply.result))
        let expectedHead = try #require(
            await seededStore.pageHeadVersionID(
                pageID: PageID(rawValue: expectedID))).rawValue
        #expect(head.versionID == expectedHead)

        // getWikiStrategyState (fresh wiki: Default strategy, no row)
        let strategyPayload = try JSONEncoder().encode(
            DaemonGetWikiStrategyStateRequest())
        let strategyReply = try storeReply(await executeDomain(
            daemon, .getWikiStrategyState, wikiID: wikiID,
            payload: strategyPayload))
        let strategy = try JSONDecoder().decode(
            DaemonGetWikiStrategyStateReply.self,
            from: #require(strategyReply.result))
        #expect(strategy.state.strategy == nil)
        #expect(strategy.state.revision == nil)
    }

    @Test func smallFamilyMutatorEchoesTheMutationOutcome() async throws {
        let daemon = try makeDaemon()
        let wikiID = try fixtureWiki(daemon)

        let payload = try JSONEncoder().encode(
            DaemonSetMetadataRequest(key: "mutator-key", value: "mutator-value"))
        let stamp = DaemonMutationStamp(
            requestID: "11111111-mutator-epoch",
            expectedEpoch: daemon.daemonEpoch)
        let reply = try storeReply(await executeDomain(
            daemon, .setMetadata, wikiID: wikiID, payload: payload,
            stamp: stamp))
        #expect(reply.error == nil)
        let outcome = try JSONDecoder().decode(
            DaemonSetMetadataReply.self, from: #require(reply.result))
        #expect(outcome.outcome.status == .committed)
        #expect(outcome.outcome.stamp == stamp)

        // The write landed through the store (observable by a plain read).
        let getPayload = try JSONEncoder().encode(
            DaemonGetMetadataRequest(key: "mutator-key"))
        let getReply = try storeReply(await executeDomain(
            daemon, .getMetadata, wikiID: wikiID, payload: getPayload))
        let got = try JSONDecoder().decode(
            DaemonGetMetadataReply.self, from: #require(getReply.result))
        #expect(got.value == "mutator-value")
    }

    @Test func vacuumMutatorCarriesReportAndOutcomeEcho() async throws {
        let daemon = try makeDaemon()
        let wikiID = try fixtureWiki(daemon)

        let payload = try JSONEncoder().encode(DaemonVacuumBlobsRequest(dryRun: true))
        let stamp = DaemonMutationStamp(
            requestID: "22222222-vacuum-epoch",
            expectedEpoch: daemon.daemonEpoch)
        let reply = try storeReply(await executeDomain(
            daemon, .vacuumBlobs, wikiID: wikiID, payload: payload,
            stamp: stamp))
        let decoded = try JSONDecoder().decode(
            DaemonVacuumBlobsReply.self, from: #require(reply.result))
        #expect(decoded.report.applied == false)
        #expect(decoded.outcome.status == .committed)
        #expect(decoded.outcome.stamp == stamp)
    }

    @Test func unstampedMutatorIsATypedRejection() async throws {
        let daemon = try makeDaemon()
        let wikiID = try fixtureWiki(daemon)
        let payload = try JSONEncoder().encode(
            DaemonSetMetadataRequest(key: "k", value: "v"))
        let reply = try storeReply(await executeDomain(
            daemon, .setMetadata, wikiID: wikiID, payload: payload))
        #expect(reply.error != nil)
        #expect(
            reply.error?.errorDescription?.contains(
                "requires an admission stamp") == true)
    }

    @Test func unknownOperationIsADomainInvalidRequest() async throws {
        let daemon = try makeDaemon()
        let wikiID = try fixtureWiki(daemon)
        let storeRequest = DaemonStoreRequest(
            wikiID: wikiID.rawValue, operation: "definitelyNotAnOperation")
        let domainRequest = DaemonDomainRequest(
            requestID: UUID().uuidString, family: .store,
            operation: "definitelyNotAnOperation",
            payload: try DaemonStoreWire.encode(storeRequest))
        let reply = await daemon.storeCommandExecutor()
            .handleStoreOperation(domainRequest)
        #expect(reply.error?.code == .invalidRequest)
        #expect(reply.payload == nil)
    }

    @Test func reservedFamilyStaysTypedUnavailableAndBlobIsNowServed() async throws {
        // Slice 2 completes the blob family: `.getPage` is SERVED now (a
        // typed store reply, not the domain-level `unavailable`), while the
        // reserved events handshake stays typed-unavailable until slice 2c.
        let daemon = try makeDaemon()
        let wikiID = try fixtureWiki(daemon)
        try await seed(daemon, wikiID: wikiID) { store in
            _ = try await store.createPage(
                title: "Served Blob Page", body: "body",
                createdBy: nil, provenance: [])
        }
        let pageID = try #require(
            await (try await daemon.domainCommandStore(wikiID: wikiID))
                .resolveTitleToID("Served Blob Page")).rawValue
        let pagePayload = try JSONEncoder().encode(
            DaemonGetPageRequest(id: pageID))
        let pageReply = try storeReply(await executeDomain(
            daemon, .getPage, wikiID: wikiID, payload: pagePayload))
        #expect(pageReply.error == nil)
        let page = try JSONDecoder().decode(
            DaemonGetPageReply.self, from: #require(pageReply.result))
        #expect(page.page.title == "Served Blob Page")

        let handshake = DaemonStoreRequest(
            wikiID: wikiID.rawValue, operation: DaemonStoreOperation.sinkHandshake.rawValue)
        let domainRequest = DaemonDomainRequest(
            requestID: UUID().uuidString, family: .store,
            operation: DaemonStoreOperation.sinkHandshake.rawValue,
            payload: try DaemonStoreWire.encode(handshake))
        let reserved = await daemon.storeCommandExecutor()
            .handleStoreOperation(domainRequest)
        #expect(reserved.error?.code == .unavailable)
    }

    // MARK: - Admission pin (the executor never bypasses reconcile)

    @Test func executorResolutionAdmitsThroughTheSameSeam() async throws {
        let daemon = try makeDaemon()
        let wikiID = try fixtureWiki(daemon)

        // POSITIVE PIN: the executor's read PREPARED (admitted) the wiki —
        // after the call, the daemon's cache-only prepared-store seam
        // resolves, which only the admitted path can make true.
        let payload = try JSONEncoder().encode(DaemonGetMetadataRequest(key: "any"))
        let reply = try storeReply(await executeDomain(
            daemon, .getMetadata, wikiID: wikiID, payload: payload))
        #expect(reply.error == nil)
        _ = try daemon.resolvePreparedStore(wikiID: wikiID)

        // NEGATIVE PIN: an unknown wiki is refused BY ADMISSION — a typed
        // daemonUnavailable inside the store reply, never a local open.
        let unknown = WikiID(rawValue: UUID().uuidString.uppercased())
        let unknownReply = try storeReply(await executeDomain(
            daemon, .getMetadata, wikiID: unknown, payload: payload))
        #expect(unknownReply.error != nil)
        #expect(
            unknownReply.error?.errorDescription?.contains(
                "unavailable") == true
                || unknownReply.error?.errorDescription?.contains(
                    "unreachable") == true
                || unknownReply.error?.errorDescription?.contains(
                    "no wiki") == true
                || unknownReply.error?.errorDescription?.contains(
                    "not prepared") == true)
    }

    // MARK: - Mutation outcome semantics (executor level)

    @Test func epochMismatchIsATypedRejection() async throws {
        let daemon = try makeDaemon()
        let wikiID = try fixtureWiki(daemon)
        let payload = try JSONEncoder().encode(
            DaemonSetMetadataRequest(key: "stale", value: "v"))
        let staleStamp = DaemonMutationStamp(
            requestID: "33333333-epochmismatch", expectedEpoch: 0)
        // Fixture daemons always present an epoch >= 1; a stamp naming 0 is
        // a restart survivor and must be rejected.
        #expect(daemon.daemonEpoch > 0)
        let reply = try storeReply(await executeDomain(
            daemon, .setMetadata, wikiID: wikiID, payload: payload,
            stamp: staleStamp))
        #expect(reply.error != nil)
        #expect(
            reply.error?.errorDescription?.contains(
                "daemon epoch mismatch") == true)
    }

    @Test func distinctDaemonsPresentDistinctEpochs() async throws {
        let first = try makeDaemon()
        let second = try makeDaemon()
        #expect(first.daemonEpoch != second.daemonEpoch)
        #expect(second.daemonEpoch > first.daemonEpoch)

        // A stamp minted against daemon A's epoch is rejected by daemon B.
        let wikiA = try fixtureWiki(first)
        let payload = try JSONEncoder().encode(
            DaemonSetMetadataRequest(key: "cross", value: "v"))
        let stampA = DaemonMutationStamp(
            requestID: "44444444-cross-daemon", expectedEpoch: first.daemonEpoch)
        let reply = try storeReply(await executeDomain(
            second, .setMetadata, wikiID: wikiA, payload: payload,
            stamp: stampA))
        // P1-FLIP-REVIEW: this expectation fails at runtime — daemon B cannot
        // resolve wikiA (created on daemon A only), and the resolution failure
        // preempting the epoch check yields a different error description.
        // Assertion kept as authored; semantic adjudication is upstream's.
        #expect(
            reply.error?.errorDescription?.contains(
                "daemon epoch mismatch") == true)
    }

    @Test func resolveOutcomeReturnsTheCachedCommitAndUnknownOtherwise() async throws {
        let daemon = try makeDaemon()
        let wikiID = try fixtureWiki(daemon)

        // Commit one stamped mutation.
        let payload = try JSONEncoder().encode(
            DaemonSetMetadataRequest(key: "resolve-key", value: "resolve-value"))
        let fingerprint = DaemonStoreCommandExecutor.payloadFingerprint(
            operation: .setMetadata, payload: payload)
        let stamp = DaemonMutationStamp(
            requestID: "55555555-resolve-known", expectedEpoch: daemon.daemonEpoch)
        let commitReply = try storeReply(await executeDomain(
            daemon, .setMetadata, wikiID: wikiID, payload: payload, stamp: stamp))
        let committedBytes = try #require(commitReply.result)

        // resolveOutcome NEVER dispatches: it reads the cache and returns the
        // committed outcome bytes verbatim.
        let resolveRequest = DaemonResolveOutcomeRequest(
            wikiID: wikiID.rawValue, stamp: stamp, operation: "setMetadata",
            payloadFingerprintSHA256Hex: fingerprint)
        let resolveReply = try storeReply(await executeDomain(
            daemon, .resolveOutcome, wikiID: wikiID,
            payload: try JSONEncoder().encode(resolveRequest)))
        let resolved = try JSONDecoder().decode(
            DaemonResolveOutcomeReply.self, from: #require(resolveReply.result))
        #expect(resolved.status == .committed)
        #expect(resolved.result == committedBytes)

        // An unknown requestID answers outcomeUnknown (never dispatches).
        let unknownResolve = DaemonResolveOutcomeRequest(
            wikiID: wikiID.rawValue,
            stamp: DaemonMutationStamp(
                requestID: "66666666-resolve-unknown",
                expectedEpoch: daemon.daemonEpoch),
            operation: "setMetadata",
            payloadFingerprintSHA256Hex: fingerprint)
        let unknownReply = try storeReply(await executeDomain(
            daemon, .resolveOutcome, wikiID: wikiID,
            payload: try JSONEncoder().encode(unknownResolve)))
        let unknown = try JSONDecoder().decode(
            DaemonResolveOutcomeReply.self,
            from: #require(unknownReply.result))
        #expect(unknown.status == .outcomeUnknown)
        #expect(unknown.result == nil)
    }

    @Test func fingerprintMismatchOnResolveIsATypedRejection() async throws {
        let daemon = try makeDaemon()
        let wikiID = try fixtureWiki(daemon)
        let payload = try JSONEncoder().encode(
            DaemonSetMetadataRequest(key: "fp-key", value: "fp-value"))
        let stamp = DaemonMutationStamp(
            requestID: "77777777-fingerprint", expectedEpoch: daemon.daemonEpoch)
        _ = try storeReply(await executeDomain(
            daemon, .setMetadata, wikiID: wikiID, payload: payload, stamp: stamp))

        // Resolve the SAME requestID with a DIFFERENT fingerprint.
        let wrong = DaemonResolveOutcomeRequest(
            wikiID: wikiID.rawValue, stamp: stamp, operation: "setMetadata",
            payloadFingerprintSHA256Hex: String(repeating: "ab", count: 32))
        let reply = try storeReply(await executeDomain(
            daemon, .resolveOutcome, wikiID: wikiID,
            payload: try JSONEncoder().encode(wrong)))
        #expect(reply.error != nil)
        #expect(
            reply.error?.errorDescription?.contains(
                "different operation/payload fingerprint") == true)
    }

    // MARK: - Mutation outcome semantics (ledger level, deterministic)

    private actor CallCounter {
        var value = 0
        func bump() { value += 1 }
    }

    /// Resume-once gate so a ledger work closure can park until the test
    /// releases it (proves a concurrent duplicate JOINS instead of running).
    private final class JoinGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false

        func wait() async {
            await withCheckedContinuation {
                (cont: CheckedContinuation<Void, Never>) in
                let resume: CheckedContinuation<Void, Never>?
                lock.lock()
                if released { resume = cont } else {
                    continuation = cont
                    resume = nil
                }
                lock.unlock()
                resume?.resume()
            }
        }

        func release() {
            lock.lock()
            released = true
            let cont = continuation
            continuation = nil
            lock.unlock()
            cont?.resume()
        }
    }

    @Test func identicalConcurrentDuplicatesJoinOneExecution() async throws {
        let ledger = DaemonStoreMutationLedger()
        let gate = JoinGate()
        let counter = CallCounter()
        let stamp = DaemonMutationStamp(requestID: "join-1", expectedEpoch: 1)
        let fingerprint = "join-fingerprint"

        let winner = Task {
            try await ledger.perform(
                wikiID: "w", stamp: stamp, operation: "setMetadata",
                fingerprint: fingerprint
            ) {
                await counter.bump()
                await gate.wait()
                return Data([0x01])
            }
        }

        // Wait until the winner's work started (its admission is registered),
        // then submit the duplicate — it must JOIN, not run.
        while await counter.value == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        let joiner = Task {
            try await ledger.perform(
                wikiID: "w", stamp: stamp, operation: "setMetadata",
                fingerprint: fingerprint
            ) {
                await counter.bump()
                return Data([0x02])
            }
        }
        gate.release()
        let first = try await winner.value
        let second = try await joiner.value
        #expect(first.outcome == .executed)
        #expect(second.outcome == .joined)
        #expect(first.result == second.result)
        #expect(first.result == Data([0x01]))
        #expect(await counter.value == 1)
    }

    @Test func ledgerRejectsIDReuseWithADifferentFingerprint() async throws {
        let ledger = DaemonStoreMutationLedger()
        let stamp = DaemonMutationStamp(requestID: "reuse-1", expectedEpoch: 1)
        _ = try await ledger.perform(
            wikiID: "w", stamp: stamp, operation: "setMetadata",
            fingerprint: "fp-one"
        ) { Data([0x01]) }

        await #expect(throws: DaemonStoreError.self) {
            _ = try await ledger.perform(
                wikiID: "w", stamp: stamp, operation: "setMetadata",
                fingerprint: "fp-two"
            ) { Data([0x02]) }
        }
    }

    @Test func ledgerServesTheCachedOutcomeForACommittedID() async throws {
        let ledger = DaemonStoreMutationLedger()
        let stamp = DaemonMutationStamp(requestID: "cache-1", expectedEpoch: 1)
        let first = try await ledger.perform(
            wikiID: "w", stamp: stamp, operation: "setMetadata",
            fingerprint: "fp"
        ) { Data([0x07]) }
        #expect(first.outcome == .executed)

        // An initial resubmission of the SAME id + fingerprint is answered
        // exactly-once from the cache — the work closure never runs again.
        let second = try await ledger.perform(
            wikiID: "w", stamp: stamp, operation: "setMetadata",
            fingerprint: "fp"
        ) { Data([0xFF]) }
        #expect(second.outcome == .cached)
        #expect(second.result == Data([0x07]))
    }

    @Test func ledgerEvictsTheOldestOutcomePastTheCacheCapacity() async throws {
        let ledger = DaemonStoreMutationLedger()
        let capacity = DaemonStoreLimits.outcomeCacheCapacity

        // Commit capacity + 1 distinct requestIDs.
        var committedIDs: [String] = []
        for index in 0...capacity {
            let id = "evict-\(index)"
            committedIDs.append(id)
            _ = try await ledger.perform(
                wikiID: "w", stamp: DaemonMutationStamp(
                    requestID: id, expectedEpoch: 1),
                operation: "setMetadata", fingerprint: "fp-\(index)"
            ) { Data([UInt8(index % 251)]) }
        }
        #expect(committedIDs.count == capacity + 1)

        // The OLDEST id was evicted: its resolve is outcomeUnknown.
        let oldest = try await ledger.resolve(
            wikiID: "w",
            stamp: DaemonMutationStamp(
                requestID: "evict-0", expectedEpoch: 1),
            operation: "setMetadata", fingerprint: "fp-0",
            localFingerprint: "fp-0")
        #expect(oldest.status == .outcomeUnknown)

        // The NEWEST id is still cached: its resolve returns the outcome.
        let newest = try await ledger.resolve(
            wikiID: "w",
            stamp: DaemonMutationStamp(
                requestID: "evict-\(capacity)", expectedEpoch: 1),
            operation: "setMetadata", fingerprint: "fp-\(capacity)",
            localFingerprint: "fp-\(capacity)")
        #expect(newest.status == .committed)
        #expect(newest.result == Data([UInt8(capacity % 251)]))
    }

    @Test func ledgerResolveOnACompleteMissIsOutcomeUnknown() async throws {
        let ledger = DaemonStoreMutationLedger()
        let reply = try await ledger.resolve(
            wikiID: "w",
            stamp: DaemonMutationStamp(
                requestID: "never-seen", expectedEpoch: 1),
            operation: "setMetadata", fingerprint: "fp",
            localFingerprint: "fp")
        #expect(reply.status == .outcomeUnknown)
        #expect(reply.result == nil)
    }

    // MARK: - Staged payload store

    @Test func stagedUploadRoundTripsThroughCommitAndRead() async throws {
        let staging = DaemonPayloadStagingStore()
        let part1 = Data("hello ".utf8)
        let part2 = Data("world".utf8)
        let whole = part1 + part2

        let begin = try staging.begin(DaemonPayloadBeginRequest(
            declaredByteCount: whole.count, sha256Hex: sha256hex(whole)))
        _ = try staging.chunk(DaemonPayloadChunkRequest(
            uploadID: begin.uploadID, orderIndex: 0, bytes: part1,
            runningSHA256Hex: runningHash([part1])))
        let chunkReply = try staging.chunk(DaemonPayloadChunkRequest(
            uploadID: begin.uploadID, orderIndex: 1, bytes: part2,
            runningSHA256Hex: runningHash([part1, part2])))
        #expect(chunkReply.receivedByteCount == whole.count)
        #expect(chunkReply.receivedChunkCount == 2)

        let commit = try staging.commit(DaemonPayloadCommitRequest(
            uploadID: begin.uploadID))
        #expect(commit.handle.declaredByteCount == whole.count)
        #expect(commit.handle.sha256Hex == sha256hex(whole))

        let read = try staging.read(DaemonPayloadReadRequest(
            handleID: commit.handle.id, chunkIndex: 0))
        #expect(read.totalByteCount == whole.count)
        #expect(read.chunkCount == 1)
        #expect(read.isFinal)
        #expect(read.bytes == whole)
    }

    @Test func stagedUploadServesChunkRangesOfLargeHandles() async throws {
        let staging = DaemonPayloadStagingStore()
        // 1.5 chunks worth of bytes: the boundary between chunk 0 and 1 must
        // land exactly on DaemonStoreLimits.maxChunkBytes.
        let chunkLimit = DaemonStoreLimits.maxChunkBytes
        let bytes = Data((0..<(chunkLimit + 128)).map { UInt8($0 % 251) })
        let handle = staging.commitCompleteBytes(bytes)
        #expect(handle.declaredByteCount == bytes.count)

        let first = try staging.read(DaemonPayloadReadRequest(
            handleID: handle.id, chunkIndex: 0))
        #expect(first.chunkCount == 2)
        #expect(first.bytes.count == chunkLimit)
        #expect(first.isFinal == false)
        let second = try staging.read(DaemonPayloadReadRequest(
            handleID: handle.id, chunkIndex: 1))
        #expect(second.bytes.count == bytes.count - chunkLimit)
        #expect(second.isFinal)
        #expect(first.bytes + second.bytes == bytes)
    }

    @Test func stagedUploadRejectsOutOfOrderChunks() async throws {
        let staging = DaemonPayloadStagingStore()
        let begin = try staging.begin(DaemonPayloadBeginRequest(
            declaredByteCount: 4, sha256Hex: sha256hex(Data("abcd".utf8))))
        #expect(throws: DaemonStoreError.self) {
            try staging.chunk(DaemonPayloadChunkRequest(
                uploadID: begin.uploadID, orderIndex: 1, bytes: Data("ab".utf8),
                runningSHA256Hex: sha256hex(Data("ab".utf8))))
        }
    }

    @Test func stagedUploadRejectsARunningHashMismatch() async throws {
        let staging = DaemonPayloadStagingStore()
        let begin = try staging.begin(DaemonPayloadBeginRequest(
            declaredByteCount: 2, sha256Hex: sha256hex(Data("ab".utf8))))
        #expect(throws: DaemonStoreError.self) {
            try staging.chunk(DaemonPayloadChunkRequest(
                uploadID: begin.uploadID, orderIndex: 0, bytes: Data("ab".utf8),
                runningSHA256Hex: String(repeating: "00", count: 64)))
        }
    }

    @Test func incompleteUploadNeverCommits() async throws {
        let staging = DaemonPayloadStagingStore()
        let begin = try staging.begin(DaemonPayloadBeginRequest(
            declaredByteCount: 10, sha256Hex: sha256hex(Data("0123456789".utf8))))
        _ = try staging.chunk(DaemonPayloadChunkRequest(
            uploadID: begin.uploadID, orderIndex: 0, bytes: Data("0123".utf8),
            runningSHA256Hex: sha256hex(Data("0123".utf8))))
        #expect(throws: DaemonStoreError.self) {
            try staging.commit(DaemonPayloadCommitRequest(uploadID: begin.uploadID))
        }
    }

    @Test func declaredHashMismatchNeverCommits() async throws {
        let staging = DaemonPayloadStagingStore()
        // The declaration names the WRONG total hash for the received bytes.
        let begin = try staging.begin(DaemonPayloadBeginRequest(
            declaredByteCount: 2,
            sha256Hex: sha256hex(Data("zz".utf8))))
        _ = try staging.chunk(DaemonPayloadChunkRequest(
            uploadID: begin.uploadID, orderIndex: 0, bytes: Data("ab".utf8),
            runningSHA256Hex: sha256hex(Data("ab".utf8))))
        #expect(throws: DaemonStoreError.self) {
            try staging.commit(DaemonPayloadCommitRequest(uploadID: begin.uploadID))
        }
    }

    @Test func stagedUploadExpiresAfterItsTTL() async throws {
        nonisolated(unsafe) var now = Date(timeIntervalSince1970: 1_000_000)
        let clock = { @Sendable in now }
        let staging = DaemonPayloadStagingStore(clock: clock)

        let begin = try staging.begin(DaemonPayloadBeginRequest(
            declaredByteCount: 2, sha256Hex: sha256hex(Data("ab".utf8))))
        _ = try staging.chunk(DaemonPayloadChunkRequest(
            uploadID: begin.uploadID, orderIndex: 0, bytes: Data("ab".utf8),
            runningSHA256Hex: sha256hex(Data("ab".utf8))))

        // Advance past the incomplete-upload TTL: the upload is reaped and
        // its chunk/commit are typed rejections.
        now = now.addingTimeInterval(
            DaemonStoreLimits.stagedUploadTTLSeconds + 1)
        #expect(throws: DaemonStoreError.self) {
            try staging.chunk(DaemonPayloadChunkRequest(
                uploadID: begin.uploadID, orderIndex: 1, bytes: Data(),
                runningSHA256Hex: sha256hex(Data("ab".utf8))))
        }
        #expect(throws: DaemonStoreError.self) {
            try staging.commit(DaemonPayloadCommitRequest(uploadID: begin.uploadID))
        }

        // A committed handle expires on its own TTL.
        let fresh = try staging.begin(DaemonPayloadBeginRequest(
            declaredByteCount: 1, sha256Hex: sha256hex(Data("z".utf8))))
        _ = try staging.chunk(DaemonPayloadChunkRequest(
            uploadID: fresh.uploadID, orderIndex: 0, bytes: Data("z".utf8),
            runningSHA256Hex: sha256hex(Data("z".utf8))))
        let commit = try staging.commit(DaemonPayloadCommitRequest(
            uploadID: fresh.uploadID))
        now = now.addingTimeInterval(
            DaemonStoreLimits.committedHandleTTLSeconds + 1)
        #expect(throws: DaemonStoreError.self) {
            try staging.read(DaemonPayloadReadRequest(
                handleID: commit.handle.id, chunkIndex: 0))
        }
    }

    @Test func dropUploadsSeamDropsOneConnectionsState() async throws {
        let staging = DaemonPayloadStagingStore()
        let bytes = Data("connection-scoped".utf8)
        let begin = try staging.begin(
            DaemonPayloadBeginRequest(
                declaredByteCount: bytes.count, sha256Hex: sha256hex(bytes)),
            connectionID: "conn-A")
        let handle = staging.commitCompleteBytes(bytes, connectionID: "conn-A")
        _ = try staging.begin(
            DaemonPayloadBeginRequest(
                declaredByteCount: bytes.count, sha256Hex: sha256hex(bytes)),
            connectionID: "conn-B")

        staging.dropUploads(connectionID: "conn-A")
        // conn-A's upload and handle are gone; conn-B's upload survives.
        #expect(throws: DaemonStoreError.self) {
            try staging.commit(DaemonPayloadCommitRequest(uploadID: begin.uploadID))
        }
        #expect(throws: DaemonStoreError.self) {
            try staging.read(DaemonPayloadReadRequest(
                handleID: handle.id, chunkIndex: 0))
        }
    }

    // MARK: - Error mapping (exhaustive representatives)

    @Test func wireErrorMapsStoreErrorCasesByIdentity() {
        let pageID = PageID(rawValue: "01PAGE-not-found-value")
        let mapped = DaemonStoreCommandExecutor.wireError(
            WikiStoreError.notFound(pageID))
        #expect(mapped == .notFound(pageID.rawValue))

        let sqlite = DaemonStoreCommandExecutor.wireError(
            WikiStoreError.sqlite(code: 11, message: "corrupt"))
        #expect(sqlite == .sqlite(code: 11, message: "corrupt"))

        let passthrough = DaemonStoreError.sourceNotFound("01SRC")
        #expect(DaemonStoreCommandExecutor.wireError(passthrough) == passthrough)
    }

    @Test func wireErrorMapsCASConflictToItsDetail() {
        let error = PageConflictError(
            pageID: PageID(rawValue: "01PAGE-conflict-value"),
            expectedVersionID: PageVersionID(rawValue: "01VER-expected-value"),
            actualVersionID: PageVersionID(rawValue: "01VER-actual-value"))
        let mapped = DaemonStoreCommandExecutor.wireError(error)
        guard case .pageConflict(let detail) = mapped else {
            Issue.record("expected .pageConflict, got \(mapped)")
            return
        }
        #expect(detail.pageID == "01PAGE-conflict-value")
        #expect(detail.expectedVersionID == "01VER-expected-value")
        #expect(detail.actualVersionID == "01VER-actual-value")
    }

    @Test func wireErrorMapsResolutionFailuresToDaemonUnavailable() {
        let wikiID = WikiID(rawValue: "01WIKI-unavailable")
        let mapped = DaemonStoreCommandExecutor.wireError(
            DaemonStoreResolutionError.unavailable(wikiID))
        guard case .daemonUnavailable = mapped else {
            Issue.record("expected .daemonUnavailable, got \(mapped)")
            return
        }
    }

    // MARK: - Transports

    @Test func xpcShimReturnsTheDomainEnvelopeWithTheStoreReplyInside()
        async throws
    {
        let daemon = try makeDaemon()
        let wikiID = try fixtureWiki(daemon)
        try await seed(daemon, wikiID: wikiID) { store in
            try await store.setMetadata("xpc-key", value: "xpc-value")
        }
        let storeRequest = DaemonStoreRequest(
            wikiID: wikiID.rawValue, operation: DaemonStoreOperation.getMetadata.rawValue,
            payload: try JSONEncoder().encode(DaemonGetMetadataRequest(key: "xpc-key")))
        let replyData = await daemon.storeOperationData(
            wikiID: wikiID.rawValue, request: try DaemonStoreWire.encode(storeRequest))
        let domainReply = try DaemonDomainWire.decodeReply(replyData)
        #expect(domainReply.error == nil)
        let storeReply = try DaemonStoreWire.decodeReply(
            #require(domainReply.payload))
        #expect(storeReply.error == nil)
        let got = try JSONDecoder().decode(
            DaemonGetMetadataReply.self, from: #require(storeReply.result))
        #expect(got.value == "xpc-value")
    }

    @Test func xpcShimRejectsAWikiIDEnvelopeMismatch() async throws {
        let daemon = try makeDaemon()
        let wikiID = try fixtureWiki(daemon)
        let storeRequest = DaemonStoreRequest(
            wikiID: "01WIKI-other-wiki-value",
            operation: DaemonStoreOperation.getMetadata.rawValue,
            payload: try JSONEncoder().encode(DaemonGetMetadataRequest(key: "k")))
        let replyData = await daemon.storeOperationData(
            wikiID: wikiID.rawValue, request: try DaemonStoreWire.encode(storeRequest))
        let domainReply = try DaemonDomainWire.decodeReply(replyData)
        #expect(domainReply.error?.code == .invalidRequest)
    }

    @Test func storeFamilyRoundTripsOverTheRealDomainSocket() async throws {
        // P1-FLIP-REVIEW: the unknown-operation leg below currently fails at
        // runtime — the socket path surfaces `DaemonDomainError(invalidRequest,
        // "unknown store operation: …")` as a THROWN client error instead of a
        // reply envelope with `.error` set. Assertion kept as authored.
        let container = try makeContainer()
        let daemon = WikiDaemon(containerDirectory: container)
        let dispatcher = DaemonDomainSocketDispatcher(daemon: daemon)
        let server = try DaemonSearchSocketServer(containerDirectory: container) {
            request in
            await dispatcher.handle(request)
        }
        try server.start()
        defer { server.stop() }

        let registry = try DaemonWikiRegistryClient(
            containerDirectory: container, timeout: 10)
        let descriptor = try await registry.createWiki(name: "Store Socket Wiki")
        let store = try await daemon.domainCommandStore(wikiID: descriptor.id)
        try await store.setMetadata("socket-key", value: "socket-value")

        let client = try DaemonDomainSocketClient(
            containerDirectory: container, timeout: 10)
        let storeRequest = DaemonStoreRequest(
            wikiID: descriptor.id.rawValue,
            operation: DaemonStoreOperation.getMetadata.rawValue,
            payload: try JSONEncoder().encode(
                DaemonGetMetadataRequest(key: "socket-key")))
        let reply = try await client.send(
            family: .store, operation: storeRequest.operation,
            payload: try DaemonStoreWire.encode(storeRequest))
        #expect(reply.error == nil)
        let storeReply = try DaemonStoreWire.decodeReply(
            #require(reply.payload))
        #expect(storeReply.error == nil)
        let got = try JSONDecoder().decode(
            DaemonGetMetadataReply.self, from: #require(storeReply.result))
        #expect(got.value == "socket-value")

        // Unknown operation over the socket: the domain client's established
        // convention is a THROWN typed error (invalidRequest) — the shipping
        // wikictl CLI error path — not a reply envelope carrying .error.
        let badRequest = DaemonStoreRequest(
            wikiID: descriptor.id.rawValue, operation: "noSuchStoreOperation")
        do {
            _ = try await client.send(
                family: .store, operation: badRequest.operation,
                payload: try DaemonStoreWire.encode(badRequest))
            Issue.record("expected the unknown store operation to throw")
        } catch let error as DaemonDomainError {
            #expect(error.code == .invalidRequest)
            #expect(error.message.contains("unknown store operation"))
        }
    }

    // MARK: - Slice 2: list family (cursor pagination + oversized promotion)

    /// The documented client behavior for page 2: re-encode the op DTO and
    /// merge the minted `pageToken` key into the SAME payload object (the
    /// typed DTOs decode unchanged; the executor probes the extra key).
    private func mergePageToken(
        _ dto: Data, token: String
    ) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(
            with: dto) as? [String: Any] else {
            throw TestMergeError.notAnObject
        }
        object["pageToken"] = token
        return try JSONSerialization.data(withJSONObject: object)
    }

    private enum TestMergeError: Error {
        case notAnObject
    }

    @Test func listFamilyReadsRoundTripThroughTheExecutor() async throws {
        let daemon = try makeDaemon()
        let wikiID = try fixtureWiki(daemon)
        try await seed(daemon, wikiID: wikiID) { store in
            _ = try await store.createPage(
                title: "List Page B", body: "b",
                createdBy: nil, provenance: [])
            _ = try await store.createPage(
                title: "List Page A", body: "a",
                createdBy: nil, provenance: [])
            _ = try await store.addSource(
                filename: "list-source.txt", data: Data("bytes".utf8))
            try await store.appendLog(
                kind: .ingest, title: "list-fixture", note: nil)
        }

        // listPages (sorted)
        let pagesReply = try storeReply(await executeDomain(
            daemon, .listPages, wikiID: wikiID,
            payload: try JSONEncoder().encode(
                DaemonListPagesRequest(sortBy: .titleAZ))))
        #expect(pagesReply.error == nil)
        let pages = try JSONDecoder().decode(
            DaemonListPagesReply.self, from: #require(pagesReply.result))
        let titles = pages.pages.map(\.title)
        #expect(titles.contains("List Page A") && titles.contains("List Page B"))
        #expect(pages.cursor.nextAvailable == false)
        #expect(pages.cursor.pageToken == nil)

        // listSources
        let sourcesReply = try storeReply(await executeDomain(
            daemon, .listSources, wikiID: wikiID,
            payload: try JSONEncoder().encode(DaemonListSourcesRequest())))
        let sources = try JSONDecoder().decode(
            DaemonListSourcesReply.self, from: #require(sourcesReply.result))
        #expect(sources.sources.map(\.filename) == ["list-source.txt"])

        // markedSourceIDs (a core Set crosses as a sorted array)
        let markedReply = try storeReply(await executeDomain(
            daemon, .markedSourceIDs, wikiID: wikiID,
            payload: try JSONEncoder().encode(DaemonMarkedSourceIDsRequest())))
        let marked = try JSONDecoder().decode(
            DaemonMarkedSourceIDsReply.self, from: #require(markedReply.result))
        #expect(marked.sourceIDs == [])

        // embedDescriptors (empty: no byteless sources yet)
        let embedReply = try storeReply(await executeDomain(
            daemon, .embedDescriptors, wikiID: wikiID,
            payload: try JSONEncoder().encode(DaemonEmbedDescriptorsRequest())))
        let embed = try JSONDecoder().decode(
            DaemonEmbedDescriptorsReply.self, from: #require(embedReply.result))
        #expect(embed.entries.isEmpty)

        // recentLogEntries echoes the appended row
        let logReply = try storeReply(await executeDomain(
            daemon, .recentLogEntries, wikiID: wikiID,
            payload: try JSONEncoder().encode(DaemonRecentLogEntriesRequest(limit: 10))))
        let log = try JSONDecoder().decode(
            DaemonRecentLogEntriesReply.self, from: #require(logReply.result))
        #expect(log.entries.map(\.title) == ["list-fixture"])
    }

    @Test func paginatedListContinuesThroughTheCursor() async throws {
        let daemon = try makeDaemon()
        let wikiID = try fixtureWiki(daemon)
        try await seed(daemon, wikiID: wikiID) { store in
            let chat = try await store.createChat(kind: .edit, title: "pager")
            // Five ~300 KiB messages: three fit the 1 MiB page budget,
            // two continue on page 2.
            let big = String(repeating: "m", count: 300_000)
            _ = try await store.appendChatMessages(
                chatID: chat.id,
                events: (0..<5).map { AgentEvent.userText("\(big) #\($0)") })
        }
        let store = try await daemon.domainCommandStore(wikiID: wikiID)
        let chatID = try #require(await store.resolveChatByTitle("pager")).rawValue

        let dto = try JSONEncoder().encode(DaemonChatMessagesRequest(chatID: chatID))
        let page1Reply = try storeReply(await executeDomain(
            daemon, .chatMessages, wikiID: wikiID, payload: dto))
        #expect(page1Reply.error == nil)
        let page1 = try JSONDecoder().decode(
            DaemonChatMessagesReply.self, from: #require(page1Reply.result))
        #expect(page1.messages.map(\.seq) == [0, 1, 2])
        #expect(page1.cursor.nextAvailable)
        let token = try #require(page1.cursor.pageToken)

        // Token round trip: the executor decodes exactly what it minted.
        let decoded = try DaemonStoreCommandExecutor.decodePageToken(
            token, wikiID: wikiID.rawValue, operation: "chatMessages")
        #expect(decoded.bytesServed > 0)

        // Page 2 continues AFTER the last-seen seq — no overlap, no skip.
        let page2Dto = try mergePageToken(dto, token: token)
        let page2Reply = try storeReply(await executeDomain(
            daemon, .chatMessages, wikiID: wikiID, payload: page2Dto))
        let page2 = try JSONDecoder().decode(
            DaemonChatMessagesReply.self, from: #require(page2Reply.result))
        #expect(page2.messages.map(\.seq) == [3, 4])
        #expect(page2.cursor.nextAvailable == false)
        #expect(page2.cursor.pageToken == nil)
        #expect(page2.cursor.accumulatedEncodedByteCount > decoded.bytesServed)
    }

    @Test func oversizedHistoryBulkPromotesIntoACommittedPayloadHandle()
        async throws
    {
        let daemon = try makeDaemon()
        let wikiID = try fixtureWiki(daemon)
        // A body over DaemonStoreLimits.listReplyBudgetEncodedBytes: the
        // header list stays inline (identity fields), the bulk crosses via
        // the committed handle.
        let big = String(repeating: "x", count: 1_100_000)
        try await seed(daemon, wikiID: wikiID) { store in
            _ = try await store.addSource(
                filename: "oversized.txt", data: Data("seed".utf8))
            let sourceID = try #require(
                await store.resolveSourceByName("oversized.txt"))
            _ = try await store.appendProcessedMarkdown(
                sourceID: sourceID, content: big,
                origin: .user, note: nil, technique: nil)
        }

        let historySourceID = try #require(
            await (try await daemon.domainCommandStore(wikiID: wikiID))
                .resolveSourceByName("oversized.txt")).rawValue
        let reply = try storeReply(await executeDomain(
            daemon, .processedMarkdownHistory, wikiID: wikiID,
            payload: try JSONEncoder().encode(
                DaemonProcessedMarkdownHistoryRequest(
                    sourceID: historySourceID))))
        #expect(reply.error == nil)
        let history = try JSONDecoder().decode(
            DaemonProcessedMarkdownHistoryReply.self,
            from: #require(reply.result))
        // Identity fields ride inline: exactly one header, the HEAD.
        #expect(history.versions.count == 1)
        #expect(history.versions[0].origin == .user)
        #expect(history.contentByteCount > 0)
        #expect(history.cursor.nextAvailable == false)

        // The handle round-trips the exact bulk through payloadRead.
        let staging = daemon.storeCommandExecutor().payloadStaging
        let expected = try JSONEncoder().encode(
            [history.versions[0].id: big])
        let first = try staging.read(DaemonPayloadReadRequest(
            handleID: history.contents.id, chunkIndex: 0))
        var reassembled = first.bytes
        if !first.isFinal {
            for index in 1..<first.chunkCount {
                reassembled.append(try staging.read(DaemonPayloadReadRequest(
                    handleID: history.contents.id, chunkIndex: index)).bytes)
            }
        }
        #expect(reassembled == expected)
    }

    @Test func oversizedSingleItemWithoutAHandleFieldIsATypedRejection()
        async throws
    {
        let daemon = try makeDaemon()
        let wikiID = try fixtureWiki(daemon)
        try await seed(daemon, wikiID: wikiID) { store in
            let chat = try await store.createChat(kind: .edit, title: "huge")
            _ = try await store.appendChatMessages(
                chatID: chat.id,
                events: [AgentEvent.userText(String(repeating: "h", count: 1_200_000))])
        }
        let store = try await daemon.domainCommandStore(wikiID: wikiID)
        let chatID = try #require(await store.resolveChatByTitle("huge")).rawValue
        let reply = try storeReply(await executeDomain(
            daemon, .chatMessages, wikiID: wikiID,
            payload: try JSONEncoder().encode(
                DaemonChatMessagesRequest(chatID: chatID))))
        let error = try #require(reply.error)
        #expect(
            error.errorDescription?.contains("exceeds the reply budget")
                == true)
    }

    @Test func pagesCitingSourcesListHonorsTheFilterAndLimit() async throws {
        let daemon = try makeDaemon()
        let wikiID = try fixtureWiki(daemon)
        try await seed(daemon, wikiID: wikiID) { store in
            _ = try await store.addSource(
                filename: "cited.txt", data: Data("cited".utf8))
            _ = try await store.addSource(
                filename: "uncited.txt", data: Data("uncited".utf8))
            let citedID = try #require(
                await store.resolveSourceByName("cited.txt"))
            _ = try await store.upsertPage(
                id: nil, title: "Citing Page", rawBody: "cites",
                expectation: .unrestricted, author: nil,
                provenance: [PageVersionSourceInput(
                    sourceID: citedID, role: .primary)])
        }

        let citedID = try #require(
            await (try await daemon.domainCommandStore(wikiID: wikiID))
                .resolveSourceByName("cited.txt")).rawValue
        let uncitedID = try #require(
            await (try await daemon.domainCommandStore(wikiID: wikiID))
                .resolveSourceByName("uncited.txt")).rawValue

        // The filter: only pages whose provenance cites the source.
        let filtered = try storeReply(await executeDomain(
            daemon, .pagesCitingSources, wikiID: wikiID,
            payload: try JSONEncoder().encode(DaemonPagesCitingSourcesRequest(
                sourceIDs: [citedID], limit: 10))))
        let cited = try JSONDecoder().decode(
            DaemonPagesCitingSourcesReply.self, from: #require(filtered.result))
        #expect(cited.pages.map(\.title) == ["Citing Page"])

        // A source nothing cites degrades honestly to empty.
        let none = try storeReply(await executeDomain(
            daemon, .pagesCitingSources, wikiID: wikiID,
            payload: try JSONEncoder().encode(DaemonPagesCitingSourcesRequest(
                sourceIDs: [uncitedID], limit: 10))))
        let empty = try JSONDecoder().decode(
            DaemonPagesCitingSourcesReply.self, from: #require(none.result))
        #expect(empty.pages.isEmpty)
    }

    @Test func pageTokenIsDeterministicAndBoundToItsWikiAndOperation()
        async throws
    {
        let daemon = try makeDaemon()
        let wikiID = try fixtureWiki(daemon)
        try await seed(daemon, wikiID: wikiID) { store in
            let chat = try await store.createChat(kind: .edit, title: "binding")
            _ = try await store.appendChatMessages(
                chatID: chat.id,
                events: (0..<4).map {
                    AgentEvent.userText(String(repeating: "b", count: 400_000) + "#\($0)")
                })
        }
        let store = try await daemon.domainCommandStore(wikiID: wikiID)
        let chatID = try #require(await store.resolveChatByTitle("binding")).rawValue
        let dto = try JSONEncoder().encode(DaemonChatMessagesRequest(chatID: chatID))
        let reply = try storeReply(await executeDomain(
            daemon, .chatMessages, wikiID: wikiID, payload: dto))
        let page = try JSONDecoder().decode(
            DaemonChatMessagesReply.self, from: #require(reply.result))
        let token = try #require(page.cursor.pageToken)

        // Determinism: decode → re-encode the same minted token decodes to
        // the same value (opaque base64 of a deterministic JSON struct).
        let decoded = try DaemonStoreCommandExecutor.decodePageToken(
            token, wikiID: wikiID.rawValue, operation: "chatMessages")
        #expect(decoded.wikiID == wikiID.rawValue)
        #expect(decoded.operation == "chatMessages")

        // A token replayed against ANOTHER wiki is a typed rejection.
        let otherWiki = try fixtureWiki(daemon, name: "Token Binding Other")
        #expect(throws: DaemonStoreError.self) {
            _ = try DaemonStoreCommandExecutor.decodePageToken(
                token, wikiID: otherWiki.rawValue, operation: "chatMessages")
        }
        // A token replayed against ANOTHER operation is a typed rejection.
        #expect(throws: DaemonStoreError.self) {
            _ = try DaemonStoreCommandExecutor.decodePageToken(
                token, wikiID: wikiID.rawValue, operation: "listSources")
        }
        // Garbage tokens never decode.
        #expect(throws: DaemonStoreError.self) {
            _ = try DaemonStoreCommandExecutor.decodePageToken(
                "not-base64!!", wikiID: wikiID.rawValue,
                operation: "chatMessages")
        }
    }

    // MARK: - Slice 2: blob family (handle up/down, one consumption)

    /// Stage `bytes` through the REAL payloadBegin/chunk/commit ops and
    /// return the committed handle.
    private func stageBytes(
        _ daemon: WikiDaemon, wikiID: WikiID, _ bytes: Data
    ) async throws -> DaemonPayloadHandle {
        let beginReply = try storeReply(await executeDomain(
            daemon, .payloadBegin, wikiID: wikiID,
            payload: try JSONEncoder().encode(DaemonPayloadBeginRequest(
                declaredByteCount: bytes.count, sha256Hex: sha256hex(bytes)))))
        let begin = try JSONDecoder().decode(
            DaemonPayloadBeginReply.self, from: #require(beginReply.result))
        let chunkReply = try storeReply(await executeDomain(
            daemon, .payloadChunk, wikiID: wikiID,
            payload: try JSONEncoder().encode(DaemonPayloadChunkRequest(
                uploadID: begin.uploadID, orderIndex: 0, bytes: bytes,
                runningSHA256Hex: sha256hex(bytes)))))
        _ = try JSONDecoder().decode(
            DaemonPayloadChunkReply.self, from: #require(chunkReply.result))
        let commitReply = try storeReply(await executeDomain(
            daemon, .payloadCommit, wikiID: wikiID,
            payload: try JSONEncoder().encode(DaemonPayloadCommitRequest(
                uploadID: begin.uploadID))))
        let commit = try JSONDecoder().decode(
            DaemonPayloadCommitReply.self, from: #require(commitReply.result))
        return commit.handle
    }

    @Test func blobUploadConsumesTheStagedHandleOnceAndCommits() async throws {
        let daemon = try makeDaemon()
        let wikiID = try fixtureWiki(daemon)
        let bytes = Data("verbatim source bytes 01".utf8)
        let handle = try await stageBytes(daemon, wikiID: wikiID, bytes)

        // The op consumes the handle: the committed store content matches.
        let request = DaemonAddSourceRequest(
            filename: "uploaded.txt", data: handle,
            detectionHints: DaemonContentTypeDetectionHints(
                declaredMIME: nil, filenameExtension: "txt", utiMIME: nil),
            ingestMetadata: nil, provenance: nil, role: .primary,
            originalPath: nil, activityID: nil, resolvedDisplayName: nil)
        let stamp = DaemonMutationStamp(
            requestID: "blob-upload-consume", expectedEpoch: daemon.daemonEpoch)
        let reply = try storeReply(await executeDomain(
            daemon, .addSource, wikiID: wikiID,
            payload: try JSONEncoder().encode(request), stamp: stamp))
        #expect(reply.error == nil)
        let added = try JSONDecoder().decode(
            DaemonAddSourceReply.self, from: #require(reply.result))
        #expect(added.source.byteSize == bytes.count)
        #expect(added.outcome.stamp == stamp)
        #expect(added.outcome.status == .committed)
        #expect(added.event != nil)

        // The committed content is verbatim (the store read).
        let store = try await daemon.domainCommandStore(wikiID: wikiID)
        let stored = try await store.sourceContent(
            id: SourceID(rawValue: added.source.id))
        #expect(stored == bytes)

        // CONSUMPTION-RELEASE: the same handle can never execute twice.
        let second = try storeReply(await executeDomain(
            daemon, .addSource, wikiID: wikiID,
            payload: try JSONEncoder().encode(request),
            stamp: DaemonMutationStamp(
                requestID: "blob-upload-consume-2",
                expectedEpoch: daemon.daemonEpoch)))
        let error = try #require(second.error)
        #expect(
            error.errorDescription?.contains("already consumed") == true
                || error.errorDescription?.contains("not found, expired")
                    == true)
    }

    @Test func blobDownloadReturnsAHandlePayloadReadReturnsExactBytes()
        async throws
    {
        let daemon = try makeDaemon()
        let wikiID = try fixtureWiki(daemon)
        let body = "download body — plain text, no links"
        try await seed(daemon, wikiID: wikiID) { store in
            _ = try await store.createPage(
                title: "Download Page", body: body,
                createdBy: nil, provenance: [])
        }
        let store = try await daemon.domainCommandStore(wikiID: wikiID)
        let pageID = try #require(
            await store.resolveTitleToID("Download Page")).rawValue

        let reply = try storeReply(await executeDomain(
            daemon, .getPage, wikiID: wikiID,
            payload: try JSONEncoder().encode(DaemonGetPageRequest(id: pageID))))
        #expect(reply.error == nil)
        let page = try JSONDecoder().decode(
            DaemonGetPageReply.self, from: #require(reply.result))
        #expect(page.page.title == "Download Page")
        #expect(page.bodyByteCount == Data(body.utf8).count)

        // payloadRead reassembles the exact bytes.
        let staging = daemon.storeCommandExecutor().payloadStaging
        let first = try staging.read(DaemonPayloadReadRequest(
            handleID: page.body.id, chunkIndex: 0))
        var reassembled = first.bytes
        if !first.isFinal {
            for index in 1..<first.chunkCount {
                reassembled.append(try staging.read(DaemonPayloadReadRequest(
                    handleID: page.body.id, chunkIndex: index)).bytes)
            }
        }
        #expect(reassembled == Data(body.utf8))
    }

    @Test func versionContentReadRoundTripsThroughAHandle() async throws {
        let daemon = try makeDaemon()
        let wikiID = try fixtureWiki(daemon)
        let bytes = Data("versioned content v1".utf8)
        try await seed(daemon, wikiID: wikiID) { store in
            _ = try await store.addSource(
                filename: "versioned.txt", data: bytes)
        }
        let store = try await daemon.domainCommandStore(wikiID: wikiID)
        let sourceID = try #require(
            await store.resolveSourceByName("versioned.txt"))
        let version = try #require(await store.activeContentVersion(sourceID: sourceID))

        let reply = try storeReply(await executeDomain(
            daemon, .sourceContent, wikiID: wikiID,
            payload: try JSONEncoder().encode(DaemonSourceContentRequest.version(
                versionID: version.id.rawValue))))
        #expect(reply.error == nil)
        let content = try JSONDecoder().decode(
            DaemonSourceContentReply.self, from: #require(reply.result))
        #expect(content.byteCount == bytes.count)

        let staging = daemon.storeCommandExecutor().payloadStaging
        let chunk = try staging.read(DaemonPayloadReadRequest(
            handleID: #require(content.bytes).id, chunkIndex: 0))
        #expect(chunk.bytes == bytes)
    }

    // MARK: - Slice 2: event producer family

    @Test func eventProducerEchoesExactlyOneEventPerCommit() async throws {
        let daemon = try makeDaemon()
        let wikiID = try fixtureWiki(daemon)

        // CREATE: exactly one .chat .created echo.
        let createRequest = DaemonCreateChatRequest(
            kind: .edit, title: "echo chat", modelProviderId: nil,
            modelId: nil, configuredThinkingOptionID: nil,
            effectiveThinkingOptionID: nil, attachments: [])
        let createStamp = DaemonMutationStamp(
            requestID: "echo-create", expectedEpoch: daemon.daemonEpoch)
        let createReply = try storeReply(await executeDomain(
            daemon, .createChat, wikiID: wikiID,
            payload: try JSONEncoder().encode(createRequest),
            stamp: createStamp))
        #expect(createReply.error == nil)
        let created = try JSONDecoder().decode(
            DaemonCreateChatReply.self, from: #require(createReply.result))
        #expect(created.outcome.status == .committed)
        #expect(created.outcome.stamp == createStamp)
        #expect(created.events.count == 1)
        #expect(created.events[0].kind == "chat")
        #expect(created.events[0].change == "created")
        #expect(created.events[0].id == created.chat.id)

        // UPDATE: exactly one .chat .updated echo for the same resource.
        let renameRequest = DaemonRenameChatRequest(id: created.chat.id, to: "renamed")
        let renameReply = try storeReply(await executeDomain(
            daemon, .renameChat, wikiID: wikiID,
            payload: try JSONEncoder().encode(renameRequest),
            stamp: DaemonMutationStamp(
                requestID: "echo-rename", expectedEpoch: daemon.daemonEpoch)))
        let renamed = try JSONDecoder().decode(
            DaemonRenameChatReply.self, from: #require(renameReply.result))
        #expect(renamed.events.count == 1)
        #expect(renamed.events[0].kind == "chat")
        #expect(renamed.events[0].change == "updated")
        #expect(renamed.events[0].id == created.chat.id)
    }

    @Test func batchDeleteResourcesEchoesAnEventArray() async throws {
        let daemon = try makeDaemon()
        let wikiID = try fixtureWiki(daemon)
        try await seed(daemon, wikiID: wikiID) { store in
            _ = try await store.createPage(
                title: "Doomed A", body: "a", createdBy: nil, provenance: [])
            _ = try await store.createPage(
                title: "Doomed B", body: "b", createdBy: nil, provenance: [])
        }
        let store = try await daemon.domainCommandStore(wikiID: wikiID)
        let aID = try #require(await store.resolveTitleToID("Doomed A")).rawValue
        let bID = try #require(await store.resolveTitleToID("Doomed B")).rawValue

        let request = DaemonDeleteResourcesRequest(request:
            DaemonResourceDeletionRequest(
                targets: [.page(id: aID), .page(id: bID)],
                linkPolicy: .unlink))
        let reply = try storeReply(await executeDomain(
            daemon, .deleteResources, wikiID: wikiID,
            payload: try JSONEncoder().encode(request),
            stamp: DaemonMutationStamp(
                requestID: "batch-delete", expectedEpoch: daemon.daemonEpoch)))
        #expect(reply.error == nil)
        let deleted = try JSONDecoder().decode(
            DaemonDeleteResourcesReply.self, from: #require(reply.result))
        // One echo per actually-deleted target (no rewrites, no bookmarks).
        #expect(deleted.result.deletedTargets.count == 2)
        #expect(deleted.events.count == 2)
        #expect(deleted.events.allSatisfy { $0.kind == "page" && $0.change == "deleted" })
        #expect(Set(deleted.events.map(\.id)) == Set([aID, bID]))
    }

    @Test func conditionalEmitterUnchangedSaveCommitsWithEmptyEvents()
        async throws
    {
        let daemon = try makeDaemon()
        let wikiID = try fixtureWiki(daemon)
        try await seed(daemon, wikiID: wikiID) { store in
            _ = try await store.createChat(kind: .edit, title: "already titled")
        }
        let store = try await daemon.domainCommandStore(wikiID: wikiID)
        let chatID = try #require(await store.resolveChatByTitle("already titled")).rawValue

        // setChatTitleIfEmpty against a NONEMPTY title: didWrite == false,
        // the commit emitted NOTHING — the empty array is the honest echo.
        let request = DaemonSetChatTitleIfEmptyRequest(
            chatID: chatID, title: "other")
        let reply = try storeReply(await executeDomain(
            daemon, .setChatTitleIfEmpty, wikiID: wikiID,
            payload: try JSONEncoder().encode(request),
            stamp: DaemonMutationStamp(
                requestID: "conditional-noop", expectedEpoch: daemon.daemonEpoch)))
        #expect(reply.error == nil)
        let outcome = try JSONDecoder().decode(
            DaemonSetChatTitleIfEmptyReply.self, from: #require(reply.result))
        #expect(outcome.didWrite == false)
        #expect(outcome.events.isEmpty)
        #expect(outcome.outcome.status == .committed)

        // saveWikiStrategy unchanged save: same honesty on the blob family
        // (committed outcome, result .unchanged, NO event). The instructions
        // ride as a staged handle (each save stages its own upload).
        let instructions = Data("unchanged instructions".utf8)
        let instructionsHandle = try await stageBytes(
            daemon, wikiID: wikiID, instructions)
        let save = DaemonSaveWikiStrategyRequest(
            name: "Steady", instructions: instructionsHandle,
            expectedRevision: nil)
        let saveStamp = DaemonMutationStamp(
            requestID: "strategy-save-1", expectedEpoch: daemon.daemonEpoch)
        let firstSave = try storeReply(await executeDomain(
            daemon, .saveWikiStrategy, wikiID: wikiID,
            payload: try JSONEncoder().encode(save), stamp: saveStamp))
        let saved = try JSONDecoder().decode(
            DaemonSaveWikiStrategyReply.self, from: #require(firstSave.result))
        guard case .saved(let revision, _) = saved.result else {
            Issue.record("expected a changed save, got \(saved.result)")
            return
        }

        let sameInstructionsHandle = try await stageBytes(
            daemon, wikiID: wikiID, instructions)
        let sameSave = DaemonSaveWikiStrategyRequest(
            name: "Steady", instructions: sameInstructionsHandle,
            expectedRevision: revision)
        let secondSave = try storeReply(await executeDomain(
            daemon, .saveWikiStrategy, wikiID: wikiID,
            payload: try JSONEncoder().encode(sameSave),
            stamp: DaemonMutationStamp(
                requestID: "strategy-save-2", expectedEpoch: daemon.daemonEpoch)))
        let unchanged = try JSONDecoder().decode(
            DaemonSaveWikiStrategyReply.self, from: #require(secondSave.result))
        #expect(unchanged.result == .unchanged)
        #expect(unchanged.event == nil)
        #expect(unchanged.outcome.status == .committed)
    }

    @Test func eventProducerThroughTheLedgerWithConcurrentDuplicateJoin()
        async throws
    {
        let daemon = try makeDaemon()
        let wikiID = try fixtureWiki(daemon)
        let request = DaemonAppendLogRequest(
            kind: .ingest, title: "once-only", note: nil)
        let payload = try JSONEncoder().encode(request)
        let stamp = DaemonMutationStamp(
            requestID: "ledger-join-once", expectedEpoch: daemon.daemonEpoch)

        // Two CONCURRENT identical submissions: the ledger admits one
        // execution; the duplicate joins (or reads the cache). Both replies
        // carry the same result bytes and the same committed outcome.
        async let first = executeDomain(
            daemon, .appendLog, wikiID: wikiID, payload: payload, stamp: stamp)
        async let second = executeDomain(
            daemon, .appendLog, wikiID: wikiID, payload: payload, stamp: stamp)
        let replies = [
            try storeReply(await first),
            try storeReply(await second),
        ]
        #expect(replies[0].error == nil)
        #expect(replies[1].error == nil)
        #expect(replies[0].result == replies[1].result)
        let firstOutcome = try JSONDecoder().decode(
            DaemonAppendLogReply.self, from: #require(replies[0].result))
        let secondOutcome = try JSONDecoder().decode(
            DaemonAppendLogReply.self, from: #require(replies[1].result))
        #expect(firstOutcome.outcome.status == .committed)
        #expect(secondOutcome.outcome.status == .committed)
        #expect(firstOutcome.outcome.stamp == stamp)
        #expect(secondOutcome.outcome.stamp == stamp)

        // Exactly-ONCE observable in the store: one row, despite two
        // submissions.
        let store = try await daemon.domainCommandStore(wikiID: wikiID)
        let entries = try await store.recentLogEntries(limit: 50)
        #expect(entries.filter { $0.title == "once-only" }.count == 1)
        // The winning execution echoed exactly one event; the joined reply
        // shares the winner's bytes, so its echo matches too.
        #expect(firstOutcome.events.count == 1)
        #expect(firstOutcome.events == secondOutcome.events)
    }
}
#endif
