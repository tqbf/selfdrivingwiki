#if os(macOS)
import Foundation
import Testing
import WikiDaemonContract

// Phase 2a slice 2 round trips: representative operations from every payload
// family encoded through the REAL envelope stack — per-op DTO JSON →
// `DaemonStoreRequest`/`DaemonStoreReply` → `.store` domain envelope →
// `DaemonStoreFrameSizing.encodeValidated*` → decoded back, asserting
// equality. Collectively the fixtures below round-trip every mirror type in
// `DaemonStoreValueMirrors.swift` (parameterized tests walk every enum case
// of the closed sets).
@Suite("Daemon store ops round-trips", .timeLimit(.minutes(1)))
struct DaemonStoreOpsRoundTripTests {

    private static let wikiID = "01JWIKI0000000000000000AB"
    private static let stamp = DaemonMutationStamp(
        requestID: "01JMUTSTAMP0000000000000AB", expectedEpoch: 7)
    private var at: Date { Date(timeIntervalSince1970: 1_800_000_000) }

    // MARK: Envelope helpers

    /// One full REQUEST round trip through the validated frame seam.
    private func opRequest<Req: Codable & Equatable>(
        _ op: DaemonStoreOperation, _ request: Req, stamp: DaemonMutationStamp? = nil
    ) throws -> Req {
        let dto = try JSONEncoder().encode(request)
        let store = DaemonStoreRequest(
            wikiID: Self.wikiID, operation: op.rawValue, stamp: stamp,
            payload: dto)
        let envelope = DaemonDomainRequest(
            requestID: "req-\(op.rawValue)", family: .store,
            operation: op.rawValue, payload: try DaemonStoreWire.encode(store))
        let wire = try DaemonStoreFrameSizing.encodeValidatedRequest(envelope)
        let decodedEnvelope = try DaemonDomainWire.decodeRequest(wire)
        let decodedStore = try DaemonStoreWire.decodeRequest(
            try #require(decodedEnvelope.payload))
        #expect(decodedStore.operation == op.rawValue)
        #expect(decodedStore.stamp == stamp)
        return try JSONDecoder().decode(
            Req.self, from: #require(decodedStore.payload))
    }

    /// One full REPLY round trip through the validated frame seam.
    private func opReply<Rep: Codable & Equatable>(
        _ op: DaemonStoreOperation, _ reply: Rep
    ) throws -> Rep {
        let dto = try JSONEncoder().encode(reply)
        let store = DaemonStoreReply(result: dto, error: nil)
        let envelope = DaemonDomainReply.success(
            requestID: "rep-\(op.rawValue)", family: .store,
            operation: op.rawValue, payload: try DaemonStoreWire.encode(store))
        let wire = try DaemonStoreFrameSizing.encodeValidatedReply(envelope)
        let decodedEnvelope = try DaemonDomainWire.decodeReply(wire)
        let decodedStore = try DaemonStoreWire.decodeReply(
            try #require(decodedEnvelope.payload))
        #expect(decodedStore.error == nil)
        return try JSONDecoder().decode(
            Rep.self, from: #require(decodedStore.result))
    }

    // MARK: Shared fixtures (instance members so parameterized arguments and
    // test bodies resolve them per suite instance)

    private var pageSummary: DaemonPageSummary {
        DaemonPageSummary(
            id: "01JPAGE0000000000000000AA", title: "Meeting Notes",
            updatedAt: at, createdAt: at)
    }
    private var sourceSummary: DaemonSourceSummary {
        DaemonSourceSummary(
            id: "01JSOURCE000000000000000AB", filename: "paper.pdf", ext: "pdf",
            mimeType: "application/pdf", byteSize: 1_024, createdAt: at,
            updatedAt: at, version: 1, role: "primary")
    }
    private func handle(
        _ id: String, bytes: Int = 12
    ) -> DaemonPayloadHandle {
        DaemonPayloadHandle(
            id: id, declaredByteCount: bytes,
            sha256Hex: String(repeating: "a", count: 64))
    }
    private func echo(_ op: String) -> DaemonMutationOutcome {
        DaemonMutationOutcome(stamp: Self.stamp, status: .committed)
    }
    private var pageEvent: DaemonResourceChangeEvent {
        DaemonResourceChangeEvent(
            kind: "page", id: "01JPAGE0000000000000000AA", change: "updated",
            seq: 42)
    }
    private var hints: DaemonContentTypeDetectionHints {
        DaemonContentTypeDetectionHints(
            declaredMIME: DaemonDeclaredMIME(
                value: "application/pdf", origin: .httpResponse),
            filenameExtension: "pdf", utiMIME: "com.adobe.pdf")
    }
    private var provenance: DaemonSourceProvenance {
        DaemonSourceProvenance(
            agentName: "website", agentKind: "software", agentVersion: "1.2",
            activityKind: "fetch", plan: "https://example.com",
            externalRef: "https://example.com/final",
            externalIdentity: "https://example.com/final")
    }

    // MARK: Small family

    @Test("small reads round-trip through the envelope")
    func smallReads() throws {
        let resolve = try opReply(
            .resolveTitleToID,
            DaemonResolveTitleToIDReply(pageID: "01JPAGE0000000000000000AA"))
        #expect(resolve.pageID == "01JPAGE0000000000000000AA")

        let request = try opRequest(
            .searchSimilar,
            DaemonSearchSimilarRequest(
                query: "agents", limit: 5, bm25Leg: [pageSummary]))
        #expect(request.bm25Leg?.first == pageSummary)
        let search = try opReply(
            .searchSimilar, DaemonSearchSimilarReply(results: [pageSummary]))
        #expect(search.results == [pageSummary])

        let state = try opReply(
            .getWikiStrategyState,
            DaemonGetWikiStrategyStateReply(state: DaemonWikiStrategyState(
                strategy: DaemonStrategySnapshot(
                    name: "House style", instructions: "# Strategy",
                    revision: 4, updatedAt: at),
                revision: 4)))
        #expect(state.state.strategy?.revision == 4)
        #expect(state.state.revision == 4)

        let origin = try opReply(
            .pageOrigin,
            DaemonPageOriginReply(origin: DaemonPageOrigin(
                versionID: "01JVERSION00000000000000AB", title: "Meeting Notes",
                blobHash: String(repeating: "b", count: 64),
                agentName: DaemonPageAuthor(rawValue: "chat:01JCHAT00000000000000000A"),
                agentKind: "chat", activityKind: "edit", plan: nil,
                externalRef: nil, runTitle: "Meeting chat", savedAt: at)))
        #expect(origin.origin?.agentName.rawValue.hasPrefix("chat:") == true)
        #expect(origin.origin?.agentKind == "chat")

        let okf = try opReply(
            .pageOKFMetadata,
            DaemonPageOKFMetadataReply(metadata: DaemonPageOKFTrustMetadata(
                pageID: "01JPAGE0000000000000000AA",
                versionID: "01JVERSION00000000000000AB",
                metadata: DaemonOKFConceptMetadata(
                    status: .stable, staleAfter: at,
                    freshnessPolicy: .ttl(
                        seconds: 86_400, anchor: .verification(id: "okf-1")),
                    verifications: [DaemonOKFVerificationEvent(
                        id: "okf-1",
                        by: DaemonOKFVerifierIdentity(
                            rawValue: "human:amy", kind: .human, name: "amy",
                            version: nil),
                        verifiedAt: at,
                        basis: DaemonOKFVerificationBasis(
                            version: 1, kind: .humanReview,
                            evidence: [
                                .source(id: "01JSOURCE000000000000000AB"),
                                .external(url: "https://example.com/e"),
                            ], note: "checked"),
                        removedAt: nil, correctionActivityID: nil,
                        correctedBy: nil, correctionReason: nil)],
                    projectionRevision: 3))))
        let verification = okf.metadata?.metadata.verifications.first
        #expect(verification?.basis.evidence.first == .source(id: "01JSOURCE000000000000000AB"))
        #expect(verification?.basis.evidence.last == .external(url: "https://example.com/e"))
    }

    @Test("small no-emit mutators echo the outcome without events")
    func smallMutators() throws {
        let request = try opRequest(
            .setMetadata, DaemonSetMetadataRequest(key: "k", value: "v"),
            stamp: Self.stamp)
        #expect(request.value == "v")
        let reply = try opReply(
            .setMetadata, DaemonSetMetadataReply(outcome: echo("setMetadata")))
        #expect(reply.outcome.status == .committed)

        let vacuum = try opReply(
            .vacuumBlobs,
            DaemonVacuumBlobsReply(
                report: DaemonBlobVacuumReport(
                    orphanCount: 3, bytesReclaimed: 9_000, applied: false),
                outcome: DaemonMutationOutcome(
                    stamp: Self.stamp, status: .joined)))
        #expect(vacuum.report.applied == false)
        #expect(vacuum.outcome.status == .joined)
    }

    // MARK: List family

    @Test("list ops round-trip cursors and entry arrays")
    func listOps() throws {
        let request = try opRequest(
            .listPages, DaemonListPagesRequest(sortBy: .titleAZ))
        #expect(request.sortBy == .titleAZ)
        let reply = try opReply(
            .listPages,
            DaemonListPagesReply(
                pages: [pageSummary],
                cursor: DaemonReplyCursor(
                    pageToken: "tok-9", nextAvailable: true,
                    accumulatedEncodedByteCount: 700_000)))
        #expect(reply.cursor.nextAvailable)
        #expect(reply.pages == [pageSummary])

        let impact = try opReply(
            .deletionImpact,
            DaemonDeletionImpactReply(
                impact: DaemonDeletionImpact(
                    linkingPages: [
                        DaemonDeletionLinkingPage(
                            pageID: "01JPAGE0000000000000000AA", title: nil)
                    ],
                    bookmarks: [
                        DaemonDeletionBookmarkImpact(
                            nodeID: "01JBMARK0000000000000000A",
                            folderPath: "Research")
                    ],
                    provenanceBlockers: [
                        DaemonProvenanceDeletionBlocker(
                            sourceID: "01JSOURCE000000000000000AB",
                            pageVersionID: "01JVERSION00000000000000AB",
                            pageID: "01JPAGE0000000000000000AA")
                    ],
                    incomingLinkCount: 2),
                cursor: DaemonReplyCursor(
                    pageToken: nil, nextAvailable: false,
                    accumulatedEncodedByteCount: 512)))
        #expect(impact.impact.provenanceBlockers.count == 1)
        #expect(impact.impact.linkingPages.first?.title == nil)

        let chains = try opReply(
            .sourceDerivedChains,
            DaemonSourceDerivedChainsReply(
                entries: [
                    DaemonSourceDerivedChainEntry(
                        sourceID: "01JSOURCE000000000000000AB",
                        chain: ["01JMDVER000000000000000A",
                                "01JMDVER000000000000000B"])
                ],
                cursor: DaemonReplyCursor(
                    pageToken: nil, nextAvailable: false,
                    accumulatedEncodedByteCount: 128)))
        #expect(chains.entries.first?.chain.count == 2)

        let transcript = try opReply(
            .readChatTranscriptPage,
            DaemonReadChatTranscriptPageReply(
                page: DaemonChatTranscriptPage(
                    items: [DaemonPersistedChatTranscriptItem(
                        cursor: DaemonChatTranscriptCursor(rawValue: 1),
                        item: .systemNotice(DaemonChatTranscriptSystemNoticeItem(
                            noticeID: "notice-1", turnID: nil, kind: .recovery,
                            title: "Resumed", message: "session restored",
                            createdAt: at)),
                        projectedEventJSON: nil,
                        projectedPlainText: "Resumed", createdAt: at,
                        summary: nil)],
                    checkpoint: DaemonChatTranscriptCursor(rawValue: 1),
                    nextCursor: nil),
                cursor: DaemonReplyCursor(
                    pageToken: "tp-2", nextAvailable: false,
                    accumulatedEncodedByteCount: 4_096)))
        guard case .systemNotice(let notice)? =
            transcript.page.items.first?.item
        else {
            Issue.record("expected a systemNotice transcript item")
            return
        }
        #expect(notice.kind == .recovery)
        #expect(notice.turnID == nil)
    }

    // MARK: Blob family

    @Test("blob uploads and handle-backed downloads round-trip")
    func blobOps() throws {
        let addSource = try opRequest(
            .addSource,
            DaemonAddSourceRequest(
                filename: "paper.pdf", data: handle("h-1", bytes: 1_024),
                detectionHints: hints, ingestMetadata: DaemonSourceIngestMetadata(
                    externalItemID: "ITEM1", externalItemTitle: "A Paper"),
                provenance: provenance, role: .primary, originalPath: "/tmp/p",
                activityID: "act-1", resolvedDisplayName: "The Paper"),
            stamp: Self.stamp)
        #expect(addSource.data.declaredByteCount == 1_024)
        #expect(addSource.role == .primary)
        let addReply = try opReply(
            .addSource,
            DaemonAddSourceReply(
                source: sourceSummary, outcome: echo("addSource"),
                event: pageEvent))
        #expect(addReply.event?.seq == 42)

        let getPage = try opReply(
            .getPage,
            DaemonGetPageReply(
                page: DaemonPageMetadata(
                    id: "01JPAGE0000000000000000AA", title: "Meeting Notes",
                    slug: "meeting-notes", createdAt: at, updatedAt: at,
                    version: 2, createdBy: "user", lastEditedBy: nil),
                body: handle("h-body", bytes: 4_096), bodyByteCount: 4_096))
        #expect(getPage.page.slug == "meeting-notes")
        #expect(getPage.body.sha256Hex.count == 64)

        // Both sourceContent overloads are representable and round-trip.
        let byID = try opRequest(
            .sourceContent, DaemonSourceContentRequest.active(
                sourceID: "01JSOURCE000000000000000AB"))
        let byVersion = try opRequest(
            .sourceContent, DaemonSourceContentRequest.version(
                versionID: "01JSRCVER000000000000000A"))
        guard case .active(let id)? = Optional(byID),
            case .version(let versionID)? = Optional(byVersion)
        else {
            Issue.record("sourceContent cases did not decode")
            return
        }
        #expect(id == "01JSOURCE000000000000000AB")
        #expect(versionID == "01JSRCVER000000000000000A")
        let content = try opReply(
            .sourceContent,
            DaemonSourceContentReply(
                bytes: handle("h-bytes", bytes: 1_024), byteCount: 1_024))
        #expect(content.byteCount == 1_024)

        // The events array rides as a staged handle over its JSON.
        let append = try opRequest(
            .appendChatMessages,
            DaemonAppendChatMessagesRequest(
                chatID: "01JCHAT00000000000000000A",
                events: handle("h-events", bytes: 256), eventCount: 2),
            stamp: Self.stamp)
        #expect(append.eventCount == 2)
        let appendReply = try opReply(
            .appendChatMessages,
            DaemonAppendChatMessagesReply(
                messages: [DaemonChatMessage(
                    id: "01JMSG000000000000000000A",
                    chatID: "01JCHAT00000000000000000A", seq: 0,
                    event: .userText(text: "Hello"), createdAt: at,
                    isDraft: false)],
                outcome: echo("appendChatMessages"), event: nil))
        #expect(appendReply.messages.first?.event == .userText(text: "Hello"))

        // The no-emit chunk store carries the outcome and NO event field.
        let chunks = try opReply(
            .storePageChunks,
            DaemonStorePageChunksReply(outcome: echo("storePageChunks")))
        #expect(chunks.outcome.stamp.requestID == Self.stamp.requestID)

        // Default strategy: nil snapshot round-trips.
        let strategy = try opReply(
            .getWikiStrategy, DaemonGetWikiStrategyReply(strategy: nil))
        #expect(strategy.strategy == nil)
    }

    @Test("blob markdown writers echo headers and events")
    func blobMarkdownWriters() throws {
        let header = DaemonSourceMarkdownVersionHeader(
            id: "01JMDVER000000000000000A",
            sourceID: "01JSOURCE000000000000000AB", parentID: nil,
            origin: .transcript, note: nil, createdAt: at, activityID: "act-2",
            sourceVersionID: "01JSRCVER000000000000000A",
            blobHash: String(repeating: "c", count: 64),
            mimeType: "text/markdown", technique: nil)
        let reply = try opReply(
            .appendHostSpeechTranscript,
            DaemonAppendHostSpeechTranscriptReply(
                version: header, outcome: echo("appendHostSpeechTranscript"),
                event: DaemonResourceChangeEvent(
                    kind: "source", id: "01JSOURCE000000000000000AB",
                    change: "updated", seq: 43)))
        #expect(reply.version.origin == .transcript)
        #expect(reply.event?.change == "updated")

        let request = try opRequest(
            .appendDerivedMarkdown,
            DaemonAppendDerivedMarkdownRequest(
                sourceID: "01JSOURCE000000000000000AB",
                content: handle("h-md"), origin: .extraction,
                producer: .installedPackage(DaemonExtractorPackageProducer(
                    packageID: "com.example.docx2md", version: "1.0.0",
                    digestHex: String(repeating: "d", count: 64),
                    registrationID: "docx", protocolRevision: "3",
                    reportedMetadata: DaemonExtractorReportedMetadata(
                        toolName: "docx2md", toolVersion: "1.0.0",
                        modelName: nil, modelVersion: nil, language: "en",
                        transcriptGenerated: nil))),
                providerID: nil, modelID: nil, toolVersion: "1.0.0",
                sourceVersionID: "01JSRCVER000000000000000A", note: nil),
            stamp: Self.stamp)
        guard case .installedPackage(let package)? = request.producer else {
            Issue.record("expected installedPackage producer")
            return
        }
        #expect(package.packageID == "com.example.docx2md")
        #expect(package.reportedMetadata.language == "en")
    }

    // MARK: Event-producer family

    @Test("event producers echo outcome stamps and change events")
    func eventProducers() throws {
        let create = try opRequest(
            .createChat,
            DaemonCreateChatRequest(
                kind: .edit, title: "New Chat", modelProviderId: "claude-acp",
                modelId: "claude-opus-5", configuredThinkingOptionID: "think",
                effectiveThinkingOptionID: "think", attachments: [
                    .page(id: "01JPAGE0000000000000000AA"),
                    .source(id: "01JSOURCE000000000000000AB"),
                ]),
            stamp: Self.stamp)
        #expect(create.attachments.count == 2)
        let createReply = try opReply(
            .createChat,
            DaemonCreateChatReply(
                chat: DaemonChatSummary(
                    id: "01JCHAT00000000000000000A", kind: .edit,
                    title: "New Chat", createdAt: at, updatedAt: at,
                    messageCount: 0, acpSessionId: nil,
                    modelProviderId: "claude-acp", modelId: "claude-opus-5",
                    configuredThinkingOptionID: "think",
                    effectiveThinkingOptionID: "think"),
                outcome: echo("createChat"),
                events: [DaemonResourceChangeEvent(
                    kind: "chat", id: "01JCHAT00000000000000000A",
                    change: "created", seq: 44)]))
        #expect(createReply.chat.kind == .edit)
        #expect(createReply.events.first?.change == "created")

        // Batch mutator: one echo per rewritten page + removed bookmark +
        // deleted target.
        let delete = try opReply(
            .deleteResources,
            DaemonDeleteResourcesReply(
                result: DaemonResourceDeletionResult(
                    deletedTargets: [.page(id: "01JPAGE0000000000000000AA")],
                    rewrittenPageIDs: ["01JPAGE0000000000000000AB"],
                    removedBookmarkIDs: ["01JBMARK0000000000000000A"],
                    incomingLinkCount: 1),
                outcome: echo("deleteResources"),
                events: [
                    pageEvent,
                    DaemonResourceChangeEvent(
                        kind: "bookmark",
                        id: "01JBMARK0000000000000000A", change: "deleted",
                        seq: 45),
                ]))
        #expect(delete.result.rewrittenPageIDs.count == 1)
        #expect(delete.events.count == 2)

        // Conditional emitter: no title write commits with NO event.
        let titleIfEmpty = try opReply(
            .setChatTitleIfEmpty,
            DaemonSetChatTitleIfEmptyReply(
                didWrite: false, outcome: echo("setChatTitleIfEmpty"),
                events: []))
        #expect(titleIfEmpty.didWrite == false)
        #expect(titleIfEmpty.events.isEmpty)

        // markFetchComplete variant: didAdvance present; the unconditional
        // overload leaves it nil.
        let markVariant = try opReply(
            .markFetchComplete,
            DaemonMarkFetchCompleteReply(
                didAdvance: true, outcome: echo("markFetchComplete"),
                events: [DaemonResourceChangeEvent(
                    kind: "source", id: "01JSOURCE000000000000000AB",
                    change: "updated", seq: 46)]))
        #expect(markVariant.didAdvance == true)
        let markUnconditional = try opReply(
            .markFetchComplete,
            DaemonMarkFetchCompleteReply(
                didAdvance: nil, outcome: echo("markFetchComplete"),
                events: []))
        #expect(markUnconditional.didAdvance == nil)
    }

    // MARK: Error-carrying reply

    @Test("a typed error reply round-trips its mirror payload intact")
    func errorReply() throws {
        // DaemonStoreError.duplicateContent carries the existing source as a
        // DaemonSourceSummary mirror — the error rides inside the store
        // reply's `error` field, never stringified.
        let failure = DaemonStoreReply(
            result: nil,
            error: .duplicateContent(sourceSummary))
        let envelope = DaemonDomainReply.success(
            requestID: "rep-error", family: .store,
            operation: DaemonStoreOperation.addSource.rawValue,
            payload: try DaemonStoreWire.encode(failure))
        let wire = try DaemonStoreFrameSizing.encodeValidatedReply(envelope)
        let decoded = try DaemonStoreWire.decodeReply(
            try #require(try DaemonDomainWire.decodeReply(wire).payload))
        guard case .duplicateContent(let existing)? = decoded.error else {
            Issue.record("expected duplicateContent")
            return
        }
        #expect(existing == sourceSummary)
        #expect(existing.displayName == nil)
    }

    // MARK: Collective mirror coverage (stragglers)

    /// Standalone JSON round trip for pure value mirrors.
    private func roundTripValue<T: Codable & Equatable>(_ value: T) throws -> T {
        try JSONDecoder().decode(
            T.self, from: JSONEncoder().encode(value))
    }

    @Test("remaining mirror types round-trip somewhere")
    func remainingMirrorTypes() throws {
        // replaceLinks request: ParsedLink mirror (embed + version pin).
        let links = try opRequest(
            .replaceLinks,
            DaemonReplaceLinksRequest(
                pageID: "01JPAGE0000000000000000AA",
                parsedLinks: [
                    DaemonParsedLink(
                        linkType: .source, target: "paper", fragment: "§2",
                        linkText: "the paper", isEmbed: true, versionPin: "3"),
                    DaemonParsedLink(
                        linkType: .chat, target: "01JCHAT00000000000000000A",
                        fragment: nil, linkText: "meeting", isEmbed: false,
                        versionPin: nil),
                ]),
            stamp: Self.stamp)
        #expect(links.parsedLinks.first?.isEmbed == true)
        #expect(links.parsedLinks.first?.versionPin == "3")

        // deletionImpact request: the typed deletion request mirror.
        let impactRequest = try opRequest(
            .deletionImpact,
            DaemonDeletionImpactRequest(targets: [
                .page(id: "01JPAGE0000000000000000AA"),
                .source(id: "01JSOURCE000000000000000AB"),
            ]))
        #expect(impactRequest.targets.count == 2)
        let policy = try roundTripValue(
            DaemonResourceDeletionRequest(
                targets: [.source(id: "01JSOURCE000000000000000AB")],
                linkPolicy: .unlink))
        #expect(policy.linkPolicy == .unlink)

        // setChatAttachments: the .chat attachment-target case.
        let attachments = try opRequest(
            .setChatAttachments,
            DaemonSetChatAttachmentsRequest(
                chatID: "01JCHAT00000000000000000A",
                targets: [.chat(id: "01JCHAT00000000000000000A")]),
            stamp: Self.stamp)
        #expect(attachments.targets.first == .chat(id: "01JCHAT00000000000000000A"))

        // workspaceConflicts: the .pageVersion conflict-target case.
        let conflicts = try opReply(
            .workspaceConflicts,
            DaemonWorkspaceConflictsReply(
                conflicts: [DaemonWorkspaceConflict(
                    workspaceID: "01JWORK000000000000000000A",
                    pageID: "01JPAGE0000000000000000AA", baseVersionID: nil,
                    mainVersionID: nil,
                    workspaceTarget: .pageVersion(
                        id: "01JVERSION00000000000000AB"), createdAt: at)],
                cursor: DaemonReplyCursor(
                    pageToken: nil, nextAvailable: false,
                    accumulatedEncodedByteCount: 100)))
        #expect(conflicts.conflicts.first?.workspaceTarget
            == .pageVersion(id: "01JVERSION00000000000000AB"))

        // pageVersionSources: the persisted provenance-edge mirror.
        let edges = try opReply(
            .pageVersionSources,
            DaemonPageVersionSourcesReply(sources: [DaemonPageVersionSource(
                pageVersionID: "01JVERSION00000000000000AB",
                sourceID: "01JSOURCE000000000000000AB", role: .quoted)]))
        #expect(edges.sources.first?.role == .quoted)

        // pagesCitingSources + pageVersionHistory reply item types.
        let cited = try opReply(
            .pagesCitingSources,
            DaemonPagesCitingSourcesReply(
                pages: [DaemonCitedPage(
                    pageID: "01JPAGE0000000000000000AA", title: nil)],
                cursor: DaemonReplyCursor(
                    pageToken: nil, nextAvailable: false,
                    accumulatedEncodedByteCount: 64)))
        #expect(cited.pages.first?.title == nil)
        let history = try opReply(
            .pageVersionHistory,
            DaemonPageVersionHistoryReply(
                versions: [DaemonPageVersionSummary(
                    id: "01JVERSION00000000000000AB",
                    pageID: "01JPAGE0000000000000000AA", parentID: nil,
                    mergeParentID: "01JVERSION00000000000000CD",
                    blobHash: String(repeating: "2", count: 64),
                    title: "Notes", activityID: "act-4", savedAt: at)],
                cursor: DaemonReplyCursor(
                    pageToken: nil, nextAvailable: false,
                    accumulatedEncodedByteCount: 200)))
        #expect(history.versions.first?.mergeParentID != nil)

        // activeContentVersion / sourceVersion: the content-version mirror.
        let version = DaemonSourceVersion(
            id: "01JSRCVER000000000000000A",
            sourceID: "01JSOURCE000000000000000AB", parentID: nil,
            blobHash: nil, mimeType: nil, activityID: nil,
            externalIdentity: "yt:abc", fetchedAt: at)
        let active = try opReply(
            .activeContentVersion,
            DaemonActiveContentVersionReply(version: version))
        #expect(active.version == version)

        // sourceOriginsBySource + embedDescriptors + agent names + sibling
        // resolvers: the keyed-map entry mirrors.
        let origins = try opReply(
            .sourceOriginsBySource,
            DaemonSourceOriginsBySourceReply(entries: [
                DaemonSourceOriginEntry(
                    sourceID: "01JSOURCE000000000000000AB",
                    origin: DaemonSourceOrigin(
                        versionID: "01JSRCVER000000000000000A",
                        agentName: "youtube", agentKind: "software",
                        activityKind: "fetch", plan: "https://youtu.be/x",
                        externalRef: nil, externalIdentity: "abc",
                        runTitle: nil, fetchedAt: at))
            ], cursor: DaemonReplyCursor(
                pageToken: nil, nextAvailable: false,
                accumulatedEncodedByteCount: 300)))
        #expect(origins.entries.first?.origin.agentName == "youtube")
        let embeds = try opReply(
            .embedDescriptors,
            DaemonEmbedDescriptorsReply(entries: [
                DaemonSourceEmbedEntry(
                    sourceID: "01JSOURCE000000000000000AB",
                    descriptor: DaemonSourceEmbedDescriptor(
                        id: "01JSOURCE000000000000000AB",
                        mimeType: "video/youtube", externalIdentity: "abc",
                        agentName: "youtube", planURL: "https://youtu.be/x"))
            ], cursor: DaemonReplyCursor(
                pageToken: nil, nextAvailable: false,
                accumulatedEncodedByteCount: 300)))
        #expect(embeds.entries.first?.descriptor.mimeType == "video/youtube")
        let agentNames = try opReply(
            .processedMarkdownAgentNames,
            DaemonProcessedMarkdownAgentNamesReply(entries: [
                DaemonMarkdownAgentNameEntry(
                    versionID: "01JMDVER000000000000000A", agentName: "pdf2md")
            ], cursor: DaemonReplyCursor(
                pageToken: nil, nextAvailable: false,
                accumulatedEncodedByteCount: 100)))
        #expect(agentNames.entries.first?.agentName == "pdf2md")
        let resolvers = try opReply(
            .siblingImageResolvers,
            DaemonSiblingImageResolversReply(entries: [
                DaemonSiblingImageResolverEntry(
                    sourceID: "01JSOURCE000000000000000AB",
                    resolvers: [DaemonSiblingImageResolver(
                        originalPath: "img/1.png",
                        sourceID: "01JSOURCE000000000000000AC")])
            ], cursor: DaemonReplyCursor(
                pageToken: nil, nextAvailable: false,
                accumulatedEncodedByteCount: 200)))
        #expect(resolvers.entries.first?.resolvers.first?.originalPath == "img/1.png")

        // processedMarkdownAlternatives + activeExtractionProvenance.
        let header = DaemonSourceMarkdownVersionHeader(
            id: "01JMDVER000000000000000A",
            sourceID: "01JSOURCE000000000000000AB", parentID: nil,
            origin: .extraction, note: nil, createdAt: at, activityID: nil,
            sourceVersionID: nil, blobHash: nil, mimeType: "text/markdown",
            technique: "pdf2md")
        let alternatives = try opReply(
            .processedMarkdownAlternatives,
            DaemonProcessedMarkdownAlternativesReply(
                alternatives: [DaemonExtractionAlternative(
                    version: header, backendDisplayName: "pdf2md",
                    agentName: "pdf2md", modelVersion: nil, package: nil,
                    charCount: 1_234, isActive: true)],
                contents: handle("h-alt", bytes: 1_234), contentByteCount: 1_234,
                cursor: DaemonReplyCursor(
                    pageToken: nil, nextAvailable: false,
                    accumulatedEncodedByteCount: 2_000)))
        #expect(alternatives.alternatives.first?.isActive == true)
        let provenanceRead = try opReply(
            .activeExtractionProvenance,
            DaemonActiveExtractionProvenanceReply(
                provenance: DaemonExtractionProvenance(
                    markdownVersionID: "01JMDVER000000000000000A",
                    sourceID: "01JSOURCE000000000000000AB", origin: .user,
                    producer: .legacy(rawTechnique: nil), providerID: nil,
                    modelID: nil, toolVersion: nil, createdAt: at,
                    sourceVersionID: nil)))
        guard case .legacy(nil)? = Optional(provenanceRead.provenance?.producer)
        else {
            Issue.record("expected a legacy producer")
            return
        }

        // fetchState: the lifecycle enum.
        let state = try opReply(
            .fetchState,
            DaemonFetchStateReply(state: .formatJobPending))
        #expect(state.state == .formatJobPending)

        // createPage: the full request/reply pair (metadata + body handle).
        let createPageRequest = try opRequest(
            .createPage,
            DaemonCreatePageRequest(
                title: "Fresh", body: nil, createdBy: nil, provenance: []),
            stamp: Self.stamp)
        #expect(createPageRequest.body == nil)
        let createPageReply = try opReply(
            .createPage,
            DaemonCreatePageReply(
                page: DaemonPageMetadata(
                    id: "01JPAGE0000000000000000AA", title: "Fresh",
                    slug: "fresh", createdAt: at, updatedAt: at, version: 1,
                    createdBy: nil, lastEditedBy: nil),
                body: handle("h-body", bytes: 0), bodyByteCount: 0,
                outcome: echo("createPage"),
                event: DaemonResourceChangeEvent(
                    kind: "page", id: "01JPAGE0000000000000000AA",
                    change: "created", seq: 49)))
        #expect(createPageReply.page.slug == "fresh")
        #expect(createPageReply.bodyByteCount == 0)

        // saveWikiStrategy: both save-outcome cases.
        let saved = try opReply(
            .saveWikiStrategy,
            DaemonSaveWikiStrategyReply(
                result: .saved(
                    revision: 5,
                    strategy: DaemonStrategySnapshot(
                        name: "House style", instructions: "# Strategy",
                        revision: 5, updatedAt: at)),
                outcome: echo("saveWikiStrategy"),
                event: DaemonResourceChangeEvent(
                    kind: "strategy", id: "wiki_strategy", change: "updated",
                    seq: 50)))
        guard case .saved(let revision, let strategy)? =
            Optional(saved.result)
        else {
            Issue.record("expected a saved outcome")
            return
        }
        #expect(revision == 5)
        #expect(strategy?.name == "House style")
        let unchanged = try roundTripValue(
            DaemonSaveWikiStrategyReply(
                result: .unchanged, outcome: echo("saveWikiStrategy"),
                event: nil))
        guard case .unchanged? = Optional(unchanged.result) else {
            Issue.record("expected an unchanged outcome")
            return
        }

        // correctPageOKFVerification: correction reason + producer verifier.
        let correct = try opRequest(
            .correctPageOKFVerification,
            DaemonCorrectPageOKFVerificationRequest(
                versionID: "01JVERSION00000000000000AB", verificationID: "okf-1",
                correctingVerifier: DaemonOKFVerifierIdentity(
                    rawValue: "pdf2md/1.0", kind: .producer, name: "pdf2md",
                    version: "1.0"),
                correctedAt: at,
                reason: DaemonOKFVerificationCorrectionReason(
                    version: 1, reason: "typo in evidence")),
            stamp: Self.stamp)
        #expect(correct.correctingVerifier.kind == .producer)
        #expect(correct.reason?.reason == "typo in evidence")
        let freshness = try opRequest(
            .setPageOKFFreshness,
            DaemonSetPageOKFFreshnessRequest(
                versionID: "01JVERSION00000000000000AB",
                policy: .fixed(date: at)),
            stamp: Self.stamp)
        #expect(freshness.policy == .fixed(date: at))
        let anchor = try roundTripValue(DaemonOKFFreshnessAnchor.generated)
        let recorded = try roundTripValue(
            DaemonOKFFreshnessAnchor.recordedVerification)
        #expect(anchor == .generated)
        #expect(recorded == .recordedVerification)

        // sourceMarkdownOKFMetadata: the markdown trust-metadata mirror.
        let mdOKF = try opReply(
            .sourceMarkdownOKFMetadata,
            DaemonSourceMarkdownOKFMetadataReply(
                metadata: DaemonSourceMarkdownOKFTrustMetadata(
                    sourceID: "01JSOURCE000000000000000AB",
                    versionID: "01JMDVER000000000000000A",
                    metadata: DaemonOKFConceptMetadata(
                        status: .draft, staleAfter: nil, freshnessPolicy: nil,
                        verifications: [], projectionRevision: 0))))
        #expect(mdOKF.metadata?.metadata.status == .draft)

        // The other two vacuum reports.
        let activityVacuum = try roundTripValue(DaemonActivityVacuumReport(
            orphanCount: 1, applied: true))
        #expect(activityVacuum.applied)
        let versionVacuum = try roundTripValue(DaemonPageVersionVacuumReport(
            deletedCount: 2, applied: false))
        #expect(versionVacuum.deletedCount == 2)

        // claimNext + setChatTitleIf request shapes.
        let claim = try opRequest(
            .claimNextPersistedChatTurn,
            DaemonClaimNextPersistedChatTurnRequest(
                chatID: "01JCHAT00000000000000000A", claimID: "claim-2",
                claimedAt: at, providerID: nil, modelID: nil),
            stamp: Self.stamp)
        #expect(claim.claimID == "claim-2")
        let titleIf = try opRequest(
            .setChatTitleIf,
            DaemonSetChatTitleIfRequest(
                chatID: "01JCHAT00000000000000000A",
                expectedTitle: "New Chat", title: "Real title"),
            stamp: Self.stamp)
        #expect(titleIf.expectedTitle == "New Chat")
    }

    // MARK: Collective mirror coverage

    @Test("every DaemonAgentEvent case round-trips", arguments: [
        DaemonAgentEvent.userText(text: "hi"),
        .systemInit(model: "claude-opus-5"),
        .assistantText(text: "hello"),
        .thinking(text: "pondering"),
        .thinkingDelta(text: "…"),
        .assistantTextDelta(text: "…"),
        .toolUse(name: "Bash", inputSummary: "ls"),
        .toolResult(isError: false, summary: "ok"),
        .subagent(subagentType: "source-reader", description: "digest", isCompletion: true),
        .result(isError: true, text: "failed"),
        .messageStop,
        .turnFailed(reason: .quotaExhausted(
            providerID: "gemini",
            resetTime: Date(timeIntervalSince1970: 1_800_000_000))),
        .raw(line: "garbage line"),
    ])
    func agentEventCases(event: DaemonAgentEvent) throws {
        let reply = try opReply(
            .appendChatMessages,
            DaemonAppendChatMessagesReply(
                messages: [DaemonChatMessage(
                    id: "01JMSG000000000000000000A",
                    chatID: "01JCHAT00000000000000000A", seq: 0, event: event,
                    createdAt: at, isDraft: true)],
                outcome: echo("appendChatMessages"), event: nil))
        #expect(reply.messages.first?.event == event)
    }

    @Test("every DaemonTurnFailureReason case round-trips", arguments: [
        DaemonTurnFailureReason.stalled(idleSeconds: 120),
        .ceilingExceeded(totalSeconds: 3_600),
        .agentError(message: "subprocess died"),
        .quotaExhausted(providerID: "claude-acp", resetTime: nil),
    ])
    func turnFailureReasons(reason: DaemonTurnFailureReason) throws {
        let data = try JSONEncoder().encode(reason)
        let decoded = try JSONDecoder().decode(
            DaemonTurnFailureReason.self, from: data)
        #expect(decoded == reason)
    }

    @Test("extraction producer cases round-trip", arguments: [
        DaemonExtractionProducer.backend(rawBackend: "anthropic"),
        .tool(rawTool: "pdf2md"),
        .legacy(rawTechnique: nil),
        .legacy(rawTechnique: "html-to-markdown"),
        .hostSpeech(DaemonExtractionHostSpeechProducer(
            engine: "speech", localeID: "en_US", acquisitionFetcher: "host")),
    ])
    func extractionProducers(producer: DaemonExtractionProducer) throws {
        let request = try opRequest(
            .appendDerivedMarkdown,
            DaemonAppendDerivedMarkdownRequest(
                sourceID: "01JSOURCE000000000000000AB",
                content: handle("h-md"), origin: .extraction, producer: producer,
                providerID: nil, modelID: nil, toolVersion: nil,
                sourceVersionID: nil, note: nil),
            stamp: Self.stamp)
        #expect(request.producer == producer)
    }

    @Test("bookmark content cases round-trip", arguments: [
        DaemonBookmarkContent.folder(label: "Research"),
        .page(id: "01JPAGE0000000000000000AA"),
        .source(id: "01JSOURCE000000000000000AB"),
        .chat(id: "01JCHAT00000000000000000A"),
    ])
    func bookmarkContents(content: DaemonBookmarkContent) throws {
        let reply = try opReply(
            .createBookmarkNode,
            DaemonCreateBookmarkNodeReply(
                node: DaemonBookmarkNode(
                    id: "01JBMARK0000000000000000A", parentID: nil,
                    position: 0, content: content, createdAt: at,
                    updatedAt: at),
                outcome: echo("createBookmarkNode"), events: []))
        #expect(reply.node.content == content)
    }

    @Test("workspace types round-trip across their ops")
    func workspaceTypes() throws {
        let summary = try opReply(
            .workspaceSummary,
            DaemonWorkspaceSummaryReply(summary: DaemonWorkspaceSummary(
                id: "01JWORK000000000000000000A", name: "ingest branch",
                status: .conflicted, activityID: "act-3", createdAt: at,
                updatedAt: at)))
        #expect(summary.summary?.status == .conflicted)

        let refs = try opReply(
            .workspaceRefs,
            DaemonWorkspaceRefsReply(
                refs: [DaemonWorkspaceRef(
                    workspaceID: "01JWORK000000000000000000A",
                    ownerID: "01JPAGE0000000000000000AA", baseVersionID: nil,
                    versionID: nil,
                    blobHash: String(repeating: "e", count: 64),
                    title: "Staged", updatedAt: at)],
                cursor: DaemonReplyCursor(
                    pageToken: nil, nextAvailable: false,
                    accumulatedEncodedByteCount: 300)))
        #expect(refs.refs.first?.baseVersionID == nil)
        #expect(refs.refs.first?.title == "Staged")

        let conflicts = try opReply(
            .workspaceConflicts,
            DaemonWorkspaceConflictsReply(
                conflicts: [DaemonWorkspaceConflict(
                    workspaceID: "01JWORK000000000000000000A",
                    pageID: "01JPAGE0000000000000000AA", baseVersionID: nil,
                    mainVersionID: "01JVERSION00000000000000AB",
                    workspaceTarget: .stagedBlob(
                        hash: String(repeating: "f", count: 64)),
                    createdAt: at)],
                cursor: DaemonReplyCursor(
                    pageToken: nil, nextAvailable: false,
                    accumulatedEncodedByteCount: 300)))
        guard case .stagedBlob(let hash)? =
            Optional(conflicts.conflicts.first?.workspaceTarget)
        else {
            Issue.record("expected a stagedBlob workspace target")
            return
        }
        #expect(hash.count == 64)
    }

    @Test("renderer preference and bridge-input mirrors round-trip")
    func rendererTypes() throws {
        let exact = try opReply(
            .rendererSourcePreference,
            DaemonRendererSourcePreferenceReply(
                preference: DaemonRendererSourcePreference(
                    sourceID: "01JSOURCE000000000000000AB",
                    preference: .exact(DaemonRendererReference(
                        packageID: "com.example.renderer", version: "2.1.0",
                        registrationID: "pdf-main")),
                    updatedAtRFC3339: "2026-08-13T00:00:00Z")))
        guard case .exact(let reference)? =
            Optional(exact.preference?.preference)
        else {
            Issue.record("expected an exact renderer reference")
            return
        }
        #expect(reference.version == "2.1.0")

        let logical = try opReply(
            .rendererSourcePreference,
            DaemonRendererSourcePreferenceReply(
                preference: DaemonRendererSourcePreference(
                    sourceID: "01JSOURCE000000000000000AB",
                    preference: .logical(DaemonLogicalRendererReference(
                        packageID: "com.example.renderer",
                        registrationID: "pdf-main")),
                    updatedAtRFC3339: "2026-08-13T00:00:00Z")))
        guard case .logical(let logicalRef)? =
            Optional(logical.preference?.preference)
        else {
            Issue.record("expected a logical renderer reference")
            return
        }
        #expect(logicalRef.registrationID == "pdf-main")

        let presentation = try opReply(
            .rendererSourcePresentation,
            DaemonRendererSourcePresentationReply(
                presentation: DaemonRendererSourcePresentation(
                    sourceID: "01JSOURCE000000000000000AB",
                    presentation: .split,
                    updatedAtRFC3339: "2026-08-13T00:00:00Z")))
        #expect(presentation.presentation?.presentation == .split)

        for input in [
            DaemonRendererBridgeInput.source(
                versionID: "01JSRCVER000000000000000A"),
            .markdown(versionID: "01JMDVER000000000000000A"),
            .inlineArtifact(DaemonRendererInlineArtifact(
                pageID: "01JPAGE0000000000000000AA",
                pageVersionID: "01JVERSION00000000000000AB", blockID: "b-1",
                fenceAlias: "mermaid", mimeType: "text/x-mermaid",
                digest: String(repeating: "1", count: 64),
                bytes: Data("graph TD".utf8))),
        ] {
            let request = try opRequest(
                .rendererInputByteCount,
                DaemonRendererInputByteCountRequest(input: input))
            #expect(request.input == input)
        }
    }

    @Test("MIME repair reports round-trip with detection mirrors")
    func mimeRepairReport() throws {
        let report = DaemonMIMERepairReport(
            scannedCount: 2, repairableCount: 1, updatedCount: 1,
            skippedBytelessCount: 1, skippedInconclusiveCount: 0, applied: true,
            items: [DaemonMIMERepairItem(
                sourceID: "01JSOURCE000000000000000AB",
                sourceVersionID: "01JSRCVER000000000000000A",
                filename: "doc.bin", nullState: .both,
                oldSourceMIMEType: nil, oldVersionMIMEType: nil,
                newMIMEType: "application/pdf",
                detection: DaemonContentTypeDetectionResult(
                    normalizedMIMEType: "application/pdf",
                    evidence: [
                        DaemonContentTypeEvidence(
                            origin: .binarySignature,
                            mimeType: "application/pdf",
                            confidence: .high, detail: "%PDF-1.7")
                    ],
                    confidence: .high,
                    conflicts: [DaemonContentTypeConflict(
                        kind: .disagreement, chosenMIMEType: "application/pdf",
                        conflictingEvidence: DaemonContentTypeEvidence(
                            origin: .filenameExtension, mimeType: "text/plain",
                            confidence: .fallback, detail: nil))],
                    structuredArtifactKind: nil),
                status: .detectorRepair, updated: true)])
        let reply = try opReply(
            .repairMIME,
            DaemonRepairMIMEReply(
                report: report, outcome: echo("repairMIME"), events: []))
        let item = try #require(reply.report.items.first)
        #expect(item.detection.evidence.first?.origin == .binarySignature)
        #expect(item.detection.conflicts.first?.kind == .disagreement)
        #expect(item.nullState == .both)
    }

    @Test("log, wiki index, chat turn, and transcript mirrors round-trip")
    func remainingMirrors() throws {
        let log = try opReply(
            .appendLog,
            DaemonAppendLogReply(
                entry: DaemonLogEntry(
                    id: "01JLOG0000000000000000000A", timestamp: at,
                    kind: .ingest, title: "ingested paper.pdf", note: nil),
                outcome: echo("appendLog"),
                events: [DaemonResourceChangeEvent(
                    kind: "log", id: "01JLOG0000000000000000000A",
                    change: "created", seq: 47)]))
        #expect(log.entry.kind == .ingest)

        let index = try opReply(
            .getWikiIndex,
            DaemonGetWikiIndexReply(
                metadata: DaemonWikiIndexMetadata(
                    updatedAt: at, version: 3),
                body: handle("h-index", bytes: 2_048), bodyByteCount: 2_048))
        #expect(index.metadata.version == 3)

        let usage = DaemonChatTurnUsageValues(
            inputTokens: 100, outputTokens: 40, thoughtTokens: 12,
            cacheReadTokens: 0, cacheWriteTokens: 0, cost: Decimal(string: "0.012")!,
            currency: "USD")
        let turn = DaemonPersistedChatTurn(
            chatID: "01JCHAT00000000000000000A", ordinal: 1,
            submission: DaemonChatTurnSubmission(
                commandID: "cmd-1", turnID: "turn-1", userText: "Summarize",
                contextReferences: [.chat(id: "01JCHAT00000000000000000A")],
                submittedAt: at),
            editedAt: nil, state: .completed, claimID: "claim-1", claimedAt: at,
            providerSubmittedAt: at, providerSessionID: "acp-1",
            terminalMessage: nil, providerID: "claude-acp",
            modelID: "claude-opus-5", finishedAt: at, usage: usage)
        let finish = try opReply(
            .finishPersistedChatTurn,
            DaemonFinishPersistedChatTurnReply(
                turn: turn, outcome: echo("finishPersistedChatTurn"),
                event: DaemonResourceChangeEvent(
                    kind: "chat", id: "01JCHAT00000000000000000A",
                    change: "updated", seq: 48)))
        #expect(finish.turn.usage.cost == Decimal(string: "0.012")!)
        #expect(finish.turn.state == .completed)
        #expect(finish.turn.submission.contextReferences.first
            == .chat(id: "01JCHAT00000000000000000A"))

        let usageSummary = try opReply(
            .chatUsageSummary,
            DaemonChatUsageSummaryReply(summary: DaemonChatUsageSummary(
                latestTurn: DaemonChatTurnUsage(
                    turnID: "turn-1", providerID: "claude-acp",
                    modelID: "claude-opus-5", startedAt: at, finishedAt: at,
                    state: .completed, inputTokens: 100, outputTokens: 40,
                    thoughtTokens: 12, cacheReadTokens: 0, cacheWriteTokens: 0,
                    cost: Decimal(string: "0.012")!, currency: "USD"),
                inputTokens: 100, outputTokens: 40, thoughtTokens: 12,
                cacheReadTokens: 0, cacheWriteTokens: 0,
                cost: Decimal(string: "0.012")!, currency: "USD")))
        #expect(usageSummary.summary.latestTurn?.state == .completed)

        // The durable transcript vocabulary: all four item cases.
        let messageItem = DaemonChatTranscriptItem.message(
            DaemonChatTranscriptMessageItem(
                messageID: "msg-1", turnID: "turn-1", role: .assistant,
                text: "Here you go", createdAt: at))
        let toolCallItem = DaemonChatTranscriptItem.toolCall(
            DaemonChatTranscriptToolCallItem(
                toolCallID: "tool-1", turnID: "turn-1", toolName: "Bash",
                status: .completed, detail: "ls", output: "file.md",
                permissionRequestID: nil, updatedAt: at))
        let failureItem = DaemonChatTranscriptItem.turnFailure(
            DaemonChatTranscriptTurnFailureItem(
                failureID: "fail-1", turnID: "turn-1", category: .cancelled,
                message: "cancelled by user", createdAt: at))
        let page = try opReply(
            .readChatTranscriptPage,
            DaemonReadChatTranscriptPageReply(
                page: DaemonChatTranscriptPage(
                    items: [
                        DaemonPersistedChatTranscriptItem(
                            cursor: DaemonChatTranscriptCursor(rawValue: 1),
                            item: messageItem, projectedEventJSON: "{}",
                            projectedPlainText: "Here you go", createdAt: at,
                            summary: "Here you go"),
                        DaemonPersistedChatTranscriptItem(
                            cursor: DaemonChatTranscriptCursor(rawValue: 2),
                            item: toolCallItem, projectedEventJSON: nil,
                            projectedPlainText: "ls", createdAt: at,
                            summary: nil),
                        DaemonPersistedChatTranscriptItem(
                            cursor: DaemonChatTranscriptCursor(rawValue: 3),
                            item: failureItem, projectedEventJSON: nil,
                            projectedPlainText: "cancelled", createdAt: at,
                            summary: nil),
                    ],
                    checkpoint: DaemonChatTranscriptCursor(rawValue: 3),
                    nextCursor: nil),
                cursor: DaemonReplyCursor(
                    pageToken: nil, nextAvailable: false,
                    accumulatedEncodedByteCount: 8_192)))
        #expect(page.page.items.count == 3)
        #expect(page.page.items[0].item == messageItem)
        #expect(page.page.items[1].item == toolCallItem)
        #expect(page.page.items[2].item == failureItem)
    }

    @Test("page write expectation and upsert outcome round-trip", arguments: [
        DaemonPageWriteExpectation.unrestricted,
        .expectedHead(versionID: "01JVERSION00000000000000AB"),
        .expectedAbsence,
    ])
    func upsertExpectations(expectation: DaemonPageWriteExpectation) throws {
        let request = try opRequest(
            .upsertPage,
            DaemonUpsertPageRequest(
                pageID: nil, title: "New Page",
                rawBody: handle("h-body", bytes: 64), expectation: expectation,
                author: "agent:ingest",
                provenance: [DaemonPageVersionSourceInput(
                    sourceID: "01JSOURCE000000000000000AB", role: .primary)]),
            stamp: Self.stamp)
        #expect(request.expectation == expectation)
        let reply = try opReply(
            .upsertPage,
            DaemonUpsertPageReply(
                result: DaemonPageUpsertOutcome(
                    id: "01JPAGE0000000000000000AA", didCreate: true),
                outcome: echo("upsertPage"), event: pageEvent))
        #expect(reply.result.didCreate)
    }
}
#endif
