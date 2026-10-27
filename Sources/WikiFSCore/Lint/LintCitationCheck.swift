import Foundation
import WikiFSMarkdown
import WikiFSTypes

// MARK: - Citation check (version-aware)

/// Verifies the page's citation occurrences against CAPTURED source-version
/// evidence. Supersedes the retired alias-required quote-regex check: the
/// contract is now the shared span/syntax parse (alias-free links, aliases,
/// source names, canonical ids, `@vN` pins, quote fragments, heading
/// fragments; protected code excluded) plus per-record capture status.
///
/// Verdict discipline:
/// - A quote absent from COMPLETE captured evidence can be reported absent
///   from that version. A quote absent from a PREFIX is unverified. A quote
///   present within a prefix establishes textual presence but not complete-
///   source verification.
/// - Correspondence uses `WikiQuoteProjection`, mirroring the production
///   reader: typography-normalized whole-quote match, then the >= 4-word
///   partial-run fallback the reader performs. Partial navigation is
///   reported as distinct from full quote correspondence — the two are
///   never called equivalent.
/// - Pins validate even without quotes; an invalid or unresolvable pin is a
///   finding in its own right.
/// - A source NAME that resolves ambiguously is report-only with the
///   candidate ids in evidence; no silent default target is ever chosen.
///   A uniquely-resolving name can offer canonicalization to its typed id
///   while preserving pin, fragment, alias, and visible text.
/// - The only repair offered is the encoding-only quote edit: offered ONLY
///   when the whole quote has a unique, evidence-backed correspondence and
///   the candidate still resolves through the production reader. No wording,
///   source identity, or pin changes; a failing gate reports the mismatch
///   without a repair.
public enum LintCitationCheck {

    /// Rule ids emitted by this check.
    enum Rule: String {
        case unverified = "citation-unverified"
        case quoteMissing = "citation-fragment-missing"
        case quotePrefixOnly = "citation-fragment-prefix-only"
        case quotePartial = "citation-fragment-partial"
        case pinInvalid = "citation-pin-invalid"
        case pinMissing = "citation-version-missing"
        case sourceAmbiguous = "citation-source-ambiguous"
        case sourceCanonicalization = "citation-source-canonicalizable"
        case encodingRepair = "citation-encoding-mismatch"
    }

    /// Recipe ids this check can attach (resolved from configuration; a
    /// missing recipe leaves the finding report-only).
    enum Recipe: String {
        case encodingFix = "citation-encoding-fix"
        case canonicalization = "source-canonicalization"
    }

    public static func findings(
        stepID: LintStepID,
        snapshot: LintPageSnapshot,
        recipes: LintAnalyzer.RecipeLookup
    ) -> [LintFinding] {
        let evidence = snapshot.citations
        // A store without the citation-capture leg stays silent — the
        // wiki-links check surfaces namespace availability separately.
        guard evidence.isAvailable else { return [] }

        let body = snapshot.body
        var findings: [LintFinding] = []
        var sequence = 0
        func nextID(_ prefix: String) -> LintFindingID {
            sequence += 1
            return LintFindingID(rawValue: "\(prefix)-\(sequence)")
        }

        for occurrence in evidence.occurrences {
            // Named targets first: ambiguity is report-only and never
            // degrades into an arbitrary quote verdict.
            if let name = occurrence.sourceName {
                switch evidence.nameIndex.resolve(name: name) {
                case .ambiguous(let candidates):
                    let ids = candidates.map { $0.rawValue }.joined(separator: ", ")
                    findings.append(LintFinding(
                        id: nextID("cite-ambiguous"),
                        stepID: stepID,
                        ruleID: LintRuleID(rawValue: Rule.sourceAmbiguous.rawValue),
                        severity: .warning,
                        message: "The source name '\(name)' matches \(candidates.count) sources — "
                            + "the citation target is ambiguous. Name it by its source id, or "
                            + "rename one of the sources.",
                        evidence: "candidates: \(ids)",
                        scope: .passage([occurrence.range]),
                        repairOptions: []))
                    continue
                case .missing:
                    // A missing source link is the wiki-links check's
                    // verdict; quote verification is moot without a target.
                    continue
                case .resolved(let id):
                    // A unique name can canonicalize to its typed id while
                    // preserving pin, fragment, alias, and visible text.
                    if let finding = canonicalizationFinding(
                        stepID: stepID, id: nextID("cite-canonical"),
                        occurrence: occurrence, resolvedID: id,
                        recipes: recipes) {
                        findings.append(finding)
                    }
                }
            }

            // Pin validation stands on its own — no quote required.
            switch occurrence.request {
            case .invalidPin(let literal):
                findings.append(LintFinding(
                    id: nextID("cite-pin"),
                    stepID: stepID,
                    ruleID: LintRuleID(rawValue: Rule.pinInvalid.rawValue),
                    severity: .warning,
                    message: "Version pin @v\(literal) is not a positive version ordinal — "
                        + "the citation cannot resolve to a version.",
                    evidence: occurrence.authoredLiteral,
                    scope: .passage([occurrence.range]),
                    repairOptions: []))
                continue
            case .pinned, .active:
                break
            }

            guard occurrence.quote != nil || occurrence.request.pin != nil else {
                // No quote and no pin: resolution is the wiki-links check's
                // territory; nothing version-aware to verify here.
                continue
            }

            let record = evidence.record(for: occurrence)
            guard let record else {
                // No record was captured for this (id, request) pair: the
                // name or id did not resolve to a loadable target. Report
                // unverified — never "broken".
                findings.append(unverifiedFinding(
                    stepID: stepID, id: nextID("cite-unverified"),
                    occurrence: occurrence,
                    message: "Could not verify this citation — its source version was not "
                        + "captured (the target may not resolve)."))
                continue
            }

            switch record.status {
            case .missingTarget:
                // The canonical id names no source row (wiki-links reports
                // the broken link); skip quote verdicts.
                continue
            case .missingVersion:
                findings.append(LintFinding(
                    id: nextID("cite-pin"),
                    stepID: stepID,
                    ruleID: LintRuleID(rawValue: Rule.pinMissing.rawValue),
                    severity: .warning,
                    message: pinMissingMessage(occurrence: occurrence),
                    evidence: occurrence.authoredLiteral,
                    scope: .passage([occurrence.range]),
                    repairOptions: []))
                continue
            case .unavailableExtraction:
                findings.append(unverifiedFinding(
                    stepID: stepID, id: nextID("cite-unverified"),
                    occurrence: occurrence,
                    message: "Could not verify this citation — the cited source has no "
                        + "processed markdown to check against."))
                continue
            case .readFailed:
                findings.append(unverifiedFinding(
                    stepID: stepID, id: nextID("cite-unverified"),
                    occurrence: occurrence,
                    message: "Could not verify this citation — reading the cited source "
                        + "version failed."))
                continue
            case .budgetOmitted:
                findings.append(unverifiedFinding(
                    stepID: stepID, id: nextID("cite-unverified"),
                    occurrence: occurrence,
                    message: "This citation was not verified — the capture budget was "
                        + "exhausted before its source version was read."))
                continue
            case .present:
                break
            }

            // Pin-only citation with a present version: the pin validated.
            guard let quote = occurrence.quote, !quote.isEmpty else {
                continue
            }

            guard let text = record.text else {
                findings.append(unverifiedFinding(
                    stepID: stepID, id: nextID("cite-unverified"),
                    occurrence: occurrence,
                    message: "Could not verify this citation — the captured record carries "
                        + "no text."))
                continue
            }

            let projected = WikiQuoteProjection.project(text)
            let outcome = WikiQuoteProjection.compare(quote: quote, projected: projected)
            let isCompleteCapture = record.isComplete
            switch outcome {
            case .unavailable:
                findings.append(unverifiedFinding(
                    stepID: stepID, id: nextID("cite-unverified"),
                    occurrence: occurrence,
                    message: "Could not verify this quote — the cited source contains "
                        + "constructs the text projection cannot represent "
                        + "(\(projected.reason ?? "unsupported"))."))
            case .fullMatch:
                if case .prefix(let original) = record.completeness {
                    findings.append(infoFinding(
                        stepID: stepID, id: nextID("cite-prefix"),
                        rule: .quotePrefixOnly, occurrence: occurrence,
                        message: "The quote was found, but only the first "
                            + "\(text.utf8.count) of \(original) bytes of this source were "
                            + "captured — presence is verified for the captured prefix, not "
                            + "the complete source."))
                }
                // Complete capture + full match: verified, no finding.
            case .partialMatch, .noMatch:
                // A PREFIX capture can never back a definitive partial-run or
                // absence verdict — the quote may live in the uncaptured
                // remainder. Report unverified, not missing.
                guard isCompleteCapture else {
                    findings.append(unverifiedFinding(
                        stepID: stepID, id: nextID("cite-unverified"),
                        occurrence: occurrence,
                        message: "The quote was not found in the captured prefix of this "
                            + "source — the remainder was not captured, so presence is "
                            + "UNVERIFIED (not reported as absent)."))
                    continue
                }
                // An authored quote carrying markup can still have a WHOLE-
                // quote correspondence after projection (e.g. markdown
                // emphasis in the anchor versus HTML emphasis in the source).
                // The encoding-only repair gate runs before the partial/
                // missing verdicts; a failing gate reports the mismatch
                // without a repair.
                findings.append(partialOrMissingFinding(
                    stepID: stepID, id: nextID("cite-miss"),
                    outcome: outcome, occurrence: occurrence,
                    record: record, projected: projected, body: body,
                    recipes: recipes))
            }
        }
        return findings
    }

    // MARK: - Finding constructors

    /// The canonicalization offer for a uniquely-resolving source name:
    /// replace the span's TARGET with `source:<ULID>`, preserving pin,
    /// fragment, alias, and the visible text. Only offered when the typed
    /// form actually differs from the authored form.
    static func canonicalizationFinding(
        stepID: LintStepID, id: LintFindingID,
        occurrence: LintCitationOccurrence, resolvedID: SourceID,
        recipes: LintAnalyzer.RecipeLookup
    ) -> LintFinding? {
        let canonicalTarget = "source:\(resolvedID.rawValue.uppercased())"
        // Rebuild the span with the canonical target, preserving pin,
        // fragment, and alias exactly as authored.
        var rebuilt = canonicalTarget
        switch occurrence.request {
        case .pinned(let pin): rebuilt += "@v\(pin.ordinal)"
        case .active, .invalidPin: break
        }
        if let quote = occurrence.quote {
            rebuilt += "#\"\(quote)\""
        } else if let heading = occurrence.headingFragment {
            rebuilt += "#\(heading)"
        }
        if let alias = occurrence.alias, !alias.isEmpty {
            rebuilt += "|\(alias)"
        }
        let canonicalSpan = "[[\(rebuilt)]]"
        guard canonicalSpan != occurrence.authoredLiteral else { return nil }
        // The alias preserved: visible text unchanged. Sanity-check the
        // rebuilt span parses back to the same identity before offering.
        let reparsed = WikiLinkParser.syntaxNodes(in: "x\(canonicalSpan)x")
        guard case .link(let reparsedLink) = reparsed.first,
              reparsedLink.target.canonicalID?.uppercased() == resolvedID.rawValue.uppercased()
        else { return nil }

        let recipe = recipes.resolve(.sourceCanonicalization)
        let fix = Self.individualFix(
            replacing: occurrence.range, with: canonicalSpan)
        return LintFinding(
            id: id, stepID: stepID,
            ruleID: LintRuleID(rawValue: Rule.sourceCanonicalization.rawValue),
            severity: .info,
            message: "This citation names the source by display name. It can be "
                + "canonicalized to the source's stable id without changing the "
                + "visible text.",
            evidence: "resolves to \(resolvedID.rawValue.uppercased())",
            scope: .passage([occurrence.range]),
            repairOptions: recipe.map {
                [LintRepairOption(
                    id: LintOptionID(rawValue: "cite-canonical-\($0.rawValue)"),
                    recipeID: $0, label: "Canonicalize to source id")]
            } ?? [],
            builtinFix: fix)
    }

    private static func unverifiedFinding(
        stepID: LintStepID, id: LintFindingID, occurrence: LintCitationOccurrence,
        message: String
    ) -> LintFinding {
        LintFinding(
            id: id, stepID: stepID,
            ruleID: LintRuleID(rawValue: Rule.unverified.rawValue),
            severity: .info, message: message,
            evidence: occurrence.quote ?? occurrence.authoredLiteral,
            scope: .passage([occurrence.range]), repairOptions: [])
    }

    private static func infoFinding(
        stepID: LintStepID, id: LintFindingID, rule: Rule,
        occurrence: LintCitationOccurrence, message: String
    ) -> LintFinding {
        LintFinding(
            id: id, stepID: stepID,
            ruleID: LintRuleID(rawValue: rule.rawValue),
            severity: .info, message: message,
            evidence: occurrence.quote ?? occurrence.authoredLiteral,
            scope: .passage([occurrence.range]), repairOptions: [])
    }

    private static func pinMissingMessage(occurrence: LintCitationOccurrence) -> String {
        switch occurrence.request {
        case .pinned(let pin):
            return "Version pin @v\(pin.ordinal) is past the end of this source's version "
                + "chain — the citation cannot resolve."
        default:
            return "The requested version does not exist for this source — the citation "
                + "cannot resolve."
        }
    }

    /// The partial/no-match outcome (complete capture only): either an
    /// encoding mismatch with a safe repair, or the honest partial/missing
    /// verdict. The repair is offered ONLY when the whole quote has a
    /// UNIQUE evidence-backed correspondence after projection and the
    /// candidate still resolves through the production reader's search.
    private static func partialOrMissingFinding(
        stepID: LintStepID, id: LintFindingID,
        outcome: WikiQuoteProjection.ComparisonOutcome,
        occurrence: LintCitationOccurrence, record: LintCapturedSourceVersion,
        projected: WikiQuoteProjection.Projection, body: String,
        recipes: LintAnalyzer.RecipeLookup
    ) -> LintFinding {
        // Encoding-only repair gate (requires a complete capture: a prefix
        // correspondence can never back a definitive wording verdict).
        if record.isComplete,
           let (candidate, quoteRange) = encodingRepairCandidate(
            occurrence: occurrence, record: record, projected: projected, body: body) {
            let recipe = recipes.resolve(.citationEncodingFix)
            let fix = Self.individualFix(
                replacing: quoteRange, with: candidate)
            return LintFinding(
                id: id, stepID: stepID,
                ruleID: LintRuleID(rawValue: Rule.encodingRepair.rawValue),
                severity: .warning,
                message: "The quote does not resolve as authored, but an encoding-only fix "
                    + "makes it resolve without changing any wording.",
                evidence: "authored: \(occurrence.quote ?? "") → resolves as: \(candidate)",
                scope: .passage([occurrence.range]),
                repairOptions: recipe.map {
                    [LintRepairOption(
                        id: LintOptionID(rawValue: "cite-fix-\($0.rawValue)"),
                        recipeID: $0, label: "Fix quote encoding")]
                } ?? [],
                builtinFix: fix)
        }

        switch outcome {
        case .partialMatch:
            let run = WikiQuoteProjection.longestPartialRun(
                quote: occurrence.quote ?? "", projected: projected)
            return LintFinding(
                id: id, stepID: stepID,
                ruleID: LintRuleID(rawValue: Rule.quotePartial.rawValue),
                severity: .warning,
                message: "Only part of this quote matches the cited source — the reader "
                    + "will highlight a shorter passage (its fallback), not the whole "
                    + "quote.",
                evidence: run.map { "matched run: \($0)" } ?? nil,
                scope: .passage([occurrence.range]),
                repairOptions: [])
        default:
            return LintFinding(
                id: id, stepID: stepID,
                ruleID: LintRuleID(rawValue: Rule.quoteMissing.rawValue),
                severity: .warning,
                message: "Quote anchor not found in the cited source version — the "
                    + "citation highlight will not resolve. The quoted phrase may have "
                    + "drifted from the source text (e.g. emphasis markup or wording).",
                evidence: occurrence.quote,
                scope: .passage([occurrence.range]),
                repairOptions: [])
        }
    }

    /// Compute the encoding-only repair when the gate passes:
    /// - project the QUOTE itself (a quote carrying markup normalizes to
    ///   its visible text);
    /// - require the whole projected quote to appear EXACTLY ONCE in the
    ///   projected source (unique, evidence-backed correspondence);
    /// - require the candidate to differ from the authored quote and to
    ///   still resolve through the production reader (the reader's search
    ///   view of the candidate is a substring of the source's search view).
    /// - never change wording: the candidate must be the projection of the
    ///   quote itself, character-for-character.
    /// Returns the replacement text and the validated quote range in the
    /// body, or nil when any gate fails.
    static func encodingRepairCandidate(
        occurrence: LintCitationOccurrence,
        record: LintCapturedSourceVersion,
        projected: WikiQuoteProjection.Projection,
        body: String
    ) -> (candidate: String, quoteRange: LintSourceRange)? {
        guard let quote = occurrence.quote, record.text != nil else { return nil }
        guard projected.state == .text else { return nil }
        // The candidate is the quote's own visible text — no rewording.
        let quoteProjections = WikiQuoteProjection.projectInline(quote)
        guard quoteProjections.state == .text else { return nil }
        let candidate = quoteProjections.text
        guard candidate != quote else { return nil } // nothing to fix

        let haystack = WikiQuoteProjection.searchView(projected.text)
        let needle = WikiQuoteProjection.searchView(candidate)
        guard !needle.isEmpty else { return nil }
        // Unique correspondence.
        guard countOccurrences(of: needle, in: haystack) == 1 else { return nil }
        // Production-reader resolution: the reader searches the DOM view;
        // the candidate must be findable there (same view both sides).
        guard haystack.contains(needle) else { return nil }

        // Locate the authored quote's byte range inside the span.
        guard let quoteRange = quoteRange(of: occurrence, in: body) else { return nil }
        return (candidate, quoteRange)
    }

    /// The number of non-overlapping occurrences of `needle` in `haystack`
    /// (both already in the reader's search view).
    private static func countOccurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchStart = haystack.startIndex
        while let found = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            count += 1
            searchStart = found.lowerBound < found.upperBound
                ? found.upperBound
                : haystack.index(after: found.lowerBound)
        }
        return count
    }

    /// The authored quote's validated byte range in the body: the fragment
    /// text (including its `#"` opening and closing quote) inside the span.
    static func quoteRange(
        of occurrence: LintCitationOccurrence, in body: String?
    ) -> LintSourceRange? {
        guard let body else { return nil }
        // Rebuild the fragment literal: `#"` + quote + `"`, as the parser
        // split it out of the authored target.
        guard let quote = occurrence.quote else { return nil }
        let fragmentLiteral = "#\"\(quote)\""
        let span = occurrence.authoredLiteral
        guard let spanRange = span.range(of: fragmentLiteral) else { return nil }
        let lower = occurrence.range.lowerBound + span.utf8.distance(
            from: span.startIndex, to: spanRange.lowerBound)
        let length = span.utf8.distance(from: spanRange.lowerBound, to: spanRange.upperBound)
        guard let expected = slice(utf8Range: lower..<(lower + length), in: body) else {
            return nil
        }
        do {
            return try LintSourceRange(
                lowerBound: lower, upperBound: lower + length,
                expectedText: expected, in: body)
        } catch {
            DebugLog.lint("LintCitationCheck: quote range not locatable at \(lower): \(error)")
            return nil
        }
    }

    private static func slice(utf8Range: Range<Int>, in body: String) -> String? {
        let view = body.utf8
        guard utf8Range.lowerBound >= 0, utf8Range.upperBound <= view.count else { return nil }
        let lower = view.index(view.startIndex, offsetBy: utf8Range.lowerBound)
        let upper = view.index(lower, offsetBy: utf8Range.count)
        return String(decoding: view[lower..<upper], as: UTF8.self)
    }

    /// A validated individual edit for an already-validated range.
    static func individualFix(
        replacing range: LintSourceRange, with newText: String
    ) -> LintIndividualFix {
        LintIndividualFix(range: range, insertText: newText)
    }
}

extension LintAnalyzer.RecipeLookup {
    /// The citation-encoding-fix recipe, when one is configured.
    var citationEncodingFix: LintRecipeID? {
        resolve(LintBuiltinProducer.citationEncodingFix)
    }
}
