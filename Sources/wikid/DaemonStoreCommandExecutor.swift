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
    /// family (this slice serves small + staged-payload + resolveOutcome) →
    /// `resolveOutcome` NEVER dispatches → staged-payload ops are
    /// daemon-scoped (no store resolution) → everything else resolves the
    /// store through ``WikiDaemon/domainCommandStore(wikiID:)`` (admission
    /// included), admits stamped mutations through the outcome ledger, and
    /// dispatches by operation.
    func handleStoreOperation(
        _ domainRequest: DaemonDomainRequest,
        expectedWikiID: String? = nil
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

        // Family gate: later slices complete list / blob / event producers.
        switch operation.family {
        case .small, .stagedPayload:
            break
        case .mutationSemantics:
            guard operation == .resolveOutcome else {
                return Self.reservedReply(domainRequest, operation)
            }
        case .list, .blob, .eventProducer, .reservedEvents:
            return Self.reservedReply(domainRequest, operation)
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
                result = try await executeAdmittedMutation(
                    daemon: daemon, store: store,
                    storeRequest: storeRequest, operation: operation,
                    stamp: stamp)
            } else {
                // Reads ignore no stamp — a stamp on a read is a client bug
                // the contract spells as "nil for reads"; it is rejected
                // below instead of silently ignored. (See the mutator cases:
                // they REQUIRE a stamp, so unstamped mutators are rejected
                // inside the dispatch, not here.)
                if Self.smallMutators.contains(operation) {
                    return Self.storeErrorReply(
                        domainRequest, storeRequest,
                        .unexpected(
                            "\(operation.rawValue) is a mutation and requires "
                                + "an admission stamp"))
                }
                if storeRequest.stamp != nil {
                    return Self.storeErrorReply(
                        domainRequest, storeRequest,
                        .unexpected(
                            "\(operation.rawValue) is a read and carries no "
                                + "mutation stamp"))
                }
                result = try await Self.dispatchSmall(
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
            try await Self.dispatchSmall(
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

    private static func errorText(_ error: Error) -> String {
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
            return DaemonDeletionBlockers(ordered: blockers.ordered.map {
                DaemonProvenanceDeletionBlocker(
                    sourceID: $0.sourceID.rawValue,
                    pageVersionID: $0.pageVersionID.rawValue,
                    pageID: $0.pageID.rawValue)
            })
        }
    }
}
#endif
