import Foundation
import WikiFSTypes

/// The result of one deterministic structural check.
public struct CheckOutcome: Sendable, Equatable, Codable {
    /// Stable machine id for the check (e.g. `retainedFact:Mara Voss`).
    public let id: String
    public let passed: Bool
    /// One-line human explanation; for failures, names the missing/unexpected
    /// evidence so a reader can act without re-deriving the check.
    public let detail: String

    public init(id: String, passed: Bool, detail: String) {
        self.id = id
        self.passed = passed
        self.detail = detail
    }
}

/// The evaluation of one scenario: every check's outcome plus the scenario
/// identity. The overall verdict is structural ONLY — rubric questions are
/// recorded separately in the readable report and are never machine-answered.
public struct ScenarioEvaluation: Sendable, Equatable, Codable {
    public let scenarioID: EvaluationScenarioID
    public let outcomes: [CheckOutcome]

    public init(scenarioID: EvaluationScenarioID, outcomes: [CheckOutcome]) {
        self.scenarioID = scenarioID
        self.outcomes = outcomes
    }

    public var passed: Bool {
        outcomes.allSatisfy(\.passed)
    }

    public var failedChecks: [CheckOutcome] {
        outcomes.filter { !$0.passed }
    }
}

/// The snapshot inputs for one evaluation. Two-source scenarios supply
/// `before` = snapshot after run A and `after` = snapshot after run B. The
/// documentation-strategy scenario supplies `before` = leg 1's snapshot and
/// `after` = leg 2's snapshot (two independent wikis), so
/// `.differentOutputShape` compares across legs while per-leg checks
/// (identity, history) evaluate within each snapshot.
public struct EvaluationInput: Sendable, Equatable {
    public let before: WikiObservation
    public let after: WikiObservation

    public init(before: WikiObservation, after: WikiObservation) {
        self.before = before
        self.after = after
    }
}

/// The deterministic structural evaluator. No model, no network, no store
/// access: it sees only captured ``WikiObservation`` values, which is what
/// makes its negative controls meaningful — the same code path classifies
/// live captures and canned fixtures.
///
/// Scope, stated plainly: every check here is a fixture-specific heuristic
/// over known phrases, citation rows, and snapshots. A pass means the
/// enumerated structural expectations held — it is NOT a general correctness
/// or truthfulness guarantee, and it never answers the rubric questions. The
/// human rubric section of the report is the authoritative semantic review.
public struct StructuralEvaluator: Sendable {
    public init() {}

    public func evaluate(
        scenario: EvaluationScenario,
        input: EvaluationInput
    ) -> ScenarioEvaluation {
        let outcomes = scenario.checks.map { outcome(for: $0, input: input) }
        return ScenarioEvaluation(scenarioID: scenario.id, outcomes: outcomes)
    }

    /// Re-evaluate one AFTER-ONLY check against a single post-run snapshot —
    /// the offline-recheck seam. Recorded live runs do not persist their
    /// per-batch before snapshots, so a check that compares snapshots
    /// (``StructuralCheck/requiresBeforeSnapshot``) cannot be re-derived
    /// offline: it returns nil, and the caller carries the recorded outcome
    /// forward. For the after-only kinds the `before` slot of the input below
    /// is plumbing the existing implementations share; the dispatch guarantees
    /// no before-reading code path runs for them.
    public func evaluate(check: StructuralCheck, after: WikiObservation) -> CheckOutcome? {
        guard !check.requiresBeforeSnapshot else { return nil }
        return outcome(for: check, input: EvaluationInput(before: after, after: after))
    }

    // MARK: - Per-check evaluation

    func outcome(for check: StructuralCheck, input: EvaluationInput) -> CheckOutcome {
        switch check {
        case .retainedFact(let pageTitle, let phrases):
            return checkPhrases(
                phrases, in: pageTitle, input: input,
                label: "retainedFact",
                missing: { missing in
                    "evidence dropped: body lacks \(missing.map { "'\($0)'" }.joined(separator: ", "))"
                })
        case .unsupportedClaim(let pageTitle, let phrases):
            return forbidPhrases(
                phrases, in: pageTitle, input: input,
                label: "unsupportedClaim",
                found: { found in
                    "unsupported claim: body asserts \(found.map { "'\($0)'" }.joined(separator: ", ")) — no fixture source states it"
                })
        case .supersededInterpretation(let pageTitle, let correctedPhrases, let supersededPhrases, let qualifiers):
            return superseded(
                pageTitle: pageTitle,
                correctedPhrases: correctedPhrases,
                supersededPhrases: supersededPhrases,
                qualifiers: qualifiers,
                input: input)
        case .citationsPresent(let pageTitle, let fragments):
            return citations(fragments: fragments, pageTitle: pageTitle, input: input)
        case .stablePageIdentity(let pageTitle):
            return stableIdentity(pageTitle: pageTitle, input: input)
        case .noUnrelatedPageEdits(let allowedFragments):
            return unrelatedEdits(allowedFragments: allowedFragments, input: input)
        case .historyDepth(let pageTitle, let minimum):
            return historyDepth(pageTitle: pageTitle, minimum: minimum, input: input)
        case .provenanceIncludes(let pageTitle, let fragments):
            return provenance(fragments: fragments, pageTitle: pageTitle, input: input)
        case .strategyShape(let pageTitle, let required, let forbidden, let firstLeg):
            return strategyShape(
                pageTitle: pageTitle,
                required: required,
                forbidden: forbidden,
                firstLeg: firstLeg,
                input: input)
        case .differentOutputShape(let pageTitle):
            return differentShape(pageTitle: pageTitle, input: input)
        }
    }

    // MARK: - Check implementations

    private func checkPhrases(
        _ phrases: [String],
        in pageTitle: String,
        input: EvaluationInput,
        label: String,
        missing: ([String]) -> String
    ) -> CheckOutcome {
        let id = "\(label):\(pageTitle)"
        guard let page = resolve(pageTitle: pageTitle, in: input.after, checkID: id) else {
            return pageNotFound(pageTitle: pageTitle, input: input.after, checkID: id)
        }
        let absent = phrases.filter { !page.body.localizedCaseInsensitiveContains($0) }
        if absent.isEmpty {
            return CheckOutcome(id: id, passed: true, detail: "all \(phrases.count) phrase(s) present in '\(page.title)'")
        }
        return CheckOutcome(id: id, passed: false, detail: missing(absent))
    }

    private func forbidPhrases(
        _ phrases: [String],
        in pageTitle: String,
        input: EvaluationInput,
        label: String,
        found: ([String]) -> String
    ) -> CheckOutcome {
        let id = "\(label):\(pageTitle)"
        guard let page = resolve(pageTitle: pageTitle, in: input.after, checkID: id) else {
            return pageNotFound(pageTitle: pageTitle, input: input.after, checkID: id)
        }
        let present = phrases.filter { page.body.localizedCaseInsensitiveContains($0) }
        if present.isEmpty {
            return CheckOutcome(id: id, passed: true, detail: "no unsupported phrase present in '\(page.title)'")
        }
        return CheckOutcome(id: id, passed: false, detail: found(present))
    }

    private func superseded(
        pageTitle: String,
        correctedPhrases: [String],
        supersededPhrases: [String],
        qualifiers: [String],
        input: EvaluationInput
    ) -> CheckOutcome {
        let id = "supersededInterpretation:\(pageTitle)"
        guard let page = resolve(pageTitle: pageTitle, in: input.after, checkID: id) else {
            return pageNotFound(pageTitle: pageTitle, input: input.after, checkID: id)
        }
        // 1. The corrected account must be present at all.
        let missingCorrected = correctedPhrases.filter { !page.body.localizedCaseInsensitiveContains($0) }
        if !missingCorrected.isEmpty {
            return CheckOutcome(
                id: id, passed: false,
                detail: "corrected interpretation missing: body lacks \(missingCorrected.map { "'\($0)'" }.joined(separator: ", ")) — the correction from the later source did not land")
        }
        // 2. EVERY occurrence of a superseded phrase in the page's CURRENT
        //    assertions must carry a qualifier. The scan is markdown-aware
        //    about what counts as a current assertion:
        //
        //    - Footnote definitions (`[^label]: …`) are citation evidence:
        //      they repeat source wording verbatim — often in present
        //      tense — and never state it as the page's own current claim.
        //      They are excluded from the scan.
        //    - A heading whose own text carries a qualifier (e.g. "ADR 014:
        //      …") opens an explicit historical section. The section
        //      extends to the next heading of the SAME or HIGHER level;
        //      subheadings inherit the scope, and occurrences inside it
        //      read as history. The scope ends at that heading boundary —
        //      a qualifier far away authorizes nothing.
        //    - Everywhere else the sentence-local rule stands: each
        //      occurrence must share its own sentence with a qualifier.
        //      "Previously X. … X." still fails because the second
        //      occurrence is unqualified — an earlier qualified claim never
        //      excuses a later unqualified repetition in current text.
        let unqualified = supersededPhrases.filter { phrase in
            presentsAsCurrentTruth(phrase, body: page.body, qualifiers: qualifiers)
        }
        if unqualified.isEmpty {
            return CheckOutcome(
                id: id, passed: true,
                detail: "corrected account present; superseded phrasing kept out of current assertions")
        }
        return CheckOutcome(
            id: id, passed: false,
            detail: "superseded interpretation presented as current truth without a qualifier: \(unqualified.map { "'\($0)'" }.joined(separator: ", "))")
    }

    // MARK: - Superseded-phrase current-assertion scan

    /// Whether any occurrence of `phrase` reads as the page's CURRENT
    /// assertion without a qualifier. Three kinds of text are not current
    /// assertions: footnote definitions (citation evidence carrying verbatim
    /// source quotes), the content of an explicit historical section (opened
    /// by a qualified heading, extending to the next heading of the same or
    /// higher level, subheadings included), and — inside current text — an
    /// occurrence whose own sentence carries a qualifier.
    ///
    /// Deliberately NOT a blanket qualifier search: a qualifier in an
    /// earlier sentence, an earlier section, or a deeper footnote authorizes
    /// only the scope it structurally covers. A page that presents the
    /// superseded decision unqualified in a CURRENT section still fails,
    /// however well-qualified its history section was.
    private func presentsAsCurrentTruth(
        _ phrase: String,
        body: String,
        qualifiers: [String]
    ) -> Bool {
        var inFootnoteDefinition = false
        var openHistoricalLevels: [Int] = []
        for line in body.components(separatedBy: "\n") {
            if inFootnoteDefinition {
                // A footnote definition continues over blank and indented
                // lines; any other line ends it.
                if Self.isBlankOrIndented(line) { continue }
                inFootnoteDefinition = false
            }
            if Self.isFootnoteDefinition(line) {
                inFootnoteDefinition = true
                continue
            }
            if let (level, text) = Self.heading(line) {
                // A heading at level N closes every open historical section
                // at level N or deeper, then may open one with its own text.
                openHistoricalLevels.removeAll { $0 >= level }
                if qualifiers.contains(where: { text.localizedCaseInsensitiveContains($0) }) {
                    openHistoricalLevels.append(level)
                }
            }
            // Content of an open historical section — including the
            // qualified heading itself and its inheriting subheadings —
            // reads as history, not as a current assertion.
            guard openHistoricalLevels.isEmpty else { continue }
            if linePresentsUnqualifiedOccurrence(of: phrase, in: line, qualifiers: qualifiers) {
                return true
            }
        }
        return false
    }

    /// The sentence-local qualifier rule, applied to one line. A newline
    /// ends a sentence, so the sentence around an occurrence never crosses a
    /// line boundary.
    private func linePresentsUnqualifiedOccurrence(
        of phrase: String,
        in line: String,
        qualifiers: [String]
    ) -> Bool {
        var searchStart = line.startIndex
        while let range = line.range(
            of: phrase, options: [.caseInsensitive], range: searchStart..<line.endIndex)
        {
            let sentenceStart = line[..<range.lowerBound].lastIndex {
                $0 == "." || $0 == "!" || $0 == "?"
            }.map { line.index(after: $0) } ?? line.startIndex
            let sentenceEnd = line[range.upperBound...].firstIndex {
                $0 == "." || $0 == "!" || $0 == "?"
            }.map { line.index(after: $0) } ?? line.endIndex
            let sentence = line[sentenceStart..<sentenceEnd]
            let qualified = qualifiers.contains {
                sentence.localizedCaseInsensitiveContains($0)
            }
            if !qualified {
                return true
            }
            searchStart = range.upperBound
        }
        return false
    }

    /// An ATX heading line (`#`…`######`): its level and text. nil for any
    /// other line, including a `#` glued to text (`#hashtag`).
    private static func heading(_ line: String) -> (level: Int, text: String)? {
        var level = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == "#" {
            level += 1
            index = line.index(after: index)
        }
        guard (1...6).contains(level),
              index == line.endIndex || line[index] == " " || line[index] == "\t"
        else { return nil }
        let rawText = index < line.endIndex ? String(line[line.index(after: index)...]) : ""
        // Strip a closing marker sequence ("## History ##" → "History").
        var text = rawText
        if let closing = text.range(of: "\\s#+\\s*$", options: .regularExpression) {
            text = String(text[..<closing.lowerBound])
        }
        return (level, text.trimmingCharacters(in: .whitespaces))
    }

    /// A Markdown footnote definition line — `[^label]: …`, optionally
    /// indented up to three spaces. Footnote definitions exist to carry
    /// citations and verbatim source quotes; they are evidence, never the
    /// page's own assertions.
    private static func isFootnoteDefinition(_ line: String) -> Bool {
        line.range(of: "^ {0,3}\\[\\^[^\\]]+\\]:", options: .regularExpression) != nil
    }

    /// Blank or indented (4+ spaces / tab) — the lines a footnote definition
    /// continues over.
    private static func isBlankOrIndented(_ line: String) -> Bool {
        line.hasPrefix("\t") || line.hasPrefix("    ")
            || line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func citations(
        fragments: [String],
        pageTitle: String,
        input: EvaluationInput
    ) -> CheckOutcome {
        let id = "citationsPresent:\(pageTitle)"
        guard let page = resolve(pageTitle: pageTitle, in: input.after, checkID: id) else {
            return pageNotFound(pageTitle: pageTitle, input: input.after, checkID: id)
        }
        // The DATABASE source-link rows are the authoritative citation edges
        // (the write pipeline derives them from the body at write time).
        //
        // When the observation carries typed fixture keys, every fragment
        // MUST resolve to a `SourceID` by exact key match and the check is
        // purely identity-based — a display name that happens to contain the
        // fragment can never satisfy it (live agents cite by source id, and
        // display names are free-form). A fragment with no typed id is a
        // hard failure naming the gap, never a silent name fallback.
        //
        // Legacy canned captures (no fixture keys anywhere) keep their
        // name-based contract so historical results still classify.
        if input.after.sources.contains(where: { $0.fixtureKey != nil }) {
            let resolved = Self.typedSourceIDs(for: fragments, in: input.after)
            if let unresolved = unresolvedFragment(fragments: fragments, resolved: resolved, in: input.after) {
                return CheckOutcome(id: id, passed: false, detail: unresolved)
            }
            let uncited = zip(fragments, resolved).compactMap { fragment, sourceID -> String? in
                // Unreachable for nil: unresolved fragments failed the check above.
                guard let sourceID else { return nil }
                return page.sourceLinkIDs.contains(sourceID) ? nil : fragment
            }
            if uncited.isEmpty {
                return CheckOutcome(id: id, passed: true, detail: "all \(fragments.count) source(s) linked by database source-link rows in '\(page.title)'")
            }
            return CheckOutcome(
                id: id, passed: false,
                detail: "no database source-link row cites: \(uncited.joined(separator: ", ")) — linked ids: \(page.sourceLinkIDs.map(\.rawValue).joined(separator: ", ")); body citations: \(page.citationNames.map { "[[\($0)]]" }.joined(separator: " "))")
        }
        let uncited = fragments.filter { fragment in
            !page.sourceLinkNames.contains { $0.localizedCaseInsensitiveContains(fragment) }
        }
        if uncited.isEmpty {
            return CheckOutcome(id: id, passed: true, detail: "all \(fragments.count) source(s) linked by database source-link rows in '\(page.title)'")
        }
        let linkedRows = page.sourceLinkNames.joined(separator: ", ")
        let bodyCitations = page.citationNames.map { "[[\($0)]]" }.joined(separator: " ")
        return CheckOutcome(
            id: id, passed: false,
            detail: "no database source-link row cites: \(uncited.joined(separator: ", ")) — link rows: \(linkedRows.isEmpty ? "(none)" : linkedRows); body citations: \(bodyCitations.isEmpty ? "(none)" : bodyCitations)")
    }

    private func stableIdentity(pageTitle: String, input: EvaluationInput) -> CheckOutcome {
        let id = "stablePageIdentity:\(pageTitle)"
        guard let beforePage = resolve(pageTitle: pageTitle, in: input.before, checkID: id) else {
            return pageNotFound(pageTitle: pageTitle, input: input.before, checkID: id)
        }
        guard let afterPage = resolve(pageTitle: pageTitle, in: input.after, checkID: id) else {
            return pageNotFound(pageTitle: pageTitle, input: input.after, checkID: id)
        }
        if beforePage.id == afterPage.id {
            return CheckOutcome(id: id, passed: true, detail: "'\(afterPage.title)' kept PageID \(afterPage.id.rawValue)")
        }
        return CheckOutcome(
            id: id, passed: false,
            detail: "page identity changed across the run: \(beforePage.id.rawValue) → \(afterPage.id.rawValue) — the page was recreated instead of updated")
    }

    private func unrelatedEdits(
        allowedFragments: [String],
        input: EvaluationInput
    ) -> CheckOutcome {
        let id = "noUnrelatedPageEdits"
        func isAllowed(_ page: ObservedPage) -> Bool {
            allowedFragments.contains { page.title.localizedCaseInsensitiveContains($0) }
        }
        var edited: [String] = []
        for beforePage in input.before.pages {
            guard let afterPage = input.after.page(id: beforePage.id) else {
                edited.append("\(beforePage.title) (deleted)")
                continue
            }
            if isAllowed(afterPage) { continue }
            if beforePage.body != afterPage.body || beforePage.version != afterPage.version {
                edited.append(beforePage.title)
            }
        }
        // Pages CREATED during the run must also be expected.
        let created = input.after.pages
            .filter { afterPage in input.before.page(id: afterPage.id) == nil }
            .filter { !isAllowed($0) }
            .map(\.title)
        let allUnexpected = edited + created.map { "\($0) (created)" }
        if allUnexpected.isEmpty {
            return CheckOutcome(id: id, passed: true, detail: "no page outside \(allowedFragments.joined(separator: ", ")) changed")
        }
        return CheckOutcome(
            id: id, passed: false,
            detail: "unrelated pages changed: \(allUnexpected.joined(separator: ", "))")
    }

    private func historyDepth(pageTitle: String, minimum: Int, input: EvaluationInput) -> CheckOutcome {
        let id = "historyDepth:\(pageTitle)"
        guard let page = resolve(pageTitle: pageTitle, in: input.after, checkID: id) else {
            return pageNotFound(pageTitle: pageTitle, input: input.after, checkID: id)
        }
        if page.historyDepth >= minimum {
            return CheckOutcome(id: id, passed: true, detail: "\(page.historyDepth) version(s) recorded (minimum \(minimum))")
        }
        return CheckOutcome(
            id: id, passed: false,
            detail: "history too shallow: \(page.historyDepth) version(s) recorded, expected at least \(minimum) — a run's write may have been lost to a stale-write path")
    }

    private func provenance(
        fragments: [String],
        pageTitle: String,
        input: EvaluationInput
    ) -> CheckOutcome {
        let id = "provenanceIncludes:\(pageTitle)"
        guard let page = resolve(pageTitle: pageTitle, in: input.after, checkID: id) else {
            return pageNotFound(pageTitle: pageTitle, input: input.after, checkID: id)
        }
        // Same resolution contract as `citations`: typed fixture keys make
        // the check identity-based; missing typed ids fail loudly; only
        // key-free legacy captures use display-name matching. The check reads
        // ONLY the current head version's provenance rows — there is
        // deliberately NO union across versions or with body citations: a
        // body that still carries chapter-3 evidence while the head version
        // records only chapter-7 is a real provenance failure, not something
        // to paper over.
        if input.after.sources.contains(where: { $0.fixtureKey != nil }) {
            let resolved = Self.typedSourceIDs(for: fragments, in: input.after)
            if let unresolved = unresolvedFragment(fragments: fragments, resolved: resolved, in: input.after) {
                return CheckOutcome(id: id, passed: false, detail: unresolved)
            }
            let missing = zip(fragments, resolved).compactMap { fragment, sourceID -> String? in
                // Unreachable for nil: unresolved fragments failed the check above.
                guard let sourceID else { return nil }
                return page.provenanceSourceIDs.contains(sourceID) ? nil : fragment
            }
            if missing.isEmpty {
                return CheckOutcome(id: id, passed: true, detail: "current head version's provenance covers all \(fragments.count) source(s)")
            }
            let recorded = page.provenanceSourceIDs.map(\.rawValue).joined(separator: ", ")
            return CheckOutcome(
                id: id, passed: false,
                detail: "provenance on the current head version omits: \(missing.joined(separator: ", ")) — recorded ids: \(recorded.isEmpty ? "(none)" : recorded)")
        }
        let missing = fragments.filter { fragment in
            !page.provenanceSourceNames.contains { $0.localizedCaseInsensitiveContains(fragment) }
        }
        if missing.isEmpty {
            return CheckOutcome(id: id, passed: true, detail: "latest version's provenance covers all \(fragments.count) source(s)")
        }
        let recorded = page.provenanceSourceNames.joined(separator: ", ")
        return CheckOutcome(
            id: id, passed: false,
            detail: "provenance on the latest version omits: \(missing.joined(separator: ", ")) — recorded: \(recorded.isEmpty ? "(none)" : recorded)")
    }

    private func strategyShape(
        pageTitle: String,
        required: [String],
        forbidden: [String],
        firstLeg: Bool,
        input: EvaluationInput
    ) -> CheckOutcome {
        let id = "strategyShape:\(pageTitle)\(firstLeg ? ":leg1" : "")"
        let observation = firstLeg ? input.before : input.after
        guard let page = resolve(pageTitle: pageTitle, in: observation, checkID: id) else {
            return pageNotFound(pageTitle: pageTitle, input: observation, checkID: id)
        }
        let missing = required.filter { !page.body.localizedCaseInsensitiveContains($0) }
        if !missing.isEmpty {
            return CheckOutcome(
                id: id, passed: false,
                detail: "strategy output shape wrong: required phrase(s) missing: \(missing.map { "'\($0)'" }.joined(separator: ", "))")
        }
        let present = forbidden.filter { page.body.localizedCaseInsensitiveContains($0) }
        if !present.isEmpty {
            return CheckOutcome(
                id: id, passed: false,
                detail: "strategy output shape wrong: forbidden phrase(s) present: \(present.map { "'\($0)'" }.joined(separator: ", ")) — the page follows the WRONG documentation strategy")
        }
        return CheckOutcome(id: id, passed: true, detail: "strategy markers satisfied in '\(page.title)'")
    }

    private func differentShape(pageTitle: String, input: EvaluationInput) -> CheckOutcome {
        let id = "differentOutputShape:\(pageTitle)"
        guard let beforePage = resolve(pageTitle: pageTitle, in: input.before, checkID: id) else {
            return pageNotFound(pageTitle: pageTitle, input: input.before, checkID: id)
        }
        guard let afterPage = resolve(pageTitle: pageTitle, in: input.after, checkID: id) else {
            return pageNotFound(pageTitle: pageTitle, input: input.after, checkID: id)
        }
        func normalized(_ body: String) -> String {
            body.lowercased()
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        if normalized(beforePage.body) != normalized(afterPage.body) {
            return CheckOutcome(id: id, passed: true, detail: "the two strategies produced different page bodies")
        }
        return CheckOutcome(
            id: id, passed: false,
            detail: "both legs produced identical page bodies — the strategy change had no observable effect on the output")
    }

    // MARK: - Helpers

    /// Resolve check fragments to typed `SourceID`s by EXACT fixture-key
    /// (filename-stem) match, case-insensitive. An ambiguous stem (two
    /// sources share it) or an absent key resolves to nil — the caller fails
    /// the check with the gap named; it never guesses and never falls through
    /// to display-name matching.
    private static func typedSourceIDs(
        for fragments: [String],
        in observation: WikiObservation
    ) -> [SourceID?] {
        fragments.map { fragment in
            let matches = observation.sources.filter {
                $0.fixtureKey?.localizedCaseInsensitiveCompare(fragment) == .orderedSame
            }
            return matches.count == 1 ? matches[0].id : nil
        }
    }

    /// The failure detail for a fragment that carried no typed id, naming the
    /// observed fixture keys so the operator can see the mapping gap. nil
    /// when every fragment resolved.
    private func unresolvedFragment(
        fragments: [String],
        resolved: [SourceID?],
        in observation: WikiObservation
    ) -> String? {
        let missing = fragments.enumerated()
            .filter { resolved[$0.offset] == nil }
            .map(\.element)
        guard !missing.isEmpty else { return nil }
        let keys = observation.sources.compactMap(\.fixtureKey).sorted()
        return "no typed source id for fixture key(s): \(missing.joined(separator: ", ")) — observed fixture keys: \(keys.isEmpty ? "(none)" : keys.joined(separator: ", "))"
    }

    private func resolve(pageTitle: String, in observation: WikiObservation, checkID: String) -> ObservedPage? {
        observation.page(titled: pageTitle).page
    }

    private func pageNotFound(pageTitle: String, input: WikiObservation, checkID: String) -> CheckOutcome {
        let resolution = input.page(titled: pageTitle)
        if case .notFound(let candidates, let allTitles) = resolution {
            let nearMisses = candidates.isEmpty ? "" : " (near-miss titles: \(candidates.joined(separator: ", ")))"
            let titles = allTitles.isEmpty ? "the wiki has no pages" : "titles present: \(allTitles.joined(separator: ", "))"
            return CheckOutcome(
                id: checkID, passed: false,
                detail: "no unique page matches '\(pageTitle)'\(nearMisses) — \(titles)")
        }
        return CheckOutcome(id: checkID, passed: false, detail: "no page matches '\(pageTitle)'")
    }
}
