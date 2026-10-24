import Foundation
import Markdown
import WikiFSTypes
import WikiFSLinks
import WikiFSMarkdown

/// The identity facts a scan resolves references against — extracted from
/// the store OUTSIDE the scan (pure scanning never touches the store). Name
/// resolution enumerates ALL matches per key: ambiguity is reported, never
/// silently resolved to a winner.
public struct LintResolutionFacts: Sendable, Equatable {
    public var knownPageTitles: Set<String> = []
    public var knownPageIDs: Set<String> = []
    public var knownSourceIDs: Set<String> = []
    /// Loose (normalization-insensitive) display-name key → every matching source ID.
    public var sourceIDsByLooseName: [String: [SourceID]] = [:]
    public var knownChatTitles: Set<String> = []
    public var knownChatIDs: Set<String> = []

    public init() {}

    /// `true` when the source target resolves to at least one known source
    /// by ULID, display name, or legacy projection.
    public func resolvesSource(_ target: WikiMarkdownTarget) -> Bool {
        if let canonical = target.canonicalID, knownSourceIDs.contains(canonical) {
            return true
        }
        return sourceMatches(for: target.literal).isEmpty == false
            || WikiLinkResolver.legacySourceProjectionID(from: target.literal) != nil
    }

    /// Every known source whose display name (loose key) matches the literal.
    public func sourceMatches(for literal: String) -> [SourceID] {
        sourceIDsByLooseName[WikiNameRules.looseMatchKey(literal)] ?? []
    }

    /// Extract the identity facts from one store read. Off-main callers go
    /// through `WikiReadService`; in-memory fixtures pass any `WikiStore`.
    public static func load(from store: WikiStore) throws -> LintResolutionFacts {
        var facts = LintResolutionFacts()
        for page in try store.listPages(sortBy: .titleAZ) {
            facts.knownPageTitles.insert(page.title)
            facts.knownPageIDs.insert(page.id.rawValue.uppercased())
        }
        for source in try store.listSources() {
            facts.knownSourceIDs.insert(source.id.rawValue.uppercased())
            if let displayName = source.displayName, !displayName.isEmpty {
                facts.sourceIDsByLooseName[WikiNameRules.looseMatchKey(displayName), default: []]
                    .append(source.id)
            }
        }
        for chat in try store.listAllChatsOrderedByID() {
            facts.knownChatTitles.insert(chat.title)
            facts.knownChatIDs.insert(chat.id.rawValue.uppercased())
        }
        return facts
    }
}

/// The mechanical lint pre-flight scanner (requirements §6). Pure: it parses
/// the snapshot's body with the reader's parser and reports findings — it
/// never writes, never reads the store, and never executes page content.
public enum LintPagePreflight {

    /// Scan one snapshot and produce the full report in REQ-23 section order.
    /// The optional facts inputs carry store-derived and package-derived
    /// checks (D09 citation fragments, D11 origin URLs, D27 history
    /// regression, D28 rich-fence validation); a `nil` fact leaves that
    /// check unevaluated and records an honest limit in its section — it
    /// never renders as a pass.
    public static func scan(
        snapshot: LintPageSnapshot,
        resolution: LintResolutionFacts,
        citations: LintCitationFacts? = nil,
        originURLs: LintOriginURLFacts? = nil,
        history: LintHistoryFacts? = nil,
        fenceValidation: LintFenceValidationFacts? = nil
    ) -> LintPreflightReport {
        let parsed = ParsedMarkdownDocument(parsing: snapshot.body)
        let protection = parsed.codeProtection
        let protectedUTF16 = WikiFootnoteMarkdown.utf16Ranges(of: protection, in: snapshot.body)
        let protectedUTF8 = protectedUTF16.compactMap { utf8Range($0, in: snapshot.body) }
        let maskedBody = byteMasked(snapshot.body, protectedUTF8: protectedUTF8)
        let fenceFacts = parsed.fenceFacts
        let footnotes = MarkdownFootnoteAnalysis.analyze(
            in: snapshot.body, protectedRanges: protectedUTF16)
        let wikiNodes = WikiLinkParser.syntaxNodes(
            in: snapshot.body, protectedRanges: protectedUTF16)

        // ---- Inventory (complete; never deduplicated by target) ----
        let inventory = buildInventory(
            parsed: parsed, fenceFacts: fenceFacts,
            footnotes: footnotes, wikiNodes: wikiNodes,
            protectedUTF16: protectedUTF16)

        // ---- Findings per section ----
        var sections: [LintPreflightReport.Section] = []
        var occurrenceCounters: [String: Int] = [:]

        // §3 fence boundaries: D25 whole-body wrap, D01 boundary candidates.
        sections.append(fenceSection(
            snapshot, fenceFacts, protection, &occurrenceCounters))

        // §4 markdown structure: D03 tables, D02/D04/D05 report-only.
        sections.append(markdownStructureSection(
            snapshot, parsed, protectedUTF8, &occurrenceCounters))

        // §5 wiki references: D06, D07, D08, D09, D10, D22.
        sections.append(wikiReferencesSection(
            snapshot, wikiNodes, footnotes, resolution, citations,
            &occurrenceCounters))

        // §6 raw URLs and rich fences: D11, D20, D28.
        sections.append(rawURLsSection(
            snapshot, parsed, inventory, maskedBody, fenceFacts,
            originURLs, fenceValidation, &occurrenceCounters))

        // §7 integrity and history: D14, D15, D17, D18, D23, D24, D26, D27.
        sections.append(integrityAndHistorySection(
            snapshot, parsed, wikiNodes, footnotes, maskedBody,
            protectedUTF8, history, &occurrenceCounters))

        // §1 identity, §2 scan failures, §8 metadata, §9 judgment audits.
        sections.append(LintPreflightReport.Section(
            section: .identity, status: .completed, findings: [], dialectLimits: []))
        sections.append(LintPreflightReport.Section(
            section: .scanFailures, status: .completed, findings: [], dialectLimits: []))
        sections.append(LintPreflightReport.Section(
            section: .metadata, status: .completed, findings: [], dialectLimits: [
                "D19: no page metadata contract exists in v1; metadata validation is off"
            ]))
        sections.append(LintPreflightReport.Section(
            section: .judgmentAudits, status: .notChecked(reason: "evidence-integrity audits are a separate operation (D3)"),
            findings: [], dialectLimits: []))

        return LintPreflightReport(
            pageID: snapshot.pageID,
            title: snapshot.title,
            inspectedHead: snapshot.headVersionID,
            bodyFingerprint: snapshot.bodyFingerprint,
            sections: sections,
            inventory: inventory,
            repairs: [])
    }

    // MARK: - Section assembly

    /// Number detector output into stable per-class occurrence IDs.
    static func numbered(
        _ detected: [DetectedFinding],
        _ counters: inout [String: Int]
    ) -> [LintFinding] {
        detected.map { finding in
            counters[finding.defectClass.rawValue, default: 0] += 1
            return LintFinding(
                occurrenceID: "\(finding.defectClass.rawValue)-\(counters[finding.defectClass.rawValue].map(String.init) ?? "?")",
                defectClass: finding.defectClass,
                authoredRange: finding.range,
                evidence: excerpt(of: finding.evidence),
                message: finding.message,
                severity: finding.severity,
                confidence: finding.confidence,
                candidateRepair: finding.candidateRepair)
        }
    }

    /// Assemble a section, applying the named per-section finding limit —
    /// an over-limit section reports truncation with the omitted count
    /// rather than silently dropping findings (REQ-25).
    static func makeSection(
        _ section: LintScanSection,
        detected: [DetectedFinding],
        limits: [String],
        _ counters: inout [String: Int]
    ) -> LintPreflightReport.Section {
        let findings = numbered(detected, &counters)
        if findings.count > LintPreflightReport.Limits.findingsPerSection {
            let kept = Array(findings.prefix(LintPreflightReport.Limits.findingsPerSection))
            return LintPreflightReport.Section(
                section: section,
                status: .truncated(
                    omittedCount: findings.count - kept.count,
                    reason: "per-section finding limit (\(LintPreflightReport.Limits.findingsPerSection)); the complete set stays in the staged inventory"),
                findings: kept,
                dialectLimits: limits)
        }
        return LintPreflightReport.Section(
            section: section,
            status: .completed,
            findings: findings,
            dialectLimits: limits)
    }

    // MARK: - Inventory

    static func buildInventory(
        parsed: ParsedMarkdownDocument,
        fenceFacts: [MarkdownFenceFact],
        footnotes: MarkdownFootnoteAnalysis,
        wikiNodes: [WikiMarkdownSyntaxNode],
        protectedUTF16: [NSRange]
    ) -> [LintInventoryItem] {
        var items: [LintInventoryItem] = []

        // Tables: AST table nodes, one item per table.
        var tableCount = 0
        collectTables(from: parsed.document, parsed: parsed) { range in
            tableCount += 1
            items.append(LintInventoryItem(
                occurrenceID: LintInventoryItem.occurrenceID(kind: .table, index: tableCount),
                kind: .table,
                authoredRange: range,
                evidence: excerpt(of: slice(parsed.sourceMarkdown, range ?? ParsedMarkdownDocument.zeroRange))))
        }

        // Source citations: every `[[source:…]]` occurrence (links + embeds).
        var citationCount = 0
        for node in wikiNodes {
            let target: WikiMarkdownTarget
            switch node {
            case .link(let link): target = link.target
            case .embed(let embed): target = embed.target
            }
            guard target.namespace == .source else { continue }
            citationCount += 1
            items.append(LintInventoryItem(
                occurrenceID: LintInventoryItem.occurrenceID(kind: .sourceCitation, index: citationCount),
                kind: .sourceCitation,
                authoredRange: node.sourceRange,
                evidence: excerpt(of: node.authoredLiteral)))
        }

        // Raw URLs outside protected code.
        var urlCount = 0
        for (range, url) in rawURLOccurrences(in: parsed.sourceMarkdown, protectedUTF16: protectedUTF16) {
            urlCount += 1
            items.append(LintInventoryItem(
                occurrenceID: LintInventoryItem.occurrenceID(kind: .rawURL, index: urlCount),
                kind: .rawURL,
                authoredRange: range,
                evidence: excerpt(of: url)))
        }

        for (index, reference) in footnotes.references.enumerated() {
            items.append(LintInventoryItem(
                occurrenceID: LintInventoryItem.occurrenceID(kind: .footnoteReference, index: index + 1),
                kind: .footnoteReference,
                authoredRange: reference.utf8Range,
                evidence: "[^\(reference.id)]"))
        }
        for (index, definition) in footnotes.definitions.enumerated() {
            items.append(LintInventoryItem(
                occurrenceID: LintInventoryItem.occurrenceID(kind: .footnoteDefinition, index: index + 1),
                kind: .footnoteDefinition,
                authoredRange: definition.utf8Range,
                evidence: excerpt(of: "[^\(definition.id)]: \(definition.markdown)")))
        }
        for (index, fence) in fenceFacts.enumerated() {
            items.append(LintInventoryItem(
                occurrenceID: LintInventoryItem.occurrenceID(kind: .fence, index: index + 1),
                kind: .fence,
                authoredRange: fence.openingRange,
                evidence: excerpt(of: String(repeating: fence.marker.rawValue, count: fence.length) + " " + fence.infoString)))
        }
        return items
    }

    static func collectTables(
        from markup: Markup,
        parsed: ParsedMarkdownDocument,
        _ visit: (MarkdownSourceRange?) -> Void
    ) {
        for child in markup.children {
            if child is Table {
                visit(parsed.utf8Range(of: child.range))
            }
            collectTables(from: child, parsed: parsed, visit)
        }
    }

    // MARK: - Sections

    private static func fenceSection(
        _ snapshot: LintPageSnapshot,
        _ fenceFacts: [MarkdownFenceFact],
        _ protection: MarkdownCodeProtection,
        _ counters: inout [String: Int]
    ) -> LintPreflightReport.Section {
        var detected: [DetectedFinding] = []
        let limits = [
            "Legal EOF-closed fences are valid — end-of-file closure alone is never a defect",
            "Fence facts derive from the reader's AST plus source slices; no heuristic fence scan",
            "Inner lines resembling delimiters are candidates: literal fence examples inside code blocks also match",
        ]

        // D25 — whole-body fence wrap: one fence opens at the first content
        // line and closes at the last; everything else is inside it.
        if let wrap = wholeBodyWrap(in: snapshot.body, fenceFacts: fenceFacts) {
            detected.append(DetectedFinding(
                .wholeBodyFenceWrap,
                wrap.openingRange,
                excerpt(of: slice(snapshot.body, wrap.openingRange)),
                "The whole body is wrapped in a fence, so links and tables render as literal text",
                .critical,
                .confirmed,
                candidateRepair: LintCandidateRepair(
                    change: .deletion,
                    reason: "unwrap the whole-body fence so the body renders as Markdown")))
            detected.append(DetectedFinding(
                .wholeBodyFenceWrap,
                wrap.closingRange,
                excerpt(of: slice(snapshot.body, wrap.closingRange)),
                "Closing delimiter of the whole-body fence wrap",
                .critical,
                .confirmed,
                candidateRepair: LintCandidateRepair(
                    change: .deletion,
                    reason: "unwrap the whole-body fence so the body renders as Markdown")))
        }

        // D01 — fence boundary damage: inner lines that resemble a closing
        // delimiter but cannot close the block.
        detected.append(contentsOf: fenceBoundaryCandidates(
            body: snapshot.body, fenceFacts: fenceFacts))

        return makeSection(.fenceBoundaries, detected: detected, limits: limits, &counters)
    }

    private static func markdownStructureSection(
        _ snapshot: LintPageSnapshot,
        _ parsed: ParsedMarkdownDocument,
        _ protectedUTF8: [MarkdownSourceRange],
        _ counters: inout [String: Int]
    ) -> LintPreflightReport.Section {
        var detected: [DetectedFinding] = []
        let limits = [
            "Tables are inventoried from AST table nodes; malformed shapes that failed to parse are reported, never reconstructed",
            "D02/D04/D05 are report-only in v1 (D4): style conventions never become confirmed defects",
        ]
        detected.append(contentsOf: tableCandidates(parsed: parsed))
        detected.append(contentsOf: inlineDelimiterCandidates(
            parsed: parsed, protectedUTF8: protectedUTF8))
        detected.append(contentsOf: indentationCandidates(
            parsed: parsed, fenceFacts: parsed.fenceFacts, protectedUTF8: protectedUTF8))
        detected.append(contentsOf: headingCandidates(parsed: parsed))
        return makeSection(.markdownStructure, detected: detected, limits: limits, &counters)
    }

    private static func wikiReferencesSection(
        _ snapshot: LintPageSnapshot,
        _ wikiNodes: [WikiMarkdownSyntaxNode],
        _ footnotes: MarkdownFootnoteAnalysis,
        _ resolution: LintResolutionFacts,
        _ citations: LintCitationFacts?,
        _ counters: inout [String: Int]
    ) -> LintPreflightReport.Section {
        var detected: [DetectedFinding] = []
        var limits = [
            "Wiki-link parsing reuses WikiLinkParser/WikiLinkResolver identity rules — no parallel grammar (REQ-41)",
            "Literal examples inside AST-protected code are never findings (REQ-42)",
            "Source-name resolution enumerates all matches; ambiguity is reported, never resolved to a winner",
        ]

        func finding(
            _ defectClass: LintDefectClass,
            range: MarkdownSourceRange?,
            evidence: String,
            message: String,
            severity: LintSeverity,
            confidence: LintConfidence,
            candidateRepair: LintCandidateRepair? = nil
        ) {
            detected.append(DetectedFinding(
                defectClass, range, evidence, message, severity, confidence,
                candidateRepair: candidateRepair))
        }

        // D06 — attempted wiki-link syntax: `[[` occurrences outside code
        // that never form a complete expression (unclosed, empty target, or
        // empty alias — forms the span scanner skips).
        for attempt in attemptedWikiExpressions(in: snapshot.body) {
            finding(
                .malformedWikiLink,
                range: attempt.range,
                evidence: attempt.text,
                message: attempt.message,
                severity: .major,
                confidence: .confirmed)
        }

        // D07 / D08 / D09 / D10 — reference identity, fragments, embed roles.
        for node in wikiNodes {
            let (target, isEmbed): (WikiMarkdownTarget, Bool)
            switch node {
            case .link(let link): (target, isEmbed) = (link.target, false)
            case .embed(let embed): (target, isEmbed) = (embed.target, true)
            }

            // D10 — only source links can be embeds.
            if isEmbed, target.namespace != .source {
                finding(
                    .unsupportedEmbed,
                    range: node.sourceRange,
                    evidence: node.authoredLiteral,
                    message: "Embeds are source-only; `![[…]]` with a \(target.namespace.rawValue) target is invalid",
                    severity: .major,
                    confidence: .confirmed)
            }

            switch target.namespace {
            case .page:
                let resolved: Bool
                if let canonical = target.canonicalID {
                    resolved = resolution.knownPageIDs.contains(canonical)
                } else {
                    resolved = resolution.knownPageTitles.contains(target.literal)
                }
                if !resolved {
                    finding(
                        .brokenTarget,
                        range: node.sourceRange,
                        evidence: node.authoredLiteral,
                        message: "Page target does not resolve to an existing page",
                        severity: .major,
                        confidence: .confirmed)
                }
            case .source:
                if let canonical = target.canonicalID {
                    if !resolution.knownSourceIDs.contains(canonical) {
                        finding(
                            .brokenTarget,
                            range: node.sourceRange,
                            evidence: node.authoredLiteral,
                            message: "Source citation points to no existing source",
                            severity: .major,
                            confidence: .confirmed)
                    }
                } else if !resolution.resolvesSource(target) {
                    finding(
                        .brokenTarget,
                        range: node.sourceRange,
                        evidence: node.authoredLiteral,
                        message: "Source citation resolves to no known source",
                        severity: .major,
                        confidence: .confirmed)
                } else {
                    // D08 — resolvable but noncanonical: candidate repair
                    // only when EXACTLY one source matches (REQ-40).
                    let matches = resolution.sourceMatches(for: target.literal)
                    let legacy = WikiLinkResolver.legacySourceProjectionID(from: target.literal)
                    if matches.count == 1 {
                        finding(
                            .noncanonicalSourceTarget,
                            range: node.sourceRange,
                            evidence: node.authoredLiteral,
                            message: "Source citation uses a display name; the canonical target is the SourceID",
                            severity: .minor,
                            confidence: .confirmed,
                            candidateRepair: canonicalSourceRepair(node: node, sourceID: matches[0]))
                    } else if matches.count > 1 {
                        finding(
                            .noncanonicalSourceTarget,
                            range: node.sourceRange,
                            evidence: node.authoredLiteral,
                            message: "Source display name matches \(matches.count) sources; ambiguous — resolve with source evidence",
                            severity: .minor,
                            confidence: .candidate)
                    } else if legacy != nil {
                        // Legacy projection-only form resolves; still noncanonical.
                        finding(
                            .noncanonicalSourceTarget,
                            range: node.sourceRange,
                            evidence: node.authoredLiteral,
                            message: "Source citation uses a legacy filename form, not the canonical SourceID",
                            severity: .minor,
                            confidence: .candidate)
                    }
                }

                // D09 — pin and fragment availability against the source
                // store (only for citations whose target itself resolves;
                // unresolvable targets are already D07 findings).
                if let canonical = target.canonicalID ?? resolution.sourceMatches(for: target.literal).first.map(\.rawValue),
                   target.fragment != nil || target.sourceVersionPin != nil {
                    appendCitationFragmentFindings(
                        target: target,
                        canonicalLiteral: canonical,
                        citations: citations,
                        finding: finding)
                }
            case .chat:
                let resolved: Bool
                if let canonical = target.canonicalID {
                    resolved = resolution.knownChatIDs.contains(canonical)
                } else {
                    resolved = resolution.knownChatTitles.contains(target.literal)
                }
                if !resolved {
                    finding(
                        .brokenTarget,
                        range: node.sourceRange,
                        evidence: node.authoredLiteral,
                        message: "Chat reference does not resolve to an existing chat",
                        severity: .major,
                        confidence: .confirmed)
                }
            }
        }

        // D22 — footnote integrity: duplicates, undefined references,
        // orphan definitions. Definitions that fail the source-citation
        // rules surface through the D07/D08 findings above (definitions
        // stay part of the parsed body).
        for id in footnotes.duplicateDefinitionIDs {
            let ranges = footnotes.definitions.filter { $0.id == id }.map(\.utf8Range)
            finding(
                .footnoteDamage,
                range: ranges.last,
                evidence: "[^\(id)]: … (defined \(ranges.count) times)",
                message: "Footnote ID is defined more than once",
                severity: .major,
                confidence: .confirmed)
        }
        for id in footnotes.undefinedReferenceIDs {
            let range = footnotes.references.first { $0.id == id }?.utf8Range
            finding(
                .footnoteDamage,
                range: range,
                evidence: "[^\(id)]",
                message: "Footnote reference has no definition",
                severity: .major,
                confidence: .confirmed)
        }
        for id in footnotes.orphanDefinitionIDs {
            let range = footnotes.definitions.first { $0.id == id }?.utf8Range
            finding(
                .footnoteDamage,
                range: range,
                evidence: "[^\(id)]: …",
                message: "Footnote definition is never referenced",
                severity: .minor,
                confidence: .confirmed)
        }

        if citations == nil {
            limits.append(
                "D09 pin/fragment availability was not evaluated: no citation facts were supplied to this scan")
        } else {
            limits.append(
                "D09 quote/anchor availability uses the patch integrity rule: whitespace-normalized, case-sensitive substring of the pinned (or active) version")
        }
        return makeSection(.wikiReferences, detected: detected, limits: limits, &counters)
    }

    /// D09 findings for one resolved source citation's pin and fragment.
    /// Facts-less scans record a section limit instead (see above); a source
    /// absent from the facts (not cited at load time) is skipped silently.
    private static func appendCitationFragmentFindings(
        target: WikiMarkdownTarget,
        canonicalLiteral: String,
        citations: LintCitationFacts?,
        finding: (LintDefectClass, MarkdownSourceRange?, String, String, LintSeverity, LintConfidence, LintCandidateRepair?) -> Void
    ) {
        guard let citations else { return }
        // The pin must name an existing extraction.
        if let pin = target.sourceVersionPin,
           citations.pinExists(sourceLiteral: canonicalLiteral, ordinal: pin) == false {
            let known = citations.sources[canonicalLiteral]?.availablePinOrdinals.count ?? 0
            finding(
                .citationFragmentDamage,
                nil,
                "@v\(pin)",
                "Version pin @v\(pin) names no extraction of this source (chain has \(known) extraction(s)).",
                .major,
                .confirmed,
                nil)
        }
        // The fragment text (quote or anchor) must be present in the pinned
        // (or active) version.
        guard var fragment = target.fragment else { return }
        let quoted = fragment.hasPrefix("\"") && fragment.hasSuffix("\"") && fragment.count >= 2
        if quoted {
            fragment = String(fragment.dropFirst().dropLast())
        }
        guard WikiText.normalized(fragment).isEmpty == false else { return }
        let authority = citations.normalizedText(sourceLiteral: canonicalLiteral, pin: target.sourceVersionPin)
        guard let authority else { return } // unknown version: the pin finding above covers it
        if LintCitationFacts.normalizedFragment(fragment).isEmpty
            || authority.contains(LintCitationFacts.normalizedFragment(fragment)) == false {
            finding(
                .citationFragmentDamage,
                nil,
                fragment,
                quoted
                    ? "The quoted text is not present in the pinned version's content (or the active head when unpinned)."
                    : "The anchor text is not present in the pinned version's content (or the active head when unpinned).",
                .major,
                .confirmed,
                nil)
        }
    }

    private static func rawURLsSection(
        _ snapshot: LintPageSnapshot,
        _ parsed: ParsedMarkdownDocument,
        _ inventory: [LintInventoryItem],
        _ maskedBody: String,
        _ fenceFacts: [MarkdownFenceFact],
        _ originURLs: LintOriginURLFacts?,
        _ fenceValidation: LintFenceValidationFacts?,
        _ counters: inout [String: Int]
    ) -> LintPreflightReport.Section {
        var detected: [DetectedFinding] = []
        var limits = [
            "Raw external URLs are inventoried; a URL is a candidate repair only on an exact origin-URL match with one verified resource (REQ-40)",
            "External-link style is otherwise strategy-owned (S)",
        ]

        // D11 — raw URLs whose exact origin identity matches exactly one
        // verified source become citation-repair candidates; ambiguity is
        // reported without a repair; zero matches stays inventory-only.
        for item in inventory where item.kind == .rawURL {
            guard let range = item.authoredRange else { continue }
            let url = slice(snapshot.body, range)
            guard let identity = URLFetchService.urlIdentity(url) else { continue }
            guard let originURLs else { continue }
            let matchCount = originURLs.matchCount(identity: identity)
            if matchCount == 1, let sourceID = originURLs.uniqueMatch(identity: identity) {
                detected.append(DetectedFinding(
                    .rawExternalURL,
                    range,
                    excerpt(of: url),
                    "This raw URL exactly matches the origin of one verified source — cite the source instead of the bare URL.",
                    .minor,
                    .confirmed,
                    candidateRepair: LintCandidateRepair(
                        change: .replacement(text: "[[source:\(sourceID.rawValue)]]"),
                        reason: "replace the raw URL with its verified source citation")))
            } else if matchCount > 1 {
                detected.append(DetectedFinding(
                    .rawExternalURL,
                    range,
                    excerpt(of: url),
                    "This raw URL matches the origin of \(matchCount) sources — ambiguous, so no citation repair is proposed; resolve with source evidence.",
                    .minor,
                    .candidate))
            }
        }
        if originURLs == nil {
            limits.append(
                "D11 origin-URL matching was not evaluated: no origin facts were supplied to this scan")
        }

        // D20 — reference labels and local media destinations.
        detected.append(contentsOf: referenceAndMediaCandidates(
            parsed: parsed, maskedBody: maskedBody))

        // D28 — rich-fence re-validation against package claims.
        for (index, fence) in fenceFacts.enumerated() {
            guard case .rich = MarkdownFenceInfo.parse(fence.infoString) else { continue }
            guard let fenceValidation, let outcome = fenceValidation.outcome(fenceIndex: index) else {
                continue
            }
            switch outcome {
            case .validated:
                continue
            case .invalid(let errors):
                detected.append(DetectedFinding(
                    .richFenceRevalidation,
                    fence.openingRange,
                    excerpt(of: fence.infoString),
                    "Rich fence failed its claiming package's validation: \(errors.isEmpty ? "invalid" : errors.joined(separator: "; ")). Report-only — the fence is never force-converted.",
                    .major,
                    .confirmed))
            case .unclaimed:
                detected.append(DetectedFinding(
                    .richFenceRevalidation,
                    fence.openingRange,
                    excerpt(of: fence.infoString),
                    "No installed renderer package claims this rich-fence format, so it renders as a plain code block. Report-only — never force-converted.",
                    .minor,
                    .candidate))
            case .suppressed:
                limits.append(
                    "D28 validation for one present rich-fence alias is suppressed (safe mode) — recorded, never rendered as a pass")
            case .unavailable(let reason):
                limits.append("D28 validation unavailable: \(reason)")
            }
        }
        if fenceValidation == nil {
            limits.append(
                "D28 rich-fence re-validation was not evaluated: no package-validation facts were supplied to this scan")
        }

        return makeSection(.rawURLsAndMedia, detected: detected, limits: limits, &counters)
    }

    /// §7 — placeholder, duplicate, conflict-marker, encoding and escaping
    /// damage, active content, truncation, meta-text leakage, and history
    /// regression. A failed parent-version read blocks the section (REQ-43).
    private static func integrityAndHistorySection(
        _ snapshot: LintPageSnapshot,
        _ parsed: ParsedMarkdownDocument,
        _ wikiNodes: [WikiMarkdownSyntaxNode],
        _ footnotes: MarkdownFootnoteAnalysis,
        _ maskedBody: String,
        _ protectedUTF8: [MarkdownSourceRange],
        _ history: LintHistoryFacts?,
        _ counters: inout [String: Int]
    ) -> LintPreflightReport.Section {
        var detected: [DetectedFinding] = []
        var limits = [
            "Placeholder markers (D14) are report-only in v1 (D4)",
            "Duplicate blocks need ≥\(DetectorConstants.duplicateBlockMinimumCharacters) non-whitespace characters and exact equality; intentional repetition stays possible",
            "Replacement characters and mojibake candidates are never guessed",
            "Active content (D18) is report-only: the lint never executes or sanitizes content",
            "History regression (D27) compares the inspected head with its ACTUAL parent version; the shrinkage threshold is 30% and loss alone never restores content",
        ]
        var blockedReason: String?

        detected.append(contentsOf: placeholderCandidates(
            maskedBody: maskedBody, source: snapshot.body))
        detected.append(contentsOf: mergeMarkerAndDuplicateCandidates(
            parsed: parsed, protectedUTF8: protectedUTF8))
        detected.append(contentsOf: encodingAndEscapingCandidates(
            source: snapshot.body, maskedBody: maskedBody, wikiNodes: wikiNodes))
        detected.append(contentsOf: activeContentCandidates(
            source: snapshot.body, maskedBody: maskedBody))
        detected.append(contentsOf: truncationCandidates(
            source: snapshot.body, maskedBody: maskedBody))
        detected.append(contentsOf: metaTextLeakageCandidates(
            source: snapshot.body, maskedBody: maskedBody))

        // D27 — history regression against the ACTUAL parent version.
        switch history?.availability {
        case .parentAvailable(_, let parentBody):
            detected.append(contentsOf: historyRegressionCandidates(
                parentBody: parentBody,
                headByteCount: snapshot.body.utf8.count,
                headTableTexts: headTableTexts(parsed: parsed),
                headCitationKeys: Set(wikiNodes.compactMap { node -> String? in
                    switch node {
                    case .link(let link) where link.target.namespace == .source:
                        return citationKey(for: link.target)
                    case .embed(let embed) where embed.target.namespace == .source:
                        return citationKey(for: embed.target)
                    default: return nil
                    }
                }),
                headHeadingTexts: headHeadingTexts(parsed: parsed),
                headFootnoteDefinitionIDs: Set(footnotes.definitions.map(\.id))))
        case .readFailed(let reason):
            blockedReason = "history regression (D27) could not run: \(reason)"
        case .firstVersion, nil:
            limits.append(
                history == nil
                    ? "D27 not evaluated: no parent-version facts were supplied to this scan"
                    : "D27 not applicable: the inspected head is the page's first version")
        }

        if let blockedReason {
            let findings = numbered(detected, &counters)
            return LintPreflightReport.Section(
                section: .integrityAndHistory,
                status: .blocked(reason: blockedReason),
                findings: findings,
                dialectLimits: limits)
        }
        return makeSection(
            .integrityAndHistory, detected: detected, limits: limits, &counters)
    }

    /// Normalized text of every table in the parsed document.
    private static func headTableTexts(parsed: ParsedMarkdownDocument) -> Set<String> {
        var texts: Set<String> = []
        collectTables(from: parsed.document, parsed: parsed) { range in
            guard let range else { return }
            texts.insert(LintCitationFacts.normalizedFragment(slice(parsed.sourceMarkdown, range)))
        }
        return texts
    }

    /// Normalized text of every heading in the parsed document.
    private static func headHeadingTexts(parsed: ParsedMarkdownDocument) -> Set<String> {
        var texts: Set<String> = []
        forEachNode(parsed.document, of: Heading.self) { heading in
            texts.insert(LintCitationFacts.normalizedFragment(flattenedText(heading)))
        }
        return texts
    }

    // MARK: - Detection helpers

    /// A whole-body fence wrap: exactly one fence whose opening sits on the
    /// first content line and whose closing sits on the last content line.
    static func wholeBodyWrap(
        in body: String,
        fenceFacts: [MarkdownFenceFact]
    ) -> (openingRange: MarkdownSourceRange, closingRange: MarkdownSourceRange)? {
        guard fenceFacts.count == 1 else { return nil }
        let fence = fenceFacts[0]
        guard let closing = fence.closingRange else { return nil }
        let lines = ParsedMarkdownDocument.authoredLines(of: body)
        let contentLines = lines.enumerated().filter { !$0.element.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let first = contentLines.first, let last = contentLines.last else { return nil }
        // The opening delimiter run must lie within the first content line;
        // the closing run within the last.
        func contains(_ outer: MarkdownSourceRange, _ offset: Int) -> Bool {
            outer.lowerBound <= offset && offset < outer.upperBound
        }
        guard contains(first.element.utf8Range, fence.openingRange.lowerBound),
              contains(last.element.utf8Range, closing.lowerBound) else { return nil }
        return (fence.openingRange, closing)
    }

    struct AttemptedExpression {
        let range: MarkdownSourceRange
        let text: String
        let message: String
    }

    /// `[[` occurrences outside protected code that never form a complete
    /// wiki link — unclosed openers and empty targets/aliases the span
    /// scanner deliberately skips.
    static func attemptedWikiExpressions(in body: String) -> [AttemptedExpression] {
        let ns = body as NSString
        let protected = WikiLinkSpan.protectedCodeRanges(in: body)
        var attempts: [AttemptedExpression] = []
        var cursor = 0
        while cursor + 2 <= ns.length {
            guard ns.character(at: cursor) == 0x5B /* [ */ ,
                  ns.character(at: cursor + 1) == 0x5B else {
                cursor += 1
                continue
            }
            // Find the first `]]` within a bounded window (2 KiB) — past it,
            // the `[[` is prose.
            let window = NSRange(location: cursor + 2, length: min(2048, ns.length - cursor - 2))
            let closing = ns.range(of: "]]", options: [], range: window)
            let expressionRange = closing.location == NSNotFound
                ? NSRange(location: cursor, length: min(64, ns.length - cursor))
                : NSRange(location: cursor, length: closing.location + closing.length - cursor)
            defer { cursor += 2 }
            guard !WikiLinkSpan.isProtected(expressionRange, by: protected) else { continue }
            let text = ns.substring(with: expressionRange)
            if closing.location == NSNotFound {
                attempts.append(AttemptedExpression(
                    range: utf8Range(expressionRange, in: body),
                    text: text,
                    message: "Unclosed `[[` — the wiki-link expression never closes"))
                continue
            }
            // Complete-span shape but rejected by the scanner: empty target
            // or empty alias.
            let inner = ns.substring(with: NSRange(location: cursor + 2, length: closing.location - cursor - 2))
            if WikiText.normalized(inner).isEmpty {
                attempts.append(AttemptedExpression(
                    range: utf8Range(expressionRange, in: body),
                    text: text,
                    message: "Empty wiki-link target"))
            } else if inner.contains("|"),
                      WikiLinkParser.syntaxNodes(in: text, protectedRanges: []).isEmpty {
                attempts.append(AttemptedExpression(
                    range: utf8Range(expressionRange, in: body),
                    text: text,
                    message: "Wiki-link expression has an empty alias or malformed target"))
            }
        }
        return attempts
    }

    private static func canonicalSourceRepair(
        node: WikiMarkdownSyntaxNode,
        sourceID: SourceID
    ) -> LintCandidateRepair? {
        // Rebuild the expression with the canonical ID, preserving the
        // fragment, version pin, alias, and embed role byte-for-byte.
        let (target, isEmbed): (WikiMarkdownTarget, Bool)
        switch node {
        case .link(let link): (target, isEmbed) = (link.target, false)
        case .embed(let embed): (target, isEmbed) = (embed.target, true)
        }
        var rebuilt = "source:\(sourceID.rawValue)"
        if let pin = target.sourceVersionPin { rebuilt += "@v\(pin)" }
        if let fragment = target.fragment {
            // `splitFragment` keeps the authored quotes — re-emit them
            // verbatim instead of wrapping again.
            let quoted = fragment.hasPrefix("\"") && fragment.hasSuffix("\"") && fragment.count >= 2
            rebuilt += quoted ? "#\(fragment)" : "#\"\(fragment)\""
        }
        let alias: String?
        switch node {
        case .link(let link): alias = link.alias
        case .embed(let embed): alias = embed.alias
        }
        if let alias { rebuilt += "|\(alias)" }
        let replacement = (isEmbed ? "![[" : "[[") + rebuilt + "]]"
        return LintCandidateRepair(
            change: .replacement(text: replacement),
            reason: "canonicalize the source citation target to its SourceID")
    }

    static func rawURLOccurrences(
        in source: String,
        protectedUTF16: [NSRange]
    ) -> [(MarkdownSourceRange, String)] {
        let pattern = #"https?://[^\s>)\]]+"#
        // The pattern is a compile-time constant — failure is a programmer error.
        let regex = try! NSRegularExpression(pattern: pattern) // swiftlint:disable:this force_try
        let ns = source as NSString
        var occurrences: [(MarkdownSourceRange, String)] = []
        for match in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            guard !WikiLinkSpan.isProtected(match.range, by: protectedUTF16) else { continue }
            occurrences.append((utf8Range(match.range, in: source), ns.substring(with: match.range)))
        }
        return occurrences
    }

    static func excerpt(of text: String, limit: Int = LintPreflightReport.Limits.evidenceCharacters) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }

    static func slice(_ source: String, _ range: MarkdownSourceRange) -> String {
        let utf8 = source.utf8
        guard let lower = utf8.index(utf8.startIndex, offsetBy: range.lowerBound, limitedBy: utf8.endIndex),
              let upper = utf8.index(utf8.startIndex, offsetBy: range.upperBound, limitedBy: utf8.endIndex) else {
            return ""
        }
        return String(decoding: utf8[lower..<upper], as: UTF8.self)
    }

    static func utf8Range(_ utf16Range: NSRange, in source: String) -> MarkdownSourceRange {
        guard let stringRange = Range(utf16Range, in: source),
              let lower = stringRange.lowerBound.samePosition(in: source.utf8),
              let upper = stringRange.upperBound.samePosition(in: source.utf8) else {
            return ParsedMarkdownDocument.zeroRange
        }
        let lowerOffset = source.utf8.distance(from: source.utf8.startIndex, to: lower)
        let upperOffset = source.utf8.distance(from: source.utf8.startIndex, to: upper)
        do {
            return try MarkdownSourceRange(lowerBound: lowerOffset, upperBound: upperOffset)
        } catch {
            return ParsedMarkdownDocument.zeroRange
        }
    }
}
