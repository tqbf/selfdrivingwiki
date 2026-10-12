import Foundation

/// Pure comparison between the DB's page list and what the File Provider
/// projection actually shows on disk, under `pages/by-id` and `pages/by-title`.
///
/// Background: `fileproviderd` can get individual items permanently stuck —
/// the extension keeps reporting the same item version, the daemon never
/// retries, and the mount silently drops behind the DB (see
/// `FileProviderFacade.verifyProjection`, which drives this check and calls
/// `reimportItems(below:)` to recover). This type owns only the pure
/// "what's missing?" arithmetic; the app layer owns listing the mount and
/// calling the recovery API — mirrors `DomainRegistrationPolicy`.
///
/// Filenames are derived via `FilenameEscaping` so the expected names can
/// never drift from what the projection actually writes. Extra on-disk files
/// (e.g. a page deleted moments ago whose file hasn't been removed yet) are
/// deliberately ignored — deletions propagate through a separate path and a
/// stray extra file is not evidence of a stuck import.
public enum ProjectionDriftCheck {
    /// The minimal page identity the check needs: enough to compute both
    /// projected filenames.
    public struct ExpectedPage: Sendable {
        public let id: PageID
        public let title: String

        public init(id: PageID, title: String) {
            self.id = id
            self.title = title
        }
    }

    /// The filenames the DB expects to see that are missing from each view.
    public struct Result: Sendable, Equatable {
        public let missingByID: [String]
        public let missingByTitle: [String]

        public init(missingByID: [String], missingByTitle: [String]) {
            self.missingByID = missingByID
            self.missingByTitle = missingByTitle
        }

        /// True when either view is missing at least one expected page.
        public var isDrifted: Bool { !missingByID.isEmpty || !missingByTitle.isEmpty }
        public var missingByIDCount: Int { missingByID.count }
        public var missingByTitleCount: Int { missingByTitle.count }
    }

    /// Compare `expectedPages` against the filenames actually listed under
    /// `pages/by-id` and `pages/by-title`, and report which expected
    /// filenames are absent from each. Order of `missingByID`/`missingByTitle`
    /// follows `expectedPages`.
    public static func check(
        expectedPages: [ExpectedPage],
        onDiskByID: Set<String>,
        onDiskByTitle: Set<String>
    ) -> Result {
        var missingByID: [String] = []
        var missingByTitle: [String] = []
        for page in expectedPages {
            let idFilename = FilenameEscaping.byIDFilename(pageID: page.id.rawValue)
            if !onDiskByID.contains(idFilename) {
                missingByID.append(idFilename)
            }
            let titleFilename = FilenameEscaping.byTitleFilename(title: page.title, pageID: page.id.rawValue)
            if !onDiskByTitle.contains(titleFilename) {
                missingByTitle.append(titleFilename)
            }
        }
        return Result(missingByID: missingByID, missingByTitle: missingByTitle)
    }
}
