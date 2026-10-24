import Foundation
import WikiFSTypes

/// Store-derived facts for the history-regression check (D27): the ACTUAL
/// parent version of the inspected head and its body bytes. A first version
/// has nothing to compare; a failed read is carried as `readFailed` so the
/// section renders blocked instead of clean (REQ-43).
public struct LintHistoryFacts: Equatable, Sendable {

    public enum Availability: Equatable, Sendable {
        /// The inspected head is the page's root version — nothing to compare.
        case firstVersion
        /// The head's recorded parent version and its exact body.
        case parentAvailable(parentVersionID: PageVersionID, parentBody: String)
        /// The chain or the parent body could not be read.
        case readFailed(reason: String)
    }

    public let availability: Availability

    public init(availability: Availability) {
        self.availability = availability
    }

    /// Load the parent facts for one snapshot's inspected head. Non-throwing:
    /// read failures become `readFailed` so the scan can report them.
    public static func load(from store: WikiStore, snapshot: LintPageSnapshot) -> LintHistoryFacts {
        guard let head = snapshot.headVersionID else {
            return LintHistoryFacts(availability: .firstVersion)
        }
        do {
            let history = try store.pageVersionHistory(pageID: snapshot.pageID)
            guard let summary = history.first(where: { $0.id == head }) else {
                return LintHistoryFacts(availability: .readFailed(
                    reason: "the inspected head is absent from the page's version chain"))
            }
            guard let parentID = summary.parentID else {
                return LintHistoryFacts(availability: .firstVersion)
            }
            guard let parentBody = try store.pageVersionBody(versionID: parentID) else {
                return LintHistoryFacts(availability: .readFailed(
                    reason: "the parent version's body is unavailable"))
            }
            return LintHistoryFacts(availability: .parentAvailable(
                parentVersionID: parentID, parentBody: parentBody))
        } catch {
            return LintHistoryFacts(availability: .readFailed(reason: "\(error)"))
        }
    }
}
