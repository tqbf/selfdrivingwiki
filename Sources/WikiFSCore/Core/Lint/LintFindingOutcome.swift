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

    public var requiresReason: Bool {
        switch self {
        case .repaired: return false
        case .validAsWritten, .unresolved, .outsideLintScope, .checkBlocked: return true
        }
    }
}
