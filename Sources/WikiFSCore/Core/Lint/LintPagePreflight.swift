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
    public static func scan(
        snapshot: LintPageSnapshot,
        resolution: LintResolutionFacts
    ) -> LintPreflightReport {
        let parsed = ParsedMarkdownDocument(parsing: snapshot.body)
        let protection = parsed.codeProtection
        let protectedUTF16 = WikiFootnoteMarkdown.utf16Ranges(of: protection, in: snapshot.body)
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

        // §3 fence boundaries: D25 whole-body wrap, D01 boundary facts.
        sections.append(fenceSection(snapshot, fenceFacts, protection, &occurrenceCounters))

        // §4 markdown structure: table candidates from the AST (D03); the
        // report-only list/heading/delimiter classes are Phase 4.
        sections.append(markdownStructureSection(snapshot, parsed, &occurrenceCounters))

        // §5 wiki references: D06, D07, D08, D10, D22.
        sections.append(wikiReferencesSection(
            snapshot, wikiNodes, footnotes, resolution, &occurrenceCounters))

        // §6 raw URLs and rich fences: D11 inventory + exact-match facts are
        // store-derived (Phase 4 completes candidate repairs).
        sections.append(rawURLsSection(inventory))

        // §1 identity, §2 scan failures, §8 metadata, §9 judgment audits.
        sections.append(LintPreflightReport.Section(
            section: .identity, status: .completed, findings: [], dialectLimits: []))
        sections.append(LintPreflightReport.Section(
            section: .scanFailures, status: .completed, findings: [], dialectLimits: []))
        sections.append(LintPreflightReport.Section(
            section: .integrityAndHistory, status: .notChecked(
                reason: "integrity and history-regression detectors land with detector phase 4"),
            findings: [], dialectLimits: []))
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

    private static func collectTables(
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
        var findings: [LintFinding] = []
        let limits = [
            "Legal EOF-closed fences are valid — end-of-file closure alone is never a defect",
            "Fence facts derive from the reader's AST plus source slices; no heuristic fence scan",
        ]

        // D25 — whole-body fence wrap: one fence opens at the first content
        // line and closes at the last; everything else is inside it.
        if let wrap = wholeBodyWrap(in: snapshot.body, fenceFacts: fenceFacts) {
            counters["D25", default: 0] += 1
            let occurrence = "D25-\(counters["D25"].map(String.init) ?? "?")"
            // Separate opening and closing deletion candidates (plan §4.1).
            findings.append(LintFinding(
                occurrenceID: occurrence + "-opening",
                defectClass: .wholeBodyFenceWrap,
                authoredRange: wrap.openingRange,
                evidence: excerpt(of: slice(snapshot.body, wrap.openingRange)),
                message: "The whole body is wrapped in a fence, so links and tables render as literal text",
                severity: .critical,
                confidence: .confirmed,
                candidateRepair: LintCandidateRepair(
                    change: .deletion,
                    reason: "unwrap the whole-body fence so the body renders as Markdown")))
            findings.append(LintFinding(
                occurrenceID: occurrence + "-closing",
                defectClass: .wholeBodyFenceWrap,
                authoredRange: wrap.closingRange,
                evidence: excerpt(of: slice(snapshot.body, wrap.closingRange)),
                message: "Closing delimiter of the whole-body fence wrap",
                severity: .critical,
                confidence: .confirmed,
                candidateRepair: LintCandidateRepair(
                    change: .deletion,
                    reason: "unwrap the whole-body fence so the body renders as Markdown")))
        }

        // D01 — fence boundary damage candidates. A fence that closes AT
        // end-of-file is legal (limit above). A fence inside a container
        // whose observed closing fence sits OUTSIDE the block's own AST
        // range would indicate boundary damage — facts only; judgment
        // confirms. v1 reports nothing without such a mismatch.
        return LintPreflightReport.Section(
            section: .fenceBoundaries,
            status: .completed,
            findings: findings,
            dialectLimits: limits)
    }

    private static func markdownStructureSection(
        _ snapshot: LintPageSnapshot,
        _ parsed: ParsedMarkdownDocument,
        _ counters: inout [String: Int]
    ) -> LintPreflightReport.Section {
        // v1: D03 candidates come from malformed tables that parse as
        // paragraphs (Phase 4 scanner). Report-only classes (D02/D04/D05)
        // are likewise Phase 4. The section exists so the report renders its
        // `none detected` state and its limits.
        return LintPreflightReport.Section(
            section: .markdownStructure,
            status: .completed,
            findings: [],
            dialectLimits: [
                "Tables are inventoried from AST table nodes; malformed tables that parse as paragraphs are Phase 4",
                "D02/D04/D05 are report-only in v1 (D4)",
            ])
    }

    private static func wikiReferencesSection(
        _ snapshot: LintPageSnapshot,
        _ wikiNodes: [WikiMarkdownSyntaxNode],
        _ footnotes: MarkdownFootnoteAnalysis,
        _ resolution: LintResolutionFacts,
        _ counters: inout [String: Int]
    ) -> LintPreflightReport.Section {
        var findings: [LintFinding] = []

        func finding(
            _ defectClass: LintDefectClass,
            range: MarkdownSourceRange?,
            evidence: String,
            message: String,
            severity: LintSeverity,
            confidence: LintConfidence,
            candidateRepair: LintCandidateRepair? = nil
        ) {
            counters[defectClass.rawValue, default: 0] += 1
            findings.append(LintFinding(
                occurrenceID: "\(defectClass.rawValue)-\(counters[defectClass.rawValue].map(String.init) ?? "?")",
                defectClass: defectClass,
                authoredRange: range,
                evidence: excerpt(of: evidence),
                message: message,
                severity: severity,
                confidence: confidence,
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

        // D07 / D08 / D10 — reference identity and embed roles.
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

        return LintPreflightReport.Section(
            section: .wikiReferences,
            status: .completed,
            findings: findings,
            dialectLimits: [
                "Wiki-link parsing reuses WikiLinkParser/WikiLinkResolver identity rules — no parallel grammar (REQ-41)",
                "Literal examples inside AST-protected code are never findings (REQ-42)",
                "Source-name resolution enumerates all matches; ambiguity is reported, never resolved to a winner",
            ])
    }

    private static func rawURLsSection(
        _ inventory: [LintInventoryItem]
    ) -> LintPreflightReport.Section {
        // v1: raw URL occurrences are inventoried; exact origin-URL matches
        // (D11 candidate repairs) need the source store's origin URLs —
        // Phase 4 wires the verified-equivalent check.
        return LintPreflightReport.Section(
            section: .rawURLsAndMedia,
            status: .completed,
            findings: [],
            dialectLimits: [
                "Raw external URLs are inventoried; a URL is a candidate repair only on an exact origin-URL match with one verified resource (REQ-40)",
                "External-link style is otherwise strategy-owned (S)",
            ])
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
