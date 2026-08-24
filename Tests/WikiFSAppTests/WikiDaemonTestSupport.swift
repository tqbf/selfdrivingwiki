#if os(macOS)
import Foundation
@testable import WikiFSCore
@testable import wikid

extension WikiDaemon {
    convenience init(containerDirectory: URL) {
        self.init(
            containerDirectory: containerDirectory,
            makeStore: { try GRDBWikiStore(databaseURL: $0) })
    }
}
#endif
