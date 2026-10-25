#if os(macOS)
import Foundation
import WikiDaemonContract
import WikiFSCore

/// Payload-level dispatch for the daemon's CLI socket — the one socket file
/// from PR #1460 now carries every CLI⇄daemon family, not just search.
///
/// The byte-level transport (`DaemonSearchSocketServer`: framing, flock guard,
/// same-user gate, deadlines) is unchanged; its `Data -> Data` handler is THIS
/// dispatcher instead of `searchData` directly. The handler decodes the
/// versioned domain envelope (`DaemonDomainWire`), version-checks before
/// dispatch, routes by family, and ALWAYS answers with an encoded
/// `DaemonDomainReply` — an unknown family/operation or a malformed payload
/// is a typed `invalidRequest` reply, never a transport failure.
///
/// Connection contexts (plans/agent-sandbox-scoping.md §6): the ordinary
/// socket keeps the exact pre-scoping behavior (v1+v2 envelopes, no
/// credentials); a `.scopedRun` context — handed in by a run-lifetime
/// listener that captured its identity at bind time — passes the scoped
/// validation gate (authorization, operation policy, target scope) before
/// the same family handlers run. Scoped PRODUCTION listeners are not wired
/// in this phase; the core is exercised by tests only.
///
/// Family routing:
/// - `hello`  — `capabilities`: the daemon's protocol version, served
///   families, and build identity (version negotiation for a newer CLI
///   against an older daemon).
/// - `search` — the payload is the unchanged `SearchRPCRequest` JSON; the
///   reply payload is the unchanged `SearchRPCReply` JSON from
///   `WikiDaemon.searchData`. PR #1460's search behavior is untouched.
/// - `queue`  — the payload is the unchanged `QueueRPCEnvelope` JSON pair.
///   Routing reuses `WikiDaemonExporter`'s queue handlers verbatim (the same
///   code the app's XPC surface serves), so the queue error taxonomy and
///   engine-less stubs stay identical on both transports.
/// - `wiki`   — registry + lifecycle: `listWikis`, `createWiki`, `deleteWiki`,
///   `renameWiki`, `resolveWiki`, each routing to the daemon's existing
///   registry methods (Phase 2). Delete inherits the daemon's full eviction.
//
// Sendable invariant: both stored fields are immutable after init and the
// dispatcher holds no mutable state of its own; `WikiDaemon` and
// `WikiDaemonExporter` are internally synchronized (the daemon's queue
// discipline), so concurrent handler calls are safe.
// swiftlint:disable:next unchecked_sendable
final class DaemonDomainSocketDispatcher: @unchecked Sendable {

    private let daemon: WikiDaemon
    /// The XPC-shaped exporter the queue family routes through. It is a thin
    /// `Data`-reply wrapper over `WikiDaemon` — no listener, no sink — so a
    /// second instance here shares nothing mutable with the app's exporter.
    private let exporter: WikiDaemonExporter
    /// The Phase 3 command-family executor: runs the CLI's read-only command
    /// layer against the daemon's prepared services (plans/cli-domain-commands.md).
    private let commands: DaemonDomainCommands
    /// The scoped-run registry (plans/agent-sandbox-scoping.md §5): owner-side
    /// registration (the Phase 2 broker) and the dispatcher's authorization
    /// lookups share this instance. Injected so a host wires ONE registry
    /// across every endpoint; the default gives each dispatcher its own (the
    /// ordinary CLI socket needs none, and tests register against the
    /// instance they hand in).
    private let runRegistry: DaemonRunRegistry
    /// The scoped-request guard: version gate, registry authorization,
    /// operation policy, target scope (§6). Consulted ONLY for scoped
    /// connections — the ordinary path below is byte-identical to the
    /// pre-scoping dispatcher.
    private let scopeGuard: DaemonScopedRequestGuard
    /// The trusted per-run lint receipt/conflict state (plan §5.8). One
    /// instance per dispatcher; the child only ever sees opaque tokens.
    private let lintRunState: DaemonLintRunState

    /// M6/m5 teardown hook: the broker's revoke calls this so per-run lint
    /// state (receipts, conflict counters, verification records) cannot grow
    /// for the daemon's lifetime.
    var lintStateTeardown: ((DaemonRunID) async -> Void)?

    init(
        daemon: WikiDaemon,
        runRegistry: DaemonRunRegistry = DaemonRunRegistry(),
        lintRunState: DaemonLintRunState = DaemonLintRunState()
    ) {
        self.daemon = daemon
        self.exporter = WikiDaemonExporter(daemon: daemon)
        self.commands = DaemonDomainCommands(daemon: daemon)
        self.runRegistry = runRegistry
        self.lintRunState = lintRunState
        self.scopeGuard = DaemonScopedRequestGuard(
            registry: runRegistry,
            // The run's OWN descriptor — resolved by its registered ULID,
            // never a foreign selector (§6: do not resolve another wiki
            // globally before denying it). Gives the guard the assigned
            // display name so scoped requests may name their own wiki by
            // name as well as id.
            assignedWiki: { [daemon] wikiID in
                guard let data = daemon.resolveWiki(selector: wikiID.rawValue) else {
                    return nil
                }
                do {
                    return try JSONDecoder().decode(WikiDescriptor.self, from: data)
                } catch {
                    DebugLog.store(
                        "wikid: assigned wiki descriptor decode failed: \(error)")
                    return nil
                }
            },
            queueItemOwningWiki: { [daemon] itemID in
                try await daemon.queueItemOwningWiki(itemID: itemID)
            })
    }

    /// The socket server's `Data -> Data` handler. Never throws: every path
    /// encodes a `DaemonDomainReply`. The connection CONTEXT is the trusted
    /// listener's identity for the connection — `.ordinary` (the App Group
    /// CLI socket) or `.scopedRun` (a run-lifetime listener that captured its
    /// run identity at bind time; Phase 2 wires those listeners). The default
    /// keeps every pre-scoping call site unchanged.
    func handle(
        _ data: Data,
        context: DaemonConnectionContext = .ordinary
    ) async -> Data {
        let request: DaemonDomainRequest
        do {
            request = try DaemonDomainWire.decodeRequest(data)
        } catch let error as DaemonDomainError {
            // The envelope itself was unreadable: no requestID/family to echo.
            return Self.encodedReply(.failure(
                requestID: "", family: nil, operation: "", error))
        } catch {
            return Self.encodedReply(.failure(
                requestID: "", family: nil, operation: "",
                DaemonDomainError(code: .invalidRequest, message: String(describing: error))))
        }
        do {
            switch context {
            case .ordinary:
                // Version check BEFORE dispatch; v1 stays served through the
                // compatibility window (plans/agent-sandbox-scoping.md §9).
                try request.requireCurrentVersion()
            case .scopedRun(let listenerRunID):
                // Validation (scoped version gate + authorization + policy +
                // target scope) runs after decode and BEFORE family dispatch
                // (§6 insertion point). The scoped hello without credentials
                // answers version-only inside.
                return try await handleScoped(request, listenerRunID: listenerRunID)
            }
            return try await dispatchFamilies(request)
        } catch let error as DaemonDomainError {
            return Self.encodedReply(.failure(
                requestID: request.requestID,
                family: request.family,
                operation: request.operation,
                error))
        } catch {
            return Self.encodedReply(.failure(
                requestID: request.requestID,
                family: request.family,
                operation: request.operation,
                DaemonDomainError(code: .operationFailed, message: String(describing: error))))
        }
    }

    // MARK: - Scoped connections

    /// The scoped path: authorization first, then the SAME family handlers —
    /// except `wiki resolveWiki`, which is special-cased to resolve ONLY the
    /// run's assigned wiki (§6).
    private func handleScoped(
        _ request: DaemonDomainRequest,
        listenerRunID: DaemonRunID
    ) async throws -> Data {
        // §9: an uncredentialed scoped hello reports the required protocol
        // version ONLY — no families, no build identity, no wiki data.
        if request.family == .hello, request.authorization == nil {
            let payload = DaemonHelloPayload.versionOnly(
                protocolVersion: DaemonDomainVersion.current)
            return Self.encodedReply(.success(
                requestID: request.requestID,
                family: .hello,
                operation: request.operation,
                payload: try JSONEncoder().encode(payload)))
        }
        let grant: DaemonRunGrant
        do {
            grant = try await scopeGuard.evaluate(
                request, listenerRunID: listenerRunID)
        } catch let error as DaemonDomainError {
            // Diagnostics name the code and the listener's run — NEVER the
            // presented capability and never a wiki name.
            DebugLog.store(
                "wikid: scoped request denied (\(error.code.rawValue), "
                    + "run \(listenerRunID))")
            throw error
        }
        if request.family == .wiki,
            request.operation == DaemonDomainOperation.Wiki.resolveWiki
        {
            return try await scopedResolveWikiReply(for: request, grant: grant)
        }
        // Lint receipt lifecycle (plan §5.8): a REPAIR-policy run mints a
        // receipt on a fresh selected-page JSON read, presents it on every
        // patch, loses it on commit, and burns its conflict budget on CAS
        // conflicts. The state lives ONLY in the trusted daemon.
        if let intercepted = try await applyLintReceiptLifecycle(request, grant: grant) {
            return intercepted
        }
        return try await dispatchFamilies(request)
    }

    // MARK: - Lint receipt lifecycle (plan §5.8)

    /// Mint/validate the snapshot receipts for a repair- OR proposal-policy
    /// lint run. Returns `nil` when the request needs no interception (any
    /// operation under other policies, and every non-get/patch/propose page
    /// operation).
    private func applyLintReceiptLifecycle(
        _ request: DaemonDomainRequest,
        grant: DaemonRunGrant
    ) async throws -> Data? {
        let selectedPage: PageID
        let isProposal: Bool
        switch grant.operationPolicy {
        case .lintSelectedPageRepair(let page):
            selectedPage = page
            isProposal = false
        case .lintSelectedPageProposal(let page):
            selectedPage = page
            isProposal = true
        default:
            return nil
        }
        // PATCH — the tier-1 write. The presented receipt must be the run's
        // CURRENT one, and the run's conflict budget must be open. Both
        // failures deny with the generic scope message (the budget stays
        // opaque to the child).
        if request.family == .page, request.operation == DaemonDomainOperation.Page.patch {
            if isProposal {
                // The tier-2 policy never patches (the scope guard already
                // denied; a second refusal here cannot hurt).
                throw Self.scopeDeniedError()
            }
            if await self.lintRunState.isClosed(runID: grant.runID) {
                throw Self.scopeDeniedError()
            }
            let payload = try decodePatchPayload(request.payload)
            let expectHead = PageVersionID(rawValue: payload?.expectHead ?? "")
            do {
                try await self.lintRunState.validateReceipt(
                    runID: grant.runID, token: payload?.lintReceipt ?? "",
                    expectedHead: expectHead)
            } catch {
                // The budget stays opaque: stale, forged, and absent tokens
                // all deny with the generic scope message.
                throw Self.scopeDeniedError()
            }
            // W2a §3: the per-run patch budget, checked BEFORE the patch
            // reaches the store. Above the cap the WHOLE patch is rejected
            // (nothing commits) and the run's write phase closes. The hunk
            // numbers are validated BEFORE the budget arithmetic reads them —
            // the store validator re-checks ranges against the real body
            // under its own transaction.
            try Self.validateHunkNumericBounds(payload?.hunks ?? [], bodyBytes: nil)
            let usage = Self.patchUsage(payload)
            if case .exceeded(let rejection) = await self.lintRunState.checkBudget(
                runID: grant.runID, request: usage) {
                await self.lintRunState.recordBudgetRejection(
                    runID: grant.runID, pageID: selectedPage, rejection: rejection)
                await self.lintRunState.invalidateReceipt(runID: grant.runID)
                await Self.appendBudgetRejectionAudit(
                    rejection: rejection, selectedPage: selectedPage,
                    wikiID: grant.scope.wikiID, daemon: self.daemon)
                DebugLog.store("wikid: lint run \(grant.runID) patch rejected whole: \(rejection.summary)")
                throw DaemonDomainError(
                    code: .operationFailed,
                    message: "lint patch rejected whole — \(rejection.summary). No change was written; report the findings without repairs.")
            }
            let reply = try await dispatchFamilies(request)
            let envelope: DaemonDomainReply?
            do {
                envelope = try DaemonDomainWire.decodeReply(reply)
            } catch {
                DebugLog.store("wikid: lint patch reply was not a domain envelope; receipt state unchanged: \(error)")
                envelope = nil
            }
            if let envelope {
                if envelope.error == nil {
                    // A committed patch kills the receipt — the next write
                    // needs a fresh read even though the head this run wrote
                    // is now current.
                    await self.lintRunState.invalidateReceipt(runID: grant.runID)
                    await self.lintRunState.recordSpend(runID: grant.runID, usage: usage)
                    // §5.8: scan the WRITTEN immutable version right after
                    // the commit and publish the run's verification record.
                    await Self.recordWrittenVersionVerification(
                        request: request, selectedPage: selectedPage,
                        runID: grant.runID, daemon: self.daemon,
                        lintRunState: self.lintRunState)
                } else if envelope.error?.code == .casConflict {
                    let stillOpen = await self.lintRunState.recordConflict(runID: grant.runID)
                    if !stillOpen {
                        DebugLog.store(
                            "wikid: lint run \(grant.runID) exhausted its CAS conflict budget")
                    }
                    // Review M4: a conflict means the head moved — the old
                    // receipt's body no longer exists, so it dies here too.
                    // The recomposition requires a fresh minting read.
                    await self.lintRunState.invalidateReceipt(runID: grant.runID)
                }
            }
            return reply
        }
        // GET — a fresh selected-page read mints the receipt the patch will
        // present. Only an id-selector read of the selected page mints (the
        // task contract reads `--id`); a title read mints nothing, so a
        // patch without a receipt fails closed. An unreadable payload is by
        // design a pass-through (no mint), not a swallowed error.
        // swiftlint:disable:next silent_try_optional
        if request.family == .page, request.operation == DaemonDomainOperation.Page.get,
           // An unreadable payload is by design a pass-through (no mint), not
           // a swallowed store error.
           // swiftlint:disable:next silent_try_optional
           let payload = try? JSONDecoder().decode(DaemonPageGetRequest.self, from: request.payload ?? Data()),
           payload.selector.id == selectedPage.rawValue {
            let reply = try await dispatchFamilies(request)
            let envelope: DaemonDomainReply?
            do {
                envelope = try DaemonDomainWire.decodeReply(reply)
            } catch {
                DebugLog.store("wikid: lint get reply was not a domain envelope; no receipt minted: \(error)")
                envelope = nil
            }
            guard let envelope, envelope.error == nil, let payloadData = envelope.payload else {
                return reply
            }
            // W2a §3: the first minting read is the run's inspected page —
            // its confirmed repairable findings fix the run's patch budget.
            await Self.establishPatchBudget(
                runID: grant.runID, selectedPage: selectedPage,
                wikiID: grant.scope.wikiID, daemon: self.daemon,
                lintRunState: self.lintRunState)
            if let minted = await Self.mintReceipt(
                into: payloadData, runID: grant.runID,
                selectedPage: selectedPage, lintRunState: self.lintRunState) {
                return try DaemonDomainWire.encode(DaemonDomainReply.success(
                    requestID: envelope.requestID,
                    family: envelope.family,
                    operation: envelope.operation,
                    payload: minted))
            }
            return reply
        }
        // PROPOSE — the tier-2 staging seam (W5a §3). Same receipt and
        // budget discipline as the patch, then VALIDATE and HOLD: the page
        // is never written here. At most ONE staged proposal per page per
        // run; a later proposal for the same page is refused.
        if request.family == .page,
           request.operation == DaemonDomainOperation.Page.proposePatch {
            return try await interceptProposePatch(
                request, grant: grant, selectedPage: selectedPage)
        }
        return nil
    }

    /// The tier-2 staging interception: receipt + budget discipline (the
    /// patch path's mirrors), `PagePatchValidator` parity, then the staged
    /// record + its trusted audit entry. Nothing here writes the page.
    private func interceptProposePatch(
        _ request: DaemonDomainRequest,
        grant: DaemonRunGrant,
        selectedPage: PageID
    ) async throws -> Data {
        if await self.lintRunState.isClosed(runID: grant.runID) {
            throw Self.scopeDeniedError()
        }
        let payload = try decodeProposePayload(request.payload)
        let expectHead = PageVersionID(rawValue: payload?.expectHead ?? "")
        do {
            try await self.lintRunState.validateReceipt(
                runID: grant.runID, token: payload?.lintReceipt ?? "",
                expectedHead: expectHead)
        } catch {
            // The budget stays opaque: stale, forged, and absent tokens all
            // deny with the generic scope message.
            throw Self.scopeDeniedError()
        }
        let wireHunks = payload?.hunks ?? []
        // Validator parity: the SAME rules the store applies to a patch
        // (ranges, boundaries, exact oldText, overlap, payload ceiling,
        // no-op) run against the page's CURRENT body. A mismatch (the page
        // changed since the receipt's read) is the conflict signal the
        // child re-reads from.
        let pageID = PageID(rawValue: payload?.id ?? selectedPage.rawValue)
        let defectClasses: [LintDefectClass] = try wireHunks.map { wire in
            guard let defect = LintDefectClass(rawValue: wire.defect) else {
                throw DaemonDomainError(
                    code: .invalidRequest,
                    message: "page propose-patch carries an unknown defect class: \(wire.defect)")
            }
            return defect
        }
        let hunks: [PagePatchHunk] = wireHunks.map { wire in
            PagePatchHunk(
                startByte: wire.startByte, endByte: wire.endByte,
                oldText: wire.oldText, newText: wire.newText, reason: wire.reason)
        }
        do {
            let store = try await daemon.domainCommandStore(wikiID: grant.scope.wikiID)
            let read = try store.readPageCoherent(id: selectedPage)
            let body = read.body
            // W2a §3 mirrored: the budget is checked BEFORE anything is
            // staged, and AFTER the hunk numbers are validated against the
            // body's real size — a hostile offset is rejected outright
            // before it reaches a subtraction. Above the cap the WHOLE
            // proposal is rejected and the run's write (staging) phase
            // closes — splitting cannot get around the cap.
            try Self.validateHunkNumericBounds(wireHunks, bodyBytes: body.utf8.count)
            let usage = Self.hunkUsage(wireHunks)
            if case .exceeded(let rejection) = await self.lintRunState.checkBudget(
                runID: grant.runID, request: usage) {
                await self.lintRunState.recordBudgetRejection(
                    runID: grant.runID, pageID: selectedPage, rejection: rejection)
                await self.lintRunState.invalidateReceipt(runID: grant.runID)
                await Self.appendBudgetRejectionAudit(
                    rejection: rejection, selectedPage: selectedPage,
                    wikiID: grant.scope.wikiID, daemon: self.daemon)
                DebugLog.store("wikid: lint run \(grant.runID) proposal rejected whole: \(rejection.summary)")
                throw DaemonDomainError(
                    code: .operationFailed,
                    message: "lint proposal rejected whole — \(rejection.summary). Nothing was staged; report the findings without repairs.")
            }
            _ = try PagePatchValidator.composedBody(
                applying: PagePatch(
                    pageID: pageID, expectHead: expectHead,
                    hunks: hunks, defectClasses: defectClasses),
                to: body)
            let fingerprint = LintPageSnapshot.fingerprint(of: body)
            let proposal = DaemonLintStagedProposal(
                id: ULID.generate(), runID: grant.runID, pageID: selectedPage,
                stagedAt: Date(), inspectedHead: expectHead,
                bodyFingerprint: fingerprint,
                hunks: hunks, perHunkClasses: defectClasses,
                breakerKey: await self.lintRunState.runBreakerKey(runID: grant.runID))
            do {
                try await self.lintRunState.stageProposal(proposal)
            } catch let error as DaemonLintRunState.StagingError {
                // Exactly one staged proposal per page per run.
                if case .alreadyStaged = error {
                    throw DaemonDomainError(
                        code: .operationFailed,
                        message: "already staged: this run staged a proposal for this page earlier — at most one staged proposal per page per run. Revise nothing; report remaining findings as unresolved.")
                }
                throw DaemonDomainError(code: .operationFailed, message: "\(error)")
            }
            await Self.appendStagedProposalAudit(
                proposal: proposal, wikiID: grant.scope.wikiID, daemon: self.daemon)
            DebugLog.store(
                "wikid: lint run \(grant.runID) staged proposal \(proposal.id) for \(selectedPage.rawValue)")
            let lines = [
                "staged\t\(proposal.id)",
                "page\t\(selectedPage.rawValue)",
                "inspected_head\t\(proposal.inspectedHead.rawValue)",
                "fingerprint\t\(proposal.bodyFingerprint)",
                "hunks\t\(proposal.hunks.count)",
                "note\tstaged for human review — nothing was written",
            ]
            let outcome = DaemonCommandOutcome(
                text: lines.joined(separator: "\n") + "\n", didCommit: false,
                stderr: "The proposal is STAGED, not applied. A human must approve it; until then the page is unchanged.")
            return Self.encodedReply(.success(
                requestID: request.requestID,
                family: request.family,
                operation: request.operation,
                payload: try JSONEncoder().encode(outcome)))
        } catch let error as DaemonDomainError {
            throw error
        } catch {
            // Store read or validator refusal — the child can fix a
            // validation failure by re-reading; a store failure is not
            // theirs to retry blind.
            let invalid = error is PagePatchValidationError
            throw DaemonDomainError(
                code: invalid ? .invalidRequest : .operationFailed,
                message: invalid
                    ? "page propose-patch rejected: \(error)"
                    : "staging failed: \(error)")
        }
    }

    /// Extract `head_version_id` + `body_markdown` from a successful
    /// `page get --json` payload, mint the run's receipt over them, and
    /// return the payload with `"lint_receipt"` injected. The daemon wraps
    /// command output in a ``DaemonCommandOutcome`` envelope (the CLI prints
    /// `text` verbatim), so both the wrapped and bare shapes are handled.
    /// Returns nil when the payload is neither shape.
    static func mintReceipt(
        into payload: Data,
        runID: DaemonRunID,
        selectedPage: PageID,
        lintRunState: DaemonLintRunState
    ) async -> Data? {
        // The envelope probe is a shape test, not a swallowed store error.
        // swiftlint:disable:next silent_try_optional
        let outcome = try? JSONDecoder().decode(DaemonCommandOutcome.self, from: payload)
        let pageJSONText: String
        if let text = outcome?.text {
            pageJSONText = text
        } else {
            pageJSONText = String(decoding: payload, as: UTF8.self)
        }
        // swiftlint:disable:next silent_try_optional
        guard var object = try? JSONSerialization.jsonObject(with: Data(pageJSONText.utf8)) as? [String: Any],
              let head = object["head_version_id"] as? String,
              let body = object["body_markdown"] as? String else {
            return nil
        }
        let receipt = await lintRunState.issueReceipt(
            runID: runID,
            head: PageVersionID(rawValue: head),
            bodyFingerprint: LintPageSnapshot.fingerprint(of: body))
        object["lint_receipt"] = receipt.token
        let updatedPageJSON: Data
        do {
            updatedPageJSON = try JSONSerialization.data(withJSONObject: object)
        } catch {
            DebugLog.store("wikid: lint receipt payload re-encode failed: \(error)")
            return nil
        }
        if let outcome {
            let updatedOutcome = DaemonCommandOutcome(
                text: String(decoding: updatedPageJSON, as: UTF8.self),
                bytesBase64: outcome.bytesBase64,
                didCommit: outcome.didCommit,
                stderr: outcome.stderr)
            do {
                return try JSONEncoder().encode(updatedOutcome)
            } catch {
                DebugLog.store("wikid: lint receipt outcome re-encode failed: \(error)")
                return nil
            }
        }
        return updatedPageJSON
    }

    private func decodePatchPayload(_ payload: Data?) throws -> DaemonPagePatchRequest? {
        guard let payload else { return nil }
        do {
            return try JSONDecoder().decode(DaemonPagePatchRequest.self, from: payload)
        } catch {
            throw Self.scopeDeniedError()
        }
    }

    /// The propose twin of `decodePatchPayload`: an unreadable payload is a
    /// generic scope denial, never a decode-leak.
    private func decodeProposePayload(_ payload: Data?) throws -> DaemonPageProposePatchRequest? {
        guard let payload else { return nil }
        do {
            return try JSONDecoder().decode(DaemonPageProposePatchRequest.self, from: payload)
        } catch {
            throw Self.scopeDeniedError()
        }
    }

    /// The generic scope denial — the receipt budget never leaks its state
    /// (stale receipt, absent receipt, closed run, and unreadable payload all
    /// deny identically).
    static func scopeDeniedError() -> DaemonDomainError {
        DaemonDomainError(
            code: .scopeDenied,
            message: "the request is outside the scope of this run")
    }

    /// Review m5/M6: drop ALL per-run lint state (receipts, conflict
    /// counters, verification records). Called from the broker's revoke so
    /// teardown paths can never leave lint state behind.
    func forgetLintState(runID: DaemonRunID) async {
        await lintRunState.forget(runID: runID)
    }

    /// §5.8: after a committed lint patch, scan the WRITTEN immutable version
    /// (pure scan + store-derived facts) and publish the run's verification
    /// record. A failure logs and skips the record — it never fails the
    /// already-committed write.
    static func recordWrittenVersionVerification(
        request: DaemonDomainRequest,
        selectedPage: PageID,
        runID: DaemonRunID,
        daemon: WikiDaemon,
        lintRunState: DaemonLintRunState
    ) async {
        do {
            let wire: DaemonPagePatchRequest?
            if let raw = request.payload {
                wire = try JSONDecoder().decode(DaemonPagePatchRequest.self, from: raw)
            } else {
                wire = nil
            }
            let store = try await daemon.domainCommandStore(
                wikiID: WikiID(rawValue: wire?.wikiID ?? ""))
            let read = try store.readPageCoherent(id: selectedPage)
            guard let writtenHead = read.headVersionID else { return }
            let snapshot = LintPageSnapshot(read)
            let resolution = try LintResolutionFacts.load(from: store)
            let written = LintPagePreflight.scan(snapshot: snapshot, resolution: resolution)
            let record = DaemonLintVerificationRecord(
                pageID: selectedPage,
                writtenHead: writtenHead,
                appliedClasses: patchPayloadClasses(request.payload ?? Data()),
                writtenFingerprint: snapshot.bodyFingerprint,
                remainingFindings: written.sections.flatMap(\.findings).map { (finding: LintFinding) -> String in
                    let range = finding.authoredRange.map { "@\($0.lowerBound)" } ?? "@whole"
                    return "\(finding.defectClass.rawValue)\(range) \(finding.occurrenceID)"
                },
                recordedAt: Date())
            await lintRunState.recordVerification(runID: runID, record: record)
        } catch {
            DebugLog.store(
                "wikid: written-version verification could not run for run \(runID): \(error)")
        }
    }

    /// The hunks and changed bytes one patch payload asks for. An absent
    /// payload asks for nothing (the patch command rejects it anyway).
    static func patchUsage(_ payload: DaemonPagePatchRequest?) -> LintPatchBudget.Usage {
        guard let payload else { return .zero }
        return Self.hunkUsage(payload.hunks)
    }

    /// The usage of a wire hunk list — shared by the patch and the staged
    /// proposal paths so the budget means the same thing on both. Callers
    /// MUST run ``validateHunkNumericBounds`` first: this aggregation is
    /// total (it saturates), but bounded inputs keep the budget numbers
    /// meaningful instead of pinned at `Int.max`.
    static func hunkUsage(_ hunks: [DaemonPagePatchRequest.WireHunk]) -> LintPatchBudget.Usage {
        LintPatchBudget.Usage(
            hunks: hunks.count,
            changedBytes: hunks.reduce(0) { total, hunk in
                let (sum, overflow) = total.addingReportingOverflow(
                    LintPatchBudget.changedBytes(
                        startByte: hunk.startByte, endByte: hunk.endByte, newText: hunk.newText))
                return overflow ? Int.max : sum
            })
    }

    /// The numeric-bounds gate BEFORE any budget arithmetic: every hunk's
    /// range must be non-negative, ordered, and — when the document size is
    /// known at this point — within the body. The offsets are child-
    /// controlled; validating them here means a hostile payload is REJECTED
    /// (`invalidRequest`) before its numbers reach a subtraction, never a
    /// daemon trap. Past-body bounds without a known size stay the patch
    /// validator's job (it reads the real body).
    static func validateHunkNumericBounds(
        _ hunks: [DaemonPagePatchRequest.WireHunk], bodyBytes: Int?
    ) throws {
        for hunk in hunks {
            let withinBody = bodyBytes.map { hunk.endByte <= $0 } ?? true
            guard hunk.startByte >= 0, hunk.endByte >= hunk.startByte, withinBody else {
                throw DaemonDomainError(
                    code: .invalidRequest,
                    message: "page patch hunk range \(hunk.startByte)..<\(hunk.endByte) is invalid"
                        + (bodyBytes.map { " for a body of \($0) bytes" } ?? "")
                        + " — ranges are non-negative and ordered and end within the body")
            }
        }
    }

    /// Fix the run's patch budget from the selected page's CURRENT scan (the
    /// first minting read; later reads never change it). A scan failure
    /// leaves the floor budget in force — never an unbounded one.
    static func establishPatchBudget(
        runID: DaemonRunID,
        selectedPage: PageID,
        wikiID: WikiID,
        daemon: WikiDaemon,
        lintRunState: DaemonLintRunState
    ) async {
        do {
            let store = try await daemon.domainCommandStore(wikiID: wikiID)
            let snapshot = LintPageSnapshot(try store.readPageCoherent(id: selectedPage))
            let resolution = try LintResolutionFacts.load(from: store)
            let inspected = LintPagePreflight.scan(snapshot: snapshot, resolution: resolution)
            await lintRunState.setBudgetIfAbsent(
                runID: runID, budget: LintPatchBudget(preflight: inspected))
        } catch {
            DebugLog.store(
                "wikid: patch budget scan failed for run \(runID); the floor budget applies: \(error)")
        }
    }

    /// The trusted `--kind lint` audit entry for a whole-patch budget
    /// rejection. Host accounting (any host — app or daemon) reads it back
    /// by its title to mark the run's write phase not performed.
    static func appendBudgetRejectionAudit(
        rejection: LintPatchBudget.Rejection,
        selectedPage: PageID,
        wikiID: WikiID,
        daemon: WikiDaemon
    ) async {
        do {
            let store = try await daemon.domainCommandStore(wikiID: wikiID)
            let title = try store.readPageCoherent(id: selectedPage).title
            _ = try store.appendLog(
                kind: .lint,
                title: LintPatchBudget.auditTitlePrefix + title,
                note: rejection.summary)
        } catch {
            DebugLog.store("wikid: budget rejection audit append failed for \(selectedPage.rawValue): \(error)")
        }
    }

    /// The trusted `--kind lint` audit entry for a STAGED proposal (W5a
    /// tier 2). Host accounting reads it back by title to fold the run's
    /// proposal count + record references into the page's durable record;
    /// the review UI keys on the proposal id.
    static func appendStagedProposalAudit(
        proposal: DaemonLintStagedProposal,
        wikiID: WikiID,
        daemon: WikiDaemon
    ) async {
        do {
            let store = try await daemon.domainCommandStore(wikiID: wikiID)
            let title = try store.readPageCoherent(id: proposal.pageID).title
            _ = try store.appendLog(
                kind: .lint,
                title: LintProposalAudit.stagedAuditTitlePrefix + title,
                note: LintProposalAudit.stagedNote(
                    proposalID: proposal.id,
                    inspectedHead: proposal.inspectedHead,
                    bodyFingerprint: proposal.bodyFingerprint,
                    hunkCount: proposal.hunks.count))
        } catch {
            DebugLog.store("wikid: staged proposal audit append failed for \(proposal.pageID.rawValue): \(error)")
        }
    }

    /// The defect classes of a patch payload's hunks, in order.
    static func patchPayloadClasses(_ payload: Data) -> [LintDefectClass] {
        struct Wire: Decodable {
            struct Hunk: Decodable { let defect: String }
            let hunks: [Hunk]
        }
        // A shape probe on an already-validated payload; unreadable → none.
        // swiftlint:disable:next silent_try_optional
        guard let wire = try? JSONDecoder().decode(Wire.self, from: payload) else {
            return []
        }
        return wire.hunks.compactMap { LintDefectClass(rawValue: $0.defect) }
    }

    /// Scoped `wiki resolveWiki`: the assigned descriptor or a GENERIC scope
    /// denial. The selector must name the run's own wiki (id or display
    /// name); any other selector — including one that matches a different
    /// live wiki — gets the fixed denial text, which names no wiki and leaks
    /// no existence.
    private func scopedResolveWikiReply(
        for request: DaemonDomainRequest,
        grant: DaemonRunGrant
    ) async throws -> Data {
        let selector = try wikiPayload(DaemonWikiResolveRequest.self, request)
        guard let descriptorData = daemon.resolveWiki(selector: grant.scope.wikiID.rawValue) else {
            // The run's own wiki vanished from the registry: nothing this
            // run asks resolves.
            throw DaemonScopedRequestGuard.scopeDenied()
        }
        let descriptor: WikiDescriptor
        do {
            descriptor = try JSONDecoder().decode(WikiDescriptor.self, from: descriptorData)
        } catch {
            throw DaemonDomainError(
                code: .operationFailed,
                message: "wiki descriptor could not be decoded")
        }
        guard selector.selector == descriptor.id.rawValue
            || selector.selector == descriptor.displayName
        else {
            throw DaemonScopedRequestGuard.scopeDenied()
        }
        return Self.encodedReply(.success(
            requestID: request.requestID,
            family: .wiki,
            operation: request.operation,
            payload: descriptorData))
    }

    // MARK: - Family dispatch (ordinary + authorized scoped requests)

    /// The family switch shared by both connection contexts. Callers have
    /// already passed the version gate (and, for scoped connections, the
    /// full authorization/policy/target validation).
    private func dispatchFamilies(_ request: DaemonDomainRequest) async throws -> Data {
        switch request.family {
        case .hello:
            return try helloReply(for: request)
        case .search:
            return try await searchReply(for: request)
        case .queue:
            return try await queueReply(for: request)
        case .wiki:
            return try await wikiReply(for: request)
        case .page, .source, .chat, .bookmark, .workspace,
             .strategy, .log, .admin, .extractor:
            // Phase 3+4 command families: the daemon executes the CLI's
            // command layer (reads and writes) against its prepared
            // services; typed CAS codes ride back inside the envelope.
            return try await commands.reply(for: request)
        }
    }

    // MARK: - hello

    private func helloReply(for request: DaemonDomainRequest) throws -> Data {
        guard request.operation == DaemonDomainOperation.Hello.capabilities else {
            throw DaemonDomainError(
                code: .invalidRequest,
                message: "unknown hello operation: \(request.operation)")
        }
        let payload = DaemonHelloPayload(
            protocolVersion: DaemonDomainVersion.current,
            families: DaemonDomainFamily.allCases.map(\.rawValue).sorted(),
            appVersion: GeneratedVersion.appVersion,
            buildVersion: GeneratedVersion.buildVersion)
        return Self.encodedReply(.success(
            requestID: request.requestID,
            family: .hello,
            operation: request.operation,
            payload: try JSONEncoder().encode(payload)))
    }

    // MARK: - search

    private func searchReply(for request: DaemonDomainRequest) async throws -> Data {
        guard request.operation == DaemonDomainOperation.Search.search else {
            throw DaemonDomainError(
                code: .invalidRequest,
                message: "unknown search operation: \(request.operation)")
        }
        guard let payload = request.payload else {
            throw DaemonDomainError(
                code: .invalidRequest,
                message: "search request carries no payload")
        }
        // The unchanged PR #1460 search wire values, wrapped by the envelope.
        let searchReplyData = await daemon.searchData(request: payload)
        return Self.encodedReply(.success(
            requestID: request.requestID,
            family: .search,
            operation: request.operation,
            payload: searchReplyData))
    }

    // MARK: - queue

    private func queueReply(for request: DaemonDomainRequest) async throws -> Data {
        // Each verb routes through the SAME exporter handler the app's XPC
        // surface serves, so the daemon-side queue logic — error envelopes,
        // ownership epoch stamps, engine-less stubs — is identical on both
        // transports. The exporter always invokes the reply closure exactly
        // once; its bytes are the envelope payload unchanged.
        let replyData: Data
        switch request.operation {
        case DaemonDomainOperation.Queue.queueSnapshot:
            replyData = await awaitExporterReply { reply in
                self.exporter.queueSnapshot(reply: reply)
            }
        case DaemonDomainOperation.Queue.enqueueItem:
            guard let payload = request.payload else {
                throw DaemonDomainError(
                    code: .invalidRequest,
                    message: "enqueueItem carries no payload")
            }
            replyData = await awaitExporterReply { reply in
                self.exporter.enqueueItem(request: payload, reply: reply)
            }
        case DaemonDomainOperation.Queue.pauseQueue, DaemonDomainOperation.Queue.resumeQueue,
            DaemonDomainOperation.Queue.haltQueue:
            guard let payload = request.payload else {
                throw DaemonDomainError(
                    code: .invalidRequest,
                    message: "\(request.operation) carries no payload")
            }
            let control: DaemonQueueControlRequest
            do {
                control = try JSONDecoder().decode(DaemonQueueControlRequest.self, from: payload)
            } catch {
                throw DaemonDomainError(
                    code: .invalidRequest,
                    message: "\(request.operation) payload could not be decoded")
            }
            let queue = control.queue
            switch request.operation {
            case DaemonDomainOperation.Queue.pauseQueue:
                replyData = await awaitExporterReply { reply in
                    self.exporter.pauseQueue(queue: queue, reply: reply)
                }
            case DaemonDomainOperation.Queue.resumeQueue:
                replyData = await awaitExporterReply { reply in
                    self.exporter.resumeQueue(queue: queue, reply: reply)
                }
            default:
                replyData = await awaitExporterReply { reply in
                    self.exporter.haltQueue(queue: queue, reply: reply)
                }
            }
        case DaemonDomainOperation.Queue.queueWikiItems:
            // Phase 3: the durable per-wiki read behind `wikictl job list/get`
            // — full terminal history + the extraction-completed wiki leg.
            replyData = try await commands.queueWikiItemsReply(for: request)
        case DaemonDomainOperation.Queue.queueItemState:
            // Phase 5: the one-item state snapshot the transcribe completion
            // wait polls — one short read per round trip.
            replyData = try await commands.queueItemStateReply(for: request)
        case DaemonDomainOperation.Queue.transcribePreflight:
            // Phase 5: the speech enqueue preflight — the YouTube-scope check
            // through the daemon's prepared store.
            replyData = try await commands.transcribePreflightReply(for: request)
        default:
            throw DaemonDomainError(
                code: .invalidRequest,
                message: "unknown queue operation: \(request.operation)")
        }
        return Self.encodedReply(.success(
            requestID: request.requestID,
            family: .queue,
            operation: request.operation,
            payload: replyData))
    }

    /// Bridges the exporter's XPC-shaped `(Data) -> Void` reply closure into
    /// async. The closure fires exactly once on every exporter path (success
    /// and typed-failure envelopes alike); the resume-once box absorbs a
    /// straggler rather than double-resuming, which would trap.
    private func awaitExporterReply(
        _ send: @escaping @Sendable (_ reply: @escaping @Sendable (Data) -> Void) -> Void
    ) async -> Data {
        let box = ExporterReplyBox()
        send { box.fulfill($0) }
        return await box.wait()
    }

    // MARK: - wiki (Phase 2)

    private func wikiReply(for request: DaemonDomainRequest) async throws -> Data {
        // Each verb routes to the daemon's EXISTING registry methods — the
        // same code the app's XPC surface serves. Reads adopt the on-disk
        // registry (the app is the primary writer); delete inherits the
        // daemon's full eviction (search runtime shutdown, child profile
        // removal, registry row, database artifacts), closing the CLI's
        // degraded-delete race. Descriptor payloads are the daemon's own
        // JSON bytes.
        let payload: Data?
        switch request.operation {
        case DaemonDomainOperation.Wiki.listWikis:
            payload = daemon.listWikis()
        case DaemonDomainOperation.Wiki.resolveWiki:
            let selector = try wikiPayload(DaemonWikiResolveRequest.self, request)
            guard let descriptorData = daemon.resolveWiki(selector: selector.selector) else {
                throw DaemonDomainError(
                    code: .notFound,
                    message: "no wiki matching \(selector.selector)")
            }
            payload = descriptorData
        case DaemonDomainOperation.Wiki.createWiki:
            let create = try wikiPayload(DaemonWikiCreateRequest.self, request)
            guard let descriptorData = await daemon.createWikiOverSocket(name: create.name) else {
                throw DaemonDomainError(
                    code: .operationFailed,
                    message: "wiki creation failed on the daemon")
            }
            payload = descriptorData
        case DaemonDomainOperation.Wiki.deleteWiki:
            let delete = try wikiPayload(DaemonWikiDeleteRequest.self, request)
            // Resolve FIRST so an unknown id is a typed notFound (the CLI's
            // byte-stable "no wiki matching <id>" failure) instead of a
            // generic delete failure.
            guard daemon.resolveWiki(selector: delete.id) != nil else {
                throw DaemonDomainError(
                    code: .notFound,
                    message: "no wiki matching \(delete.id)")
            }
            guard await daemon.deleteWikiOverSocket(id: WikiID(rawValue: delete.id)) else {
                throw DaemonDomainError(
                    code: .operationFailed,
                    message: "wiki delete failed on the daemon")
            }
            payload = nil
        case DaemonDomainOperation.Wiki.renameWiki:
            let rename = try wikiPayload(DaemonWikiRenameRequest.self, request)
            // Same resolve-first notFound contract as delete.
            guard daemon.resolveWiki(selector: rename.id) != nil else {
                throw DaemonDomainError(
                    code: .notFound,
                    message: "no wiki matching \(rename.id)")
            }
            guard daemon.renameWiki(id: WikiID(rawValue: rename.id), name: rename.name) else {
                throw DaemonDomainError(
                    code: .operationFailed,
                    message: "wiki rename failed on the daemon (empty name, deleted wiki, or unreadable registry)")
            }
            payload = nil
        default:
            throw DaemonDomainError(
                code: .invalidRequest,
                message: "unknown wiki operation: \(request.operation)")
        }
        return Self.encodedReply(.success(
            requestID: request.requestID,
            family: .wiki,
            operation: request.operation,
            payload: payload))
    }

    /// Decodes a wiki-family request payload; a missing or malformed one is a
    /// typed `invalidRequest`.
    private func wikiPayload<Payload: Decodable>(
        _ type: Payload.Type,
        _ request: DaemonDomainRequest
    ) throws -> Payload {
        guard let data = request.payload else {
            throw DaemonDomainError(
                code: .invalidRequest,
                message: "\(request.operation) carries no payload")
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw DaemonDomainError(
                code: .invalidRequest,
                message: "\(request.operation) payload could not be decoded")
        }
    }

    // MARK: - Shared reply encoding

    /// Encode-or-empty: a `DaemonDomainReply` of these value payloads cannot
    /// fail to encode; if it ever did, an empty body is the honest "no reply"
    /// and the client surfaces it as a malformed reply. An encoded reply that
    /// would exceed the socket's 4 MiB frame cap is replaced by a TYPED
    /// `operationFailed` failure envelope instead — never a truncation and
    /// never a client-side transport fault (the client refuses oversized
    /// announced lengths before buffering).
    private static func encodedReply(_ reply: DaemonDomainReply) -> Data {
        do {
            let encoded = try DaemonDomainWire.encode(reply)
            if encoded.count > Int(SearchSocketWire.maxFrameSize) {
                return try DaemonDomainWire.encode(.failure(
                    requestID: reply.requestID,
                    family: reply.family,
                    operation: reply.operation,
                    DaemonDomainError(
                        code: .operationFailed,
                        message: "reply payload (\(encoded.count) bytes) exceeds the socket "
                            + "frame cap (\(SearchSocketWire.maxFrameSize) bytes) — use a "
                            + "narrower read (for example `source export --out <file>`); "
                            + "nothing was truncated")))
            }
            return encoded
        } catch {
            DebugLog.store("wikid: domain reply encoding failed: \(error)")
            return Data()
        }
    }
}

/// Resume-once carrier for one exporter queue reply: the exporter's reply
/// closure fulfils the box exactly once; a second invocation is absorbed
/// instead of double-resuming the continuation (which traps). The NSLock is
/// the Sendable invariant for the single mutable field.
// swiftlint:disable:next unchecked_sendable
private final class ExporterReplyBox: @unchecked Sendable {

    private enum Payload {
        case idle
        case waiting(CheckedContinuation<Data, Never>)
        case settled(Data)
    }

    private let lock = NSLock()
    private var payload: Payload = .idle

    func fulfill(_ data: Data) {
        lock.lock()
        let continuation: CheckedContinuation<Data, Never>?
        switch payload {
        case .idle:
            payload = .settled(data)
            continuation = nil
        case .waiting(let waiting):
            payload = .settled(data)
            continuation = waiting
        case .settled:
            // Resume-once: a straggling second reply is discarded.
            continuation = nil
        }
        lock.unlock()
        continuation?.resume(returning: data)
    }

    func wait() async -> Data {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
            lock.lock()
            switch payload {
            case .idle:
                payload = .waiting(continuation)
                lock.unlock()
            case .settled(let data):
                lock.unlock()
                continuation.resume(returning: data)
            case .waiting:
                // One box serves one reply and one waiter; a second waiter is
                // a caller bug — fail it with empty data, never double-resume.
                lock.unlock()
                continuation.resume(returning: Data())
            }
        }
    }
}
#endif
