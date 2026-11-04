import Foundation
import WikiFSLinks
import WikiFSMarkdown
import WikiFSTypes

// MARK: - Resolution facts

/// The store-derived facts the built-in wiki-link check resolves against.
/// Captured once per run with the snapshot; never re-read mid-run.
///
/// Availability is explicit per namespace: `…Available == false` means the
/// lookup itself failed, which the analyzer reports separately from a
/// genuinely missing target.
public struct LintResolutionFacts: Sendable, Equatable {
    public var knownPageTitles: Set<String>
    public var knownPageIDs: Set<String>
    public var knownSourceIDs: Set<String>
    public var sourceEffectiveNames: [String]
    public var knownChatTitles: Set<String>
    public var knownChatIDs: Set<String>
    public var pagesAvailable: Bool
    public var sourcesAvailable: Bool
    public var chatsAvailable: Bool

    public init(
        knownPageTitles: Set<String> = [],
        knownPageIDs: Set<String> = [],
        knownSourceIDs: Set<String> = [],
        sourceEffectiveNames: [String] = [],
        knownChatTitles: Set<String> = [],
        knownChatIDs: Set<String> = [],
        pagesAvailable: Bool = true,
        sourcesAvailable: Bool = true,
        chatsAvailable: Bool = true
    ) {
        self.knownPageTitles = knownPageTitles
        self.knownPageIDs = knownPageIDs
        self.knownSourceIDs = knownSourceIDs
        self.sourceEffectiveNames = sourceEffectiveNames
        self.knownChatTitles = knownChatTitles
        self.knownChatIDs = knownChatIDs
        self.pagesAvailable = pagesAvailable
        self.sourcesAvailable = sourcesAvailable
        self.chatsAvailable = chatsAvailable
    }

    public static let empty = LintResolutionFacts()
}

// MARK: - Coherent capture

/// The raw store state one lint run captures in a single read transaction:
/// page identity + body + head version + the resolution namespaces. The
/// session turns this into a `LintPageSnapshot` (adding the strategy
/// context) and into the analyzer's `LintResolutionFacts`.
public struct LintCapture: Sendable, Equatable {
    public let pageID: PageID
    public let title: String
    /// The committed body markdown (raw stored bytes).
    public let body: String
    public let headVersionID: PageVersionID
    public let facts: LintResolutionFacts
    /// Version-aware citation evidence: occurrences, bounded source-version
    /// records, the source-name index, and typed budget notices.
    public let citations: LintCitationEvidence
    /// The captured parent of the head version (history facts), when the
    /// page has a head to compare against.
    public let parent: LintCapturedParentVersion?

    public init(
        pageID: PageID, title: String, body: String,
        headVersionID: PageVersionID, facts: LintResolutionFacts,
        citations: LintCitationEvidence = .empty,
        parent: LintCapturedParentVersion? = nil
    ) {
        self.pageID = pageID
        self.title = title
        self.body = body
        self.headVersionID = headVersionID
        self.facts = facts
        self.citations = citations
        self.parent = parent
    }
}

// MARK: - Analyzer

/// The read-only detection pipeline. Produces findings with validated passage
/// ranges; never writes. This is the extraction of the legacy
/// `WikiStoreModel.preflightLint` detection WITHOUT its automatic save.
public enum LintAnalyzer {

    /// The built-in check implementations a configured step can invoke.
    public enum BuiltinCheck: String, CaseIterable, Sendable {
        case wikiLinks = "wiki-links"
        case markdownCosmetics = "markdown-cosmetics"
        case truncatedOutput = "truncated-output"
        case citations = "wiki-citations"
        case footnotes = "footnotes"
        case tableStructure = "table-structure"
        case history = "history"

        public static func named(_ raw: String) -> BuiltinCheck? {
            BuiltinCheck(rawValue: raw)
        }
    }

    /// Recipe resolution: maps a built-in producer kind to the configured
    /// recipe id that implements it (nil = no recipe configured → the
    /// finding is report-only). Supplied by the run plan from the loaded
    /// configuration.
    public struct RecipeLookup: Sendable {
        public var resolve: @Sendable (LintBuiltinProducer) -> LintRecipeID?
        public init(resolve: @escaping @Sendable (LintBuiltinProducer) -> LintRecipeID?) {
            self.resolve = resolve
        }

        public static let none = RecipeLookup { _ in nil }
    }

    // MARK: Entry point

    /// Run one built-in check against the snapshot. Throws when `builtin`
    /// names no known check (a configuration error surfaced before launch —
    /// reaching here with an unknown name is a caller bug).
    public static func run(
        _ builtin: BuiltinCheck,
        stepID: LintStepID,
        snapshot: LintPageSnapshot,
        facts: LintResolutionFacts,
        recipes: RecipeLookup
    ) -> [LintFinding] {
        switch builtin {
        case .wikiLinks:
            return wikiLinkFindings(
                stepID: stepID, body: snapshot.body, facts: facts, recipes: recipes)
        case .markdownCosmetics:
            return markdownCosmeticFindings(
                stepID: stepID, body: snapshot.body, recipes: recipes)
        case .truncatedOutput:
            return truncationCandidates(stepID: stepID, body: snapshot.body)
        case .citations:
            return LintCitationCheck.findings(
                stepID: stepID, snapshot: snapshot, recipes: recipes)
        case .footnotes:
            return LintFootnoteCheck.findings(
                stepID: stepID, body: snapshot.body, recipes: recipes)
        case .tableStructure:
            return LintTableCheck.findings(stepID: stepID, body: snapshot.body)
        case .history:
            return LintHistoryCheck.findings(stepID: stepID, snapshot: snapshot)
        }
    }

    // MARK: - Truncated-output candidates
    /// Leading-fragment and trailing-truncation candidates (report-only):
    /// the mirror of a truncated document's telltale ends. The FIRST
    /// non-blank line closing more brackets than it opens means the page may
    /// begin mid-construct — content before it appears lost (a real case:
    /// a page whose stored body starts `terface][^ref]` with the title
    /// heading and lead sentence gone). The LAST non-blank line opening an
    /// unclosed inline-code run or bracket means the page may end
    /// mid-construct. Candidates only — never a truth verdict about what
    /// the author intended; no repair is offered.
    public static func truncationCandidates(
        stepID: LintStepID, body: String
    ) -> [LintFinding] {
        let ns = body as NSString
        let codeRanges = WikiLinkSpan.protectedCodeRanges(in: body)
        let nonBlankLines = enumeratedNonBlankLines(body: body, codeRanges: codeRanges)
        guard let first = nonBlankLines.first, let last = nonBlankLines.last else {
            return []
        }

        var findings: [LintFinding] = []

        // Leading fragment: the first line CLOSES more brackets than it opens.
        let firstDelta = bracketDelta(first.text)
        if firstDelta < 0 {
            if let finding = makeTruncationFinding(
                stepID: stepID, id: "leading-fragment", line: first, ns: ns, body: body,
                message: "The page may open mid-construct — the first line closes "
                    + "\(-firstDelta) bracket(s) it never opened, so content before "
                    + "it appears lost.") {
                findings.append(finding)
            }
        }

        // Trailing truncation: unclosed inline-code run (odd backtick count).
        let backticks = last.text.filter { $0 == "`" }.count
        if backticks % 2 == 1 {
            if let finding = makeTruncationFinding(
                stepID: stepID, id: "trailing-code", line: last, ns: ns, body: body,
                message: "The final line opens an inline-code run that never closes — "
                    + "the page may end mid-construct.") {
                findings.append(finding)
            }
        }

        // Trailing truncation: brackets opened on the final line that never
        // close (code spans masked so backtick content does not confuse the
        // balance).
        let trailingDelta = bracketDelta(last.text)
        if trailingDelta > 0 {
            if let finding = makeTruncationFinding(
                stepID: stepID, id: "trailing-bracket", line: last, ns: ns, body: body,
                message: "The final line opens \(trailingDelta) bracket(s) that never "
                    + "close — the page may end mid-construct.") {
                findings.append(finding)
            }
        }
        return findings
    }

    /// Non-blank, non-code lines as (index, text, nsRange) triples.
    private static func enumeratedNonBlankLines(
        body: String, codeRanges: [NSRange]
    ) -> [(index: Int, text: String, nsRange: NSRange)] {
        var result: [(Int, String, NSRange)] = []
        var cursor = 0
        for (index, line) in body.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineText = String(line)
            let range = NSRange(location: cursor, length: lineText.utf16.count)
            cursor += lineText.utf16.count + 1  // + the newline
            if lineText.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if WikiLinkSpan.isProtected(range, by: codeRanges) { continue }
            result.append((index, lineText, range))
        }
        return result
    }

    /// Bracket balance of one line: opens minus closes, with inline code
    /// spans and backslash escapes masked so their contents don't count.
    private static func bracketDelta(_ line: String) -> Int {
        var delta = 0
        var inCode = false
        var previous: Character?
        for character in line {
            if character == "`" {
                inCode.toggle()
                previous = character
                continue
            }
            guard !inCode else { continue }
            switch character {
            case "(", "[", "{":
                if previous != "\\" { delta += 1 }
            case ")", "]", "}":
                if previous != "\\" { delta -= 1 }
            default:
                break
            }
            previous = character
        }
        return delta
    }

    private static func makeTruncationFinding(
        stepID: LintStepID, id: String, line: (index: Int, text: String, nsRange: NSRange),
        ns: NSString, body: String, message: String
    ) -> LintFinding? {
        guard let range = validatedRange(line.nsRange, in: body, ns: ns) else { return nil }
        return LintFinding(
            id: LintFindingID(rawValue: "trunc-\(id)-\(line.index + 1)"),
            stepID: stepID,
            ruleID: LintRuleID(rawValue: "truncated-output"),
            severity: .warning,
            message: message,
            evidence: line.text.trimmingCharacters(in: .whitespaces).prefix(120).description,
            scope: .passage([range]),
            repairOptions: [])
    }

    // MARK: - Wiki-link check

    /// Malformed brackets and unresolvable page/source/chat links, one
    /// finding per occurrence. Mirrors the legacy preflight detection loop:
    /// code spans/fences are protected; canonical ULID targets resolve by id;
    /// name targets resolve through `WikiLinkResolver`.
    public static func wikiLinkFindings(
        stepID: LintStepID,
        body: String,
        facts: LintResolutionFacts,
        recipes: RecipeLookup
    ) -> [LintFinding] {
        let ns = body as NSString
        let codeRanges = WikiLinkSpan.protectedCodeRanges(in: body)
        let matches = WikiLinkSpan.matches(in: body)
        let knownTitles = facts.knownPageTitles
        let knownPageIDs = facts.knownPageIDs

        var findings: [LintFinding] = []
        var sequence = 0
        func nextID(_ prefix: String) -> LintFindingID {
            sequence += 1
            return LintFindingID(rawValue: "\(prefix)-\(sequence)")
        }

        /// Validate + construct a passage range from an NSString range. An
        /// unlocatable range is an invalid result: the finding is dropped,
        /// with the drop visible in Console.app.
        func passageRange(_ nsRange: NSRange) -> LintSourceRange? {
            Self.validatedRange(nsRange, in: body, ns: ns)
        }

        for match in matches {
            let fullRange = match.range
            // `[[Like This]]` inside backticks/fences is example text, not a link.
            guard !WikiLinkSpan.isProtected(fullRange, by: codeRanges) else { continue }

            let rawTarget = ns.substring(with: match.range(at: 1))
            let aliasRange = match.range(at: 2)
            let rawAlias = aliasRange.location != NSNotFound ? ns.substring(with: aliasRange) : nil

            // 1. Bracket repair: the fixer normalizes escaped-bracket damage.
            let fix = WikiLinkFixer.fix(target: rawTarget, alias: rawAlias)
            let spanText = ns.substring(with: fullRange)

            // 2. Resolution classification (shared by both finding kinds).
            let collapsed = WikiText.normalized(fix.target)
            let isBracketDamaged = fix.wasModified
            var classification = LinkClassification.resolved
            if !isBracketDamaged, !collapsed.isEmpty {
                classification = classify(
                    fixedTarget: fix.target, fixedAlias: fix.alias,
                    knownTitles: knownTitles, knownPageIDs: knownPageIDs,
                    facts: facts)
            }

            guard isBracketDamaged || classification != .resolved else { continue }

            guard let span = passageRange(fullRange) else { continue }

            if isBracketDamaged {
                // Exact bracket correction: replace the whole span with the
                // fixed form.
                let aliasPart = fix.alias.map { "|\($0)" } ?? ""
                let fixedSpan = "[[\(fix.target)\(aliasPart)]]"
                let recipe = recipes.resolve(.bracketCorrection)
                let fixEdit = Self.individualFix(
                    replacing: span, with: fixedSpan, in: body)
                findings.append(LintFinding(
                    id: nextID("bracket"),
                    stepID: stepID,
                    ruleID: LintRuleID(rawValue: "wiki-link-brackets"),
                    severity: .warning,
                    message: "Malformed wiki-link bracket syntax (escaped bracket).",
                    evidence: spanText,
                    scope: .passage([span]),
                    repairOptions: recipe.map {
                        [LintRepairOption(
                            id: LintOptionID(rawValue: "fix-\($0.rawValue)"),
                            recipeID: $0, label: "Fix bracket syntax")]
                    } ?? [],
                    builtinFix: fixEdit))
            }

            switch classification {
            case .resolved:
                continue
            case .lookupUnavailable(let namespace):
                // The lookup itself failed — report, never claim broken.
                findings.append(LintFinding(
                    id: nextID("lookup"),
                    stepID: stepID,
                    ruleID: LintRuleID(rawValue: "wiki-link-\(namespace)-lookup-unavailable"),
                    severity: .info,
                    message: "Could not verify \(namespace) link '\(spanText)' — the \(namespace) list was unavailable.",
                    evidence: nil,
                    scope: .passage([span]),
                    repairOptions: []))
            case .broken(let namespace, let label):
                // Explicit removal keeps the readable text.
                let display = label.isEmpty ? "" : (WikiText.normalized(fix.alias ?? "") )
                let readable = display.isEmpty ? strippedTarget(fix.target) : display
                let recipe = recipes.resolve(.removeBrokenLink)
                let fixEdit = Self.individualFix(
                    replacing: span, with: readable, in: body)
                findings.append(LintFinding(
                    id: nextID("broken"),
                    stepID: stepID,
                    ruleID: LintRuleID(rawValue: "broken-\(namespace)-link"),
                    severity: .warning,
                    message: "Broken \(namespace) link: '\(label)' does not resolve to an existing \(namespace).",
                    evidence: spanText,
                    scope: .passage([span]),
                    repairOptions: recipe.map {
                        [LintRepairOption(
                            id: LintOptionID(rawValue: "remove-\($0.rawValue)"),
                            recipeID: $0, label: "Remove broken link (keep text)")]
                    } ?? [],
                    builtinFix: fixEdit))
            }
        }
        return findings
    }

    private enum LinkClassification: Equatable {
        case resolved
        case lookupUnavailable(namespace: String)
        case broken(namespace: String, label: String)
    }

    /// The resolution rules from the legacy preflight: canonical ULID targets
    /// resolve by id; name targets resolve through `WikiLinkResolver` with the
    /// same candidate readings (handles `#` in titles, version pins).
    private static func classify(
        fixedTarget: String,
        fixedAlias: String?,
        knownTitles: Set<String>,
        knownPageIDs: Set<String>,
        facts: LintResolutionFacts
    ) -> LinkClassification {
        let collapsed = WikiText.normalized(fixedTarget)
        guard !collapsed.isEmpty else { return .resolved }
        let (base, fragment) = WikiLinkParser.splitFragment(collapsed)
        guard !base.isEmpty else { return .resolved }
        let (bareBase, _) = WikiLinkParser.splitVersionPin(base)
        let (kind, bareTarget) = WikiLinkParser.classify(bareBase)
        guard !bareTarget.isEmpty, !WikiLinkParser.isEmptyPrefix(bareBase) else { return .resolved }

        let raw = fragment.map { "\(bareTarget)#\($0)" } ?? bareTarget

        switch kind {
        case .page:
            let known: (String) -> Bool = { knownTitles.contains($0) }
            if WikiLinkParser.isCanonicalULID(bareTarget) {
                if knownPageIDs.contains(bareTarget.uppercased()) { return .resolved }
            } else if WikiLinkResolver.resolvedSplit(of: raw, isKnown: known) != nil {
                return .resolved
            }
            return .broken(namespace: "page", label: displayLabel(fixedAlias, bareTarget))
        case .source:
            guard facts.sourcesAvailable else {
                return .lookupUnavailable(namespace: "source")
            }
            let sourceIDs = facts.knownSourceIDs
            let names = facts.sourceEffectiveNames
            let known: (String) -> Bool = { name in
                if let sourceID = WikiLinkResolver.legacySourceProjectionID(from: name),
                   sourceIDs.contains(sourceID.rawValue.uppercased()) {
                    return true
                }
                return names.contains(name)
                    || names.contains {
                        WikiNameRules.looseMatchKey($0) == WikiNameRules.looseMatchKey(name)
                    }
            }
            if WikiLinkParser.isCanonicalULID(bareTarget) {
                if sourceIDs.contains(bareTarget.uppercased()) { return .resolved }
            } else if WikiLinkResolver.resolvedSplit(of: raw, isKnown: known) != nil {
                return .resolved
            }
            return .broken(namespace: "source", label: displayLabel(fixedAlias, bareTarget))
        case .chat:
            guard facts.chatsAvailable else {
                return .lookupUnavailable(namespace: "chat")
            }
            let known: (String) -> Bool = { facts.knownChatTitles.contains($0) }
            if WikiLinkParser.isCanonicalULID(bareTarget) {
                if facts.knownChatIDs.contains(bareTarget.uppercased()) { return .resolved }
            } else if WikiLinkResolver.resolvedSplit(of: raw, isKnown: known) != nil {
                return .resolved
            }
            return .broken(namespace: "chat", label: displayLabel(fixedAlias, bareTarget))
        }
    }

    private static func displayLabel(_ alias: String?, _ target: String) -> String {
        let label = alias.map { WikiText.normalized($0) } ?? target
        return label.isEmpty ? target : label
    }

    /// The readable text kept when a broken link is removed: the target
    /// without its namespace prefix.
    private static func strippedTarget(_ target: String) -> String {
        let collapsed = WikiText.normalized(target)
        let (base, _) = WikiLinkParser.splitFragment(collapsed)
        let (bareBase, _) = WikiLinkParser.splitVersionPin(base)
        let (_, bare) = WikiLinkParser.classify(bareBase)
        return bare.isEmpty ? target : bare
    }

    // MARK: - Markdown cosmetics check

    /// The curated markdownlint rules as per-occurrence findings. Each
    /// fixable finding carries its typed individual edit converted to a
    /// validated byte range; findings whose coordinates do not locate real
    /// text are dropped (an invalid location never becomes a page finding).
    public static func markdownCosmeticFindings(
        stepID: LintStepID,
        body: String,
        recipes: RecipeLookup,
        linter: MarkdownLinter? = MarkdownLinter.shared
    ) -> [LintFinding] {
        guard let linter else { return [] }
        let results = linter.lint(markdown: body)
        let table = ByteLineTable(source: body)
        let ns = body as NSString
        let recipe = recipes.resolve(.cosmeticIndividualFix)

        var findings: [LintFinding] = []
        var sequence = 0
        for result in results {
            sequence += 1
            let id = LintFindingID(rawValue: "md-\(sequence)-\(result.ruleID)")

            // The finding's anchor: the individual fix range when present,
            // otherwise the reported line.
            var fix: LintIndividualFix?
            if let fixInfo = result.fixInfo {
                fix = individualFix(from: fixInfo, fallbackLine: result.lineNumber,
                                    table: table, body: body, ns: ns)
            }
            let anchorRange: LintSourceRange?
            if let fix {
                anchorRange = fix.range
            } else {
                // Whole reported line, when it exists.
                anchorRange = Self.reportedLineRange(
                    result.lineNumber, table: table, body: body, ns: ns)
            }
            // An unlocatable finding is an invalid result — drop it rather
            // than inventing a page-level anchor.
            guard let anchorRange else { continue }

            findings.append(LintFinding(
                id: id,
                stepID: stepID,
                ruleID: LintRuleID(rawValue: result.ruleID),
                severity: .info,
                message: result.ruleDescription + (result.errorDetail.map { " — \($0)" } ?? ""),
                evidence: result.errorContext,
                scope: .passage([anchorRange]),
                repairOptions: (fix != nil ? recipe : nil).map {
                    [LintRepairOption(
                        id: LintOptionID(rawValue: "cosmetic-\($0.rawValue)"),
                        recipeID: $0, label: "Apply cosmetic fix")]
                } ?? [],
                builtinFix: fix))
        }
        return findings
    }

    /// Convert markdownlint's typed fixInfo to a validated byte-range edit.
    /// Position: `editColumn` when present, else the start of the fix's line
    /// (markdownlint's documented default). The one past-end line maps to
    /// end-of-file (file-end insertion rules).
    private static func individualFix(
        from fixInfo: MarkdownLinter.LintFixInfo,
        fallbackLine: Int,
        table: ByteLineTable,
        body: String,
        ns: NSString
    ) -> LintIndividualFix? {
        let line = fixInfo.lineNumber != 0 ? fixInfo.lineNumber : fallbackLine
        let position: Int
        if let column = fixInfo.editColumn {
            guard let offset = table.offset(line: line, column: column) else { return nil }
            position = offset
        } else {
            guard let offset = table.offset(line: line, column: 1) else { return nil }
            position = offset
        }
        // deleteCount is a JS character (UTF-16 unit) count from the edit position.
        let end: Int
        if fixInfo.deleteCount > 0 {
            do {
                let utf16Start = try LintLocationAdapter.utf16Offset(ofUTF8Offset: position, in: body)
                let utf16End = utf16Start + fixInfo.deleteCount
                guard utf16End <= ns.length else { return nil }
                end = try LintLocationAdapter.utf8Offset(ofUTF16Offset: utf16End, in: body)
                guard end >= position else { return nil }
            } catch {
                DebugLog.lint("LintAnalyzer: fix edit position unlocatable at \(position): \(error)")
                return nil
            }
        } else {
            end = position
        }
        guard let expected = utf8Slice(position..<end, in: body, ns: ns) else { return nil }
        guard let range = validatedByteRange(position..<end, expected: expected, in: body) else {
            return nil
        }
        return LintIndividualFix(range: range, insertText: fixInfo.insertText)
    }

    /// The validated range covering a reported markdownlint line, or nil when
    /// the line does not locate real text.
    private static func reportedLineRange(
        _ lineNumber: Int, table: ByteLineTable, body: String, ns: NSString
    ) -> LintSourceRange? {
        guard let lower = table.offset(line: lineNumber, column: 1) else { return nil }
        let lineEnd: Int
        if lineNumber < table.lineCount {
            lineEnd = table.offset(line: lineNumber + 1, column: 1) ?? body.utf8.count
        } else {
            lineEnd = body.utf8.count
        }
        guard let text = utf8Slice(lower..<lineEnd, in: body, ns: ns) else { return nil }
        return validatedByteRange(lower..<lineEnd, expected: text, in: body)
    }

    /// A validated range over raw byte bounds (the drop is logged).
    static func validatedByteRange(
        _ bounds: Range<Int>, expected: String, in body: String
    ) -> LintSourceRange? {
        do {
            return try LintSourceRange(
                lowerBound: bounds.lowerBound, upperBound: bounds.upperBound,
                expectedText: expected, in: body)
        } catch {
            DebugLog.lint("LintAnalyzer: dropping invalid byte range \(bounds): \(error)")
            return nil
        }
    }

    /// An individual fix replacing an already-validated range with new text.
    static func individualFix(
        replacing range: LintSourceRange, with newText: String, in body: String
    ) -> LintIndividualFix? {
        // The range is already validated against this body; construction
        // re-checks by contract. A mismatch here is a logic bug — log it.
        guard range.isValid(in: body) else {
            DebugLog.lint("LintAnalyzer: fix range no longer matches body at \(range.lowerBound)")
            return nil
        }
        return LintIndividualFix(range: range, insertText: newText)
    }

    /// The exact body text a half-open UTF-8 byte range addresses, or nil
    /// when the range cannot be located (the failure is logged).
    static func utf8Slice(
        _ range: Range<Int>, in body: String, ns: NSString
    ) -> String? {
        do {
            let lower16 = try LintLocationAdapter.utf16Offset(ofUTF8Offset: range.lowerBound, in: body)
            let upper16 = try LintLocationAdapter.utf16Offset(ofUTF8Offset: range.upperBound, in: body)
            return ns.substring(with: NSRange(location: lower16, length: upper16 - lower16))
        } catch {
            DebugLog.lint("LintAnalyzer: unlocatable slice \(range): \(error)")
            return nil
        }
    }

    /// Validate + construct a source range from an NSString range, logging
    /// the drop. An invalid location is an invalid result — never a
    /// page-level finding invented by the host.
    static func validatedRange(
        _ nsRange: NSRange, in body: String, ns: NSString
    ) -> LintSourceRange? {
        do {
            let bytes = try LintLocationAdapter.utf8Range(forNSRange: nsRange, in: body)
            return try LintSourceRange(
                lowerBound: bytes.lowerBound, upperBound: bytes.upperBound,
                expectedText: ns.substring(with: nsRange), in: body)
        } catch {
            DebugLog.lint("LintAnalyzer: dropping finding with unlocatable range: \(error)")
            return nil
        }
    }
}
