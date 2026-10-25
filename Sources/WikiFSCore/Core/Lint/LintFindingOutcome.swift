import Foundation

/// The outcome the audit assigns to one finding or inventoried item
/// (requirements §2.4). Exactly one outcome per item; an unresolved finding
/// or blocked check prevents a claim that the page passed every check.
public enum LintFindingOutcome: Equatable, Sendable {
    /// A confirmed defect has a verified repair, applied as a hunk with its
    /// defect class.
    case repaired
    /// Context establishes that the candidate is intentional or supported.
    case validAsWritten(reason: String)
    /// A defect or concern remains because evidence or a safe repair is
    /// unavailable.
    case unresolved(reason: String)
    /// The concern belongs to strategy or another operation.
    case outsideLintScope(reason: String)
    /// The agent could not complete a required check.
    case checkBlocked(reason: String)
    /// The run-report skeleton's own unfilled placeholder. It PARSES (the
    /// prompt seeds `pending` lines and instructs the agent to replace them,
    /// so the seeded template must not be a parse error) but it never counts
    /// as a completed outcome: the coverage validator rejects every `pending`
    /// row as unfilled.
    case pending

    public var requiresReason: Bool {
        switch self {
        case .repaired, .pending: return false
        case .validAsWritten, .unresolved, .outsideLintScope, .checkBlocked: return true
        }
    }
}
