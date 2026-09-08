import Foundation
import WikiFSCore

/// Window-local filters never change scheduler order or execution scope.
struct QueueJobFilter: Equatable {
    enum Operation: String, CaseIterable, Identifiable {
        case ingestion = "Ingestion"
        case extraction = "Extraction"
        case lint = "Lint"
        var id: Self { self }

        init(item: QueueItem) {
            if item.payload.lintPageIDs != nil {
                self = .lint
            } else {
                switch item.queue {
                case .ingestion: self = .ingestion
                case .extraction, .transcription: self = .extraction
                }
            }
        }
    }

    var search = ""
    var state: QueueItemState?
    var wikiID: WikiID?
    var operation: Operation?

    var isActive: Bool {
        !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || state != nil || wikiID != nil || operation != nil
    }

    var allowsReordering: Bool { !isActive }

    func includes(_ item: QueueItem, searchText: String) -> Bool {
        if let state, item.state != state { return false }
        if let wikiID, item.wikiID != wikiID { return false }
        if let operation, Operation(item: item) != operation { return false }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || searchText.localizedStandardContains(query)
    }
}
