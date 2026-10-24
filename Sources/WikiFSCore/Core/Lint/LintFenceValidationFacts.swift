import Foundation
import WikiFSMarkdown

/// Package-validation facts for the rich-fence re-validation check (D28),
/// resolved OUTSIDE the pure scan and injected per fence. Outcomes mirror the
/// validation service's detailed API: a fence either validated, failed
/// validation (with the format's own errors), is unclaimed by any installed
/// package, is suppressed (safe mode), or validation was unavailable — an
/// unavailable check is recorded as a limit, never as a pass.
public struct LintFenceValidationFacts: Equatable, Sendable {

    public enum Outcome: Equatable, Sendable {
        /// The claiming package's engine accepted every claimed block.
        case validated
        /// At least one block failed the package's validation.
        case invalid(errors: [String])
        /// No installed renderer package declares this rich-fence format.
        case unclaimed
        /// A package declares the format but validation is suppressed
        /// (safe mode) — the same way rendering falls back.
        case suppressed
        /// Validation could not run (store or engine unavailable).
        case unavailable(reason: String)
    }

    /// Outcome per rich fence, keyed by the fence's 0-based index in the
    /// scan's `fenceFacts` (only fences whose info string parses as a rich
    /// alias carry an entry).
    public var outcomesByFenceIndex: [Int: Outcome] = [:]

    public init() {}

    public func outcome(fenceIndex: Int) -> Outcome? {
        outcomesByFenceIndex[fenceIndex]
    }

    /// Resolve validation facts for `body`'s fences through the package-driven
    /// validation service. Fences whose info string is an ordinary
    /// programming-language label get no entry (they are not rich fences).
    public static func load(
        body: String,
        fenceFacts: [MarkdownFenceFact],
        service: FenceSyntaxValidationService
    ) async -> LintFenceValidationFacts {
        var facts = LintFenceValidationFacts()
        let detailed = await service.detailedFenceValidation(for: body)
        for (index, fence) in fenceFacts.enumerated() {
            guard case .rich(let info) = MarkdownFenceInfo.parse(fence.infoString) else { continue }
            guard detailed.unavailabilityReason == nil else {
                facts.outcomesByFenceIndex[index] = .unavailable(reason: detailed.unavailabilityReason ?? "unavailable")
                continue
            }
            switch detailed.aliases[info.alias] {
            case .validated: facts.outcomesByFenceIndex[index] = .validated
            case .invalid(let blockErrors):
                // The fence fact's block is the alias's Nth claimed block in
                // document order — count preceding claimed blocks of the same
                // alias to find this fence's block index.
                let blockIndex = claimedBlockOrdinal(ofFence: index, fenceFacts: fenceFacts)
                let errors = blockErrors[blockIndex] ?? blockErrors.values.flatMap { $0 }
                facts.outcomesByFenceIndex[index] = .invalid(errors: errors)
            case .unclaimed: facts.outcomesByFenceIndex[index] = .unclaimed
            case .suppressed: facts.outcomesByFenceIndex[index] = .suppressed
            case .unavailable(let reason):
                facts.outcomesByFenceIndex[index] = .unavailable(reason: reason)
            case nil: facts.outcomesByFenceIndex[index] = .unclaimed
            }
        }
        return facts
    }

    /// The 0-based ordinal of the fence at `index` among the rich fences that
    /// share its alias — matching the validator's per-alias block order.
    static func claimedBlockOrdinal(ofFence index: Int, fenceFacts: [MarkdownFenceFact]) -> Int {
        guard fenceFacts.indices.contains(index),
              case .rich(let info) = MarkdownFenceInfo.parse(fenceFacts[index].infoString) else {
            return 0
        }
        var ordinal = 0
        for (candidate, other) in fenceFacts.enumerated() where candidate < index {
            if case .rich(let otherInfo) = MarkdownFenceInfo.parse(other.infoString),
               otherInfo.alias == info.alias {
                ordinal += 1
            }
        }
        return ordinal
    }
}
