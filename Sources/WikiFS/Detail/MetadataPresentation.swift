import Foundation
import WikiFSCore
import WikiFSEngine

/// Immutable, display-ready description of the metadata inspector. The model is
/// deliberately free of closures and store references so it can cross a read
/// pool boundary safely.
struct MetadataPanelModel: Equatable, Sendable {
    let subject: MetadataSubject
    let sections: [MetadataSection]
    let emptyState: MetadataEmptyState
}

enum MetadataSubject: Hashable, Sendable {
    case page(PageID)
    case source(SourceID)
    case chat(ChatID)
}

enum MetadataEmptyState: Equatable, Sendable {
    case none
    case unavailable
}

enum MetadataSectionID: String, Hashable, Sendable, CaseIterable {
    case summary
    case provenance
    case extraction
    case usage
    case conversationTotals
    case trustLifecycle
    case technical
}

struct MetadataSection: Identifiable, Equatable, Sendable {
    let id: MetadataSectionID
    let title: String
    let rows: [MetadataRow]
}

enum MetadataFieldID: Hashable, Sendable {
    case title, created, updated, version, author, writer, agent
    case source, sourceReference(SourceID), extractionType, producer, backend, provider, model, extractionDate
    case pageID, alternatives, sourceVersion, extractionVersion, hash, mimeType, byteCount
    case started, finished, duration, status, inputTokens, outputTokens, totalTokens
    case thoughtTokens, cacheReadTokens, cacheWriteTokens, cost, messageCount, compareVersions
    case conversationInputTokens, conversationOutputTokens, conversationThoughtTokens
    case conversationCacheReadTokens, conversationCacheWriteTokens, conversationCost
    case compareExtractions
    case lifecycleStatus, trustTier, staleAfter, freshnessState
    case verificationActor(OKFVerificationID), verificationDate(OKFVerificationID)
    case verificationBasis(OKFVerificationID), verificationNote(OKFVerificationID)
    case verificationEvidence(OKFVerificationID, Int)
}

struct MetadataRow: Identifiable, Equatable, Sendable {
    let id: MetadataFieldID
    let label: String
    let value: MetadataValue
    let accessibilityHint: String?
}

enum MetadataValue: Equatable, Sendable {
    case text(String)
    case date(Date)
    case byteCount(Int64)
    case integer(Int)
    case tokenCount(Int)
    case duration(Duration)
    case identifier(String)
    case link(label: String, target: MetadataLinkTarget)
    case action(label: String, target: MetadataActionTarget)
}

enum MetadataLinkTarget: Equatable, Sendable {
    case page(PageID)
    case source(SourceID)
    case chat(ChatID)
    case activity(QueueItem.ID)
    case url(URL)
}

enum MetadataActionTarget: Equatable, Sendable {
    case comparePageVersions(PageID)
    case compareSourceExtractions(SourceID)
    case copyIdentifier(String)
    case none
}

enum MetadataProjectionError: Error, LocalizedError, Equatable, Sendable {
    case missingSource(SourceID)

    var errorDescription: String? {
        switch self { case .missingSource: "The source is no longer available." }
    }
}

struct MetadataPageSource: Equatable, Sendable {
    let sourceID: SourceID
    let displayName: String
    let role: PageVersionSourceRole
}

struct PageMetadataInput: Sendable {
    let page: WikiPage
    let currentVersion: PageVersionSummary?
    let origin: PageOrigin?
    let sources: [MetadataPageSource]
    let okfMetadata: OKFConceptMetadata
}

enum OKFMetadataPresentation {
    static func section(_ metadata: OKFConceptMetadata, now: Date = Date()) -> MetadataSection {
        var rows: [MetadataRow] = [
            .init(
                id: .lifecycleStatus,
                label: "Lifecycle status",
                value: .text(metadata.status?.rawValue.capitalized ?? "Not explicitly set"),
                accessibilityHint: metadata.status == nil ? "No lifecycle status was authored" : nil),
            .init(
                id: .trustTier,
                label: "Trust tier",
                value: .text(trustLabel(metadata.trustTier)),
                accessibilityHint: "Derived from active verification actors")
        ]
        if let deadline = metadata.staleAfter {
            rows.append(.init(id: .staleAfter, label: "Stale after", value: .date(deadline), accessibilityHint: nil))
            rows.append(.init(
                id: .freshnessState, label: "Freshness",
                value: .text(metadata.isStale(at: now) == true ? "Stale" : "Fresh"),
                accessibilityHint: "Evaluated against the persisted deadline"))
        } else {
            rows.append(.init(
                id: .freshnessState, label: "Freshness",
                value: .text("No deadline set"), accessibilityHint: nil))
        }
        for verification in metadata.activeVerifications {
            rows.append(.init(
                id: .verificationActor(verification.id), label: "Verified by",
                value: .text(verification.by.rawValue), accessibilityHint: nil))
            rows.append(.init(
                id: .verificationDate(verification.id), label: "Verified at",
                value: .date(verification.verifiedAt), accessibilityHint: nil))
            rows.append(.init(
                id: .verificationBasis(verification.id), label: "Basis",
                value: .text(basisLabel(verification.basis.kind)), accessibilityHint: nil))
            for (index, evidence) in verification.basis.evidence.enumerated() {
                let value: MetadataValue
                switch evidence {
                case .source(let sourceID):
                    value = .link(label: sourceID.rawValue, target: .source(sourceID))
                case .external(let url):
                    value = .link(label: url.absoluteString, target: .url(url))
                }
                rows.append(.init(
                    id: .verificationEvidence(verification.id, index), label: "Evidence",
                    value: value, accessibilityHint: "Open verification evidence"))
            }
            if let note = verification.basis.note {
                rows.append(.init(
                    id: .verificationNote(verification.id), label: "Verification note",
                    value: .text(note), accessibilityHint: nil))
            }
        }
        return .init(id: .trustLifecycle, title: "Trust & lifecycle", rows: rows)
    }

    private static func trustLabel(_ tier: OKFTrustTier) -> String {
        switch tier {
        case .unverified: "Unverified"
        case .machineConfirmed: "Machine confirmed"
        case .humanReviewed: "Human reviewed"
        }
    }

    private static func basisLabel(_ basis: OKFVerificationBasisKind) -> String {
        switch basis {
        case .humanReview: "Human review"
        case .sourceChecked: "Source checked"
        case .externalRevalidation: "External revalidation"
        }
    }
}

enum PageMetadataProjection {
    static func make(input: PageMetadataInput) -> MetadataPanelModel {
        var summary = [
            MetadataRow(id: .title, label: "Title", value: .text(input.page.title), accessibilityHint: nil),
            MetadataRow(id: .created, label: "Created", value: .date(input.page.createdAt), accessibilityHint: nil),
            MetadataRow(id: .updated, label: "Updated", value: .date(input.page.updatedAt), accessibilityHint: nil),
            MetadataRow(id: .version, label: "Version", value: .integer(input.page.version), accessibilityHint: nil)
        ]
        if let author = input.page.createdBy {
            summary.append(.init(id: .author, label: "Author", value: .text(author), accessibilityHint: nil))
        }
        if let writer = input.page.lastEditedBy {
            summary.append(.init(id: .writer, label: "Last writer", value: .text(writer), accessibilityHint: nil))
        }
        if let origin = input.origin {
            summary.append(.init(id: .agent, label: "Agent", value: .text(origin.agentName.rawValue), accessibilityHint: nil))
        }

        let orderedSources = input.sources.sorted {
            let leftRole = roleRank($0.role)
            let rightRole = roleRank($1.role)
            if leftRole != rightRole { return leftRole < rightRole }
            let byName = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            if byName != .orderedSame { return byName == .orderedAscending }
            return $0.sourceID.rawValue < $1.sourceID.rawValue
        }
        let sourceRows = orderedSources.map { source in
            MetadataRow(
                id: .sourceReference(source.sourceID),
                label: source.role.rawValue.capitalized + " source",
                value: .link(label: source.displayName, target: .source(source.sourceID)),
                accessibilityHint: "Open source")
        }
        var technical: [MetadataRow] = [
            .init(id: .pageID, label: "Page ID", value: .identifier(input.page.id.rawValue), accessibilityHint: "Copy page identifier")
        ]
        if let hash = input.currentVersion?.blobHash {
            technical.append(.init(id: .hash, label: "Content hash", value: .identifier(hash), accessibilityHint: "Copy content hash"))
        }
        technical.append(.init(id: .compareVersions, label: "Versions", value: .action(label: "Compare versions", target: .comparePageVersions(input.page.id)), accessibilityHint: "Open page version comparison"))
        var sections = [MetadataSection(id: .summary, title: "Summary", rows: summary)]
        if !sourceRows.isEmpty { sections.append(.init(id: .provenance, title: "Sources", rows: sourceRows)) }
        sections.append(OKFMetadataPresentation.section(input.okfMetadata))
        sections.append(.init(id: .technical, title: "Technical", rows: technical))
        return .init(subject: .page(input.page.id), sections: sections, emptyState: .none)
    }

    private static func roleRank(_ role: PageVersionSourceRole) -> Int {
        switch role { case .primary: 0; case .supporting: 1; case .quoted: 2 }
    }
}

struct SourceMetadataInput: Sendable {
    let source: SourceSummary
    let markdown: SourceMarkdownVersion?
    let extraction: ExtractionProvenance?
    let alternativeCount: Int
    let okfMetadata: OKFConceptMetadata
}

enum SourceMetadataProjection {
    static func make(input: SourceMetadataInput) -> MetadataPanelModel {
        var extractionRows: [MetadataRow] = []
        if let provenance = input.extraction {
            extractionRows.append(.init(id: .extractionType, label: "Type", value: .text(provenance.origin.rawValue), accessibilityHint: nil))
            if let producer = producerName(provenance.producer) {
                extractionRows.append(.init(id: .producer, label: "Producer", value: .text(producer), accessibilityHint: nil))
            }
            if let provider = provenance.providerID { extractionRows.append(.init(id: .provider, label: "Provider", value: .text(provider.rawValue), accessibilityHint: nil)) }
            if let model = provenance.modelID { extractionRows.append(.init(id: .model, label: "Model", value: .text(model.rawValue), accessibilityHint: nil)) }
            if let toolVersion = provenance.toolVersion { extractionRows.append(.init(id: .backend, label: "Tool version", value: .text(toolVersion), accessibilityHint: nil)) }
            extractionRows.append(.init(id: .extractionDate, label: "Extracted", value: .date(provenance.createdAt), accessibilityHint: nil))
        }
        extractionRows.append(.init(id: .alternatives, label: "Alternatives", value: .integer(input.alternativeCount), accessibilityHint: nil))
        if input.alternativeCount >= 2 {
            extractionRows.append(.init(id: .compareExtractions, label: "Extractions", value: .action(label: "Compare extractions", target: .compareSourceExtractions(input.source.id)), accessibilityHint: "Compare extraction alternatives"))
        }
        var technical = [
            MetadataRow(id: .source, label: "Source ID", value: .identifier(input.source.id.rawValue), accessibilityHint: "Copy source identifier"),
            MetadataRow(id: .mimeType, label: "MIME type", value: .text(input.source.mimeType ?? "Unavailable"), accessibilityHint: nil),
            MetadataRow(id: .byteCount, label: "Size", value: .byteCount(Int64(input.source.byteSize)), accessibilityHint: nil)
        ]
        if let markdown = input.markdown {
            technical.append(.init(id: .extractionVersion, label: "Extraction version", value: .identifier(markdown.id.rawValue), accessibilityHint: "Copy extraction version identifier"))
            if let hash = markdown.blobHash { technical.append(.init(id: .hash, label: "Content hash", value: .identifier(hash), accessibilityHint: "Copy content hash")) }
        }
        if let sourceVersion = input.extraction?.sourceVersionID { technical.append(.init(id: .sourceVersion, label: "Source version", value: .identifier(sourceVersion.rawValue), accessibilityHint: "Copy source version identifier")) }
        return .init(subject: .source(input.source.id), sections: [
            .init(id: .summary, title: "Summary", rows: [
                .init(id: .title, label: "Name", value: .text(input.source.effectiveName), accessibilityHint: nil),
                .init(id: .created, label: "Created", value: .date(input.source.createdAt), accessibilityHint: nil),
                .init(id: .updated, label: "Updated", value: .date(input.source.updatedAt), accessibilityHint: nil)
            ]),
            .init(id: .extraction, title: "Extraction", rows: extractionRows),
            OKFMetadataPresentation.section(input.okfMetadata),
            .init(id: .technical, title: "Technical", rows: technical)
        ], emptyState: .none)
    }

    private static func producerName(_ producer: ExtractionProducer?) -> String? {
        guard let producer else { return nil }
        switch producer {
        case .backend(let backend): return backend.rawValue
        case .tool(let tool): return tool.rawValue
        case .legacy(let rawTechnique): return rawTechnique
        }
    }
}

struct ChatMetadataInput: Sendable {
    let chat: ChatSummary
    let usageSummary: ChatUsageSummary
    let live: ChatMetadataLiveSnapshot?

    init(chat: ChatSummary, usageSummary: ChatUsageSummary, live: ChatMetadataLiveSnapshot? = nil) {
        self.chat = chat
        self.usageSummary = usageSummary
        self.live = live
    }
}

/// The current daemon snapshot is an overlay, not another durable usage row.
/// Matching its turn id replaces the cached durable value so counters cannot be
/// summed twice while a persistence write is still in flight.
struct ChatMetadataLiveSnapshot: Equatable, Sendable {
    let turnID: ChatTurnID
    let state: ChatTurnState
    let providerID: ProviderID?
    let modelID: ModelID?
    let usage: SessionUsage?

    static func from(_ projection: ChatSyncProjection?) -> ChatMetadataLiveSnapshot? {
        guard let projection, let turn = projection.activeTurn else { return nil }
        return .init(
            turnID: turn.turnID,
            state: turn.state,
            providerID: projection.providerState.providerID,
            modelID: projection.providerState.modelID,
            usage: projection.usage)
    }
}

enum ChatMetadataProjection {
    static func make(input: ChatMetadataInput) -> MetadataPanelModel {
        let summary = [
            MetadataRow(id: .title, label: "Title", value: .text(input.chat.title), accessibilityHint: nil),
            MetadataRow(id: .created, label: "Created", value: .date(input.chat.createdAt), accessibilityHint: nil),
            MetadataRow(id: .updated, label: "Updated", value: .date(input.chat.updatedAt), accessibilityHint: nil),
            MetadataRow(id: .messageCount, label: "Messages", value: .integer(input.chat.messageCount), accessibilityHint: nil)
        ]
        var usageRows: [MetadataRow] = []
        if let usage = mergedUsage(persisted: input.usageSummary.latestTurn, live: input.live) {
            if let provider = usage.providerID { usageRows.append(.init(id: .provider, label: "Provider", value: .text(provider.rawValue), accessibilityHint: nil)) }
            if let model = usage.modelID { usageRows.append(.init(id: .model, label: "Model", value: .text(model.rawValue), accessibilityHint: nil)) }
            if let startedAt = usage.startedAt { usageRows.append(.init(id: .started, label: "Started", value: .date(startedAt), accessibilityHint: nil)) }
            if let finishedAt = usage.finishedAt { usageRows.append(.init(id: .finished, label: "Finished", value: .date(finishedAt), accessibilityHint: nil)) }
            if let startedAt = usage.startedAt, let finishedAt = usage.finishedAt, finishedAt >= startedAt {
                usageRows.append(.init(id: .duration, label: "Duration", value: .duration(.seconds(finishedAt.timeIntervalSince(startedAt))), accessibilityHint: nil))
            }
            usageRows.append(.init(id: .status, label: "Status", value: .text(usage.state.rawValue), accessibilityHint: nil))
            appendTokens(usage, to: &usageRows)
            if let cost = usage.cost, let currency = usage.currency {
                usageRows.append(.init(id: .cost, label: "Cost", value: .text("\(currency) \(cost)"), accessibilityHint: nil))
            }
        }
        var sections = [MetadataSection(id: .summary, title: "Summary", rows: summary)]
        if !usageRows.isEmpty { sections.append(.init(id: .usage, title: "Latest turn", rows: usageRows)) }
        let conversationRows = aggregateRows(input.usageSummary)
        if !conversationRows.isEmpty {
            sections.append(.init(id: .conversationTotals, title: "Persisted conversation totals", rows: conversationRows))
        }
        sections.append(.init(id: .technical, title: "Technical", rows: [.init(id: .source, label: "Chat ID", value: .identifier(input.chat.id.rawValue), accessibilityHint: "Copy chat identifier")]))
        return .init(subject: .chat(input.chat.id), sections: sections, emptyState: .none)
    }

    static func mergedUsage(
        persisted: ChatTurnUsage?,
        live: ChatMetadataLiveSnapshot?
    ) -> ChatTurnUsage? {
        guard let live else { return persisted }
        return mergedUsages(persisted: persisted.map { [$0] } ?? [], live: live)
            .last { $0.turnID == live.turnID }
    }

    /// Merge a daemon overlay by durable turn identity. A live snapshot replaces
    /// the matching durable turn, while a new active turn is appended so callers
    /// that retain history never lose an earlier turn or sum its counters.
    static func mergedUsages(
        persisted: [ChatTurnUsage],
        live: ChatMetadataLiveSnapshot?
    ) -> [ChatTurnUsage] {
        guard let live else { return persisted }
        let matchingPersisted = persisted.first { $0.turnID == live.turnID }
        let usage = live.usage
        let overlay = ChatTurnUsage(
            turnID: live.turnID,
            providerID: live.providerID ?? matchingPersisted?.providerID,
            modelID: live.modelID ?? matchingPersisted?.modelID,
            startedAt: matchingPersisted?.startedAt,
            finishedAt: matchingPersisted?.finishedAt,
            state: persistenceState(for: live.state),
            inputTokens: usage?.inputTokens ?? matchingPersisted?.inputTokens,
            outputTokens: usage?.outputTokens ?? matchingPersisted?.outputTokens,
            thoughtTokens: usage?.thoughtTokens ?? matchingPersisted?.thoughtTokens,
            cacheReadTokens: usage?.cachedReadTokens ?? matchingPersisted?.cacheReadTokens,
            cacheWriteTokens: usage?.cachedWriteTokens ?? matchingPersisted?.cacheWriteTokens,
            cost: usage?.cost.map { Decimal($0) } ?? matchingPersisted?.cost,
            currency: usage?.currency ?? matchingPersisted?.currency)
        if let index = persisted.firstIndex(where: { $0.turnID == live.turnID }) {
            var merged = persisted
            merged[index] = overlay
            return merged
        }
        return persisted + [overlay]
    }

    private static func persistenceState(for state: ChatTurnState) -> ChatTurnPersistenceState {
        switch state {
        case .queued: .queued
        case .submitting, .responding, .awaitingPermission, .cancelling: .providerSubmitted
        case .terminal(let outcome):
            switch outcome {
            case .completed: .completed
            case .cancelled: .cancelled
            case .failed, .interrupted: .failed
            }
        }
    }

    private static func appendTokens(_ usage: ChatTurnUsage, to rows: inout [MetadataRow]) {
        let fields: [(MetadataFieldID, String, Int?)] = [(.inputTokens, "Input", usage.inputTokens), (.outputTokens, "Output", usage.outputTokens), (.thoughtTokens, "Thought", usage.thoughtTokens), (.cacheReadTokens, "Cache read", usage.cacheReadTokens), (.cacheWriteTokens, "Cache write", usage.cacheWriteTokens)]
        for (id, label, count) in fields {
            if let count {
                rows.append(.init(id: id, label: label, value: .tokenCount(count), accessibilityHint: nil))
            }
        }
        if let input = usage.inputTokens, let output = usage.outputTokens {
            rows.append(.init(id: .totalTokens, label: "Total", value: .tokenCount(input + output), accessibilityHint: nil))
        }
    }

    private static func aggregateRows(_ summary: ChatUsageSummary) -> [MetadataRow] {
        let hasAggregateUsage = summary.inputTokens != 0
            || summary.outputTokens != 0
            || summary.thoughtTokens != 0
            || summary.cacheReadTokens != 0
            || summary.cacheWriteTokens != 0
            || summary.cost != nil
        guard hasAggregateUsage else { return [] }

        var rows: [MetadataRow] = [
            .init(id: .conversationInputTokens, label: "Input", value: .tokenCount(summary.inputTokens), accessibilityHint: "Persisted total across conversation turns"),
            .init(id: .conversationOutputTokens, label: "Output", value: .tokenCount(summary.outputTokens), accessibilityHint: "Persisted total across conversation turns"),
            .init(id: .conversationThoughtTokens, label: "Thought", value: .tokenCount(summary.thoughtTokens), accessibilityHint: "Persisted total across conversation turns"),
            .init(id: .conversationCacheReadTokens, label: "Cache read", value: .tokenCount(summary.cacheReadTokens), accessibilityHint: "Persisted total across conversation turns"),
            .init(id: .conversationCacheWriteTokens, label: "Cache write", value: .tokenCount(summary.cacheWriteTokens), accessibilityHint: "Persisted total across conversation turns")
        ]
        if let cost = summary.cost, let currency = summary.currency {
            rows.append(.init(id: .conversationCost, label: "Cost", value: .text("\(currency) \(cost)"), accessibilityHint: "Persisted total across conversation turns"))
        }
        return rows
    }
}
