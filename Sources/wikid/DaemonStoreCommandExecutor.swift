#if os(macOS)
import CryptoKit
import Foundation
import WikiDaemonContract
import WikiFSCore
import WikiFSMarkdown
import WikiFSTypes

// Phase 2b slice 1 of plans/daemon-only-access.md: the daemon-side executor
// for the structured store family. One `DaemonDomainRequest` with
// `family: .store` in, one `DaemonDomainReply` out — never a transport fault
// for a store-level failure (the typed error rides INSIDE the
// `DaemonStoreReply` envelope). This slice wires the SMALL payload family
// (all 37 operations), the staged-payload infrastructure ops
// (`payloadBegin` / `payloadChunk` / `payloadCommit` / `payloadRead`), and
// the mutation outcome semantics (`resolveOutcome`); the list / blob /
// event-producer families land in the next slice.
//
// Discipline this file preserves:
// - The store is resolved ONLY through ``WikiDaemon/domainCommandStore(wikiID:)``
//   — the same admitted seam (`reconcileForOperation` + prepared-service
//   admission) every other per-wiki operation goes through. No direct SQLite
//   opens, no transaction poking, no event suppression: exactly-one-event-
//   per-commit stays the store's own `mutate(event:)` job.
// - The executor calls public `WikiStore` methods only.
// - Unknown operations, bad versions, and malformed outer envelopes answer
//   the domain-level typed `invalidRequest` (the established domain-command
//   style); malformed per-op payloads answer a typed `DaemonStoreError`
//   inside the store reply.
//
// Sendable invariant: every mutable field is NSLock-guarded inside
// ``DaemonStoreMutationLedger`` / ``DaemonPayloadStagingStore``; the executor
// itself holds immutable references only.
// swiftlint:disable:next unchecked_sendable
final class DaemonStoreCommandExecutor: @unchecked Sendable {

    /// The daemon this executor serves. Weak on purpose: the daemon owns the
    /// executor (its outcome ledger and staging table live as long as the
    /// daemon), so a strong back-reference would be a retain cycle. A
    /// deallocated daemon answers `daemonUnavailable`, matching the wire
    /// contract for a daemon that can no longer serve.
    private weak var daemon: WikiDaemon?

    /// The mutation outcome layer: in-flight admission table + bounded
    /// per-wiki outcome cache (plan 2a mutation outcome semantics).
    private let ledger: DaemonStoreMutationLedger

    /// The staged-payload upload table (plan 2a staged payload handles).
    private let staging: DaemonPayloadStagingStore

    init(daemon: WikiDaemon) {
        self.daemon = daemon
        self.ledger = DaemonStoreMutationLedger()
        self.staging = DaemonPayloadStagingStore()
    }

    /// Test/next-slice access to the staged-payload table (the oversized-item
    /// promotion helper and the blob slice consume it).
    var payloadStaging: DaemonPayloadStagingStore { staging }

    // MARK: - Family entry

    /// Execute one `.store` family request. NEVER throws: every failure is a
    /// typed reply, because a store failure must never become a transport
    /// fault the client cannot distinguish from connection loss.
    ///
    /// Flow: decode the outer `DaemonStoreRequest` → gate the operation
    /// family (the events family's `sinkHandshake` is daemon-scoped; every
    /// other family proceeds) → `resolveOutcome` NEVER dispatches →
    /// staged-payload ops are daemon-scoped (no store resolution) →
    /// everything else resolves the store through
    /// ``WikiDaemon/domainCommandStore(wikiID:)`` (admission included),
    /// admits stamped mutations through the outcome ledger, and dispatches
    /// by operation.
    func handleStoreOperation(
        _ domainRequest: DaemonDomainRequest,
        expectedWikiID: String? = nil,
        sinkRegistrationID: UUID? = nil
    ) async -> DaemonDomainReply {
        guard let payload = domainRequest.payload else {
            return Self.invalidRequest(
                domainRequest, "the store request carries no payload")
        }
        let storeRequest: DaemonStoreRequest
        do {
            storeRequest = try DaemonStoreWire.decodeRequest(payload)
        } catch {
            return Self.invalidRequest(
                domainRequest,
                "the store request payload could not be decoded: "
                    + Self.errorText(error))
        }
        if let expectedWikiID, expectedWikiID != storeRequest.wikiID {
            return Self.invalidRequest(
                domainRequest,
                "store request targets wiki \(storeRequest.wikiID) but was "
                    + "submitted for \(expectedWikiID)")
        }
        guard let operation = DaemonStoreOperation(rawValue: storeRequest.operation) else {
            return Self.invalidRequest(
                domainRequest,
                "unknown store operation: \(storeRequest.operation)")
        }

        // Family gate: every manifest family is served. `sessionBootstrap`
        // stays reserved for the bootstrap slice (2e); the events family is
        // served by this build (2c handshake).
        switch operation.family {
        case .small, .stagedPayload, .list, .blob, .eventProducer, .events:
            break
        case .mutationSemantics:
            guard operation == .resolveOutcome else {
                return Self.reservedReply(domainRequest, operation)
            }
        }

        // Epoch gate BEFORE store resolution (plan 2a): a stamped mutation
        // whose expected epoch does not match this daemon is rejected at the
        // door. Resolution (which may admit a wiki this daemon does not host)
        // must not preempt the stale-stamp rejection — a restarted daemon
        // never replays a stamped mutation, whatever wikis it hosts.
        if let stamp = storeRequest.stamp {
            guard let daemon else {
                return Self.storeErrorReply(
                    domainRequest, storeRequest,
                    .daemonUnavailable("the wiki daemon has been released"))
            }
            let currentEpoch = daemon.daemonEpoch
            if stamp.expectedEpoch != currentEpoch {
                return Self.storeErrorReply(
                    domainRequest, storeRequest,
                    .unexpected(
                        "daemon epoch mismatch: the submission expects "
                            + "\(stamp.expectedEpoch) but this daemon is at "
                            + "\(currentEpoch); a restarted daemon never replays a "
                            + "stamped mutation — re-read state and resubmit with a "
                            + "new requestID"))
            }
        }

        // RESOLVE-ONLY: joins an in-flight admission or reads the bounded
        // outcome cache. It never resolves the store and never dispatches.
        if operation == .resolveOutcome {
            return await resolveOutcomeReply(domainRequest, storeRequest)
        }

        // Staged-payload infra is daemon-scoped in-memory state; the wiki
        // admission gate applies when the committed handle is CONSUMED by a
        // real operation, not while chunks stream.
        if operation.family == .stagedPayload {
            return await stagedPayloadReply(domainRequest, storeRequest, operation)
        }

        // EVENTS family: the acknowledged `sinkHandshake` — daemon-scoped,
        // NEVER a per-wiki store resolution (plan 2c). It carries no stamp
        // and RETURNS the epoch, so the mutation epoch gate below does not
        // apply.
        if operation.family == .events {
            return await sinkHandshakeReply(
                domainRequest, storeRequest,
                sinkRegistrationID: sinkRegistrationID)
        }

        // SMALL family: resolve through the SAME admitted seam the CLI
        // command families use — never a bypass of reconcileForOperation.
        guard let daemon else {
            return Self.storeErrorReply(
                domainRequest, storeRequest,
                .daemonUnavailable("the wiki daemon has been released"))
        }
        do {
            let store = try await daemon.domainCommandStore(
                wikiID: WikiID(rawValue: storeRequest.wikiID))
            let result: Data
            if let stamp = storeRequest.stamp {
                // List operations are reads and never stamp — a stamp there
                // is a client bug the contract spells as "reads carry no
                // stamp" (slice 2 list DTOs are stamp-less by definition).
                if operation.family == .list {
                    return Self.storeErrorReply(
                        domainRequest, storeRequest,
                        .unexpected(
                            "\(operation.rawValue) is a read and carries no "
                                + "mutation stamp"))
                }
                result = try await executeAdmittedMutation(
                    daemon: daemon, store: store,
                    storeRequest: storeRequest, operation: operation,
                    stamp: stamp)
            } else {
                // Unstamped dispatch: small reads, list reads, and blob
                // reads. Every unstamped MUTATOR (small, blob, and every
                // event-producer operation) is a typed rejection here.
                result = try await dispatchUnstamped(
                    operation, storeRequest, store)
            }
            return Self.storeSuccessReply(domainRequest, result)
        } catch {
            return Self.storeErrorReply(
                domainRequest, storeRequest, Self.wireError(error))
        }
    }

    /// Admission + execution for one stamped mutation (plan 2a): epoch gate →
    /// atomic `(wikiID, requestID)` admission with an operation/payload
    /// fingerprint → identical concurrent duplicates JOIN one execution;
    /// ID reuse with a different fingerprint is a typed rejection; a
    /// committed outcome is cached (bounded per wiki) for `resolveOutcome`.
    private func executeAdmittedMutation(
        daemon: WikiDaemon,
        store: WikiStore,
        storeRequest: DaemonStoreRequest,
        operation: DaemonStoreOperation,
        stamp: DaemonMutationStamp
    ) async throws -> Data {
        let currentEpoch = daemon.daemonEpoch
        guard stamp.expectedEpoch == currentEpoch else {
            throw DaemonStoreError.unexpected(
                "daemon epoch mismatch: the submission expects "
                    + "\(stamp.expectedEpoch) but this daemon is at "
                    + "\(currentEpoch); a restarted daemon never replays a "
                    + "stamped mutation — re-read state and resubmit with a "
                    + "new requestID")
        }
        let fingerprint = Self.payloadFingerprint(
            operation: operation, payload: storeRequest.payload)
        let box = StoreBox(store: store)
        let capturedOperation = operation
        let capturedRequest = storeRequest
        let admission = try await ledger.perform(
            wikiID: storeRequest.wikiID, stamp: stamp,
            operation: operation.rawValue, fingerprint: fingerprint
        ) {
            try await self.dispatchAdmitted(
                capturedOperation, capturedRequest, box.store)
        }
        return admission.result
    }

    // MARK: - resolveOutcome (never dispatches)

    private func resolveOutcomeReply(
        _ domainRequest: DaemonDomainRequest,
        _ storeRequest: DaemonStoreRequest
    ) async -> DaemonDomainReply {
        do {
            let resolveRequest = try Self.decodePayload(
                DaemonResolveOutcomeRequest.self, storeRequest)
            if resolveRequest.wikiID != storeRequest.wikiID {
                throw DaemonStoreError.unexpected(
                    "resolveOutcome targets wiki \(resolveRequest.wikiID) "
                        + "but the envelope scopes \(storeRequest.wikiID)")
            }
            guard let daemon else {
                return Self.storeSuccessReply(
                    domainRequest, try Self.encodeResult(DaemonResolveOutcomeReply(
                        status: .outcomeUnknown, result: nil,
                        message: "the wiki daemon has been released")))
            }
            // A resolve whose stamp names a past epoch NEVER reports a
            // cached outcome: the cache it would read was emptied by the
            // restart, so "unknown" is the only honest answer.
            if resolveRequest.stamp.expectedEpoch != daemon.daemonEpoch {
                return Self.storeSuccessReply(
                    domainRequest, try Self.encodeResult(DaemonResolveOutcomeReply(
                        status: .outcomeUnknown, result: nil,
                        message: "daemon epoch mismatch: the resolve expects "
                            + "\(resolveRequest.stamp.expectedEpoch), this "
                            + "daemon is at \(daemon.daemonEpoch) — "
                            + "reconcile through change tokens")))
            }
            let fingerprint = Self.payloadFingerprint(
                operationString: resolveRequest.operation,
                payload: nil)
            let reply = try await ledger.resolve(
                wikiID: resolveRequest.wikiID, stamp: resolveRequest.stamp,
                operation: resolveRequest.operation,
                fingerprint: resolveRequest.payloadFingerprintSHA256Hex,
                localFingerprint: fingerprint)
            return Self.storeSuccessReply(
                domainRequest, try Self.encodeResult(reply))
        } catch {
            return Self.storeErrorReply(
                domainRequest, storeRequest, Self.wireError(error))
        }
    }

    // MARK: - staged payload ops

    private func stagedPayloadReply(
        _ domainRequest: DaemonDomainRequest,
        _ storeRequest: DaemonStoreRequest,
        _ operation: DaemonStoreOperation
    ) async -> DaemonDomainReply {
        do {
            switch operation {
            case .payloadBegin:
                let request = try Self.decodePayload(
                    DaemonPayloadBeginRequest.self, storeRequest)
                let reply = try staging.begin(request)
                return Self.storeSuccessReply(
                    domainRequest, try Self.encodeResult(reply))
            case .payloadChunk:
                let request = try Self.decodePayload(
                    DaemonPayloadChunkRequest.self, storeRequest)
                try DaemonStoreFrameSizing.validateChunkByteCount(
                    request.bytes.count)
                let reply = try staging.chunk(request)
                return Self.storeSuccessReply(
                    domainRequest, try Self.encodeResult(reply))
            case .payloadCommit:
                let request = try Self.decodePayload(
                    DaemonPayloadCommitRequest.self, storeRequest)
                let reply = try staging.commit(request)
                return Self.storeSuccessReply(
                    domainRequest, try Self.encodeResult(reply))
            case .payloadRead:
                let request = try Self.decodePayload(
                    DaemonPayloadReadRequest.self, storeRequest)
                let reply = try staging.read(request)
                return Self.storeSuccessReply(
                    domainRequest, try Self.encodeResult(reply))
            default:
                throw DaemonStoreError.unexpected(
                    "\(operation.rawValue) is not a staged-payload operation")
            }
        } catch {
            return Self.storeErrorReply(
                domainRequest, storeRequest, Self.wireError(error))
        }
    }

    // MARK: - sinkHandshake (events family, 2c)

    /// Serve the daemon-scoped acknowledged handshake: the reply carries the
    /// epoch plus one watermark per PREPARED wiki, and — when the request
    /// arrived through an XPC connection that exported an event sink — the
    /// coordinator replays that sink's bounded pre-handshake ring and flips
    /// it live. NO store resolution happens here: the handshake is the one
    /// store-family operation scoped to the DAEMON, not to a wiki.
    private func sinkHandshakeReply(
        _ domainRequest: DaemonDomainRequest,
        _ storeRequest: DaemonStoreRequest,
        sinkRegistrationID: UUID?
    ) async -> DaemonDomainReply {
        guard let daemon else {
            return Self.storeErrorReply(
                domainRequest, storeRequest,
                .daemonUnavailable("the wiki daemon has been released"))
        }
        do {
            // The request DTO is empty today; decode it when present so a
            // malformed payload is still a typed rejection.
            if storeRequest.payload != nil {
                _ = try Self.decodePayload(
                    DaemonSinkHandshakeRequest.self, storeRequest)
            }
            let reply = daemon.sinkHandshake(
                sinkRegistrationID: sinkRegistrationID)
            return Self.storeSuccessReply(
                domainRequest, try Self.encodeResult(reply))
        } catch {
            return Self.storeErrorReply(
                domainRequest, storeRequest, Self.wireError(error))
        }
    }

    // MARK: - reply shaping

    private static let smallMutators: Set<DaemonStoreOperation> = [
        .setMetadata, .vacuumActivities, .vacuumBlobs, .vacuumPageVersions,
    ]

    /// Domain-level typed `invalidRequest` (the established domain-command
    /// style): the outer envelope was undecodable, carried the wrong version,
    /// or named an unknown operation.
    private static func invalidRequest(
        _ domainRequest: DaemonDomainRequest, _ message: String
    ) -> DaemonDomainReply {
        .failure(
            requestID: domainRequest.requestID, family: .store,
            operation: domainRequest.operation,
            DaemonDomainError(code: .invalidRequest, message: message))
    }

    /// A manifest operation this daemon build does not serve yet (list /
    /// blob / event families and the reserved events handshake land in later
    /// slices). Typed `unavailable`, never a transport fault.
    private static func reservedReply(
        _ domainRequest: DaemonDomainRequest, _ operation: DaemonStoreOperation
    ) -> DaemonDomainReply {
        .failure(
            requestID: domainRequest.requestID, family: .store,
            operation: domainRequest.operation,
            DaemonDomainError(
                code: .unavailable,
                message: "store operation \(operation.rawValue) is not served "
                    + "by this daemon build yet"))
    }

    /// The store family's success reply: the encoded `DaemonStoreReply`
    /// (typed error nil) rides the domain envelope's payload.
    private static func storeSuccessReply(
        _ domainRequest: DaemonDomainRequest, _ result: Data
    ) -> DaemonDomainReply {
        let payload: Data
        do {
            payload = try DaemonStoreWire.encode(
                DaemonStoreReply(result: result, error: nil))
        } catch {
            // Encode of this fixed-shape value cannot fail; empty data is the
            // honest "no reply" the client surfaces as malformed.
            DebugLog.store("wikid: store success reply encode failed: \(error)")
            payload = Data()
        }
        return .success(
            requestID: domainRequest.requestID, family: .store,
            operation: domainRequest.operation, payload: payload)
    }

    /// The store family's failure reply: the typed rejection rides INSIDE the
    /// `DaemonStoreReply` envelope — never stringified into the outer
    /// envelope's `operationFailed`.
    private static func storeErrorReply(
        _ domainRequest: DaemonDomainRequest,
        _ storeRequest: DaemonStoreRequest,
        _ error: DaemonStoreError
    ) -> DaemonDomainReply {
        DebugLog.store(
            "wikid: store operation \(storeRequest.operation) failed: "
                + "\(error.errorDescription ?? String(describing: error))")
        let payload: Data
        do {
            payload = try DaemonStoreWire.encode(
                DaemonStoreReply(result: nil, error: error))
        } catch {
            DebugLog.store("wikid: store error reply encode failed: \(error)")
            payload = Data()
        }
        return .success(
            requestID: domainRequest.requestID, family: .store,
            operation: domainRequest.operation, payload: payload)
    }

    /// Internal so the file-scope ``DaemonStoreMirrorMapping`` can share the
    /// same truncation rule.
    static func errorText(_ error: Error) -> String {
        String(describing: error).prefix(200).description
    }

    // MARK: - payload fingerprint

    /// SHA-256 over the operation raw string + the request payload bytes —
    /// the operation/payload fingerprint the admission table is keyed by
    /// (plan 2a). A `resolveOutcome` reconstructs the same fingerprint over
    /// the operation string alone when it validates a caller-supplied digest.
    static func payloadFingerprint(
        operation: DaemonStoreOperation, payload: Data?
    ) -> String {
        payloadFingerprint(operationString: operation.rawValue, payload: payload)
    }

    static func payloadFingerprint(
        operationString: String, payload: Data?
    ) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(operationString.utf8))
        hasher.update(data: payload ?? Data())
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - error mapping (the ONE exhaustive store-error mapping)

    /// Map any thrown error to the wire's typed `DaemonStoreError`. The
    /// exhaustive `WikiStoreError` cases keep their identities (deliberate
    /// collapses: NONE); the CAS family maps to the dedicated conflict
    /// details; resolution / transport failures map to `daemonUnavailable`;
    /// anything else lands in `unexpected` with its description.
    static func wireError(_ error: Error) -> DaemonStoreError {
        switch error {
        case let error as DaemonStoreError:
            return error
        case let error as WikiStoreError:
            switch error {
            case .open(let message):
                return .open(message)
            case .sqlite(let code, let message):
                return .sqlite(code: code, message: message)
            case .notFound(let id):
                return .notFound(id.rawValue)
            case .chatNotFound(let id):
                return .chatNotFound(id.rawValue)
            case .sourceNotFound(let id):
                return .sourceNotFound(id.rawValue)
            case .sourceVersionNotFound(let id):
                return .sourceVersionNotFound(id.rawValue)
            case .sourceMarkdownVersionNotFound(let id):
                return .sourceMarkdownVersionNotFound(id.rawValue)
            case .noProcessedMarkdown(let id):
                return .noProcessedMarkdown(id.rawValue)
            case .deletionRestricted(let restriction):
                return .deletionRestricted(DaemonStoreMirrorMapping.mirror(restriction))
            case .invalidBookmarkRow(let id, let reason):
                return .invalidBookmarkRow(id: id, reason: reason)
            case .invalidRendererEventID(let raw):
                return .invalidRendererEventID(raw)
            case .unexpected(let message):
                return .unexpected(message)
            case .duplicateContent(let existing):
                return .duplicateContent(DaemonStoreMirrorMapping.mirror(existing))
            case .duplicateURL(let existing):
                return .duplicateURL(DaemonStoreMirrorMapping.mirror(existing))
            }
        case let error as PageConflictError:
            return .pageConflict(DaemonPageConflictDetail(
                pageID: error.pageID.rawValue,
                expectedVersionID: error.expectedVersionID.rawValue,
                actualVersionID: error.actualVersionID?.rawValue))
        case let error as PageCreateConflictError:
            return .pageCreateConflict(DaemonPageCreateConflictDetail(
                pageID: error.pageID.rawValue, title: error.title,
                actualVersionID: error.actualVersionID?.rawValue))
        case let error as PageExpectedTargetMissingError:
            return .pageExpectedTargetMissing(DaemonPageExpectedTargetMissingDetail(
                pageID: error.pageID?.rawValue,
                expectedHeadVersionID: error.expectedHead.rawValue,
                title: error.title))
        case let error as WikiStrategyConflictError:
            return .strategyRevisionConflict(DaemonStrategyConflictDetail(
                expectedRevision: error.expectedRevision.map(\.rawValue),
                currentRevision: error.currentRevision.map(\.rawValue),
                currentStrategy: nil))
        case let error as SourceMarkdownConflictError:
            return .sourceMarkdownConflict(DaemonSourceMarkdownConflictDetail(
                sourceID: error.sourceID.rawValue,
                expectedHead: error.expectedHead.rawValue,
                currentHead: error.currentHead?.rawValue))
        case let error as DaemonStoreResolutionError:
            return .daemonUnavailable(error.errorDescription ?? String(describing: error))
        case let error as DaemonStoreFrameError:
            return .unexpected(error.errorDescription ?? String(describing: error))
        case is CancellationError:
            return .daemonUnavailable("the store operation was cancelled")
        default:
            return .unexpected(errorText(error))
        }
    }

    // MARK: - small family dispatch (all 37)

    /// Decode the request DTO, call the store method, encode the reply DTO.
    /// Each mapping is thin and total; the four no-emit mutators echo the
    /// mutation outcome (`.committed` — the ledger stamps this submission as
    /// the executor; a joined duplicate shares the winner's bytes, whose
    /// echo truthfully states that the mutation committed once).
    static func dispatchSmall(
        _ operation: DaemonStoreOperation,
        _ request: DaemonStoreRequest,
        _ store: WikiStore
    ) async throws -> Data {
        guard operation.family == .small else {
            throw DaemonStoreError.unexpected(
                "\(operation.rawValue) is not part of the small payload family")
        }
        switch operation {
        // MARK: reads (33)

        case .activeContentVersion:
            let req = try decodePayload(DaemonActiveContentVersionRequest.self, request)
            let version = try await store.activeContentVersion(
                sourceID: SourceID(rawValue: req.sourceID))
            return try encodeResult(DaemonActiveContentVersionReply(
                version: version.map(DaemonStoreMirrorMapping.mirror)))
        case .activeExtractionProvenance:
            let req = try decodePayload(DaemonActiveExtractionProvenanceRequest.self, request)
            let provenance = try await store.activeExtractionProvenance(
                sourceID: SourceID(rawValue: req.sourceID))
            return try encodeResult(DaemonActiveExtractionProvenanceReply(
                provenance: provenance.map(DaemonStoreMirrorMapping.mirror)))
        case .chatAttachments:
            let req = try decodePayload(DaemonChatAttachmentsRequest.self, request)
            let targets = try await store.chatAttachments(
                chatID: ChatID(rawValue: req.chatID))
            return try encodeResult(DaemonChatAttachmentsReply(
                targets: targets.map(DaemonStoreMirrorMapping.mirror)))
        case .chatTranscriptCheckpoint:
            let req = try decodePayload(DaemonChatTranscriptCheckpointRequest.self, request)
            let checkpoint = try await store.chatTranscriptCheckpoint(
                chatID: ChatID(rawValue: req.chatID))
            return try encodeResult(DaemonChatTranscriptCheckpointReply(
                checkpoint: DaemonStoreMirrorMapping.mirror(checkpoint)))
        case .chatUsageSummary:
            let req = try decodePayload(DaemonChatUsageSummaryRequest.self, request)
            let summary = try await store.chatUsageSummary(
                chatID: ChatID(rawValue: req.chatID))
            return try encodeResult(DaemonChatUsageSummaryReply(
                summary: DaemonStoreMirrorMapping.mirror(summary)))
        case .fetchState:
            let req = try decodePayload(DaemonFetchStateRequest.self, request)
            let state = try await store.fetchState(
                sourceID: SourceID(rawValue: req.sourceID))
            return try encodeResult(DaemonFetchStateReply(
                state: state.map { DaemonSourceFetchState(rawValue: $0.rawValue) ?? .pending }))
        case .getChat:
            let req = try decodePayload(DaemonGetChatRequest.self, request)
            let chat = try await store.getChat(id: ChatID(rawValue: req.id))
            return try encodeResult(DaemonGetChatReply(
                chat: DaemonStoreMirrorMapping.mirror(chat)))
        case .getMetadata:
            let req = try decodePayload(DaemonGetMetadataRequest.self, request)
            let value = try await store.getMetadata(req.key)
            return try encodeResult(DaemonGetMetadataReply(value: value))
        case .getWikiStrategyState:
            _ = try decodePayload(DaemonGetWikiStrategyStateRequest.self, request)
            let state = try await store.getWikiStrategyState()
            return try encodeResult(DaemonGetWikiStrategyStateReply(
                state: DaemonStoreMirrorMapping.mirror(state)))
        case .hasImageSiblings:
            let req = try decodePayload(DaemonHasImageSiblingsRequest.self, request)
            let hasSiblings = try await store.hasImageSiblings(
                sourceID: SourceID(rawValue: req.sourceID))
            return try encodeResult(DaemonHasImageSiblingsReply(hasSiblings: hasSiblings))
        case .hasProcessedMarkdown:
            let req = try decodePayload(DaemonHasProcessedMarkdownRequest.self, request)
            let hasAny = try await store.hasProcessedMarkdown(
                sourceID: SourceID(rawValue: req.sourceID))
            return try encodeResult(DaemonHasProcessedMarkdownReply(hasAny: hasAny))
        case .initialContentVersion:
            let req = try decodePayload(DaemonInitialContentVersionRequest.self, request)
            let version = try await store.initialContentVersion(
                sourceID: SourceID(rawValue: req.sourceID))
            return try encodeResult(DaemonInitialContentVersionReply(
                version: version.map(DaemonStoreMirrorMapping.mirror)))
        case .pageHeadSources:
            let req = try decodePayload(DaemonPageHeadSourcesRequest.self, request)
            let sources = try await store.pageHeadSources(
                pageID: PageID(rawValue: req.pageID))
            return try encodeResult(DaemonPageHeadSourcesReply(
                sources: sources.map(DaemonStoreMirrorMapping.mirror)))
        case .pageHeadVersionID:
            let req = try decodePayload(DaemonPageHeadVersionIDRequest.self, request)
            let versionID = try await store.pageHeadVersionID(
                pageID: PageID(rawValue: req.pageID))
            return try encodeResult(DaemonPageHeadVersionIDReply(
                versionID: versionID?.rawValue))
        case .pageOKFMetadata:
            let req = try decodePayload(DaemonPageOKFMetadataRequest.self, request)
            let metadata = try await store.pageOKFMetadata(
                versionID: PageVersionID(rawValue: req.versionID),
                includeCorrected: req.includeCorrected)
            return try encodeResult(DaemonPageOKFMetadataReply(
                metadata: metadata.map(DaemonStoreMirrorMapping.mirror)))
        case .pageOrigin:
            let req = try decodePayload(DaemonPageOriginRequest.self, request)
            let origin = try await store.pageOrigin(
                pageID: PageID(rawValue: req.pageID))
            return try encodeResult(DaemonPageOriginReply(
                origin: origin.map(DaemonStoreMirrorMapping.mirror)))
        case .pageVersionSources:
            let req = try decodePayload(DaemonPageVersionSourcesRequest.self, request)
            let sources = try await store.pageVersionSources(
                versionID: PageVersionID(rawValue: req.versionID))
            return try encodeResult(DaemonPageVersionSourcesReply(
                sources: sources.map(DaemonStoreMirrorMapping.mirror)))
        case .rendererInputByteCount:
            let req = try decodePayload(DaemonRendererInputByteCountRequest.self, request)
            let byteCount = try await store.rendererInputByteCount(
                try DaemonStoreMirrorMapping.coreRendererInput(req.input))
            return try encodeResult(DaemonRendererInputByteCountReply(byteCount: byteCount))
        case .rendererSourcePreference:
            let req = try decodePayload(DaemonRendererSourcePreferenceRequest.self, request)
            let preference = try await store.rendererSourcePreference(
                sourceID: SourceID(rawValue: req.sourceID))
            return try encodeResult(DaemonRendererSourcePreferenceReply(
                preference: preference.map(DaemonStoreMirrorMapping.mirror)))
        case .rendererSourcePresentation:
            let req = try decodePayload(DaemonRendererSourcePresentationRequest.self, request)
            let presentation = try await store.rendererSourcePresentation(
                sourceID: SourceID(rawValue: req.sourceID))
            return try encodeResult(DaemonRendererSourcePresentationReply(
                presentation: presentation.map(DaemonStoreMirrorMapping.mirror)))
        case .resolveChatByTitle:
            let req = try decodePayload(DaemonResolveChatByTitleRequest.self, request)
            let chatID = try await store.resolveChatByTitle(req.title)
            return try encodeResult(DaemonResolveChatByTitleReply(chatID: chatID?.rawValue))
        case .resolveSourceByName:
            let req = try decodePayload(DaemonResolveSourceByNameRequest.self, request)
            let sourceID = try await store.resolveSourceByName(req.displayName)
            return try encodeResult(DaemonResolveSourceByNameReply(sourceID: sourceID?.rawValue))
        case .resolveTitleToID:
            let req = try decodePayload(DaemonResolveTitleToIDRequest.self, request)
            let pageID = try await store.resolveTitleToID(req.title)
            return try encodeResult(DaemonResolveTitleToIDReply(pageID: pageID?.rawValue))
        case .searchSimilar:
            let req = try decodePayload(DaemonSearchSimilarRequest.self, request)
            let results = try await store.searchSimilar(
                query: req.query, limit: req.limit,
                bm25Leg: req.bm25Leg?.map(DaemonStoreMirrorMapping.corePageSummary))
            return try encodeResult(DaemonSearchSimilarReply(
                results: results.map(DaemonStoreMirrorMapping.mirror)))
        case .searchSimilarChats:
            let req = try decodePayload(DaemonSearchSimilarChatsRequest.self, request)
            let results = try await store.searchSimilarChats(
                query: req.query, limit: req.limit,
                bm25Leg: req.bm25Leg?.map(DaemonStoreMirrorMapping.coreChatSummary))
            return try encodeResult(DaemonSearchSimilarChatsReply(
                results: results.map(DaemonStoreMirrorMapping.mirror)))
        case .searchSimilarSources:
            let req = try decodePayload(DaemonSearchSimilarSourcesRequest.self, request)
            let results = try await store.searchSimilarSources(
                query: req.query, limit: req.limit,
                bm25Leg: req.bm25Leg?.map(DaemonStoreMirrorMapping.coreSourceSummary))
            return try encodeResult(DaemonSearchSimilarSourcesReply(
                results: results.map(DaemonStoreMirrorMapping.mirror)))
        case .sourceMarkdownOKFMetadata:
            let req = try decodePayload(DaemonSourceMarkdownOKFMetadataRequest.self, request)
            let metadata = try await store.sourceMarkdownOKFMetadata(
                versionID: SourceMarkdownVersionID(rawValue: req.versionID),
                includeCorrected: req.includeCorrected)
            return try encodeResult(DaemonSourceMarkdownOKFMetadataReply(
                metadata: metadata.map(DaemonStoreMirrorMapping.mirror)))
        case .sourceMatchingURLIdentity:
            let req = try decodePayload(DaemonSourceMatchingURLIdentityRequest.self, request)
            let source = try await store.sourceMatchingURLIdentity(req.identity)
            return try encodeResult(DaemonSourceMatchingURLIdentityReply(
                source: source.map(DaemonStoreMirrorMapping.mirror)))
        case .sourceOrigin:
            let req = try decodePayload(DaemonSourceOriginRequest.self, request)
            let origin = try await store.sourceOrigin(
                sourceID: SourceID(rawValue: req.sourceID))
            return try encodeResult(DaemonSourceOriginReply(
                origin: origin.map(DaemonStoreMirrorMapping.mirror)))
        case .sourceVersion:
            let req = try decodePayload(DaemonSourceVersionRequest.self, request)
            let version = try await store.sourceVersion(
                id: SourceVersionID(rawValue: req.versionID))
            return try encodeResult(DaemonSourceVersionReply(
                version: version.map(DaemonStoreMirrorMapping.mirror)))
        case .wikiStrategyRevision:
            _ = try decodePayload(DaemonWikiStrategyRevisionRequest.self, request)
            let revision = try await store.wikiStrategyRevision()
            return try encodeResult(DaemonWikiStrategyRevisionReply(
                revision: revision?.rawValue))
        case .workspacePageVersion:
            let req = try decodePayload(DaemonWorkspacePageVersionRequest.self, request)
            let versionID = try await store.workspacePageVersion(
                workspaceID: WorkspaceID(rawValue: req.workspaceID),
                pageID: PageID(rawValue: req.pageID))
            return try encodeResult(DaemonWorkspacePageVersionReply(
                versionID: versionID?.rawValue))
        case .workspaceSummary:
            let req = try decodePayload(DaemonWorkspaceSummaryRequest.self, request)
            let summary = try await store.workspaceSummary(
                id: WorkspaceID(rawValue: req.id))
            return try encodeResult(DaemonWorkspaceSummaryReply(
                summary: summary.map(DaemonStoreMirrorMapping.mirror)))

        // MARK: no-emit mutators (outcome echo, never an event)

        case .setMetadata:
            let req = try decodePayload(DaemonSetMetadataRequest.self, request)
            let stamp = try requireStamp(request, operation.rawValue)
            try await store.setMetadata(req.key, value: req.value)
            return try encodeResult(DaemonSetMetadataReply(
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed)))
        case .vacuumActivities:
            let req = try decodePayload(DaemonVacuumActivitiesRequest.self, request)
            let stamp = try requireStamp(request, operation.rawValue)
            let report = try await store.vacuumActivities(dryRun: req.dryRun)
            return try encodeResult(DaemonVacuumActivitiesReply(
                report: DaemonStoreMirrorMapping.mirror(report),
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed)))
        case .vacuumBlobs:
            let req = try decodePayload(DaemonVacuumBlobsRequest.self, request)
            let stamp = try requireStamp(request, operation.rawValue)
            let report = try await store.vacuumBlobs(dryRun: req.dryRun)
            return try encodeResult(DaemonVacuumBlobsReply(
                report: DaemonStoreMirrorMapping.mirror(report),
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed)))
        case .vacuumPageVersions:
            let req = try decodePayload(DaemonVacuumPageVersionsRequest.self, request)
            let stamp = try requireStamp(request, operation.rawValue)
            let report = try await store.vacuumPageVersions(dryRun: req.dryRun)
            return try encodeResult(DaemonVacuumPageVersionsReply(
                report: DaemonStoreMirrorMapping.mirror(report),
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed)))

        // MARK: not-small operations are gated before dispatch
        default:
            throw DaemonStoreError.unexpected(
                "\(operation.rawValue) is not part of the small payload family")
        }
    }

    private static func requireStamp(
        _ request: DaemonStoreRequest, _ operation: String
    ) throws -> DaemonMutationStamp {
        guard let stamp = request.stamp else {
            throw DaemonStoreError.unexpected(
                "\(operation) is a mutation and requires an admission stamp")
        }
        return stamp
    }

    // MARK: - DTO helpers

    private static func decodePayload<Payload: Decodable>(
        _ type: Payload.Type, _ request: DaemonStoreRequest
    ) throws -> Payload {
        guard let data = request.payload else {
            throw DaemonStoreError.unexpected(
                "\(request.operation) carries no payload")
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw DaemonStoreError.unexpected(
                "\(request.operation) payload could not be decoded: "
                    + errorText(error))
        }
    }

    private static func encodeResult<Reply: Encodable>(_ reply: Reply) throws -> Data {
        do {
            return try JSONEncoder().encode(reply)
        } catch {
            throw DaemonStoreError.unexpected(
                "reply could not be encoded: " + errorText(error))
        }
    }

    // MARK: - dispatch routing (slice 2: all four manifest families)

    /// The blob family's read members (no stamp, no outcome echo). The
    /// remaining 28 blob operations are stamped mutations.
    private static let blobReads: Set<DaemonStoreOperation> = [
        .getPage, .getWikiIndex, .getWikiStrategy,
        .missingChatEmbeddingWork, .missingPageEmbeddingWork,
        .missingSourceEmbeddingWork, .pageVersionBody,
        .processedMarkdownHead, .processedMarkdownVersion,
        .sourceContent, .workspacePageBody,
    ]

    /// Route one unstamped request: small reads, list reads, and blob reads.
    /// Every unstamped MUTATOR (small, blob, and every event-producer
    /// operation) is a typed rejection here — the caller's catch maps it to
    /// the same store reply the small family answered before slice 2.
    private func dispatchUnstamped(
        _ operation: DaemonStoreOperation,
        _ request: DaemonStoreRequest,
        _ store: WikiStore
    ) async throws -> Data {
        switch operation.family {
        case .small:
            guard Self.smallMutators.contains(operation) == false else {
                throw DaemonStoreError.unexpected(
                    "\(operation.rawValue) is a mutation and requires "
                        + "an admission stamp")
            }
            return try await Self.dispatchSmall(operation, request, store)
        case .list:
            return try await dispatchList(operation, request, store)
        case .blob:
            guard Self.blobReads.contains(operation) else {
                throw DaemonStoreError.unexpected(
                    "\(operation.rawValue) is a mutation and requires "
                        + "an admission stamp")
            }
            return try await dispatchBlob(operation, request, store)
        default:
            throw DaemonStoreError.unexpected(
                "\(operation.rawValue) is a mutation and requires "
                    + "an admission stamp")
        }
    }

    /// Route one admitted (stamped) execution by family. List operations
    /// never reach here (reads are gated at the door); blob and
    /// event-producer mutators run inside the ledger's once-only work
    /// closure exactly like the small family.
    private func dispatchAdmitted(
        _ operation: DaemonStoreOperation,
        _ request: DaemonStoreRequest,
        _ store: WikiStore
    ) async throws -> Data {
        switch operation.family {
        case .small:
            return try await Self.dispatchSmall(operation, request, store)
        case .blob:
            return try await dispatchBlob(operation, request, store)
        case .eventProducer:
            return try await dispatchEventProducer(operation, request, store)
        default:
            throw DaemonStoreError.unexpected(
                "\(operation.rawValue) is not an admitted mutation")
        }
    }

    // MARK: - list family (25) — byte-budgeted cursor pagination

    /// The list family's request-side continuation key. The per-op DTOs fix
    /// their op-specific fields; the opaque token minted by the reply's
    /// ``DaemonReplyCursor`` rides beside them as an extra `pageToken` JSON
    /// key inside the SAME payload object. Codable ignores unknown keys, so
    /// the typed DTOs decode unchanged; this probe reads the token without
    /// touching any DTO shape. A `pageToken` decode failure here cannot
    /// happen for a payload the typed DTO already decoded, and an absent key
    /// decodes as nil ("from the beginning") — both are the honest reading.
    private struct ListContinuationKey: Codable {
        let pageToken: String?
    }

    /// One page walk under ``DaemonStoreLimits/listReplyBudgetEncodedBytes``:
    /// the budget bounds EACH PAGE's encoded bytes; the token carries the
    /// listing-cumulative total (``DaemonReplyCursor``'s
    /// `accumulatedEncodedByteCount` reports the running total). The page
    /// stops BEFORE the budget would be exceeded and mints the next token,
    /// so every page makes progress. A single item whose own encoded size
    /// alone exceeds the whole budget cannot cross the wire — no list reply
    /// except `processedMarkdownAlternatives` / `processedMarkdownHistory`
    /// carries a payload-handle field, and those two commit their bulk via a
    /// handle BEFORE paginating (small headers only) — so an oversized
    /// single item is the typed frame rejection below, never a silent
    /// truncation.
    private enum PageContinuation {
        /// Skip items whose sort key is ≤ the token's `lastKey` (stable
        /// across inserts before the page boundary; keys order exactly as
        /// the store's ordering).
        case keyed
        /// Skip the first N items (N = the token's decimal ordinal) — for
        /// store-ordered listings whose order is not key-sorted.
        case ordinal
    }

    private func paginate<Item: Encodable>(
        _ items: [Item],
        continuation: PageContinuation,
        start: DaemonStorePageToken?,
        request: DaemonStoreRequest,
        keyOf: ((Item) -> String)? = nil
    ) throws -> (page: [Item], cursor: DaemonReplyCursor) {
        let budget = DaemonStoreLimits.listReplyBudgetEncodedBytes
        let encoder = JSONEncoder()
        var remaining = items
        var skipped = 0
        if let start {
            switch continuation {
            case .keyed:
                guard let keyOf else {
                    throw DaemonStoreError.unexpected(
                        "\(request.operation) paginates by key but carries "
                            + "no key function")
                }
                remaining = Array(
                    items.drop { keyOf($0) <= start.lastKey })
                skipped = items.count - remaining.count
            case .ordinal:
                let resume = (Int(start.lastKey) ?? -1) + 1
                let clamped = min(max(resume, 0), items.count)
                skipped = clamped
                remaining = Array(items.dropFirst(clamped))
            }
        }
        var page: [Item] = []
        var pageServed = 0
        var lastKey = start?.lastKey
        var added = 0
        for (offset, item) in remaining.enumerated() {
            let itemBytes: Int
            do {
                itemBytes = try encoder.encode(item).count
            } catch {
                throw DaemonStoreError.unexpected(
                    "\(request.operation) reply item could not be encoded: "
                        + Self.errorText(error))
            }
            guard pageServed + itemBytes <= budget else {
                if page.isEmpty {
                    throw DaemonStoreError.unexpected(
                        "\(request.operation) produced a single item whose "
                            + "encoded size (\(itemBytes) bytes) exceeds the "
                            + "reply budget (\(budget) bytes) and the reply "
                            + "carries no payload-handle field to promote it "
                            + "into — the item cannot cross the wire; narrow "
                            + "the listing")
                }
                break
            }
            pageServed += itemBytes
            page.append(item)
            if let keyOf {
                lastKey = keyOf(item)
            } else {
                lastKey = "\(skipped + offset)"
            }
            added = offset + 1
        }
        let nextAvailable = added < remaining.count
        var token: String?
        if nextAvailable {
            token = try Self.encodePageToken(
                DaemonStorePageToken(
                    wikiID: request.wikiID,
                    operation: request.operation,
                    lastKey: lastKey ?? "",
                    bytesServed: (start?.bytesServed ?? 0) + pageServed))
        }
        return (
            page,
            DaemonReplyCursor(
                pageToken: token, nextAvailable: nextAvailable,
                accumulatedEncodedByteCount:
                    (start?.bytesServed ?? 0) + pageServed)
        )
    }

    /// Zero-padded decimal sort keys so numeric ordering survives the
    /// string comparison (`seq`, transcript cursors).
    private static func numericKey(_ value: Int64) -> String {
        String(format: "%020lld", value)
    }

    private static func encodePageToken(_ token: DaemonStorePageToken) throws -> String {
        let data: Data
        do {
            data = try JSONEncoder().encode(token)
        } catch {
            throw DaemonStoreError.unexpected(
                "page token could not be encoded: " + errorText(error))
        }
        return data.base64EncodedString()
    }

    /// Decode + validate one continuation token. The token is BOUND to the
    /// wiki and operation that minted it: a replay against another wiki or
    /// operation is a typed rejection, never a silent page fetch.
    static func decodePageToken(
        _ raw: String, wikiID: String, operation: String
    ) throws -> DaemonStorePageToken {
        guard let data = Data(base64Encoded: raw) else {
            throw DaemonStoreError.unexpected(
                "list page token is not decodable base64")
        }
        let token: DaemonStorePageToken
        do {
            token = try JSONDecoder().decode(DaemonStorePageToken.self, from: data)
        } catch {
            throw DaemonStoreError.unexpected(
                "list page token could not be decoded: " + errorText(error))
        }
        guard token.wikiID == wikiID, token.operation == operation else {
            throw DaemonStoreError.unexpected(
                "list page token belongs to wiki \(token.wikiID) operation "
                    + "\(token.operation), not this request (\(wikiID), "
                    + "\(operation)) — tokens are bound to the listing that "
                    + "minted them")
        }
        return token
    }

    /// Decode the request DTO, call the store method, paginate, encode the
    /// reply. Each mapping is thin and total; dictionary values cross as
    /// entry arrays sorted by key so the wire form is deterministic.
    private func dispatchList(
        _ operation: DaemonStoreOperation,
        _ request: DaemonStoreRequest,
        _ store: WikiStore
    ) async throws -> Data {
        guard operation.family == .list else {
            throw DaemonStoreError.unexpected(
                "\(operation.rawValue) is not part of the list family")
        }
        // Probe the request-side continuation (absent = first page).
        let continuationKey: String? = request.payload.flatMap { data in
            do {
                return try JSONDecoder().decode(ListContinuationKey.self, from: data).pageToken
            } catch {
                // The typed DTO decode below would already have failed for a
                // payload that isn't a JSON object, so this leg is only the
                // absent-key case: nil means "from the beginning".
                return nil
            }
        }
        let start = try continuationKey.map {
            try Self.decodePageToken(
                $0, wikiID: request.wikiID, operation: request.operation)
        }

        func finish<Item: Encodable>(
            _ page: [Item], _ cursor: DaemonReplyCursor,
            reply: ([Item], DaemonReplyCursor) -> Encodable
        ) throws -> Data {
            try Self.encodeResult(reply(page, cursor))
        }

        switch operation {
        case .chatMessages:
            let req = try Self.decodePayload(DaemonChatMessagesRequest.self, request)
            let all = try await store.chatMessages(chatID: ChatID(rawValue: req.chatID))
            let mirrors = all.map(DaemonStoreMirrorMapping.mirror)
            let (page, cursor) = try paginate(
                mirrors, continuation: .keyed, start: start, request: request,
                keyOf: { Self.numericKey(Int64($0.seq)) })
            return try finish(page, cursor, reply: DaemonChatMessagesReply.init)
        case .deletionImpact:
            // A single-impact listing (not item-ordered): one page, never a
            // token. Oversized impact = the shared typed frame rejection.
            let req = try Self.decodePayload(DaemonDeletionImpactRequest.self, request)
            let targets = Set(req.targets.map(DaemonStoreMirrorMapping.coreDeletionTarget))
            let impact = try await store.deletionImpact(for: targets)
            let (page, cursor) = try paginate(
                [DaemonStoreMirrorMapping.mirror(impact)],
                continuation: .ordinal, start: start, request: request)
            return try finish(page, cursor, reply: { impact, cursor in
                DaemonDeletionImpactReply(impact: impact[0], cursor: cursor)
            })
        case .embedDescriptors:
            _ = try Self.decodePayload(DaemonEmbedDescriptorsRequest.self, request)
            let descriptors = try await store.embedDescriptors()
            let entries = descriptors
                .map { DaemonSourceEmbedEntry(
                    sourceID: $0.key.rawValue,
                    descriptor: DaemonStoreMirrorMapping.mirror($0.value)) }
                .sorted { $0.sourceID < $1.sourceID }
            let (page, cursor) = try paginate(
                entries, continuation: .keyed, start: start, request: request,
                keyOf: { $0.sourceID })
            return try finish(page, cursor, reply: DaemonEmbedDescriptorsReply.init)
        case .listAllChatsOrderedByID:
            _ = try Self.decodePayload(DaemonListAllChatsOrderedByIDRequest.self, request)
            let chats = try await store.listAllChatsOrderedByID()
                .map(DaemonStoreMirrorMapping.mirror)
            let (page, cursor) = try paginate(
                chats, continuation: .keyed, start: start, request: request,
                keyOf: { $0.id })
            return try finish(page, cursor, reply: DaemonListAllChatsOrderedByIDReply.init)
        case .listBookmarkNodes:
            _ = try Self.decodePayload(DaemonListBookmarkNodesRequest.self, request)
            let nodes = try await store.listBookmarkNodes()
                .map(DaemonStoreMirrorMapping.mirror)
            let (page, cursor) = try paginate(
                nodes, continuation: .ordinal, start: start, request: request)
            return try finish(page, cursor, reply: DaemonListBookmarkNodesReply.init)
        case .listChats:
            _ = try Self.decodePayload(DaemonListChatsRequest.self, request)
            let chats = try await store.listChats()
                .map(DaemonStoreMirrorMapping.mirror)
            let (page, cursor) = try paginate(
                chats, continuation: .ordinal, start: start, request: request)
            return try finish(page, cursor, reply: DaemonListChatsReply.init)
        case .listPages:
            let req = try Self.decodePayload(DaemonListPagesRequest.self, request)
            let sortBy = PageSortOrder(rawValue: req.sortBy.rawValue) ?? .lastUpdated
            let pages = try await store.listPages(sortBy: sortBy)
                .map(DaemonStoreMirrorMapping.mirror)
            let (page, cursor) = try paginate(
                pages, continuation: .ordinal, start: start, request: request)
            return try finish(page, cursor, reply: DaemonListPagesReply.init)
        case .listPersistedChatTurns:
            let req = try Self.decodePayload(DaemonListPersistedChatTurnsRequest.self, request)
            let turns = try await store.listPersistedChatTurns(chatID: ChatID(rawValue: req.chatID))
                .map(DaemonStoreMirrorMapping.mirror)
            let (page, cursor) = try paginate(
                turns, continuation: .ordinal, start: start, request: request)
            return try finish(page, cursor, reply: DaemonListPersistedChatTurnsReply.init)
        case .listSources:
            _ = try Self.decodePayload(DaemonListSourcesRequest.self, request)
            let sources = try await store.listSources()
                .map(DaemonStoreMirrorMapping.mirror)
            let (page, cursor) = try paginate(
                sources, continuation: .ordinal, start: start, request: request)
            return try finish(page, cursor, reply: DaemonListSourcesReply.init)
        case .markedSourceIDs:
            _ = try Self.decodePayload(DaemonMarkedSourceIDsRequest.self, request)
            let ids = try await store.markedSourceIDs().sorted()
            let (page, cursor) = try paginate(
                ids, continuation: .keyed, start: start, request: request)
            return try finish(page, cursor, reply: DaemonMarkedSourceIDsReply.init)
        case .pageEditHistory:
            let req = try Self.decodePayload(DaemonPageEditHistoryRequest.self, request)
            let entries = try await store.pageEditHistory(pageID: PageID(rawValue: req.pageID))
                .map(DaemonStoreMirrorMapping.mirror)
            let (page, cursor) = try paginate(
                entries, continuation: .ordinal, start: start, request: request)
            return try finish(page, cursor, reply: DaemonPageEditHistoryReply.init)
        case .pagesCitingSources:
            let req = try Self.decodePayload(DaemonPagesCitingSourcesRequest.self, request)
            let cited = try await store.pagesCitingSources(
                sourceIDs: req.sourceIDs.map { SourceID(rawValue: $0) },
                limit: req.limit)
                .map(DaemonStoreMirrorMapping.mirror)
            let (page, cursor) = try paginate(
                cited, continuation: .ordinal, start: start, request: request)
            return try finish(page, cursor, reply: DaemonPagesCitingSourcesReply.init)
        case .pageVersionHistory:
            let req = try Self.decodePayload(DaemonPageVersionHistoryRequest.self, request)
            let versions = try await store.pageVersionHistory(pageID: PageID(rawValue: req.pageID))
                .map(DaemonStoreMirrorMapping.mirror)
            let (page, cursor) = try paginate(
                versions, continuation: .keyed, start: start, request: request,
                keyOf: { $0.id })
            return try finish(page, cursor, reply: DaemonPageVersionHistoryReply.init)
        case .processedMarkdownAgentNames:
            let req = try Self.decodePayload(DaemonProcessedMarkdownAgentNamesRequest.self, request)
            let names = try await store.processedMarkdownAgentNames(
                sourceID: SourceID(rawValue: req.sourceID))
            let entries = names
                .map { DaemonMarkdownAgentNameEntry(
                    versionID: $0.key.rawValue, agentName: $0.value) }
                .sorted { $0.versionID < $1.versionID }
            let (page, cursor) = try paginate(
                entries, continuation: .keyed, start: start, request: request,
                keyOf: { $0.versionID })
            return try finish(page, cursor, reply: DaemonProcessedMarkdownAgentNamesReply.init)
        case .processedMarkdownAlternatives:
            // Bulk content NEVER rides inline: the alternatives' full texts
            // commit as ONE handle (`[versionID: content]` JSON) before the
            // small headers paginate. A single oversized header is the typed
            // frame rejection (headers are bounded by construction).
            let req = try Self.decodePayload(DaemonProcessedMarkdownAlternativesRequest.self, request)
            let alternatives = try await store.processedMarkdownAlternatives(
                sourceID: SourceID(rawValue: req.sourceID))
            var contents: [String: String] = [:]
            for alternative in alternatives {
                contents[alternative.version.id.rawValue] = alternative.version.content
            }
            let contentData = try JSONEncoder().encode(contents)
            let contentHandle = staging.commitCompleteBytes(contentData)
            let headers = alternatives.map { alternative in
                DaemonStoreMirrorMapping.mirrorAlternativeHeader(alternative)
            }
            let (page, cursor) = try paginate(
                headers, continuation: .ordinal, start: start, request: request)
            return try Self.encodeResult(DaemonProcessedMarkdownAlternativesReply(
                alternatives: page, contents: contentHandle,
                contentByteCount: contentData.count, cursor: cursor))
        case .processedMarkdownHistory:
            // Same bulk-as-handle rule as alternatives.
            let req = try Self.decodePayload(DaemonProcessedMarkdownHistoryRequest.self, request)
            let versions = try await store.processedMarkdownHistory(
                sourceID: SourceID(rawValue: req.sourceID))
            var contents: [String: String] = [:]
            for version in versions {
                contents[version.id.rawValue] = version.content
            }
            let contentData = try JSONEncoder().encode(contents)
            let contentHandle = staging.commitCompleteBytes(contentData)
            let headers = versions.map(DaemonStoreMirrorMapping.mirror)
            let (page, cursor) = try paginate(
                headers, continuation: .ordinal, start: start, request: request)
            return try Self.encodeResult(DaemonProcessedMarkdownHistoryReply(
                versions: page, contents: contentHandle,
                contentByteCount: contentData.count, cursor: cursor))
        case .readChatTranscriptPage:
            // The typed `after` cursor bounds the QUERY (page 2's `after` is
            // the token's last-seen cursor); the reply cursor bounds the
            // encoded BYTES within each query page.
            let req = try Self.decodePayload(DaemonReadChatTranscriptPageRequest.self, request)
            let after: ChatTranscriptCursor?
            if let start {
                guard let resumed = Int64(start.lastKey) else {
                    throw DaemonStoreError.unexpected(
                        "list page token carries a non-cursor key for a "
                            + "transcript page listing")
                }
                after = ChatTranscriptCursor(rawValue: resumed)
            } else {
                after = req.after.map { ChatTranscriptCursor(rawValue: $0.rawValue) }
            }
            let pageResult = try await store.readChatTranscriptPage(
                chatID: ChatID(rawValue: req.chatID), after: after, limit: req.limit)
            let items = pageResult.items.map(DaemonStoreMirrorMapping.mirror)
            let (page, cursor) = try paginate(
                items, continuation: .keyed, start: start, request: request,
                keyOf: { Self.numericKey($0.cursor.rawValue) })
            return try Self.encodeResult(DaemonReadChatTranscriptPageReply(
                page: DaemonChatTranscriptPage(
                    items: page,
                    checkpoint: DaemonStoreMirrorMapping.mirror(pageResult.checkpoint),
                    nextCursor: pageResult.nextCursor.map(DaemonStoreMirrorMapping.mirror)),
                cursor: cursor))
        case .recentLogEntries:
            let req = try Self.decodePayload(DaemonRecentLogEntriesRequest.self, request)
            let entries = try await store.recentLogEntries(limit: req.limit)
                .map(DaemonStoreMirrorMapping.mirror)
            let (page, cursor) = try paginate(
                entries, continuation: .ordinal, start: start, request: request)
            return try finish(page, cursor, reply: DaemonRecentLogEntriesReply.init)
        case .siblingImageResolvers:
            _ = try Self.decodePayload(DaemonSiblingImageResolversRequest.self, request)
            let resolvers = try await store.siblingImageResolvers()
            let entries = resolvers
                .map { element in
                    DaemonSiblingImageResolverEntry(
                        sourceID: element.key.rawValue,
                        resolvers: element.value
                            .sorted { $0.key < $1.key }
                            .map { resolver in
                                DaemonSiblingImageResolver(
                                    originalPath: resolver.key,
                                    sourceID: resolver.value.rawValue) })
                }
                .sorted { $0.sourceID < $1.sourceID }
            let (page, cursor) = try paginate(
                entries, continuation: .keyed, start: start, request: request,
                keyOf: { $0.sourceID })
            return try finish(page, cursor, reply: DaemonSiblingImageResolversReply.init)
        case .sourceDerivedChains:
            _ = try Self.decodePayload(DaemonSourceDerivedChainsRequest.self, request)
            let chains = try await store.sourceDerivedChains()
            let entries = chains
                .map { DaemonSourceDerivedChainEntry(
                    sourceID: $0.key.rawValue,
                    chain: $0.value.map(\.rawValue)) }
                .sorted { $0.sourceID < $1.sourceID }
            let (page, cursor) = try paginate(
                entries, continuation: .keyed, start: start, request: request,
                keyOf: { $0.sourceID })
            return try finish(page, cursor, reply: DaemonSourceDerivedChainsReply.init)
        case .sourceEditHistory:
            let req = try Self.decodePayload(DaemonSourceEditHistoryRequest.self, request)
            let origins = try await store.sourceEditHistory(
                sourceID: SourceID(rawValue: req.sourceID))
                .map(DaemonStoreMirrorMapping.mirror)
            let (page, cursor) = try paginate(
                origins, continuation: .ordinal, start: start, request: request)
            return try finish(page, cursor, reply: DaemonSourceEditHistoryReply.init)
        case .sourceOriginsBySource:
            _ = try Self.decodePayload(DaemonSourceOriginsBySourceRequest.self, request)
            let origins = try await store.sourceOriginsBySource()
            let entries = origins
                .map { DaemonSourceOriginEntry(
                    sourceID: $0.key.rawValue,
                    origin: DaemonStoreMirrorMapping.mirror($0.value)) }
                .sorted { $0.sourceID < $1.sourceID }
            let (page, cursor) = try paginate(
                entries, continuation: .keyed, start: start, request: request,
                keyOf: { $0.sourceID })
            return try finish(page, cursor, reply: DaemonSourceOriginsBySourceReply.init)
        case .sourcesWithPendingFormatJobs:
            _ = try Self.decodePayload(DaemonSourcesWithPendingFormatJobsRequest.self, request)
            let ids = try await store.sourcesWithPendingFormatJobs()
                .map(\.rawValue)
            let (page, cursor) = try paginate(
                ids, continuation: .ordinal, start: start, request: request)
            return try finish(page, cursor, reply: DaemonSourcesWithPendingFormatJobsReply.init)
        case .workspaceConflicts:
            let req = try Self.decodePayload(DaemonWorkspaceConflictsRequest.self, request)
            let conflicts = try await store.workspaceConflicts(
                workspaceID: WorkspaceID(rawValue: req.workspaceID))
                .map(DaemonStoreMirrorMapping.mirror)
            let (page, cursor) = try paginate(
                conflicts, continuation: .ordinal, start: start, request: request)
            return try finish(page, cursor, reply: DaemonWorkspaceConflictsReply.init)
        case .workspaceRefs:
            let req = try Self.decodePayload(DaemonWorkspaceRefsRequest.self, request)
            let refs = try await store.workspaceRefs(
                workspaceID: WorkspaceID(rawValue: req.workspaceID))
                .map(DaemonStoreMirrorMapping.mirror)
            let (page, cursor) = try paginate(
                refs, continuation: .ordinal, start: start, request: request)
            return try finish(page, cursor, reply: DaemonWorkspaceRefsReply.init)
        default:
            throw DaemonStoreError.unexpected(
                "\(operation.rawValue) is not part of the list family")
        }
    }

    // MARK: - blob family (39) — bytes up/down via staged payload handles

    /// Materialize one request-referenced UPLOAD handle: verify the
    /// declared byte count + SHA-256 against the staged bytes, then CONSUME
    /// the staged entry (one consumption — reusing the same handle is a
    /// typed rejection). A joined duplicate never re-materializes: the
    /// ledger's work closure runs once, so the handle is consumed once.
    private func materializeUpload(_ handle: DaemonPayloadHandle) throws -> Data {
        try staging.consume(matching: handle)
    }

    /// UTF-8 text of a materialized byte blob (markdown bodies, strategy
    /// documents, index bodies, page bodies).
    private static func utf8(_ bytes: Data) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    /// The `[{id: String, text: String}]` JSON shape the three
    /// missing-embedding-work replies stage behind one handle.
    private struct EmbeddingWorkItem: Codable {
        let id: String
        let text: String
    }

    private func dispatchBlob(
        _ operation: DaemonStoreOperation,
        _ request: DaemonStoreRequest,
        _ store: WikiStore
    ) async throws -> Data {
        guard operation.family == .blob else {
            throw DaemonStoreError.unexpected(
                "\(operation.rawValue) is not part of the blob family")
        }

        switch operation {
        // MARK: reads (bytes down — reply carries a committed handle)

        case .getPage:
            let req = try Self.decodePayload(DaemonGetPageRequest.self, request)
            let page = try await store.getPage(id: PageID(rawValue: req.id))
            let body = Data(page.bodyMarkdown.utf8)
            return try Self.encodeResult(DaemonGetPageReply(
                page: DaemonStoreMirrorMapping.mirrorPageMetadata(page),
                body: staging.commitCompleteBytes(body),
                bodyByteCount: body.count))
        case .getWikiIndex:
            _ = try Self.decodePayload(DaemonGetWikiIndexRequest.self, request)
            let index = try await store.getWikiIndex()
            let body = Data(index.body.utf8)
            return try Self.encodeResult(DaemonGetWikiIndexReply(
                metadata: DaemonWikiIndexMetadata(
                    updatedAt: index.updatedAt, version: index.version),
                body: staging.commitCompleteBytes(body),
                bodyByteCount: body.count))
        case .getWikiStrategy:
            // BOUNDED INLINE (≤ 32 KiB store-side): no handle round trip.
            _ = try Self.decodePayload(DaemonGetWikiStrategyRequest.self, request)
            let strategy = try await store.getWikiStrategy()
            return try Self.encodeResult(DaemonGetWikiStrategyReply(
                strategy: strategy.map(DaemonStoreMirrorMapping.mirror)))
        case .missingPageEmbeddingWork:
            _ = try Self.decodePayload(DaemonMissingPageEmbeddingWorkRequest.self, request)
            let work = try await store.missingPageEmbeddingWork()
            let items = work.map { EmbeddingWorkItem(id: $0.id.rawValue, text: $0.text) }
            let bytes = try JSONEncoder().encode(items)
            return try Self.encodeResult(DaemonMissingPageEmbeddingWorkReply(
                work: staging.commitCompleteBytes(bytes), itemCount: items.count))
        case .missingSourceEmbeddingWork:
            _ = try Self.decodePayload(DaemonMissingSourceEmbeddingWorkRequest.self, request)
            let work = try await store.missingSourceEmbeddingWork()
            let items = work.map { EmbeddingWorkItem(id: $0.id.rawValue, text: $0.text) }
            let bytes = try JSONEncoder().encode(items)
            return try Self.encodeResult(DaemonMissingSourceEmbeddingWorkReply(
                work: staging.commitCompleteBytes(bytes), itemCount: items.count))
        case .missingChatEmbeddingWork:
            _ = try Self.decodePayload(DaemonMissingChatEmbeddingWorkRequest.self, request)
            let work = try await store.missingChatEmbeddingWork()
            let items = work.map { EmbeddingWorkItem(id: $0.id.rawValue, text: $0.text) }
            let bytes = try JSONEncoder().encode(items)
            return try Self.encodeResult(DaemonMissingChatEmbeddingWorkReply(
                work: staging.commitCompleteBytes(bytes), itemCount: items.count))
        case .pageVersionBody:
            let req = try Self.decodePayload(DaemonPageVersionBodyRequest.self, request)
            let body = try await store.pageVersionBody(
                versionID: PageVersionID(rawValue: req.versionID))
            if let body {
                let bytes = Data(body.utf8)
                return try Self.encodeResult(DaemonPageVersionBodyReply(
                    body: staging.commitCompleteBytes(bytes),
                    bodyByteCount: bytes.count))
            }
            return try Self.encodeResult(DaemonPageVersionBodyReply(
                body: nil, bodyByteCount: 0))
        case .processedMarkdownHead:
            let req = try Self.decodePayload(DaemonProcessedMarkdownHeadRequest.self, request)
            let version = try await store.processedMarkdownHead(
                sourceID: SourceID(rawValue: req.sourceID))
            let header = version.map(DaemonStoreMirrorMapping.mirror)
            let content = version.map { Data($0.content.utf8) }
            return try Self.encodeResult(DaemonProcessedMarkdownHeadReply(
                version: header,
                content: content.map { staging.commitCompleteBytes($0) },
                contentByteCount: content?.count ?? 0))
        case .processedMarkdownVersion:
            let req = try Self.decodePayload(DaemonProcessedMarkdownVersionRequest.self, request)
            let version = try await store.processedMarkdownVersion(
                id: SourceMarkdownVersionID(rawValue: req.versionID))
            let header = version.map(DaemonStoreMirrorMapping.mirror)
            let content = version.map { Data($0.content.utf8) }
            return try Self.encodeResult(DaemonProcessedMarkdownVersionReply(
                version: header,
                content: content.map { staging.commitCompleteBytes($0) },
                contentByteCount: content?.count ?? 0))
        case .sourceContent:
            let req = try Self.decodePayload(DaemonSourceContentRequest.self, request)
            let bytes: Data
            switch req {
            case .active(let sourceID):
                // A byteless source's core read returns empty Data() — the
                // committed EMPTY payload is the honest echo, never nil.
                bytes = try await store.sourceContent(id: SourceID(rawValue: sourceID))
            case .version(let versionID):
                // No matching row throws `.sourceVersionNotFound`, so the
                // nil leg of the reply never fires on this path.
                bytes = try await store.sourceContent(
                    versionID: SourceVersionID(rawValue: versionID))
            }
            return try Self.encodeResult(DaemonSourceContentReply(
                bytes: staging.commitCompleteBytes(bytes), byteCount: bytes.count))
        case .workspacePageBody:
            let req = try Self.decodePayload(DaemonWorkspacePageBodyRequest.self, request)
            let body = try await store.workspacePageBody(
                workspaceID: WorkspaceID(rawValue: req.workspaceID),
                pageID: PageID(rawValue: req.pageID))
            if let body {
                let bytes = Data(body.utf8)
                return try Self.encodeResult(DaemonWorkspacePageBodyReply(
                    body: staging.commitCompleteBytes(bytes),
                    bodyByteCount: bytes.count))
            }
            return try Self.encodeResult(DaemonWorkspacePageBodyReply(
                body: nil, bodyByteCount: 0))

        // MARK: mutations (bytes up — staged handle consumed once)

        case .addSnapshotImage:
            let req = try Self.decodePayload(DaemonAddSnapshotImageRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let bytes = try materializeUpload(req.data)
            guard let sourceURL = URL(string: req.sourceURL) else {
                throw DaemonStoreError.unexpected(
                    "addSnapshotImage sourceURL is not a parseable URL: "
                        + req.sourceURL)
            }
            let (summary, events) = try await captureEvents(store) {
                try await store.addSnapshotImage(
                    filename: req.filename, data: bytes,
                    detectionHints: DaemonStoreMirrorMapping.coreHints(
                        req.detectionHints),
                    originalPath: req.originalPath, sourceURL: sourceURL,
                    activityID: req.activityID,
                    role: SourceRole(rawValue: req.role.rawValue) ?? .primary)
            }
            return try Self.encodeResult(DaemonAddSnapshotImageReply(
                source: DaemonStoreMirrorMapping.mirror(summary),
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                event: events.first.map(Self.mirrorEvent)))
        case .addSource:
            let req = try Self.decodePayload(DaemonAddSourceRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let bytes = try materializeUpload(req.data)
            let (summary, events) = try await captureEvents(store) {
                try await store.addSource(
                    filename: req.filename, data: bytes,
                    detectionHints: DaemonStoreMirrorMapping.coreHints(
                        req.detectionHints),
                    ingestMetadata: req.ingestMetadata.map(
                        DaemonStoreMirrorMapping.coreIngestMetadata),
                    provenance: req.provenance.map(
                        DaemonStoreMirrorMapping.coreProvenance),
                    role: SourceRole(rawValue: req.role.rawValue) ?? .primary,
                    originalPath: req.originalPath,
                    activityID: req.activityID,
                    // The wire's nil and an explicit nil both fall through
                    // to the filename-derived resolver store-side.
                    resolvedDisplayName: .some(req.resolvedDisplayName))
            }
            return try Self.encodeResult(DaemonAddSourceReply(
                source: DaemonStoreMirrorMapping.mirror(summary),
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                event: events.first.map(Self.mirrorEvent)))
        case .appendChatMessages:
            let req = try Self.decodePayload(DaemonAppendChatMessagesRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let eventsData = try materializeUpload(req.events)
            let wireEvents = try Self.decodeJSON(
                [DaemonAgentEvent].self, eventsData, operation.rawValue)
            let coreEvents = wireEvents.map(DaemonStoreMirrorMapping.coreAgentEvent)
            let (messages, events) = try await captureEvents(store) {
                try await store.appendChatMessages(
                    chatID: ChatID(rawValue: req.chatID), events: coreEvents)
            }
            return try Self.encodeResult(DaemonAppendChatMessagesReply(
                messages: messages.map(DaemonStoreMirrorMapping.mirror),
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                event: events.first.map(Self.mirrorEvent)))
        case .appendChatTranscriptItems:
            let req = try Self.decodePayload(DaemonAppendChatTranscriptItemsRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let itemsData = try materializeUpload(req.items)
            let wireItems = try Self.decodeJSON(
                [DaemonChatTranscriptItem].self, itemsData, operation.rawValue)
            let coreItems = wireItems.map(DaemonStoreMirrorMapping.coreTranscriptItem)
            let (persisted, events) = try await captureEvents(store) {
                try await store.appendChatTranscriptItems(
                    chatID: ChatID(rawValue: req.chatID), items: coreItems)
            }
            return try Self.encodeResult(DaemonAppendChatTranscriptItemsReply(
                items: persisted.map(DaemonStoreMirrorMapping.mirror),
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                event: events.first.map(Self.mirrorEvent)))
        case .appendContentVersion:
            let req = try Self.decodePayload(DaemonAppendContentVersionRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let bytes = try materializeUpload(req.data)
            let (version, events) = try await captureEvents(store) {
                try await store.appendContentVersion(
                    sourceID: SourceID(rawValue: req.sourceID), data: bytes,
                    detectionHints: DaemonStoreMirrorMapping.coreHints(
                        req.detectionHints),
                    provenance: req.provenance.map(
                        DaemonStoreMirrorMapping.coreProvenance))
            }
            return try Self.encodeResult(DaemonAppendContentVersionReply(
                version: DaemonStoreMirrorMapping.mirror(version),
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                event: events.first.map(Self.mirrorEvent)))
        case .appendDerivedMarkdown:
            let req = try Self.decodePayload(DaemonAppendDerivedMarkdownRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let content = Self.utf8(try materializeUpload(req.content))
            let (version, events) = try await captureEvents(store) {
                try await store.appendDerivedMarkdown(
                    sourceID: SourceID(rawValue: req.sourceID),
                    content: content,
                    origin: DaemonStoreMirrorMapping.coreMarkdownOrigin(req.origin),
                    producer: try req.producer.map {
                        try DaemonStoreMirrorMapping.coreProducer($0)
                    },
                    providerID: req.providerID.map(ProviderID.init(rawValue:)),
                    modelID: req.modelID.map(ModelID.init(rawValue:)),
                    toolVersion: req.toolVersion,
                    sourceVersionID: req.sourceVersionID.map(
                        SourceVersionID.init(rawValue:)),
                    note: req.note)
            }
            return try Self.encodeResult(DaemonAppendDerivedMarkdownReply(
                version: DaemonStoreMirrorMapping.mirror(version),
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                event: events.first.map(Self.mirrorEvent)))
        case .appendFetchMarkdown:
            let req = try Self.decodePayload(DaemonAppendFetchMarkdownRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let content = Self.utf8(try materializeUpload(req.content))
            let (version, events) = try await captureEvents(store) {
                try await store.appendFetchMarkdown(
                    sourceID: SourceID(rawValue: req.sourceID),
                    content: content,
                    package: try DaemonStoreMirrorMapping.corePackageProducer(
                        req.package),
                    externalItemKey: req.externalItemKey,
                    externalItemTitle: req.externalItemTitle,
                    sourceVersionID: SourceVersionID(rawValue: req.sourceVersionID))
            }
            return try Self.encodeResult(DaemonAppendFetchMarkdownReply(
                version: DaemonStoreMirrorMapping.mirror(version),
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                event: events.first.map(Self.mirrorEvent)))
        case .appendHostSpeechTranscript:
            // Typed rejection, not a silent default: the wire mirror carries
            // the acquisition fetcher as ONE identity string, but the core
            // producer needs the fetcher's exact package identity (packageID,
            // version, digest, protocol revision, reported metadata) to be
            // reconstructed — the mirror dropped those fields by design. The
            // identity fields stay intact for a later slice that widens the
            // wire shape (a contract change, out of this slice's scope).
            let req = try Self.decodePayload(DaemonAppendHostSpeechTranscriptRequest.self, request)
            _ = req
            throw DaemonStoreError.unexpected(
                "appendHostSpeechTranscript is not servable over the wire "
                    + "yet: the host-speech mirror carries the acquisition "
                    + "fetcher as one identity string without the exact "
                    + "package identity the core producer requires")
        case .appendInstalledPackageMarkdown:
            let req = try Self.decodePayload(DaemonAppendInstalledPackageMarkdownRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let content = Self.utf8(try materializeUpload(req.content))
            let (version, events) = try await captureEvents(store) {
                try await store.appendInstalledPackageMarkdown(
                    sourceID: SourceID(rawValue: req.sourceID),
                    content: content,
                    package: try DaemonStoreMirrorMapping.corePackageProducer(
                        req.package),
                    origin: DaemonStoreMirrorMapping.coreMarkdownOrigin(req.origin),
                    toolVersion: req.toolVersion,
                    sourceVersionID: req.sourceVersionID.map(
                        SourceVersionID.init(rawValue:)),
                    note: req.note)
            }
            return try Self.encodeResult(DaemonAppendInstalledPackageMarkdownReply(
                version: DaemonStoreMirrorMapping.mirror(version),
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                event: events.first.map(Self.mirrorEvent)))
        case .appendPageVersion:
            let req = try Self.decodePayload(DaemonAppendPageVersionRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let body = try req.body.map { body in
                Self.utf8(try materializeUpload(body))
            } ?? ""
            let (versionID, events) = try await captureEvents(store) {
                try await store.appendPageVersion(
                    pageID: PageID(rawValue: req.pageID), title: req.title,
                    body: body,
                    expectedHeadVersionID: req.expectedHeadVersionID.map(
                        PageVersionID.init(rawValue:)),
                    lastEditedBy: req.lastEditedBy,
                    provenance: req.provenance.map(
                        DaemonStoreMirrorMapping.coreVersionSourceInput))
            }
            return try Self.encodeResult(DaemonAppendPageVersionReply(
                versionID: versionID.rawValue,
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                event: events.first.map(Self.mirrorEvent)))
        case .appendProcessedMarkdown:
            let req = try Self.decodePayload(DaemonAppendProcessedMarkdownRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let content = Self.utf8(try materializeUpload(req.content))
            let (version, events) = try await captureEvents(store) {
                try await store.appendProcessedMarkdown(
                    sourceID: SourceID(rawValue: req.sourceID),
                    content: content,
                    origin: DaemonStoreMirrorMapping.coreMarkdownOrigin(req.origin),
                    note: req.note, technique: req.technique)
            }
            return try Self.encodeResult(DaemonAppendProcessedMarkdownReply(
                version: DaemonStoreMirrorMapping.mirror(version),
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                event: events.first.map(Self.mirrorEvent)))
        case .appendUserProcessedMarkdown:
            let req = try Self.decodePayload(DaemonAppendUserProcessedMarkdownRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let content = Self.utf8(try materializeUpload(req.content))
            let (version, events) = try await captureEvents(store) {
                try await store.appendUserProcessedMarkdown(
                    sourceID: SourceID(rawValue: req.sourceID),
                    content: content,
                    expectedHead: SourceMarkdownVersionID(rawValue: req.expectedHead))
            }
            return try Self.encodeResult(DaemonAppendUserProcessedMarkdownReply(
                version: DaemonStoreMirrorMapping.mirror(version),
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                event: events.first.map(Self.mirrorEvent)))
        case .attachAcquiredBytes:
            let req = try Self.decodePayload(DaemonAttachAcquiredBytesRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let bytes = try materializeUpload(req.bytes)
            let (version, events) = try await captureEvents(store) {
                try await store.attachAcquiredBytes(
                    sourceID: SourceID(rawValue: req.sourceID), bytes: bytes,
                    mimeType: req.mimeType,
                    originalFilename: req.originalFilename,
                    externalItemKey: req.externalItemKey,
                    externalItemTitle: req.externalItemTitle,
                    producer: try req.producer.map {
                        try DaemonStoreMirrorMapping.corePackageProducer($0)
                    })
            }
            return try Self.encodeResult(DaemonAttachAcquiredBytesReply(
                version: DaemonStoreMirrorMapping.mirror(version),
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                event: events.first.map(Self.mirrorEvent)))
        case .checkpointStreamingMessage:
            let req = try Self.decodePayload(DaemonCheckpointStreamingMessageRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let eventData = try materializeUpload(req.event)
            let wireEvent = try Self.decodeJSON(
                DaemonAgentEvent.self, eventData, operation.rawValue)
            let (_, events) = try await captureEvents(store) {
                try await store.checkpointStreamingMessage(
                    chatID: ChatID(rawValue: req.chatID), handle: req.handle,
                    event: DaemonStoreMirrorMapping.coreAgentEvent(wireEvent),
                    isDraft: req.isDraft)
            }
            return try Self.encodeResult(DaemonCheckpointStreamingMessageReply(
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                event: events.first.map(Self.mirrorEvent)))
        case .claimNextPersistedChatTurn:
            let req = try Self.decodePayload(DaemonClaimNextPersistedChatTurnRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (turn, events) = try await captureEvents(store) {
                try await store.claimNextPersistedChatTurn(
                    chatID: ChatID(rawValue: req.chatID),
                    claimID: ChatTurnClaimID(rawValue: req.claimID),
                    claimedAt: req.claimedAt,
                    providerID: req.providerID.map(ProviderID.init(rawValue:)),
                    modelID: req.modelID.map(ModelID.init(rawValue:)))
            }
            return try Self.encodeResult(DaemonClaimNextPersistedChatTurnReply(
                turn: turn.map(DaemonStoreMirrorMapping.mirror),
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                event: events.first.map(Self.mirrorEvent)))
        case .createPage:
            let req = try Self.decodePayload(DaemonCreatePageRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let body = try req.body.map { body in
                Self.utf8(try materializeUpload(body))
            } ?? ""
            let (page, events) = try await captureEvents(store) {
                try await store.createPage(
                    title: req.title, body: body, createdBy: req.createdBy,
                    provenance: req.provenance.map(
                        DaemonStoreMirrorMapping.coreVersionSourceInput))
            }
            let committedBody = Data(page.bodyMarkdown.utf8)
            return try Self.encodeResult(DaemonCreatePageReply(
                page: DaemonStoreMirrorMapping.mirrorPageMetadata(page),
                body: staging.commitCompleteBytes(committedBody),
                bodyByteCount: committedBody.count,
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                event: events.first.map(Self.mirrorEvent)))
        case .enqueuePersistedChatTurn:
            let req = try Self.decodePayload(DaemonEnqueuePersistedChatTurnRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (turn, events) = try await captureEvents(store) {
                try await store.enqueuePersistedChatTurn(
                    chatID: ChatID(rawValue: req.chatID),
                    submission: DaemonStoreMirrorMapping.coreTurnSubmission(
                        req.submission))
            }
            return try Self.encodeResult(DaemonEnqueuePersistedChatTurnReply(
                turn: DaemonStoreMirrorMapping.mirror(turn),
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                event: events.first.map(Self.mirrorEvent)))
        case .finishPersistedChatTurn:
            let req = try Self.decodePayload(DaemonFinishPersistedChatTurnRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let state = ChatTurnPersistenceState(rawValue: req.state.rawValue) ?? .failed
            let (turn, events) = try await captureEvents(store) {
                if let finishedAt = req.finishedAt {
                    return try await store.finishPersistedChatTurn(
                        chatID: ChatID(rawValue: req.chatID),
                        turnID: ChatTurnID(rawValue: req.turnID),
                        claimID: ChatTurnClaimID(rawValue: req.claimID),
                        state: state,
                        terminalMessage: req.terminalMessage,
                        finishedAt: finishedAt,
                        usage: req.usage.map(
                            DaemonStoreMirrorMapping.coreUsageValues))
                }
                // nil finishedAt = the 5-arg overload: the store stamps "now"
                // and no usage rides.
                return try await store.finishPersistedChatTurn(
                    chatID: ChatID(rawValue: req.chatID),
                    turnID: ChatTurnID(rawValue: req.turnID),
                    claimID: ChatTurnClaimID(rawValue: req.claimID),
                    state: state,
                    terminalMessage: req.terminalMessage)
            }
            return try Self.encodeResult(DaemonFinishPersistedChatTurnReply(
                turn: DaemonStoreMirrorMapping.mirror(turn),
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                event: events.first.map(Self.mirrorEvent)))
        case .recordMarkdownExtraction:
            let req = try Self.decodePayload(DaemonRecordMarkdownExtractionRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let content = Self.utf8(try materializeUpload(req.content))
            guard let backend = ExtractionBackend(rawValue: req.backend) else {
                throw DaemonStoreError.unexpected(
                    "recordMarkdownExtraction backend is not a known "
                        + "ExtractionBackend raw value: \(req.backend)")
            }
            let (version, events) = try await captureEvents(store) {
                try await store.recordMarkdownExtraction(
                    sourceID: SourceID(rawValue: req.sourceID),
                    content: content, backend: backend,
                    sourceVersionID: req.sourceVersionID.map(
                        SourceVersionID.init(rawValue:)),
                    note: req.note, modelVersion: req.modelVersion)
            }
            return try Self.encodeResult(DaemonRecordMarkdownExtractionReply(
                version: DaemonStoreMirrorMapping.mirror(version),
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                event: events.first.map(Self.mirrorEvent)))
        case .saveWikiStrategy:
            let req = try Self.decodePayload(DaemonSaveWikiStrategyRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let instructions = Self.utf8(try materializeUpload(req.instructions))
            let (result, events) = try await captureEvents(store) {
                try await store.saveWikiStrategy(
                    name: req.name, instructions: instructions,
                    expectedRevision: req.expectedRevision.map(
                        WikiStrategyRevision.init(rawValue:)))
            }
            return try Self.encodeResult(DaemonSaveWikiStrategyReply(
                result: DaemonStoreMirrorMapping.mirror(result),
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                event: events.first.map(Self.mirrorEvent)))
        case .setWorkspaceIndexBody:
            let req = try Self.decodePayload(DaemonSetWorkspaceIndexBodyRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let indexBody = Self.utf8(try materializeUpload(req.indexBody))
            let (_, events) = try await captureEvents(store) {
                try await store.setWorkspaceIndexBody(
                    workspaceID: WorkspaceID(rawValue: req.workspaceID),
                    indexBody: indexBody, indexBaseVersion: req.indexBaseVersion)
            }
            return try Self.encodeResult(DaemonSetWorkspaceIndexBodyReply(
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                event: events.first.map(Self.mirrorEvent)))
        case .storePageChunks:
            let req = try Self.decodePayload(DaemonStorePageChunksRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let chunks = try decodeChunkBlobs(req.chunks, operation.rawValue)
            try await store.storePageChunks(
                id: PageID(rawValue: req.id), chunks: chunks)
            // NO-EMIT (derived data): outcome echo, no event.
            return try Self.encodeResult(DaemonStorePageChunksReply(
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed)))
        case .storeSourceChunks:
            let req = try Self.decodePayload(DaemonStoreSourceChunksRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let chunks = try decodeChunkBlobs(req.chunks, operation.rawValue)
            try await store.storeSourceChunks(
                id: SourceID(rawValue: req.id), chunks: chunks)
            return try Self.encodeResult(DaemonStoreSourceChunksReply(
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed)))
        case .storeChatChunks:
            let req = try Self.decodePayload(DaemonStoreChatChunksRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let chunks = try decodeChunkBlobs(req.chunks, operation.rawValue)
            try await store.storeChatChunks(
                id: ChatID(rawValue: req.id), chunks: chunks)
            return try Self.encodeResult(DaemonStoreChatChunksReply(
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed)))
        case .updatePage:
            let req = try Self.decodePayload(DaemonUpdatePageRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let body = try req.body.map { body in
                Self.utf8(try materializeUpload(body))
            } ?? ""
            let (_, events) = try await captureEvents(store) {
                try await store.updatePage(
                    id: PageID(rawValue: req.id), title: req.title,
                    body: body, lastEditedBy: req.lastEditedBy,
                    provenance: req.provenance.map(
                        DaemonStoreMirrorMapping.coreVersionSourceInput))
            }
            return try Self.encodeResult(DaemonUpdatePageReply(
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                event: events.first.map(Self.mirrorEvent)))
        case .updateWikiIndex:
            let req = try Self.decodePayload(DaemonUpdateWikiIndexRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let body = Self.utf8(try materializeUpload(req.body))
            let (_, events) = try await captureEvents(store) {
                try await store.updateWikiIndex(body: body)
            }
            return try Self.encodeResult(DaemonUpdateWikiIndexReply(
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                event: events.first.map(Self.mirrorEvent)))
        case .upsertPage:
            let req = try Self.decodePayload(DaemonUpsertPageRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let rawBody = try req.rawBody.map { body in
                Self.utf8(try materializeUpload(body))
            } ?? ""
            let (outcomeValue, events) = try await captureEvents(store) {
                try await store.upsertPage(
                    id: req.pageID.map(PageID.init(rawValue:)),
                    title: req.title, rawBody: rawBody,
                    expectation: DaemonStoreMirrorMapping.coreExpectation(
                        req.expectation),
                    author: req.author,
                    provenance: req.provenance.map(
                        DaemonStoreMirrorMapping.coreVersionSourceInput))
            }
            return try Self.encodeResult(DaemonUpsertPageReply(
                result: DaemonStoreMirrorMapping.mirror(outcomeValue),
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                // nil when the commit rolled back (CAS/create-only conflict)
                // — a failed expectation emits nothing.
                event: events.first.map(Self.mirrorEvent)))
        case .workspaceWritePage:
            let req = try Self.decodePayload(DaemonWorkspaceWritePageRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let body = try req.body.map { body in
                Self.utf8(try materializeUpload(body))
            } ?? ""
            let (versionID, events) = try await captureEvents(store) {
                try await store.workspaceWritePage(
                    workspaceID: WorkspaceID(rawValue: req.workspaceID),
                    pageID: PageID(rawValue: req.pageID), title: req.title,
                    body: body, author: req.author,
                    provenance: req.provenance.map(
                        DaemonStoreMirrorMapping.coreVersionSourceInput))
            }
            return try Self.encodeResult(DaemonWorkspaceWritePageReply(
                versionID: versionID?.rawValue,
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                event: events.first.map(Self.mirrorEvent)))
        default:
            throw DaemonStoreError.unexpected(
                "\(operation.rawValue) is not part of the blob family")
        }
    }

    /// Decode one staged `chunks` upload: a JSON array of base64 chunk blobs
    /// (`[String]`, each 512 × Float32), decoded to raw chunk `Data`. The
    /// handle is an UPLOAD handle — consumed exactly once.
    private func decodeChunkBlobs(
        _ handle: DaemonPayloadHandle, _ operation: String
    ) throws -> [Data] {
        let bytes = try materializeUpload(handle)
        let raw = try Self.decodeJSON([String].self, bytes, operation)
        return raw.map { base64 in
            guard let chunk = Data(base64Encoded: base64) else {
                return Data()
            }
            return chunk
        }
    }

    /// Typed JSON decode for staged bytes.
    private static func decodeJSON<T: Decodable>(
        _ type: T.Type, _ data: Data, _ operation: String
    ) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw DaemonStoreError.unexpected(
                "\(operation) staged payload could not be decoded: "
                    + errorText(error))
        }
    }

    // MARK: - event producer family (50)

    /// One captureEvents wrapper per case: subscribe → call the store
    /// EXACTLY ONCE → drain → unsubscribe. The executor never suppresses or
    /// duplicates events; `events` in the reply is the store's own emission
    /// (empty = committed, emitted nothing — the honest conditional-emitter
    /// answer).
    private func dispatchEventProducer(
        _ operation: DaemonStoreOperation,
        _ request: DaemonStoreRequest,
        _ store: WikiStore
    ) async throws -> Data {
        guard operation.family == .eventProducer else {
            throw DaemonStoreError.unexpected(
                "\(operation.rawValue) is not part of the event-producer family")
        }

        switch operation {
        // MARK: workspaces

        case .abandonWorkspace:
            let req = try Self.decodePayload(DaemonAbandonWorkspaceRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (_, events) = try await captureEvents(store) {
                try await store.abandonWorkspace(id: WorkspaceID(rawValue: req.id))
            }
            return try Self.encodeResult(DaemonAbandonWorkspaceReply(
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))
        case .createWorkspace:
            let req = try Self.decodePayload(DaemonCreateWorkspaceRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (workspaceID, events) = try await captureEvents(store) {
                try await store.createWorkspace(name: req.name, activityID: req.activityID)
            }
            return try Self.encodeResult(DaemonCreateWorkspaceReply(
                workspaceID: workspaceID.rawValue,
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))
        case .workspaceMerge:
            let req = try Self.decodePayload(DaemonWorkspaceMergeRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (merged, events) = try await captureEvents(store) {
                try await store.workspaceMerge(workspaceID: WorkspaceID(rawValue: req.workspaceID))
            }
            return try Self.encodeResult(DaemonWorkspaceMergeReply(
                mergedPageIDs: merged,
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))
        case .workspaceRefresh:
            let req = try Self.decodePayload(DaemonWorkspaceRefreshRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (_, events) = try await captureEvents(store) {
                try await store.workspaceRefresh(
                    workspaceID: WorkspaceID(rawValue: req.workspaceID))
            }
            return try Self.encodeResult(DaemonWorkspaceRefreshReply(
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))
        case .workspaceResolveConflict:
            let req = try Self.decodePayload(DaemonWorkspaceResolveConflictRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (_, events) = try await captureEvents(store) {
                try await store.workspaceResolveConflict(
                    workspaceID: WorkspaceID(rawValue: req.workspaceID),
                    pageID: PageID(rawValue: req.pageID), body: req.body)
            }
            return try Self.encodeResult(DaemonWorkspaceResolveConflictReply(
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))
        case .workspaceRetryMerge:
            let req = try Self.decodePayload(DaemonWorkspaceRetryMergeRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (_, events) = try await captureEvents(store) {
                try await store.workspaceRetryMerge(
                    workspaceID: WorkspaceID(rawValue: req.workspaceID))
            }
            return try Self.encodeResult(DaemonWorkspaceRetryMergeReply(
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))
        case .reapStaleWorkspaces:
            let req = try Self.decodePayload(DaemonReapStaleWorkspacesRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (reaped, events) = try await captureEvents(store) {
                try await store.reapStaleWorkspaces(ttl: req.ttl)
            }
            return try Self.encodeResult(DaemonReapStaleWorkspacesReply(
                reapedCount: reaped,
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))

        // MARK: sources

        case .addBytelessSource:
            let req = try Self.decodePayload(DaemonAddBytelessSourceRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (summary, events) = try await captureEvents(store) {
                try await store.addBytelessSource(
                    filename: req.filename, mimeType: req.mimeType,
                    provenance: DaemonStoreMirrorMapping.coreProvenance(
                        req.provenance),
                    role: SourceRole(rawValue: req.role.rawValue) ?? .primary)
            }
            return try Self.encodeResult(DaemonAddBytelessSourceReply(
                source: DaemonStoreMirrorMapping.mirror(summary),
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))
        case .ensureFetchActivity:
            let req = try Self.decodePayload(DaemonEnsureFetchActivityRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (activityID, events) = try await captureEvents(store) {
                try await store.ensureFetchActivity(
                    provenance: DaemonStoreMirrorMapping.coreProvenance(
                        req.provenance))
            }
            return try Self.encodeResult(DaemonEnsureFetchActivityReply(
                activityID: activityID,
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))
        case .markFetchComplete:
            let req = try Self.decodePayload(DaemonMarkFetchCompleteRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let sourceID = SourceID(rawValue: req.sourceID)
            if let expected = req.expectedContentVersionID {
                // Recovery-scan variant: Bool reply (false = the active
                // version moved on; the newer marker stays for its own scan).
                let (didAdvance, events) = try await captureEvents(store) {
                    try await store.markFetchComplete(
                        sourceID: sourceID,
                        expectedContentVersionID: SourceVersionID(rawValue: expected))
                }
                return try Self.encodeResult(DaemonMarkFetchCompleteReply(
                    didAdvance: didAdvance,
                    outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                    events: events.map(Self.mirrorEvent)))
            }
            let (_, events) = try await captureEvents(store) {
                try await store.markFetchComplete(sourceID: sourceID)
            }
            return try Self.encodeResult(DaemonMarkFetchCompleteReply(
                didAdvance: nil,
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))
        case .markSourceIngested:
            let req = try Self.decodePayload(DaemonMarkSourceIngestedRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (_, events) = try await captureEvents(store) {
                try await store.markSourceIngested(id: SourceID(rawValue: req.id))
            }
            return try Self.encodeResult(DaemonMarkSourceIngestedReply(
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))
        case .renameSource:
            let req = try Self.decodePayload(DaemonRenameSourceRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (_, events) = try await captureEvents(store) {
                try await store.renameSource(
                    id: SourceID(rawValue: req.id), to: req.to)
            }
            return try Self.encodeResult(DaemonRenameSourceReply(
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))
        case .setSourceDisplayName:
            let req = try Self.decodePayload(DaemonSetSourceDisplayNameRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (_, events) = try await captureEvents(store) {
                try await store.setSourceDisplayName(
                    id: SourceID(rawValue: req.id), displayName: req.displayName)
            }
            return try Self.encodeResult(DaemonSetSourceDisplayNameReply(
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))
        case .repairMIME:
            let req = try Self.decodePayload(DaemonRepairMIMERequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (report, events) = try await captureEvents(store) {
                try await store.repairMIME(dryRun: req.dryRun)
            }
            return try Self.encodeResult(DaemonRepairMIMEReply(
                report: DaemonStoreMirrorMapping.mirror(report),
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))

        // MARK: processed markdown

        case .setActiveMarkdown:
            let req = try Self.decodePayload(DaemonSetActiveMarkdownRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (_, events) = try await captureEvents(store) {
                try await store.setActiveMarkdown(
                    sourceID: SourceID(rawValue: req.sourceID),
                    to: SourceMarkdownVersionID(rawValue: req.to))
            }
            return try Self.encodeResult(DaemonSetActiveMarkdownReply(
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))

        // MARK: OKF trust

        case .recordPageOKFVerification:
            let req = try Self.decodePayload(DaemonRecordPageOKFVerificationRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (verificationID, events) = try await captureEvents(store) {
                try await store.recordPageOKFVerification(
                    versionID: PageVersionID(rawValue: req.versionID),
                    verifier: try DaemonStoreMirrorMapping.coreVerifier(req.verifier),
                    verifiedAt: req.verifiedAt,
                    basis: DaemonStoreMirrorMapping.coreBasis(req.basis),
                    freshnessPolicy: req.freshnessPolicy.map(
                        DaemonStoreMirrorMapping.coreFreshness))
            }
            return try Self.encodeResult(DaemonRecordPageOKFVerificationReply(
                verificationID: verificationID.rawValue,
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))
        case .recordSourceMarkdownOKFVerification:
            let req = try Self.decodePayload(DaemonRecordSourceMarkdownOKFVerificationRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (verificationID, events) = try await captureEvents(store) {
                try await store.recordSourceMarkdownOKFVerification(
                    versionID: SourceMarkdownVersionID(rawValue: req.versionID),
                    verifier: try DaemonStoreMirrorMapping.coreVerifier(req.verifier),
                    verifiedAt: req.verifiedAt,
                    basis: DaemonStoreMirrorMapping.coreBasis(req.basis),
                    freshnessPolicy: req.freshnessPolicy.map(
                        DaemonStoreMirrorMapping.coreFreshness))
            }
            return try Self.encodeResult(DaemonRecordSourceMarkdownOKFVerificationReply(
                verificationID: verificationID.rawValue,
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))
        case .correctPageOKFVerification:
            let req = try Self.decodePayload(DaemonCorrectPageOKFVerificationRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (_, events) = try await captureEvents(store) {
                try await store.correctPageOKFVerification(
                    versionID: PageVersionID(rawValue: req.versionID),
                    verificationID: OKFVerificationID(rawValue: req.verificationID),
                    correctingVerifier: try DaemonStoreMirrorMapping.coreVerifier(
                        req.correctingVerifier),
                    correctedAt: req.correctedAt,
                    reason: req.reason.map(DaemonStoreMirrorMapping.coreCorrectionReason))
            }
            return try Self.encodeResult(DaemonCorrectPageOKFVerificationReply(
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))
        case .correctSourceMarkdownOKFVerification:
            let req = try Self.decodePayload(DaemonCorrectSourceMarkdownOKFVerificationRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (_, events) = try await captureEvents(store) {
                try await store.correctSourceMarkdownOKFVerification(
                    versionID: SourceMarkdownVersionID(rawValue: req.versionID),
                    verificationID: OKFVerificationID(rawValue: req.verificationID),
                    correctingVerifier: try DaemonStoreMirrorMapping.coreVerifier(
                        req.correctingVerifier),
                    correctedAt: req.correctedAt,
                    reason: req.reason.map(DaemonStoreMirrorMapping.coreCorrectionReason))
            }
            return try Self.encodeResult(DaemonCorrectSourceMarkdownOKFVerificationReply(
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))
        case .setPageOKFStatus:
            let req = try Self.decodePayload(DaemonSetPageOKFStatusRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (_, events) = try await captureEvents(store) {
                try await store.setPageOKFStatus(
                    versionID: PageVersionID(rawValue: req.versionID),
                    status: req.status.map { OKFConceptStatus(rawValue: $0.rawValue) ?? .draft })
            }
            return try Self.encodeResult(DaemonSetPageOKFStatusReply(
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))
        case .setPageOKFFreshness:
            let req = try Self.decodePayload(DaemonSetPageOKFFreshnessRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (_, events) = try await captureEvents(store) {
                try await store.setPageOKFFreshness(
                    versionID: PageVersionID(rawValue: req.versionID),
                    policy: req.policy.map(DaemonStoreMirrorMapping.coreFreshness))
            }
            return try Self.encodeResult(DaemonSetPageOKFFreshnessReply(
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))
        case .setSourceMarkdownOKFStatus:
            let req = try Self.decodePayload(DaemonSetSourceMarkdownOKFStatusRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (_, events) = try await captureEvents(store) {
                try await store.setSourceMarkdownOKFStatus(
                    versionID: SourceMarkdownVersionID(rawValue: req.versionID),
                    status: req.status.map { OKFConceptStatus(rawValue: $0.rawValue) ?? .draft })
            }
            return try Self.encodeResult(DaemonSetSourceMarkdownOKFStatusReply(
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))
        case .setSourceMarkdownOKFFreshness:
            let req = try Self.decodePayload(DaemonSetSourceMarkdownOKFFreshnessRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (_, events) = try await captureEvents(store) {
                try await store.setSourceMarkdownOKFFreshness(
                    versionID: SourceMarkdownVersionID(rawValue: req.versionID),
                    policy: req.policy.map(DaemonStoreMirrorMapping.coreFreshness))
            }
            return try Self.encodeResult(DaemonSetSourceMarkdownOKFFreshnessReply(
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))

        // MARK: pages

        case .replaceLinks:
            let req = try Self.decodePayload(DaemonReplaceLinksRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (_, events) = try await captureEvents(store) {
                try await store.replaceLinks(
                    from: PageID(rawValue: req.pageID),
                    parsedLinks: req.parsedLinks.map(
                        DaemonStoreMirrorMapping.coreParsedLink))
            }
            return try Self.encodeResult(DaemonReplaceLinksReply(
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))
        case .restorePage:
            let req = try Self.decodePayload(DaemonRestorePageRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (versionID, events) = try await captureEvents(store) {
                try await store.restorePage(
                    pageID: PageID(rawValue: req.pageID),
                    to: PageVersionID(rawValue: req.to))
            }
            return try Self.encodeResult(DaemonRestorePageReply(
                versionID: versionID.rawValue,
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))
        case .revertPage:
            let req = try Self.decodePayload(DaemonRevertPageRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (_, events) = try await captureEvents(store) {
                try await store.revertPage(
                    pageID: PageID(rawValue: req.pageID),
                    to: PageVersionID(rawValue: req.to))
            }
            return try Self.encodeResult(DaemonRevertPageReply(
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))

        // MARK: protected deletion (batch)

        case .deleteResources:
            let req = try Self.decodePayload(DaemonDeleteResourcesRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let coreRequest = ResourceDeletionRequest(
                targets: Set(req.request.targets.map(
                    DaemonStoreMirrorMapping.coreDeletionTarget)),
                // The core policy enum carries no raw value; the wire case
                // maps by identity (preserve is the contract default).
                linkPolicy: req.request.linkPolicy == .unlink
                    ? .unlink : .preserve)
            let (result, events) = try await captureEvents(store) {
                try await store.deleteResources(coreRequest)
            }
            return try Self.encodeResult(DaemonDeleteResourcesReply(
                result: DaemonStoreMirrorMapping.mirror(result),
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))

        // MARK: log

        case .appendLog:
            let req = try Self.decodePayload(DaemonAppendLogRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (entry, events) = try await captureEvents(store) {
                try await store.appendLog(
                    kind: LogEntry.Kind(rawValue: req.kind.rawValue) ?? .ingest,
                    title: req.title, note: req.note)
            }
            return try Self.encodeResult(DaemonAppendLogReply(
                entry: DaemonStoreMirrorMapping.mirror(entry),
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))

        // MARK: bookmarks

        case .createBookmarkNode:
            let req = try Self.decodePayload(DaemonCreateBookmarkNodeRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (node, events) = try await captureEvents(store) {
                try await store.createBookmarkNode(
                    parentID: req.parentID.map(BookmarkID.init(rawValue:)),
                    position: req.position,
                    content: DaemonStoreMirrorMapping.coreBookmarkContent(
                        req.content))
            }
            return try Self.encodeResult(DaemonCreateBookmarkNodeReply(
                node: DaemonStoreMirrorMapping.mirror(node),
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))
        case .renameBookmarkFolder:
            let req = try Self.decodePayload(DaemonRenameBookmarkFolderRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (_, events) = try await captureEvents(store) {
                try await store.renameBookmarkFolder(
                    id: BookmarkID(rawValue: req.id), to: req.to)
            }
            return try Self.encodeResult(DaemonRenameBookmarkFolderReply(
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))
        case .retargetBookmarkNode:
            let req = try Self.decodePayload(DaemonRetargetBookmarkNodeRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (_, events) = try await captureEvents(store) {
                try await store.retargetBookmarkNode(
                    id: BookmarkID(rawValue: req.id),
                    to: DaemonStoreMirrorMapping.coreBookmarkContent(req.to))
            }
            return try Self.encodeResult(DaemonRetargetBookmarkNodeReply(
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))
        case .deleteBookmarkNode:
            let req = try Self.decodePayload(DaemonDeleteBookmarkNodeRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (_, events) = try await captureEvents(store) {
                try await store.deleteBookmarkNode(id: BookmarkID(rawValue: req.id))
            }
            return try Self.encodeResult(DaemonDeleteBookmarkNodeReply(
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))
        case .moveBookmarkNode:
            let req = try Self.decodePayload(DaemonMoveBookmarkNodeRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (_, events) = try await captureEvents(store) {
                try await store.moveBookmarkNode(
                    id: BookmarkID(rawValue: req.id),
                    toParentID: req.toParentID.map(BookmarkID.init(rawValue:)),
                    position: req.position)
            }
            return try Self.encodeResult(DaemonMoveBookmarkNodeReply(
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))

        // MARK: chats

        case .createChat:
            let req = try Self.decodePayload(DaemonCreateChatRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let kind = ChatKind(rawValue: req.kind.rawValue) ?? .edit
            let attachments = req.attachments.map(
                DaemonStoreMirrorMapping.coreAttachmentTarget)
            let (chat, events) = try await captureEvents(store) {
                // The DTO carries all three overloads' fields in one union;
                // the overload priority follows the DTO's overload doc:
                // attachments (composes the chip set), else provider/model +
                // thinking, else the 2-arg convenience.
                if !attachments.isEmpty {
                    return try await store.createChat(
                        kind: kind, title: req.title, attachments: attachments)
                }
                if req.modelProviderId != nil || req.modelId != nil
                    || req.configuredThinkingOptionID != nil
                    || req.effectiveThinkingOptionID != nil {
                    return try await store.createChat(
                        kind: kind, title: req.title,
                        modelProviderId: req.modelProviderId.map(
                            ProviderID.init(rawValue:)),
                        modelId: req.modelId.map(ModelID.init(rawValue:)),
                        configuredThinkingOptionID: req.configuredThinkingOptionID
                            .map(ChatConfigurationValueID.init(rawValue:)),
                        effectiveThinkingOptionID: req.effectiveThinkingOptionID
                            .map(ChatConfigurationValueID.init(rawValue:)))
                }
                return try await store.createChat(kind: kind, title: req.title)
            }
            return try Self.encodeResult(DaemonCreateChatReply(
                chat: DaemonStoreMirrorMapping.mirror(chat),
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))
        case .setChatAttachments:
            let req = try Self.decodePayload(DaemonSetChatAttachmentsRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (_, events) = try await captureEvents(store) {
                try await store.setChatAttachments(
                    chatID: ChatID(rawValue: req.chatID),
                    targets: req.targets.map(
                        DaemonStoreMirrorMapping.coreAttachmentTarget))
            }
            return try Self.encodeResult(DaemonSetChatAttachmentsReply(
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))
        case .renameChat:
            let req = try Self.decodePayload(DaemonRenameChatRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (_, events) = try await captureEvents(store) {
                try await store.renameChat(
                    id: ChatID(rawValue: req.id), to: req.to)
            }
            return try Self.encodeResult(DaemonRenameChatReply(
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))
        case .setChatTitleIfEmpty:
            let req = try Self.decodePayload(DaemonSetChatTitleIfEmptyRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (didWrite, events) = try await captureEvents(store) {
                try await store.setChatTitleIfEmpty(
                    chatID: ChatID(rawValue: req.chatID), title: req.title)
            }
            // Conditional emitter: didWrite == false committed with NO event;
            // the empty array is the honest echo.
            return try Self.encodeResult(DaemonSetChatTitleIfEmptyReply(
                didWrite: didWrite,
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))
        case .setChatTitleIf:
            let req = try Self.decodePayload(DaemonSetChatTitleIfRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (didWrite, events) = try await captureEvents(store) {
                try await store.setChatTitleIf(
                    chatID: ChatID(rawValue: req.chatID),
                    expectedTitle: req.expectedTitle, title: req.title)
            }
            return try Self.encodeResult(DaemonSetChatTitleIfReply(
                didWrite: didWrite,
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))
        case .deleteChat:
            let req = try Self.decodePayload(DaemonDeleteChatRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (_, events) = try await captureEvents(store) {
                try await store.deleteChat(id: ChatID(rawValue: req.id))
            }
            return try Self.encodeResult(DaemonDeleteChatReply(
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))
        case .updateChatAcpSessionId:
            let req = try Self.decodePayload(DaemonUpdateChatAcpSessionIdRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (_, events) = try await captureEvents(store) {
                try await store.updateChatAcpSessionId(
                    chatID: ChatID(rawValue: req.chatID),
                    acpSessionId: req.acpSessionId.map(AcpSessionID.init(rawValue:)))
            }
            return try Self.encodeResult(DaemonUpdateChatAcpSessionIdReply(
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))
        case .updateChatModelOverride:
            let req = try Self.decodePayload(DaemonUpdateChatModelOverrideRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (_, events) = try await captureEvents(store) {
                try await store.updateChatModelOverride(
                    id: ChatID(rawValue: req.id),
                    providerId: req.providerId.map(ProviderID.init(rawValue:)),
                    modelId: req.modelId.map(ModelID.init(rawValue:)))
            }
            return try Self.encodeResult(DaemonUpdateChatModelOverrideReply(
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))
        case .updateChatModelAndThinkingSelection:
            let req = try Self.decodePayload(DaemonUpdateChatModelAndThinkingSelectionRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (_, events) = try await captureEvents(store) {
                try await store.updateChatModelAndThinkingSelection(
                    chatID: ChatID(rawValue: req.chatID),
                    providerID: req.providerID.map(ProviderID.init(rawValue:)),
                    modelID: req.modelID.map(ModelID.init(rawValue:)),
                    configuredThinkingID: req.configuredThinkingID.map(
                        ChatConfigurationValueID.init(rawValue:)),
                    effectiveThinkingID: req.effectiveThinkingID.map(
                        ChatConfigurationValueID.init(rawValue:)))
            }
            return try Self.encodeResult(DaemonUpdateChatModelAndThinkingSelectionReply(
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))
        case .updateMessageSummary:
            let req = try Self.decodePayload(DaemonUpdateMessageSummaryRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (_, events) = try await captureEvents(store) {
                try await store.updateMessageSummary(
                    chatID: ChatID(rawValue: req.chatID),
                    cursor: ChatTranscriptCursor(rawValue: req.cursor.rawValue),
                    summary: req.summary,
                    kind: ChatMessageSummaryKind(rawValue: req.kind.rawValue)
                        ?? .defaultTruncation)
            }
            return try Self.encodeResult(DaemonUpdateMessageSummaryReply(
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))
        case .finalizeStaleDrafts:
            let req = try Self.decodePayload(DaemonFinalizeStaleDraftsRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (_, events) = try await captureEvents(store) {
                try await store.finalizeStaleDrafts(forChat: ChatID(rawValue: req.chatID))
            }
            return try Self.encodeResult(DaemonFinalizeStaleDraftsReply(
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))
        case .cancelUnclaimedPersistedChatTurn:
            let req = try Self.decodePayload(DaemonCancelUnclaimedPersistedChatTurnRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (turn, events) = try await captureEvents(store) {
                try await store.cancelUnclaimedPersistedChatTurn(
                    chatID: ChatID(rawValue: req.chatID),
                    turnID: ChatTurnID(rawValue: req.turnID))
            }
            return try Self.encodeResult(DaemonCancelUnclaimedPersistedChatTurnReply(
                turn: turn.map(DaemonStoreMirrorMapping.mirror),
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))
        case .markPersistedChatTurnProviderSubmitted:
            let req = try Self.decodePayload(DaemonMarkPersistedChatTurnProviderSubmittedRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (turn, events) = try await captureEvents(store) {
                try await store.markPersistedChatTurnProviderSubmitted(
                    chatID: ChatID(rawValue: req.chatID),
                    turnID: ChatTurnID(rawValue: req.turnID),
                    claimID: ChatTurnClaimID(rawValue: req.claimID),
                    providerSessionID: req.providerSessionID.map(
                        AcpSessionID.init(rawValue:)),
                    submittedAt: req.submittedAt)
            }
            return try Self.encodeResult(DaemonMarkPersistedChatTurnProviderSubmittedReply(
                turn: DaemonStoreMirrorMapping.mirror(turn),
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))
        case .updatePersistedChatTurnUsage:
            let req = try Self.decodePayload(DaemonUpdatePersistedChatTurnUsageRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (turn, events) = try await captureEvents(store) {
                try await store.updatePersistedChatTurnUsage(
                    chatID: ChatID(rawValue: req.chatID),
                    turnID: ChatTurnID(rawValue: req.turnID),
                    claimID: ChatTurnClaimID(rawValue: req.claimID),
                    usage: DaemonStoreMirrorMapping.coreUsageValues(req.usage))
            }
            return try Self.encodeResult(DaemonUpdatePersistedChatTurnUsageReply(
                turn: DaemonStoreMirrorMapping.mirror(turn),
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))

        // MARK: renderer settings

        case .setRendererSourcePreference:
            let req = try Self.decodePayload(DaemonSetRendererSourcePreferenceRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (_, events) = try await captureEvents(store) {
                try await store.setRendererSourcePreference(
                    sourceID: SourceID(rawValue: req.sourceID),
                    preference: try DaemonStoreMirrorMapping.corePreference(
                        req.preference))
            }
            return try Self.encodeResult(DaemonSetRendererSourcePreferenceReply(
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))
        case .setRendererSourcePresentation:
            let req = try Self.decodePayload(DaemonSetRendererSourcePresentationRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (_, events) = try await captureEvents(store) {
                try await store.setRendererSourcePresentation(
                    sourceID: SourceID(rawValue: req.sourceID),
                    presentation: RendererSourcePresentationMode(
                        rawValue: req.presentation.rawValue) ?? .source)
            }
            return try Self.encodeResult(DaemonSetRendererSourcePresentationReply(
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))
        case .removeRendererSourcePresentation:
            let req = try Self.decodePayload(DaemonRemoveRendererSourcePresentationRequest.self, request)
            let stamp = try Self.requireStamp(request, operation.rawValue)
            let (_, events) = try await captureEvents(store) {
                try await store.removeRendererSourcePresentation(
                    sourceID: SourceID(rawValue: req.sourceID))
            }
            return try Self.encodeResult(DaemonRemoveRendererSourcePresentationReply(
                outcome: DaemonMutationOutcome(stamp: stamp, status: .committed),
                events: events.map(Self.mirrorEvent)))
        default:
            throw DaemonStoreError.unexpected(
                "\(operation.rawValue) is not part of the event-producer family")
        }
    }

    // MARK: - event capture (the store's own emit seam)

    /// Capture the events one store call actually emitted: subscribe on the
    /// wiki's event bus, call the store EXACTLY ONCE inside the closure,
    /// drain the dispatched handlers, unsubscribe. The executor never
    /// suppresses or duplicates events — `mutate(event:)` stays the store's
    /// job; this only LISTENS. Handlers ride `Task { @MainActor in … }` and
    /// were enqueued before the store call returned, so two hops onto the
    /// main actor drain them (same-actor jobs run in submission order);
    /// a busless store (never the daemon's case — the mandatory-bus
    /// invariant) captures nothing.
    private func captureEvents<T>(
        _ store: WikiStore,
        _ body: () async throws -> T
    ) async throws -> (value: T, events: [ResourceChangeEvent]) {
        let collector = StoreEventCollector()
        let bus = store.eventBus
        let token = bus?.subscribe(nil) { event in
            collector.append(event)
        }
        defer { if let token { bus?.unsubscribe(token) } }
        let value = try await body()
        await MainActor.run {}
        await MainActor.run {}
        return (value, collector.snapshot())
    }

    /// Map one core event to its wire mirror (kind raw string, id, change
    /// raw string, seq). The wikiID does not ride — the store envelope
    /// already scopes every operation to one wiki.
    static func mirrorEvent(_ event: ResourceChangeEvent) -> DaemonResourceChangeEvent {
        DaemonResourceChangeEvent(
            kind: event.kind?.rawValue, id: event.id,
            change: event.change.rawValue, seq: event.seq)
    }
}

/// The lock-guarded event bucket behind ``captureEvents``: appended from the
/// bus's `@MainActor` handler, read after the drain hops.
// swiftlint:disable:next unchecked_sendable
final class StoreEventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ResourceChangeEvent] = []

    func append(_ event: ResourceChangeEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> [ResourceChangeEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

// MARK: - List page token (the DaemonReplyCursor codec)

/// The daemon-side value behind ``DaemonReplyCursor``'s opaque `pageToken`:
/// base64(JSON) of the last-seen sort key + the accumulated encoded byte
/// count, BOUND to the wiki and operation that minted it. Deterministic:
/// encoding is a plain JSON encode, so the same walk state always produces
/// the same token.
struct DaemonStorePageToken: Codable, Equatable, Sendable {
    /// The wiki that minted the token (binding).
    let wikiID: String
    /// The operation that minted the token (binding).
    let operation: String
    /// The last-seen item's sort key (id / zero-padded seq / transcript
    /// cursor) for key-ordered listings; the decimal ordinal of the last
    /// served item for store-ordered listings.
    let lastKey: String
    /// The accumulated ENCODED byte estimate served so far.
    let bytesServed: Int
}

/// An `@unchecked Sendable` box for one admitted store reference crossing the
/// ledger's execution task. The concrete store is internally synchronized
/// (method-atomic), so the only hazard the box suppresses is the compiler's
/// existential-Sendable check; the store's own recursive entry-point lock is
/// the invariant that makes sharing safe.
// swiftlint:disable:next unchecked_sendable
private struct StoreBox: @unchecked Sendable {
    let store: WikiStore
}

// MARK: - Daemon epoch (store mutation admission)

/// The process-global monotonic counter behind `WikiDaemon.daemonEpoch`.
/// Each daemon instance claims the next value at init, so a restarted daemon
/// always presents an epoch greater than any previously served epoch: a
/// stamped mutation naming an older epoch is a typed rejection, never a
/// silent replay (plan 2a mutation outcome semantics). Safety invariant: the
/// single mutable `current` field is guarded by `lock` for the whole
/// claim-and-return critical section.
// swiftlint:disable:next unchecked_sendable
final class DaemonEpochCounter: @unchecked Sendable {

    private let lock = NSLock()
    private var current: UInt64 = 0

    func claimNext() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        current &+= 1
        return current
    }
}

// MARK: - Mutation outcome ledger (plan 2a)

/// The per-daemon mutation outcome state: the atomic in-flight admission
/// table keyed `(wikiID, requestID)` plus the bounded per-wiki outcome cache
/// (last ``DaemonStoreLimits/outcomeCacheCapacity`` requestIDs, FIFO
/// eviction). Identical concurrent duplicates JOIN one execution; ID reuse
/// with a different operation/payload fingerprint is a typed rejection;
/// `resolveOutcome` reads this ledger without ever dispatching.
///
/// Only COMMITTED (successful) outcomes are cached: a failed mutation leaves
/// no resolvable outcome, so a later resolve answers `outcomeUnknown` and the
/// client reconciles through change tokens — the plan's exactly-once rule.
// swiftlint:disable:next unchecked_sendable
final class DaemonStoreMutationLedger: @unchecked Sendable {

    private struct Key: Hashable {
        let wikiID: String
        let requestID: String
    }

    private struct InFlight {
        let operation: String
        let fingerprint: String
        let task: Task<Data, Error>
    }

    private struct CachedOutcome {
        let operation: String
        let fingerprint: String
        let result: Data
    }

    enum AdmissionOutcome {
        /// This submission executed the mutation (first admission won).
        case executed
        /// An identical in-flight duplicate joined an admission already
        /// running; the shared outcome rode with the winner's completion.
        case joined
        /// The requestID already committed on THIS daemon epoch; the cached
        /// outcome was served (an initial resubmission of a committed ID is
        /// answered exactly-once rather than re-executed).
        case cached
    }

    private var inFlight: [Key: InFlight] = [:]
    /// Per-wiki bounded outcome caches + their FIFO eviction order.
    private var cache: [String: [Key: CachedOutcome]] = [:]
    private var cacheOrder: [String: [Key]] = [:]
    /// Serial state queue (the daemon's established discipline): admission
    /// reads and the post-completion publish run here; the mutation work and
    /// the await on its task run OUTSIDE, so the queue is never held across
    /// a suspension.
    private let state = DispatchQueue(
        label: "com.selfdrivingwiki.wikid.store-mutation-ledger")

    /// Admit one stamped mutation and run it exactly once per requestID.
    /// The `work` closure runs at most once (the winner); joiners await the
    /// winner's task. Failures remove the admission WITHOUT caching, so a
    /// failed mutation can be retried with a fresh requestID and a resolve
    /// after a failure honestly answers `outcomeUnknown`.
    func perform(
        wikiID: String,
        stamp: DaemonMutationStamp,
        operation: String,
        fingerprint: String,
        work: @escaping @Sendable () async throws -> Data
    ) async throws -> (outcome: AdmissionOutcome, result: Data) {
        let key = Key(wikiID: wikiID, requestID: stamp.requestID)
        enum Admission {
            case cached(Data)
            case join(Task<Data, Error>)
            case execute(Task<Data, Error>)
        }
        let admission: Admission = try state.sync {
            if let cached = cache[wikiID]?[key] {
                guard cached.operation == operation,
                      cached.fingerprint == fingerprint else {
                    throw Self.fingerprintMismatch(requestID: stamp.requestID)
                }
                return .cached(cached.result)
            }
            if let flight = inFlight[key] {
                guard flight.operation == operation,
                      flight.fingerprint == fingerprint else {
                    throw Self.fingerprintMismatch(requestID: stamp.requestID)
                }
                return .join(flight.task)
            }
            let task = Task { try await work() }
            inFlight[key] = InFlight(
                operation: operation, fingerprint: fingerprint, task: task)
            return .execute(task)
        }
        switch admission {
        case .cached(let result):
            return (.cached, result)
        case .join(let task):
            return (.joined, try await task.value)
        case .execute(let task):
            do {
                let result = try await task.value
                state.sync {
                    inFlight[key] = nil
                    var wikiCache = cache[wikiID] ?? [:]
                    wikiCache[key] = CachedOutcome(
                        operation: operation, fingerprint: fingerprint,
                        result: result)
                    var order = cacheOrder[wikiID] ?? []
                    order.append(key)
                    if order.count > DaemonStoreLimits.outcomeCacheCapacity {
                        let evicted = order.removeFirst()
                        wikiCache[evicted] = nil
                    }
                    cache[wikiID] = wikiCache
                    cacheOrder[wikiID] = order
                }
                return (.executed, result)
            } catch {
                // A FAILED mutation leaves no resolvable outcome: the
                // admission is removed WITHOUT caching, so the next
                // resolve honestly answers `outcomeUnknown`.
                state.sync { inFlight[key] = nil }
                throw error
            }
        }
    }

    /// RESOLVE-ONLY lookup: joins an in-flight admission or reads the
    /// bounded cache; a miss answers `outcomeUnknown`. Throws the typed
    /// fingerprint rejection when the resolve names a different
    /// operation/payload than the admission it references. Epoch checking is
    /// the caller's job (the resolve reply cannot carry a typed error, so an
    /// epoch mismatch answers `outcomeUnknown` there instead of throwing).
    func resolve(
        wikiID: String,
        stamp: DaemonMutationStamp,
        operation: String,
        fingerprint: String,
        localFingerprint: String
    ) async throws -> DaemonResolveOutcomeReply {
        let key = Key(wikiID: wikiID, requestID: stamp.requestID)
        enum Admission {
            case cached(Data)
            case join(Task<Data, Error>)
            case miss
        }
        let admission: Admission = try state.sync {
            if let cached = cache[wikiID]?[key] {
                guard cached.operation == operation,
                      cached.fingerprint == fingerprint else {
                    throw Self.fingerprintMismatch(requestID: stamp.requestID)
                }
                return .cached(cached.result)
            }
            if let flight = inFlight[key] {
                guard flight.operation == operation,
                      flight.fingerprint == fingerprint else {
                    throw Self.fingerprintMismatch(requestID: stamp.requestID)
                }
                return .join(flight.task)
            }
            return .miss
        }
        switch admission {
        case .cached(let result):
            return DaemonResolveOutcomeReply(
                status: .committed, result: result, message: nil)
        case .join(let task):
            do {
                let result = try await task.value
                return DaemonResolveOutcomeReply(
                    status: .joined, result: result, message: nil)
            } catch {
                return DaemonResolveOutcomeReply(
                    status: .outcomeUnknown, result: nil,
                    message: "the in-flight mutation failed before "
                        + "committing: "
                        + String(describing: error).prefix(200).description)
            }
        case .miss:
            return DaemonResolveOutcomeReply(
                status: .outcomeUnknown, result: nil,
                message: "no in-flight admission and no cached outcome for "
                    + "requestID \(stamp.requestID) on this daemon epoch — "
                    + "reconcile through change tokens")
        }
    }

    private static func fingerprintMismatch(requestID: String) -> DaemonStoreError {
        .unexpected(
            "requestID \(requestID) is already admitted with a different "
                + "operation/payload fingerprint — reusing an ID with "
                + "different content is rejected; submit a new requestID")
    }
}

// MARK: - Staged payload store (plan 2a)

/// The per-daemon staged-upload table behind `payloadBegin` / `payloadChunk`
/// / `payloadCommit` / `payloadRead`: in-memory chunks + running SHA-256
/// verification per chunk, commit-time total hash + completeness verification,
/// TTL expiry (swept lazily on every access), and committed handles served
/// chunk-at-a-time through `payloadRead`. A partial upload NEVER becomes a
/// resolvable handle.
///
/// Disconnect cleanup: the XPC client slice will call
/// ``dropUploads(connectionID:)`` from its invalidation handler; every
/// record carries the optional connection id that staged it, so a sweep can
/// drop one connection's uploads without touching others. Slice 1 leaves the
/// sweep seam unwired (XPC disconnect cleanup arrives with the client slice).
// swiftlint:disable:next unchecked_sendable
final class DaemonPayloadStagingStore: @unchecked Sendable {

    private struct Upload {
        let declaredByteCount: Int
        let declaredSHA256Hex: String
        var chunks: [Data]
        var receivedByteCount: Int
        var runningDigest: SHA256
        var lastActivity: Date
        let connectionID: String?
    }

    private struct Committed {
        let handle: DaemonPayloadHandle
        let bytes: Data
        let expiresAt: Date
        let connectionID: String?
    }

    private var uploads: [String: Upload] = [:]
    private var committed: [String: Committed] = [:]
    /// Serial state queue (the daemon's established discipline). Every
    /// public method enters exactly once — expiry sweeping runs INSIDE the
    /// same block, never nested (DispatchQueue.sync is not reentrant).
    private let state = DispatchQueue(
        label: "com.selfdrivingwiki.wikid.store-payload-staging")

    /// Injectable for tests (the default generates real ULIDs).
    private let makeID: @Sendable () -> String
    private let clock: @Sendable () -> Date

    init(
        clock: @escaping @Sendable () -> Date = { Date() },
        makeID: @escaping @Sendable () -> String = { ULID.generate() }
    ) {
        self.clock = clock
        self.makeID = makeID
    }

    // MARK: begin

    func begin(
        _ request: DaemonPayloadBeginRequest, connectionID: String? = nil
    ) throws -> DaemonPayloadBeginReply {
        let now = clock()
        try validateBegin(request)
        let uploadID = makeID()
        state.sync {
            sweepExpiredLocked(now: now)
            uploads[uploadID] = Upload(
                declaredByteCount: request.declaredByteCount,
                declaredSHA256Hex: request.sha256Hex,
                chunks: [],
                receivedByteCount: 0,
                runningDigest: SHA256(),
                lastActivity: now,
                connectionID: connectionID)
        }
        return DaemonPayloadBeginReply(uploadID: uploadID)
    }

    /// Begin-time validation runs OUTSIDE the state queue (pure checks).
    private func validateBegin(_ request: DaemonPayloadBeginRequest) throws {
        guard request.declaredByteCount >= 0 else {
            throw DaemonStoreError.unexpected(
                "staged upload declared byte count must be non-negative, got "
                    + "\(request.declaredByteCount)")
        }
        guard request.declaredByteCount <= DaemonStoreLimits.maxTotalStagedBytes else {
            throw DaemonStoreError.unexpected(
                "staged upload declares \(request.declaredByteCount) bytes, "
                    + "above the \(DaemonStoreLimits.maxTotalStagedBytes)-byte cap")
        }
        guard Self.isValidSHA256Hex(request.sha256Hex) else {
            throw DaemonStoreError.unexpected(
                "staged upload declared SHA-256 must be 64 lowercase hex "
                    + "characters")
        }
    }

    // MARK: chunk

    func chunk(_ request: DaemonPayloadChunkRequest) throws -> DaemonPayloadChunkReply {
        let now = clock()
        return try state.sync {
            sweepExpiredLocked(now: now)
            guard var upload = uploads[request.uploadID] else {
                throw DaemonStoreError.unexpected(
                    "staging upload not found (unknown, committed, or "
                        + "expired): \(request.uploadID)")
            }
            guard request.orderIndex == upload.chunks.count else {
                throw DaemonStoreError.unexpected(
                    "chunk out of order: expected index "
                        + "\(upload.chunks.count), received "
                        + "\(request.orderIndex) — staged chunks must arrive "
                        + "strictly in sequence")
            }
            guard upload.receivedByteCount + request.bytes.count
                <= upload.declaredByteCount else {
                throw DaemonStoreError.unexpected(
                    "chunk would exceed the upload's declared byte count: "
                        + "received \(upload.receivedByteCount) so far, "
                        + "chunk carries \(request.bytes.count), declared "
                        + "\(upload.declaredByteCount)")
            }
            upload.runningDigest.update(data: request.bytes)
            let copy = upload.runningDigest
            let interim = copy.finalize()
                .map { String(format: "%02x", $0) }.joined()
            guard interim == request.runningSHA256Hex else {
                throw DaemonStoreError.unexpected(
                    "running hash mismatch at chunk \(request.orderIndex): "
                        + "the chunk sequence differs from the client's "
                        + "expectation")
            }
            upload.chunks.append(request.bytes)
            upload.receivedByteCount += request.bytes.count
            upload.lastActivity = now
            uploads[request.uploadID] = upload
            return DaemonPayloadChunkReply(
                receivedChunkCount: upload.chunks.count,
                receivedByteCount: upload.receivedByteCount)
        }
    }

    // MARK: commit

    func commit(
        _ request: DaemonPayloadCommitRequest, connectionID: String? = nil
    ) throws -> DaemonPayloadCommitReply {
        let now = clock()
        return try state.sync {
            sweepExpiredLocked(now: now)
            guard let upload = uploads[request.uploadID] else {
                throw DaemonStoreError.unexpected(
                    "staging upload not found (unknown, committed, or "
                        + "expired): \(request.uploadID)")
            }
            guard upload.receivedByteCount == upload.declaredByteCount else {
                throw DaemonStoreError.unexpected(
                    "commit incomplete: received \(upload.receivedByteCount) "
                        + "of \(upload.declaredByteCount) declared bytes — "
                        + "partial uploads never commit")
            }
            let copy = upload.runningDigest
            let total = copy.finalize()
                .map { String(format: "%02x", $0) }.joined()
            guard total == upload.declaredSHA256Hex else {
                throw DaemonStoreError.unexpected(
                    "declared hash mismatch: the received bytes hash to "
                        + "\(total), not the declared "
                        + "\(upload.declaredSHA256Hex)")
            }
            let handle = DaemonPayloadHandle(
                id: makeID(),
                declaredByteCount: upload.declaredByteCount,
                sha256Hex: upload.declaredSHA256Hex)
            let expiresAt = now.addingTimeInterval(
                DaemonStoreLimits.committedHandleTTLSeconds)
            committed[handle.id] = Committed(
                handle: handle,
                bytes: upload.chunks.reduce(into: Data()) { $0.append($1) },
                expiresAt: expiresAt,
                connectionID: connectionID ?? upload.connectionID)
            uploads[request.uploadID] = nil
            return DaemonPayloadCommitReply(handle: handle, expiresAt: expiresAt)
        }
    }

    // MARK: read

    func read(_ request: DaemonPayloadReadRequest) throws -> DaemonPayloadReadReply {
        let now = clock()
        return try state.sync {
            sweepExpiredLocked(now: now)
            guard let entry = committed[request.handleID] else {
                throw DaemonStoreError.unexpected(
                    "payload handle not found or expired: "
                        + "\(request.handleID)")
            }
            let chunkCount = max(
                1, (entry.bytes.count + DaemonStoreLimits.maxChunkBytes - 1)
                    / DaemonStoreLimits.maxChunkBytes)
            guard request.chunkIndex >= 0, request.chunkIndex < chunkCount else {
                throw DaemonStoreError.unexpected(
                    "chunk index \(request.chunkIndex) out of range for a "
                        + "\(chunkCount)-chunk payload handle")
            }
            let start = request.chunkIndex * DaemonStoreLimits.maxChunkBytes
            let end = min(
                start + DaemonStoreLimits.maxChunkBytes, entry.bytes.count)
            let slice = entry.bytes.subdata(in: start..<end)
            return DaemonPayloadReadReply(
                totalByteCount: entry.bytes.count,
                chunkIndex: request.chunkIndex,
                chunkCount: chunkCount,
                bytes: slice,
                isFinal: request.chunkIndex == chunkCount - 1)
        }
    }

    // MARK: consume (upload materialization)

    /// One-consumption read for UPLOAD handles: verifies the caller's
    /// declared byte count + SHA-256 against the stored bytes, then REMOVES
    /// the entry so the same handle can never execute twice — the blob
    /// family's materialization contract. Download handles (minted by
    /// ``commitCompleteBytes``) are read through `payloadRead` and never
    /// flow through here.
    func consume(matching handle: DaemonPayloadHandle) throws -> Data {
        let now = clock()
        return try state.sync {
            sweepExpiredLocked(now: now)
            guard let entry = committed[handle.id] else {
                throw DaemonStoreError.unexpected(
                    "payload handle not found, expired, or already "
                        + "consumed: \(handle.id)")
            }
            guard entry.bytes.count == handle.declaredByteCount else {
                committed[handle.id] = nil
                throw DaemonStoreError.unexpected(
                    "payload handle byte count mismatch: the staged payload "
                        + "carries \(entry.bytes.count) bytes but the handle "
                        + "declares \(handle.declaredByteCount)")
            }
            let digest = SHA256.hash(data: entry.bytes)
                .map { String(format: "%02x", $0) }.joined()
            guard digest == handle.sha256Hex else {
                committed[handle.id] = nil
                throw DaemonStoreError.unexpected(
                    "payload handle SHA-256 mismatch: the staged payload "
                        + "hashes to \(digest), not the declared "
                        + "\(handle.sha256Hex)")
            }
            committed[handle.id] = nil
            return entry.bytes
        }
    }

    // MARK: oversized-item promotion (plan 2a byte-budgeted replies)

    /// Commit ALREADY-COMPLETE bytes as a payload handle without the chunk
    /// flow — the daemon-side half of the oversized-single-item policy. The
    /// list/blob slices call this when one encoded reply item would exceed
    /// ``DaemonStoreLimits/listReplyBudgetEncodedBytes``: the reply carries
    /// the item's identity fields plus this handle, and `payloadRead` serves
    /// the bulk content. The small family's replies stay under budget by
    /// construction; the helper exists so the policy is one function.
    func commitCompleteBytes(
        _ bytes: Data, connectionID: String? = nil
    ) -> DaemonPayloadHandle {
        let digest = SHA256.hash(data: bytes)
            .map { String(format: "%02x", $0) }.joined()
        let handle = DaemonPayloadHandle(
            id: makeID(), declaredByteCount: bytes.count, sha256Hex: digest)
        let now = clock()
        state.sync {
            committed[handle.id] = Committed(
                handle: handle, bytes: bytes,
                expiresAt: now.addingTimeInterval(
                    DaemonStoreLimits.committedHandleTTLSeconds),
                connectionID: connectionID)
        }
        return handle
    }

    /// Whether one encoded item fits the reply budget inline.
    static func fitsReplyBudget(encodedByteCount: Int) -> Bool {
        encodedByteCount <= DaemonStoreLimits.listReplyBudgetEncodedBytes
    }

    // MARK: cleanup seams

    /// Drop every staged upload AND committed handle staged by one
    /// connection. The XPC client slice wires this to its invalidation
    /// handler; the domain-socket client slice does the same for its peers.
    func dropUploads(connectionID: String) {
        state.sync {
            uploads = uploads.filter { $0.value.connectionID != connectionID }
            committed = committed.filter { $0.value.connectionID != connectionID }
        }
    }

    /// Reap expired state now (an alternative to the lazy sweep on access).
    func sweepExpired() {
        sweepExpiredLocked(now: clock())
    }

    /// Expiry sweep: incomplete uploads past
    /// ``DaemonStoreLimits/stagedUploadTTLSeconds`` after their last chunk,
    /// committed handles past ``DaemonStoreLimits/committedHandleTTLSeconds``.
    /// MUST run inside `state` — every mutating entry point calls it once.
    /// A partial upload is never resolvable either way.
    private func sweepExpiredLocked(now: Date) {
        uploads = uploads.filter { entry in
            now.timeIntervalSince(entry.value.lastActivity)
                < DaemonStoreLimits.stagedUploadTTLSeconds
        }
        committed = committed.filter { now < $0.value.expiresAt }
    }

    private static func isValidSHA256Hex(_ value: String) -> Bool {
        value.count == 64
            && value.allSatisfy {
                ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f")
            }
    }
}

// MARK: - Mirror mappings (core ⇄ wire)

/// Total forward (core → wire) and reverse (wire → core) mappings for the
/// values the small family carries. Enum mirrors share raw values with the
/// domain, so every mapping is total; an unknown raw value on the wire is a
/// typed `unexpected` rejection rather than a silent default.
enum DaemonStoreMirrorMapping {

    // MARK: sources

    static func mirror(_ value: SourceSummary) -> DaemonSourceSummary {
        DaemonSourceSummary(
            id: value.id.rawValue, filename: value.filename, ext: value.ext,
            mimeType: value.mimeType, byteSize: value.byteSize,
            createdAt: value.createdAt, updatedAt: value.updatedAt,
            version: value.version, externalItemKey: value.externalItemKey,
            externalItemTitle: value.externalItemTitle,
            displayName: value.displayName, role: value.role.rawValue)
    }

    static func coreSourceSummary(_ value: DaemonSourceSummary) -> SourceSummary {
        SourceSummary(
            id: SourceID(rawValue: value.id), filename: value.filename,
            ext: value.ext, mimeType: value.mimeType,
            byteSize: value.byteSize, createdAt: value.createdAt,
            updatedAt: value.updatedAt, version: value.version,
            externalItemKey: value.externalItemKey,
            externalItemTitle: value.externalItemTitle,
            displayName: value.displayName,
            role: SourceRole(rawValue: value.role) ?? .primary)
    }

    static func mirror(_ value: SourceVersion) -> DaemonSourceVersion {
        DaemonSourceVersion(
            id: value.id.rawValue, sourceID: value.sourceID.rawValue,
            parentID: value.parentID?.rawValue, blobHash: value.blobHash,
            mimeType: value.mimeType, activityID: value.activityID,
            externalIdentity: value.externalIdentity,
            fetchedAt: value.fetchedAt)
    }

    static func mirror(_ value: SourceOrigin) -> DaemonSourceOrigin {
        DaemonSourceOrigin(
            versionID: value.versionID.rawValue, agentName: value.agentName,
            agentKind: value.agentKind, activityKind: value.activityKind,
            plan: value.plan, externalRef: value.externalRef,
            externalIdentity: value.externalIdentity,
            runTitle: value.runTitle, fetchedAt: value.fetchedAt)
    }

    // MARK: extraction provenance

    static func mirror(_ value: ExtractionProvenance) -> DaemonExtractionProvenance {
        DaemonExtractionProvenance(
            markdownVersionID: value.markdownVersionID.rawValue,
            sourceID: value.sourceID.rawValue,
            origin: DaemonSourceMarkdownOrigin(rawValue: value.origin.rawValue)
                ?? .extraction,
            producer: value.producer.map(mirror),
            providerID: value.providerID?.rawValue,
            modelID: value.modelID?.rawValue,
            toolVersion: value.toolVersion,
            createdAt: value.createdAt,
            sourceVersionID: value.sourceVersionID?.rawValue)
    }

    static func mirror(_ value: ExtractionProducer) -> DaemonExtractionProducer {
        switch value {
        case .backend(let backend):
            return .backend(rawBackend: backend.rawValue)
        case .tool(let tool):
            return .tool(rawTool: tool.rawValue)
        case .legacy(let rawTechnique):
            return .legacy(rawTechnique: rawTechnique)
        case .installedPackage(let package):
            return .installedPackage(mirrorPackageProducer(package))
        case .hostSpeech(let hostSpeech):
            return .hostSpeech(DaemonExtractionHostSpeechProducer(
                engine: hostSpeech.engine, localeID: hostSpeech.localeID,
                // The mirror carries the fetcher as one identity string; the
                // registration id is the stable identity of that exact
                // fetcher revision.
                acquisitionFetcher: hostSpeech.acquisitionFetcher
                    .registrationID.rawValue))
        }
    }

    static func mirrorPackageProducer(
        _ value: ExtractorPackageExecutionProvenance
    ) -> DaemonExtractorPackageProducer {
        DaemonExtractorPackageProducer(
            packageID: value.packageID, version: value.version,
            digestHex: value.digest,
            registrationID: value.registrationID.rawValue,
            // ExtractorProtocolRevision's raw value is an Int; the mirror
            // carries it as its string form.
            protocolRevision: String(value.protocolRevision.rawValue),
            reportedMetadata: DaemonExtractorReportedMetadata(
                toolName: value.reportedMetadata.toolName,
                toolVersion: value.reportedMetadata.toolVersion,
                modelName: value.reportedMetadata.modelName,
                modelVersion: value.reportedMetadata.modelVersion,
                language: value.reportedMetadata.language,
                transcriptGenerated: value.reportedMetadata.transcriptGenerated))
    }

    // MARK: chats

    static func mirror(_ value: ChatSummary) -> DaemonChatSummary {
        DaemonChatSummary(
            id: value.id.rawValue, kind: DaemonChatKind(rawValue: value.kind.rawValue) ?? .edit,
            title: value.title, createdAt: value.createdAt,
            updatedAt: value.updatedAt, messageCount: value.messageCount,
            acpSessionId: value.acpSessionId?.rawValue,
            modelProviderId: value.modelProviderId?.rawValue,
            modelId: value.modelId?.rawValue,
            configuredThinkingOptionID: value.configuredThinkingOptionID?.rawValue,
            effectiveThinkingOptionID: value.effectiveThinkingOptionID?.rawValue)
    }

    static func coreChatSummary(_ value: DaemonChatSummary) -> ChatSummary {
        ChatSummary(
            id: ChatID(rawValue: value.id),
            kind: ChatKind(rawValue: value.kind.rawValue) ?? .edit,
            title: value.title, createdAt: value.createdAt,
            updatedAt: value.updatedAt, messageCount: value.messageCount,
            acpSessionId: value.acpSessionId.map(AcpSessionID.init(rawValue:)),
            modelProviderId: value.modelProviderId.map(ProviderID.init(rawValue:)),
            modelId: value.modelId.map(ModelID.init(rawValue:)),
            configuredThinkingOptionID: value.configuredThinkingOptionID
                .map(ChatConfigurationValueID.init(rawValue:)),
            effectiveThinkingOptionID: value.effectiveThinkingOptionID
                .map(ChatConfigurationValueID.init(rawValue:)))
    }

    static func mirror(_ value: ChatAttachmentTarget) -> DaemonChatAttachmentTarget {
        switch value {
        case .page(let id): return .page(id: id.rawValue)
        case .source(let id): return .source(id: id.rawValue)
        case .chat(let id): return .chat(id: id.rawValue)
        }
    }

    static func mirror(_ value: ChatTranscriptCursor) -> DaemonChatTranscriptCursor {
        DaemonChatTranscriptCursor(rawValue: value.rawValue)
    }

    static func mirror(_ value: ChatTurnUsage) -> DaemonChatTurnUsage {
        DaemonChatTurnUsage(
            turnID: value.turnID.rawValue,
            providerID: value.providerID?.rawValue,
            modelID: value.modelID?.rawValue,
            startedAt: value.startedAt, finishedAt: value.finishedAt,
            state: DaemonChatTurnPersistenceState(
                rawValue: value.state.rawValue) ?? .queued,
            inputTokens: value.inputTokens, outputTokens: value.outputTokens,
            thoughtTokens: value.thoughtTokens,
            cacheReadTokens: value.cacheReadTokens,
            cacheWriteTokens: value.cacheWriteTokens,
            cost: value.cost, currency: value.currency)
    }

    static func mirror(_ value: ChatUsageSummary) -> DaemonChatUsageSummary {
        DaemonChatUsageSummary(
            latestTurn: value.latestTurn.map(mirror),
            inputTokens: value.inputTokens, outputTokens: value.outputTokens,
            thoughtTokens: value.thoughtTokens,
            cacheReadTokens: value.cacheReadTokens,
            cacheWriteTokens: value.cacheWriteTokens,
            cost: value.cost, currency: value.currency)
    }

    // MARK: pages

    static func mirror(_ value: WikiPageSummary) -> DaemonPageSummary {
        DaemonPageSummary(
            id: value.id.rawValue, title: value.title,
            updatedAt: value.updatedAt, createdAt: value.createdAt)
    }

    static func corePageSummary(_ value: DaemonPageSummary) -> WikiPageSummary {
        WikiPageSummary(
            id: PageID(rawValue: value.id), title: value.title,
            updatedAt: value.updatedAt, createdAt: value.createdAt)
    }

    static func mirror(_ value: PageVersionSource) -> DaemonPageVersionSource {
        DaemonPageVersionSource(
            pageVersionID: value.pageVersionID.rawValue,
            sourceID: value.sourceID.rawValue,
            role: DaemonPageVersionSourceRole(rawValue: value.role.rawValue) ?? .primary)
    }

    static func mirror(_ value: PageOrigin) -> DaemonPageOrigin {
        DaemonPageOrigin(
            versionID: value.versionID.rawValue, title: value.title,
            blobHash: value.blobHash,
            agentName: DaemonPageAuthor(rawValue: value.agentName.rawValue),
            agentKind: value.agentKind.rawValue,
            activityKind: value.activityKind.rawValue,
            plan: value.plan, externalRef: value.externalRef,
            runTitle: value.runTitle, savedAt: value.savedAt)
    }

    // MARK: OKF trust

    static func mirror(_ value: PageOKFTrustMetadata) -> DaemonPageOKFTrustMetadata {
        DaemonPageOKFTrustMetadata(
            pageID: value.pageID.rawValue, versionID: value.versionID.rawValue,
            metadata: mirror(value.metadata))
    }

    static func mirror(
        _ value: SourceMarkdownOKFTrustMetadata
    ) -> DaemonSourceMarkdownOKFTrustMetadata {
        DaemonSourceMarkdownOKFTrustMetadata(
            sourceID: value.sourceID.rawValue,
            versionID: value.versionID.rawValue,
            metadata: mirror(value.metadata))
    }

    static func mirror(_ value: OKFConceptMetadata) -> DaemonOKFConceptMetadata {
        DaemonOKFConceptMetadata(
            status: value.status.map { DaemonOKFConceptStatus(rawValue: $0.rawValue) ?? .draft },
            staleAfter: value.staleAfter,
            freshnessPolicy: value.freshnessPolicy.map(mirror),
            verifications: value.verifications.map(mirror),
            projectionRevision: value.projectionRevision)
    }

    static func mirror(_ value: OKFFreshnessPolicy) -> DaemonOKFFreshnessPolicy {
        switch value {
        case .fixed(let date):
            return .fixed(date: date)
        case .ttl(let seconds, let anchor):
            return .ttl(seconds: seconds, anchor: mirror(anchor))
        }
    }

    static func mirror(_ value: OKFFreshnessAnchor) -> DaemonOKFFreshnessAnchor {
        switch value {
        case .generated:
            return .generated
        case .verification(let id):
            return .verification(id: id.rawValue)
        case .recordedVerification:
            return .recordedVerification
        }
    }

    static func mirror(_ value: OKFVerifierIdentity) -> DaemonOKFVerifierIdentity {
        DaemonOKFVerifierIdentity(
            rawValue: value.rawValue,
            kind: DaemonOKFVerifierKind(rawValue: value.kind.rawValue) ?? .process,
            name: value.name, version: value.version)
    }

    static func mirror(_ value: OKFVerificationBasis) -> DaemonOKFVerificationBasis {
        DaemonOKFVerificationBasis(
            version: value.version,
            kind: DaemonOKFVerificationBasisKind(rawValue: value.kind.rawValue)
                ?? .sourceChecked,
            evidence: value.evidence.map(mirror),
            note: value.note)
    }

    static func mirror(_ value: OKFEvidenceReference) -> DaemonOKFEvidenceReference {
        switch value {
        case .source(let id):
            return .source(id: id.rawValue)
        case .external(let url):
            return .external(url: url.absoluteString)
        }
    }

    static func mirror(_ value: OKFVerificationEvent) -> DaemonOKFVerificationEvent {
        DaemonOKFVerificationEvent(
            id: value.id.rawValue, by: mirror(value.by),
            verifiedAt: value.verifiedAt, basis: mirror(value.basis),
            removedAt: value.removedAt,
            correctionActivityID: value.correctionActivityID?.rawValue,
            correctedBy: value.correctedBy.map(mirror),
            correctionReason: value.correctionReason.map(mirror))
    }

    static func mirror(
        _ value: OKFVerificationCorrectionReason
    ) -> DaemonOKFVerificationCorrectionReason {
        DaemonOKFVerificationCorrectionReason(
            version: value.version, reason: value.reason)
    }

    // MARK: renderer settings

    static func mirror(_ value: RendererSourcePreference) -> DaemonRendererSourcePreference {
        DaemonRendererSourcePreference(
            sourceID: value.sourceID.rawValue,
            preference: mirror(value.preference),
            updatedAtRFC3339: value.updatedAt.rawValue)
    }

    static func mirror(_ value: RendererSourcePresentation) -> DaemonRendererSourcePresentation {
        DaemonRendererSourcePresentation(
            sourceID: value.sourceID.rawValue,
            presentation: DaemonRendererSourcePresentationMode(
                rawValue: value.presentation.rawValue) ?? .source,
            updatedAtRFC3339: value.updatedAt.rawValue)
    }

    static func mirror(_ value: RendererPreferenceReference) -> DaemonRendererPreferenceReference {
        switch value {
        case .exact(let reference):
            return .exact(DaemonRendererReference(
                packageID: reference.packageID.rawValue,
                version: reference.version.rawValue,
                registrationID: reference.registrationID.rawValue))
        case .logical(let reference):
            return .logical(DaemonLogicalRendererReference(
                packageID: reference.packageID.rawValue,
                registrationID: reference.registrationID.rawValue))
        }
    }

    static func coreRendererInput(
        _ value: DaemonRendererBridgeInput
    ) throws -> RendererBridgeInput {
        switch value {
        case .source(let versionID):
            return .source(versionID: SourceVersionID(rawValue: versionID))
        case .markdown(let versionID):
            return .markdown(versionID: SourceMarkdownVersionID(rawValue: versionID))
        case .inlineArtifact:
            // MarkdownBlockID (pageID + pageVersionID + parserOrdinal +
            // digest) has no string codec, and the wire mirror carries the
            // block id as one string without the parser ordinal — so the
            // daemon cannot reconstruct a validated `InlineArtifact` from
            // the mirror yet. Typed rejection, not a silent default; the
            // mirror's identity fields stay intact for a later slice that
            // adds the ordinal (or a canonical block-id codec).
            throw DaemonStoreError.unexpected(
                "rendererInputByteCount(.inlineArtifact) is not served over "
                    + "the wire yet: the block-id mirror carries no parser "
                    + "ordinal to reconstruct the validated artifact")
        }
    }

    // MARK: strategy

    static func mirror(_ value: WikiStrategy) -> DaemonStrategySnapshot {
        DaemonStrategySnapshot(
            name: value.name, instructions: value.instructions,
            revision: value.revision.rawValue, updatedAt: value.updatedAt)
    }

    static func mirror(_ value: WikiStrategyState) -> DaemonWikiStrategyState {
        DaemonWikiStrategyState(
            strategy: value.strategy.map(mirror),
            revision: value.revision?.rawValue)
    }

    // MARK: workspaces

    static func mirror(_ value: WorkspaceSummary) -> DaemonWorkspaceSummary {
        DaemonWorkspaceSummary(
            id: value.id.rawValue, name: value.name,
            status: DaemonWorkspaceStatus(rawValue: value.status.rawValue) ?? .open,
            activityID: value.activityID, createdAt: value.createdAt,
            updatedAt: value.updatedAt)
    }

    // MARK: vacuum reports

    static func mirror(_ value: BlobVacuumReport) -> DaemonBlobVacuumReport {
        DaemonBlobVacuumReport(
            orphanCount: value.orphanCount,
            bytesReclaimed: value.bytesReclaimed, applied: value.applied)
    }

    static func mirror(_ value: ActivityVacuumReport) -> DaemonActivityVacuumReport {
        DaemonActivityVacuumReport(
            orphanCount: value.orphanCount, applied: value.applied)
    }

    static func mirror(_ value: PageVersionVacuumReport) -> DaemonPageVersionVacuumReport {
        DaemonPageVersionVacuumReport(
            deletedCount: value.deletedCount, applied: value.applied)
    }

    // MARK: deletion blockers (error payloads)

    static func mirror(
        _ value: ResourceDeletionRestriction
    ) -> DaemonDeletionBlockers {
        switch value {
        case .provenance(let blockers):
            return DaemonDeletionBlockers(ordered: blockers.ordered.map(mirror))
        }
    }

    // MARK: - slice 2: list / blob / event-producer value mirrors

    // MARK: pages (blob reads)

    /// `WikiPage` minus the body (the body crosses via a handle).
    static func mirrorPageMetadata(_ value: WikiPage) -> DaemonPageMetadata {
        DaemonPageMetadata(
            id: value.id.rawValue, title: value.title, slug: value.slug,
            createdAt: value.createdAt, updatedAt: value.updatedAt,
            version: value.version, createdBy: value.createdBy,
            lastEditedBy: value.lastEditedBy)
    }

    static func mirror(_ value: PageVersionSummary) -> DaemonPageVersionSummary {
        DaemonPageVersionSummary(
            id: value.id.rawValue, pageID: value.pageID.rawValue,
            parentID: value.parentID?.rawValue,
            mergeParentID: value.mergeParentID?.rawValue,
            blobHash: value.blobHash, title: value.title,
            activityID: value.activityID, savedAt: value.savedAt)
    }

    static func mirror(_ value: CitedPage) -> DaemonCitedPage {
        DaemonCitedPage(pageID: value.pageID.rawValue, title: value.title)
    }

    // MARK: composed page writes

    static func mirror(_ value: PageUpsert.Outcome) -> DaemonPageUpsertOutcome {
        DaemonPageUpsertOutcome(
            id: value.id.rawValue, didCreate: value.didCreate)
    }

    static func coreExpectation(
        _ value: DaemonPageWriteExpectation
    ) -> PageWriteExpectation {
        switch value {
        case .unrestricted:
            return .unrestricted
        case .expectedHead(let versionID):
            return .expectedHead(PageVersionID(rawValue: versionID))
        case .expectedAbsence:
            return .expectedAbsence
        }
    }

    static func coreVersionSourceInput(
        _ value: DaemonPageVersionSourceInput
    ) -> PageVersionSourceInput {
        PageVersionSourceInput(
            sourceID: SourceID(rawValue: value.sourceID),
            role: PageVersionSourceRole(rawValue: value.role.rawValue) ?? .primary)
    }

    static func coreParsedLink(_ value: DaemonParsedLink) -> ParsedLink {
        ParsedLink(
            linkType: ParsedLink.LinkType(rawValue: value.linkType.rawValue)
                ?? .page,
            target: value.target, fragment: value.fragment,
            linkText: value.linkText, isEmbed: value.isEmbed,
            versionPin: value.versionPin)
    }

    // MARK: wiki index / strategy save

    static func mirror(_ value: WikiStrategySaveOutcome) -> DaemonWikiStrategySaveOutcome {
        switch value {
        case .saved(let revision, let strategy):
            return .saved(
                revision: revision.rawValue, strategy: strategy.map(mirror))
        case .unchanged:
            return .unchanged
        }
    }

    // MARK: source markdown (blob reads + mutator echoes)

    static func mirror(_ value: SourceMarkdownVersion) -> DaemonSourceMarkdownVersionHeader {
        DaemonSourceMarkdownVersionHeader(
            id: value.id.rawValue, sourceID: value.sourceID.rawValue,
            parentID: value.parentID?.rawValue,
            origin: DaemonSourceMarkdownOrigin(rawValue: value.origin.rawValue)
                ?? .extraction,
            note: value.note, createdAt: value.createdAt,
            activityID: value.activityID,
            sourceVersionID: value.sourceVersionID?.rawValue,
            blobHash: value.blobHash, mimeType: value.mimeType,
            technique: value.technique)
    }

    /// The alternative's header (the wrapped version's full content never
    /// rides inline — the bulk crosses as one `[versionID: content]` handle).
    static func mirrorAlternativeHeader(
        _ value: ExtractionAlternative
    ) -> DaemonExtractionAlternative {
        DaemonExtractionAlternative(
            version: mirror(value.version),
            backendDisplayName: value.backendDisplayName,
            agentName: value.agentName, modelVersion: value.modelVersion,
            package: value.package.map(mirrorPackageProducer),
            charCount: value.charCount, isActive: value.isActive)
    }

    static func coreMarkdownOrigin(
        _ value: DaemonSourceMarkdownOrigin
    ) -> SourceMarkdownOrigin {
        SourceMarkdownOrigin(rawValue: value.rawValue) ?? .extraction
    }

    /// Reverse package-identity reconstruction: the wire mirror carries the
    /// exact immutable identity fields, so this is total except for
    /// validation failures (a malformed id/version/digest/protocol revision
    /// is a typed rejection, never a silent default).
    static func corePackageProducer(
        _ value: DaemonExtractorPackageProducer
    ) throws -> ExtractorPackageExecutionProvenance {
        let packageID: ExtractorPackageID
        do {
            packageID = try ExtractorPackageID(validating: value.packageID)
        } catch {
            throw DaemonStoreError.unexpected(
                "package producer carries an invalid package id: "
                    + value.packageID)
        }
        let version: ExtractorPackageVersion
        do {
            version = try ExtractorPackageVersion(validating: value.version)
        } catch {
            throw DaemonStoreError.unexpected(
                "package producer carries an invalid package version: "
                    + value.version)
        }
        let digest: ExtractorPackageDigest
        do {
            digest = try ExtractorPackageDigest(hex: value.digestHex)
        } catch {
            throw DaemonStoreError.unexpected(
                "package producer carries an invalid package digest: "
                    + value.digestHex)
        }
        let registrationID: ExtractorRegistrationID
        do {
            registrationID = try ExtractorRegistrationID(
                validating: value.registrationID)
        } catch {
            throw DaemonStoreError.unexpected(
                "package producer carries an invalid registration id: "
                    + value.registrationID)
        }
        guard let rawRevision = Int(value.protocolRevision),
              let protocolRevision = ExtractorProtocolRevision(
                rawValue: rawRevision) else {
            throw DaemonStoreError.unexpected(
                "package producer carries an invalid protocol revision: "
                    + value.protocolRevision)
        }
        return ExtractorPackageExecutionProvenance(
            revision: ExtractorPackageRevisionID(
                packageID: packageID, version: version, digest: digest),
            registrationID: registrationID,
            protocolRevision: protocolRevision,
            reportedMetadata: try Self.reportedMetadata(value.reportedMetadata))
    }

    /// Throwing core init → typed rejection (bounds/null-byte validation).
    private static func reportedMetadata(
        _ value: DaemonExtractorReportedMetadata
    ) throws -> ExtractorReportedMetadata {
        do {
            return try ExtractorReportedMetadata(
                toolName: value.toolName,
                toolVersion: value.toolVersion,
                modelName: value.modelName,
                modelVersion: value.modelVersion,
                language: value.language,
                transcriptGenerated: value.transcriptGenerated)
        } catch {
            throw DaemonStoreError.unexpected(
                "package producer carries invalid reported metadata: "
                    + DaemonStoreCommandExecutor.errorText(error))
        }
    }

    /// Reverse producer mapping. `.hostSpeech` is a typed rejection: the
    /// wire mirror carries the acquisition fetcher as ONE identity string
    /// (the registration id), but the core producer needs the fetcher's
    /// exact package identity the mirror dropped — no honest reconstruction
    /// exists without a contract change.
    static func coreProducer(
        _ value: DaemonExtractionProducer
    ) throws -> ExtractionProducer {
        switch value {
        case .backend(let rawBackend):
            guard let backend = ExtractionBackend(rawValue: rawBackend) else {
                throw DaemonStoreError.unexpected(
                    "producer backend is not a known ExtractionBackend raw "
                        + "value: \(rawBackend)")
            }
            return .backend(backend)
        case .tool(let rawTool):
            guard let tool = ExtractionTool(rawValue: rawTool) else {
                throw DaemonStoreError.unexpected(
                    "producer tool is not a known ExtractionTool raw value: "
                        + rawTool)
            }
            return .tool(tool)
        case .legacy(let rawTechnique):
            return .legacy(rawTechnique: rawTechnique)
        case .installedPackage(let package):
            return .installedPackage(try corePackageProducer(package))
        case .hostSpeech:
            throw DaemonStoreError.unexpected(
                "the host-speech producer mirror carries the acquisition "
                    + "fetcher as one identity string without the exact "
                    + "package identity the core producer requires")
        }
    }

    // MARK: source ingestion (addSource / addBytelessSource)

    static func coreHints(
        _ value: DaemonContentTypeDetectionHints
    ) -> ContentTypeDetectionHints {
        ContentTypeDetectionHints(
            declaredMIME: value.declaredMIME.map {
                DeclaredMIME($0.value, origin: DeclaredMIMEOrigin(
                    rawValue: $0.origin.rawValue) ?? .localUTI)
            },
            filenameExtension: value.filenameExtension,
            utiMIME: value.utiMIME)
    }

    static func coreIngestMetadata(
        _ value: DaemonSourceIngestMetadata
    ) -> SourceIngestMetadata {
        SourceIngestMetadata(
            externalItemID: value.externalItemID,
            externalItemTitle: value.externalItemTitle)
    }

    static func coreProvenance(_ value: DaemonSourceProvenance) -> SourceProvenance {
        SourceProvenance(
            agentName: value.agentName, agentKind: value.agentKind,
            agentVersion: value.agentVersion, activityKind: value.activityKind,
            plan: value.plan, externalRef: value.externalRef,
            externalIdentity: value.externalIdentity)
    }

    // MARK: list family value mirrors

    static func mirror(_ value: SourceEmbedDescriptor) -> DaemonSourceEmbedDescriptor {
        DaemonSourceEmbedDescriptor(
            id: value.id.rawValue, mimeType: value.mimeType,
            externalIdentity: value.externalIdentity,
            agentName: value.agentName, planURL: value.planURL)
    }

    static func mirror(_ value: DeletionImpact) -> DaemonDeletionImpact {
        DaemonDeletionImpact(
            linkingPages: value.linkingPages.map {
                DaemonDeletionLinkingPage(
                    pageID: $0.pageID.rawValue, title: $0.title)
            },
            bookmarks: value.bookmarks.map {
                DaemonDeletionBookmarkImpact(
                    nodeID: $0.nodeID.rawValue, folderPath: $0.folderPath)
            },
            provenanceBlockers: value.provenanceBlockers.map(mirror),
            incomingLinkCount: value.incomingLinkCount)
    }

    /// One provenance blocker (shared by the deletion restriction's typed
    /// error payload and `deletionImpact`'s blocker list).
    static func mirror(
        _ value: ProvenanceDeletionBlocker
    ) -> DaemonProvenanceDeletionBlocker {
        DaemonProvenanceDeletionBlocker(
            sourceID: value.sourceID.rawValue,
            pageVersionID: value.pageVersionID.rawValue,
            pageID: value.pageID.rawValue)
    }

    static func coreDeletionTarget(
        _ value: DaemonResourceDeletionTarget
    ) -> ResourceDeletionTarget {
        switch value {
        case .page(let id):
            return .page(PageID(rawValue: id))
        case .source(let id):
            return .source(SourceID(rawValue: id))
        }
    }

    static func mirror(
        _ value: ResourceDeletionTarget
    ) -> DaemonResourceDeletionTarget {
        switch value {
        case .page(let id):
            return .page(id: id.rawValue)
        case .source(let id):
            return .source(id: id.rawValue)
        }
    }

    static func mirror(_ value: ResourceDeletionResult) -> DaemonResourceDeletionResult {
        DaemonResourceDeletionResult(
            deletedTargets: value.deletedTargets.map(mirror),
            rewrittenPageIDs: value.rewrittenPageIDs.map(\.rawValue),
            removedBookmarkIDs: value.removedBookmarkIDs.map(\.rawValue),
            incomingLinkCount: value.incomingLinkCount)
    }

    // MARK: workspaces

    static func mirror(_ value: WorkspaceRef) -> DaemonWorkspaceRef {
        DaemonWorkspaceRef(
            workspaceID: value.workspaceID.rawValue,
            ownerID: value.ownerID.rawValue,
            baseVersionID: value.baseVersionID?.rawValue,
            versionID: value.versionID?.rawValue,
            blobHash: value.blobHash, title: value.title,
            updatedAt: value.updatedAt)
    }

    static func mirror(_ value: WorkspaceConflict) -> DaemonWorkspaceConflict {
        DaemonWorkspaceConflict(
            workspaceID: value.workspaceID.rawValue,
            pageID: value.pageID.rawValue,
            baseVersionID: value.baseVersionID?.rawValue,
            mainVersionID: value.mainVersionID?.rawValue,
            workspaceTarget: mirror(value.workspaceTarget),
            createdAt: value.createdAt)
    }

    static func mirror(
        _ value: WorkspaceConflict.Target
    ) -> DaemonWorkspaceConflictTarget {
        switch value {
        case .pageVersion(let id):
            return .pageVersion(id: id.rawValue)
        case .stagedBlob(let hash):
            return .stagedBlob(hash: hash)
        }
    }

    // MARK: log

    static func mirror(_ value: LogEntry) -> DaemonLogEntry {
        DaemonLogEntry(
            id: value.id.rawValue, timestamp: value.timestamp,
            kind: DaemonLogEntry.Kind(rawValue: value.kind.rawValue) ?? .ingest,
            title: value.title, note: value.note)
    }

    // MARK: bookmarks

    static func mirror(_ value: BookmarkNode) -> DaemonBookmarkNode {
        DaemonBookmarkNode(
            id: value.id.rawValue, parentID: value.parentID?.rawValue,
            position: value.position, content: mirror(value.content),
            createdAt: value.createdAt, updatedAt: value.updatedAt)
    }

    static func mirror(_ value: BookmarkNode.Content) -> DaemonBookmarkContent {
        switch value {
        case .folder(let label):
            return .folder(label: label)
        case .page(let id):
            return .page(id: id.rawValue)
        case .source(let id):
            return .source(id: id.rawValue)
        case .chat(let id):
            return .chat(id: id.rawValue)
        }
    }

    static func coreBookmarkContent(
        _ value: DaemonBookmarkContent
    ) -> BookmarkNode.Content {
        switch value {
        case .folder(let label):
            return .folder(label: label)
        case .page(let id):
            return .page(PageID(rawValue: id))
        case .source(let id):
            return .source(SourceID(rawValue: id))
        case .chat(let id):
            return .chat(ChatID(rawValue: id))
        }
    }

    // MARK: chats

    static func mirror(_ value: ChatMessage) -> DaemonChatMessage {
        DaemonChatMessage(
            id: value.id.rawValue, chatID: value.chatID.rawValue,
            seq: value.seq, event: mirror(value.event),
            createdAt: value.createdAt, isDraft: value.isDraft)
    }

    static func mirror(_ value: AgentEvent) -> DaemonAgentEvent {
        switch value {
        case .userText(let text):
            return .userText(text: text)
        case .systemInit(let model):
            return .systemInit(model: model)
        case .assistantText(let text):
            return .assistantText(text: text)
        case .thinking(let text):
            return .thinking(text: text)
        case .thinkingDelta(let text):
            return .thinkingDelta(text: text)
        case .assistantTextDelta(let text):
            return .assistantTextDelta(text: text)
        case .toolUse(let name, let inputSummary):
            return .toolUse(name: name, inputSummary: inputSummary)
        case .toolResult(let isError, let summary):
            return .toolResult(isError: isError, summary: summary)
        case .subagent(let subagentType, let description, let isCompletion):
            return .subagent(
                subagentType: subagentType, description: description,
                isCompletion: isCompletion)
        case .result(let isError, let text):
            return .result(isError: isError, text: text)
        case .messageStop:
            return .messageStop
        case .turnFailed(let reason):
            return .turnFailed(reason: mirror(reason))
        case .raw(let line):
            return .raw(line: line)
        }
    }

    static func mirror(_ value: TurnFailureReason) -> DaemonTurnFailureReason {
        switch value {
        case .stalled(let idleSeconds):
            return .stalled(idleSeconds: idleSeconds)
        case .ceilingExceeded(let totalSeconds):
            return .ceilingExceeded(totalSeconds: totalSeconds)
        case .agentError(let message):
            return .agentError(message: message)
        case .quotaExhausted(let provider, let resetTime):
            return .quotaExhausted(providerID: provider.rawValue, resetTime: resetTime)
        }
    }

    static func coreAgentEvent(_ value: DaemonAgentEvent) -> AgentEvent {
        switch value {
        case .userText(let text):
            return .userText(text)
        case .systemInit(let model):
            return .systemInit(model: model)
        case .assistantText(let text):
            return .assistantText(text)
        case .thinking(let text):
            return .thinking(text)
        case .thinkingDelta(let text):
            return .thinkingDelta(text)
        case .assistantTextDelta(let text):
            return .assistantTextDelta(text)
        case .toolUse(let name, let inputSummary):
            return .toolUse(name: name, inputSummary: inputSummary)
        case .toolResult(let isError, let summary):
            return .toolResult(isError: isError, summary: summary)
        case .subagent(let subagentType, let description, let isCompletion):
            return .subagent(
                subagentType: subagentType, description: description,
                isCompletion: isCompletion)
        case .result(let isError, let text):
            return .result(isError: isError, text: text)
        case .messageStop:
            return .messageStop
        case .turnFailed(let reason):
            return .turnFailed(reason: coreTurnFailureReason(reason))
        case .raw(let line):
            return .raw(line)
        }
    }

    static func coreTurnFailureReason(
        _ value: DaemonTurnFailureReason
    ) -> TurnFailureReason {
        switch value {
        case .stalled(let idleSeconds):
            return .stalled(idleSeconds: idleSeconds)
        case .ceilingExceeded(let totalSeconds):
            return .ceilingExceeded(totalSeconds: totalSeconds)
        case .agentError(let message):
            return .agentError(message)
        case .quotaExhausted(let providerID, let resetTime):
            return .quotaExhausted(
                provider: ProviderID(rawValue: providerID), resetTime: resetTime)
        }
    }

    // MARK: persisted chat turns (blob + event family)

    static func mirror(_ value: ChatTurnSubmission) -> DaemonChatTurnSubmission {
        DaemonChatTurnSubmission(
            commandID: value.commandID.rawValue, turnID: value.turnID.rawValue,
            userText: value.userText,
            contextReferences: value.contextReferences.map { reference in
                switch reference {
                case .page(let id):
                    return .page(id: id.rawValue)
                case .source(let id):
                    return .source(id: id.rawValue)
                case .chat(let id):
                    return .chat(id: id.rawValue)
                }
            },
            submittedAt: value.submittedAt)
    }

    static func coreTurnSubmission(
        _ value: DaemonChatTurnSubmission
    ) -> ChatTurnSubmission {
        ChatTurnSubmission(
            commandID: ChatCommandID(rawValue: value.commandID),
            turnID: ChatTurnID(rawValue: value.turnID),
            userText: value.userText,
            contextReferences: value.contextReferences.map { reference in
                switch reference {
                case .page(let id):
                    return .page(PageID(rawValue: id))
                case .source(let id):
                    return .source(SourceID(rawValue: id))
                case .chat(let id):
                    return .chat(ChatID(rawValue: id))
                }
            },
            submittedAt: value.submittedAt)
    }

    static func mirror(_ value: ChatTurnUsageValues) -> DaemonChatTurnUsageValues {
        DaemonChatTurnUsageValues(
            inputTokens: value.inputTokens, outputTokens: value.outputTokens,
            thoughtTokens: value.thoughtTokens,
            cacheReadTokens: value.cacheReadTokens,
            cacheWriteTokens: value.cacheWriteTokens,
            cost: value.cost, currency: value.currency)
    }

    static func coreUsageValues(
        _ value: DaemonChatTurnUsageValues
    ) -> ChatTurnUsageValues {
        ChatTurnUsageValues(
            inputTokens: value.inputTokens, outputTokens: value.outputTokens,
            thoughtTokens: value.thoughtTokens,
            cacheReadTokens: value.cacheReadTokens,
            cacheWriteTokens: value.cacheWriteTokens,
            cost: value.cost, currency: value.currency)
    }

    static func mirror(_ value: PersistedChatTurn) -> DaemonPersistedChatTurn {
        DaemonPersistedChatTurn(
            chatID: value.chatID.rawValue, ordinal: value.ordinal,
            submission: mirror(value.submission),
            editedAt: value.editedAt,
            state: DaemonChatTurnPersistenceState(
                rawValue: value.state.rawValue) ?? .queued,
            claimID: value.claimID?.rawValue,
            claimedAt: value.claimedAt,
            providerSubmittedAt: value.providerSubmittedAt,
            providerSessionID: value.providerSessionID?.rawValue,
            terminalMessage: value.terminalMessage,
            providerID: value.providerID?.rawValue,
            modelID: value.modelID?.rawValue,
            finishedAt: value.finishedAt,
            usage: mirror(value.usage))
    }

    // MARK: typed transcript (blob + list family)

    static func mirror(
        _ value: ChatTranscriptItem
    ) -> DaemonChatTranscriptItem {
        switch value {
        case .message(let item):
            return .message(DaemonChatTranscriptMessageItem(
                messageID: item.messageID.rawValue,
                turnID: item.turnID.rawValue,
                role: DaemonChatTranscriptMessageRole(
                    rawValue: item.role.rawValue) ?? .user,
                text: item.text, createdAt: item.createdAt))
        case .toolCall(let item):
            return .toolCall(DaemonChatTranscriptToolCallItem(
                toolCallID: item.toolCallID.rawValue,
                turnID: item.turnID.rawValue, toolName: item.toolName,
                status: DaemonChatToolCallStatus(
                    rawValue: item.status.rawValue) ?? .pending,
                detail: item.detail, output: item.output,
                permissionRequestID: item.permissionRequestID?.rawValue,
                updatedAt: item.updatedAt))
        case .systemNotice(let item):
            return .systemNotice(DaemonChatTranscriptSystemNoticeItem(
                noticeID: item.noticeID.rawValue,
                turnID: item.turnID?.rawValue,
                kind: DaemonChatSystemNoticeKind(
                    rawValue: item.kind.rawValue) ?? .session,
                title: item.title, message: item.message,
                createdAt: item.createdAt))
        case .turnFailure(let item):
            return .turnFailure(DaemonChatTranscriptTurnFailureItem(
                failureID: item.failureID.rawValue,
                turnID: item.turnID.rawValue,
                category: DaemonChatTurnFailureCategory(
                    rawValue: item.category.rawValue) ?? .runtimeError,
                message: item.message, createdAt: item.createdAt))
        }
    }

    static func coreTranscriptItem(
        _ value: DaemonChatTranscriptItem
    ) -> ChatTranscriptItem {
        switch value {
        case .message(let item):
            return .message(ChatTranscriptMessageItem(
                messageID: ChatMessageID(rawValue: item.messageID),
                turnID: ChatTurnID(rawValue: item.turnID),
                role: ChatTranscriptMessageRole(
                    rawValue: item.role.rawValue) ?? .user,
                text: item.text, createdAt: item.createdAt))
        case .toolCall(let item):
            return .toolCall(ChatTranscriptToolCallItem(
                toolCallID: ToolCallID(rawValue: item.toolCallID),
                turnID: ChatTurnID(rawValue: item.turnID),
                toolName: item.toolName,
                status: ChatToolCallStatus(
                    rawValue: item.status.rawValue) ?? .pending,
                detail: item.detail, output: item.output,
                permissionRequestID: item.permissionRequestID.map(
                    PermissionRequestID.init(rawValue:)),
                updatedAt: item.updatedAt))
        case .systemNotice(let item):
            return .systemNotice(ChatTranscriptSystemNoticeItem(
                noticeID: ChatTranscriptNoticeID(rawValue: item.noticeID),
                turnID: item.turnID.map(ChatTurnID.init(rawValue:)),
                kind: ChatSystemNoticeKind(
                    rawValue: item.kind.rawValue) ?? .session,
                title: item.title, message: item.message,
                createdAt: item.createdAt))
        case .turnFailure(let item):
            return .turnFailure(ChatTranscriptTurnFailureItem(
                failureID: ChatTranscriptFailureID(rawValue: item.failureID),
                turnID: ChatTurnID(rawValue: item.turnID),
                category: ChatTurnFailureCategory(
                    rawValue: item.category.rawValue) ?? .runtimeError,
                message: item.message, createdAt: item.createdAt))
        }
    }

    static func mirror(
        _ value: PersistedChatTranscriptItem
    ) -> DaemonPersistedChatTranscriptItem {
        DaemonPersistedChatTranscriptItem(
            cursor: mirror(value.cursor), item: mirror(value.item),
            projectedEventJSON: value.projectedEventJSON,
            projectedPlainText: value.projectedPlainText,
            createdAt: value.createdAt, summary: value.summary)
    }

    // MARK: chats (event family)

    static func coreAttachmentTarget(
        _ value: DaemonChatAttachmentTarget
    ) -> ChatAttachmentTarget {
        switch value {
        case .page(let id):
            return .page(PageID(rawValue: id))
        case .source(let id):
            return .source(SourceID(rawValue: id))
        case .chat(let id):
            return .chat(ChatID(rawValue: id))
        }
    }

    // MARK: renderer settings (event family)

    static func corePreference(
        _ value: DaemonRendererPreferenceReference
    ) throws -> RendererPreferenceReference {
        // Renderer identity types carry failable validating inits; a
        // malformed identity string is a typed rejection.
        func packageID(_ raw: String) throws -> RendererPackageID {
            guard let id = RendererPackageID(rawValue: raw) else {
                throw DaemonStoreError.unexpected(
                    "renderer preference carries an invalid package id: " + raw)
            }
            return id
        }
        func registrationID(_ raw: String) throws -> RendererRegistrationID {
            guard let id = RendererRegistrationID(rawValue: raw) else {
                throw DaemonStoreError.unexpected(
                    "renderer preference carries an invalid registration id: "
                        + raw)
            }
            return id
        }
        switch value {
        case .exact(let reference):
            guard let version = RendererPackageVersion(
                rawValue: reference.version) else {
                throw DaemonStoreError.unexpected(
                    "renderer preference carries an invalid package version: "
                        + reference.version)
            }
            return .exact(RendererReference(
                packageID: try packageID(reference.packageID),
                version: version,
                registrationID: try registrationID(reference.registrationID)))
        case .logical(let reference):
            return .logical(LogicalRendererReference(
                packageID: try packageID(reference.packageID),
                registrationID: try registrationID(reference.registrationID)))
        }
    }

    // MARK: MIME repair (event family)

    static func mirror(_ value: MIMERepairReport) -> DaemonMIMERepairReport {
        DaemonMIMERepairReport(
            scannedCount: value.scannedCount,
            repairableCount: value.repairableCount,
            updatedCount: value.updatedCount,
            skippedBytelessCount: value.skippedBytelessCount,
            skippedInconclusiveCount: value.skippedInconclusiveCount,
            applied: value.applied,
            items: value.items.map(mirror))
    }

    static func mirror(_ value: MIMERepairItem) -> DaemonMIMERepairItem {
        DaemonMIMERepairItem(
            sourceID: value.sourceID.rawValue,
            sourceVersionID: value.sourceVersionID.rawValue,
            filename: value.filename,
            nullState: DaemonMIMERepairNullState(
                rawValue: value.nullState.rawValue) ?? .neither,
            oldSourceMIMEType: value.oldSourceMIMEType,
            oldVersionMIMEType: value.oldVersionMIMEType,
            newMIMEType: value.newMIMEType,
            detection: mirror(value.detection),
            status: DaemonMIMERepairStatus(
                rawValue: value.status.rawValue) ?? .inconclusive,
            updated: value.updated)
    }

    static func mirror(
        _ value: ContentTypeDetectionResult
    ) -> DaemonContentTypeDetectionResult {
        DaemonContentTypeDetectionResult(
            normalizedMIMEType: value.normalizedMIMEType,
            evidence: value.evidence.map(mirror),
            confidence: value.confidence.map {
                DaemonContentTypeConfidence(rawValue: $0.rawValue) ?? .fallback
            },
            conflicts: value.conflicts.map(mirror),
            structuredArtifactKind: value.structuredArtifactKind.map { _ in
                // Single-case mirror: the sole members of both enums
                // correspond (equal raw values by wire-format construction).
                DaemonContentArtifactKind.sole
            })
    }

    static func mirror(_ value: ContentTypeEvidence) -> DaemonContentTypeEvidence {
        DaemonContentTypeEvidence(
            origin: DaemonContentTypeEvidenceOrigin(
                rawValue: value.origin.rawValue) ?? .filenameExtension,
            mimeType: value.mimeType,
            confidence: DaemonContentTypeConfidence(
                rawValue: value.confidence.rawValue) ?? .fallback,
            detail: value.detail)
    }

    static func mirror(_ value: ContentTypeConflict) -> DaemonContentTypeConflict {
        DaemonContentTypeConflict(
            kind: DaemonContentTypeConflictKind(
                rawValue: value.kind.rawValue) ?? .disagreement,
            chosenMIMEType: value.chosenMIMEType,
            conflictingEvidence: mirror(value.conflictingEvidence))
    }

    // MARK: OKF trust (event family)

    /// Reverse verifier mapping: the core initializer PARSES the raw
    /// identity string, so the mirror's kind/name/version fields must agree
    /// with the parse — a mismatch is a typed rejection, never a silent
    /// reinterpretation.
    static func coreVerifier(
        _ value: DaemonOKFVerifierIdentity
    ) throws -> OKFVerifierIdentity {
        let parsed: OKFVerifierIdentity
        do {
            parsed = try OKFVerifierIdentity(value.rawValue)
        } catch {
            throw DaemonStoreError.unexpected(
                "OKF verifier identity is not parseable: \(value.rawValue)")
        }
        let mirrorKind = OKFVerifierIdentity.Kind(
            rawValue: value.kind.rawValue) ?? .process
        guard parsed.kind == mirrorKind, parsed.name == value.name,
              parsed.version == value.version else {
            throw DaemonStoreError.unexpected(
                "OKF verifier mirror fields disagree with the parsed raw "
                    + "identity \(value.rawValue)")
        }
        return parsed
    }

    static func coreBasis(_ value: DaemonOKFVerificationBasis) -> OKFVerificationBasis {
        OKFVerificationBasis(
            kind: OKFVerificationBasisKind(
                rawValue: value.kind.rawValue) ?? .sourceChecked,
            evidence: value.evidence.map { reference in
                switch reference {
                case .source(let id):
                    return .source(SourceID(rawValue: id))
                case .external(let url):
                    return .external(URL(string: url) ?? URL(fileURLWithPath: "/"))
                }
            },
            note: value.note)
    }

    static func coreFreshness(_ value: DaemonOKFFreshnessPolicy) -> OKFFreshnessPolicy {
        switch value {
        case .fixed(let date):
            return .fixed(date)
        case .ttl(let seconds, let anchor):
            switch anchor {
            case .generated:
                return .ttl(seconds: seconds, anchor: .generated)
            case .verification(let id):
                return .ttl(seconds: seconds, anchor: .verification(
                    OKFVerificationID(rawValue: id)))
            case .recordedVerification:
                return .ttl(seconds: seconds, anchor: .recordedVerification)
            }
        }
    }

    static func coreCorrectionReason(
        _ value: DaemonOKFVerificationCorrectionReason
    ) -> OKFVerificationCorrectionReason {
        OKFVerificationCorrectionReason(reason: value.reason)
    }
}
#endif
