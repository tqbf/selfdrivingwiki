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

    @Test func blobFamilyOpIsReservedUntilItsSlice() async throws {
        let daemon = try makeDaemon()
        let wikiID = try fixtureWiki(daemon)
        let payload = try JSONEncoder().encode(
            DaemonGetMetadataRequest(key: "k"))
        let reply = try await executeDomain(
            daemon, .getPage, wikiID: wikiID, payload: payload)
        #expect(reply.error?.code == .unavailable)
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
}
#endif
