import Foundation

// MARK: - Lint identifiers

/// One foreground lint run. Fresh per sheet run; rejects late results after
/// cancellation, dismissal, or rerun.
public struct LintRunID: Hashable, Codable, RawRepresentable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID().uuidString }
}

/// A check or repair pipeline step's id from the configuration file.
public struct LintStepID: Hashable, Codable, RawRepresentable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// A deterministic rule id (built-in check or markdownlint rule, e.g. "MD009").
public struct LintRuleID: Hashable, Codable, RawRepresentable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// A named repair recipe from the configuration file.
public struct LintRecipeID: Hashable, Codable, RawRepresentable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// One user-selectable repair choice on a finding.
public struct LintOptionID: Hashable, Codable, RawRepresentable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// One finding within one run.
public struct LintFindingID: Hashable, Codable, RawRepresentable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

// MARK: - Severity

/// How much attention a finding deserves. Display-ordered.
public enum LintSeverity: String, Codable, Comparable, Sendable {
    case info
    case warning
    case error

    private var rank: Int {
        switch self {
        case .info: 0
        case .warning: 1
        case .error: 2
        }
    }
    public static func < (lhs: LintSeverity, rhs: LintSeverity) -> Bool {
        lhs.rank < rhs.rank
    }
}

// MARK: - Source ranges

/// One validated half-open UTF-8 byte range in the captured page body, paired
/// with the exact text the range must decode to. Construction validates
/// bounds, UTF-8 scalar boundaries, and the expected bytes against the body,
/// so a stored instance always addresses real text in its snapshot.
public struct LintSourceRange: Hashable, Sendable {
    /// Half-open lower bound, in UTF-8 bytes from the body's start.
    public let lowerBound: Int
    /// Half-open upper bound, in UTF-8 bytes from the body's start.
    public let upperBound: Int
    /// The exact body text this range is expected to address. Always present;
    /// validated at construction.
    public let expectedText: String

    /// Validate and construct a range over `body`. Zero-width ranges
    /// (insertion points) are legal.
    public init(lowerBound: Int, upperBound: Int, expectedText: String, in body: String) throws {
        try LintLocationAdapter.validateRange(
            lowerBound..<upperBound, expectedText: expectedText, in: body)
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.expectedText = expectedText
    }

    /// Re-validate this stored range against a (possibly different) body.
    public func isValid(in body: String) -> Bool {
        do {
            try LintLocationAdapter.validateRange(bounds, expectedText: expectedText, in: body)
            return true
        } catch {
            return false
        }
    }

    /// The raw half-open byte interval (the external JSON boundary shape).
    public var bounds: Range<Int> { lowerBound..<upperBound }
}

// MARK: - Finding scope

/// Where a finding applies. Page findings address the document as a whole
/// (consistency, contradictions); passage findings anchor to one or more
/// validated source ranges.
public enum LintFindingScope: Hashable, Sendable {
    /// The whole page. No text highlight is fabricated for it.
    case page
    /// One or more validated passage ranges in the captured body.
    case passage([LintSourceRange])
}

// MARK: - Repair options

/// A user-selectable repair a finding offers. `recipeID` names the configured
/// repair recipe that runs when the user picks this option; nothing else may
/// produce a proposal for it.
public struct LintRepairOption: Hashable, Sendable, Identifiable {
    public let id: LintOptionID
    public let recipeID: LintRecipeID
    /// User-facing choice label, e.g. "Fix bracket syntax".
    public let label: String

    public init(id: LintOptionID, recipeID: LintRecipeID, label: String) {
        self.id = id
        self.recipeID = recipeID
        self.label = label
    }
}

// MARK: - Typed individual fix

/// The validated individual edit one deterministic rule attaches to a finding.
/// The `cosmetic-individual-fix` producer converts this into a proposal
/// replacement — the all-fixes API is never used for selected repairs.
public struct LintIndividualFix: Hashable, Sendable {
    /// The byte range in the captured body the edit applies to. For a pure
    /// insert this is a zero-width range (expectedText is empty); for a
    /// delete or replace it carries the exact text removed.
    public let range: LintSourceRange
    /// The text inserted at the range ("" for a pure delete).
    public let insertText: String

    public init(range: LintSourceRange, insertText: String) {
        self.range = range
        self.insertText = insertText
    }

    /// The proposal replacement this fix produces (delete → empty newText).
    public var replacement: LintSourceReplacement {
        LintSourceReplacement(range: range, newText: insertText)
    }
}

// MARK: - Finding

/// One lint finding from one check step. Model observations are suggestions —
/// repair generation and Apply still validate everything a proposal claims.
public struct LintFinding: Hashable, Sendable, Identifiable {
    public let id: LintFindingID
    /// The check step that produced this finding (shown in the UI).
    public let stepID: LintStepID
    /// The deterministic rule when one applies (built-in / markdownlint).
    public let ruleID: LintRuleID?
    public let severity: LintSeverity
    /// Concise human-readable message.
    public let message: String
    /// Supporting evidence shown under the message (model quote, rule detail).
    public let evidence: String?
    public let scope: LintFindingScope
    /// Repair choices offered for this finding. Empty = report-only.
    public let repairOptions: [LintRepairOption]
    /// The validated individual edit when the finding's rule carries one.
    public let builtinFix: LintIndividualFix?

    public init(
        id: LintFindingID,
        stepID: LintStepID,
        ruleID: LintRuleID?,
        severity: LintSeverity,
        message: String,
        evidence: String?,
        scope: LintFindingScope,
        repairOptions: [LintRepairOption],
        builtinFix: LintIndividualFix? = nil
    ) {
        self.id = id
        self.stepID = stepID
        self.ruleID = ruleID
        self.severity = severity
        self.message = message
        self.evidence = evidence
        self.scope = scope
        self.repairOptions = repairOptions
        self.builtinFix = builtinFix
    }

    /// True when the scope carries validated passage ranges.
    public var passageRanges: [LintSourceRange] {
        if case .passage(let ranges) = scope { return ranges }
        return []
    }
}
