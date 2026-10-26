import Foundation
import WikiFSCore

/// One finding row's identity in Run Details: the page plus the finding's
/// stable occurrence id. Keys the Activity window's click-local fix state.
struct QueueLintFindingKey: Hashable, Sendable {
    let pageID: PageID
    let findingID: String
}
