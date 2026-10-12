import Foundation
import Testing
@testable import WikiFSCore

/// Tests for `ProjectionDriftCheck` — the pure "what's missing on disk?"
/// arithmetic behind the File Provider reimport recovery
/// (`FileProviderFacade.verifyProjection`). The side effects (listing the
/// mount, calling `reimportItems`) live in the app layer and aren't
/// unit-testable; this is the extracted, tested seam.
struct ProjectionDriftCheckTests {

    private func page(_ id: String, _ title: String) -> ProjectionDriftCheck.ExpectedPage {
        ProjectionDriftCheck.ExpectedPage(id: PageID(rawValue: id), title: title)
    }

    @Test func noDriftWhenEverythingIsOnDisk() {
        let pages = [page("01AAAAAAAAAAAAAAAAAAAAAAAA", "Home"), page("01BBBBBBBBBBBBBBBBBBBBBBBB", "About")]
        let result = ProjectionDriftCheck.check(
            expectedPages: pages,
            onDiskByID: Set(pages.map { FilenameEscaping.byIDFilename(pageID: $0.id.rawValue) }),
            onDiskByTitle: Set(pages.map { FilenameEscaping.byTitleFilename(title: $0.title, pageID: $0.id.rawValue) }))

        #expect(!result.isDrifted)
        #expect(result.missingByID.isEmpty)
        #expect(result.missingByTitle.isEmpty)
    }

    @Test func emptyExpectedPagesNeverDrifts() {
        let result = ProjectionDriftCheck.check(expectedPages: [], onDiskByID: [], onDiskByTitle: [])
        #expect(!result.isDrifted)
    }

    @Test func missingFromByIDOnlyIsStillDrifted() {
        let home = page("01AAAAAAAAAAAAAAAAAAAAAAAA", "Home")
        let result = ProjectionDriftCheck.check(
            expectedPages: [home],
            onDiskByID: [],
            onDiskByTitle: [FilenameEscaping.byTitleFilename(title: home.title, pageID: home.id.rawValue)])

        #expect(result.isDrifted)
        #expect(result.missingByID == [FilenameEscaping.byIDFilename(pageID: home.id.rawValue)])
        #expect(result.missingByTitle.isEmpty)
    }

    @Test func missingFromByTitleOnlyIsStillDrifted() {
        let home = page("01AAAAAAAAAAAAAAAAAAAAAAAA", "Home")
        let result = ProjectionDriftCheck.check(
            expectedPages: [home],
            onDiskByID: [FilenameEscaping.byIDFilename(pageID: home.id.rawValue)],
            onDiskByTitle: [])

        #expect(result.isDrifted)
        #expect(result.missingByID.isEmpty)
        #expect(result.missingByTitle == [FilenameEscaping.byTitleFilename(title: home.title, pageID: home.id.rawValue)])
    }

    @Test func onlySomePagesMissingReportsOnlyThose() {
        let home = page("01AAAAAAAAAAAAAAAAAAAAAAAA", "Home")
        let about = page("01BBBBBBBBBBBBBBBBBBBBBBBB", "About")
        let result = ProjectionDriftCheck.check(
            expectedPages: [home, about],
            onDiskByID: [FilenameEscaping.byIDFilename(pageID: home.id.rawValue)],
            onDiskByTitle: [FilenameEscaping.byTitleFilename(title: home.title, pageID: home.id.rawValue)])

        #expect(result.isDrifted)
        #expect(result.missingByID == [FilenameEscaping.byIDFilename(pageID: about.id.rawValue)])
        #expect(result.missingByTitle == [FilenameEscaping.byTitleFilename(title: about.title, pageID: about.id.rawValue)])
        #expect(result.missingByIDCount == 1)
        #expect(result.missingByTitleCount == 1)
    }

    /// Extra on-disk files (stray leftovers, in-flight deletions) are never
    /// evidence of drift — only ABSENCE of an expected file is.
    @Test func extraOnDiskFilesAreIgnored() {
        let home = page("01AAAAAAAAAAAAAAAAAAAAAAAA", "Home")
        let result = ProjectionDriftCheck.check(
            expectedPages: [home],
            onDiskByID: [
                FilenameEscaping.byIDFilename(pageID: home.id.rawValue),
                "01ZZZZZZZZZZZZZZZZZZZZZZZZ.md",
            ],
            onDiskByTitle: [
                FilenameEscaping.byTitleFilename(title: home.title, pageID: home.id.rawValue),
                "Stale Leftover--01ZZZZZZ.md",
            ])

        #expect(!result.isDrifted)
    }

    @Test func resultOrderFollowsExpectedPagesOrder() {
        let home = page("01AAAAAAAAAAAAAAAAAAAAAAAA", "Home")
        let about = page("01BBBBBBBBBBBBBBBBBBBBBBBB", "About")
        let result = ProjectionDriftCheck.check(expectedPages: [about, home], onDiskByID: [], onDiskByTitle: [])

        #expect(result.missingByID == [
            FilenameEscaping.byIDFilename(pageID: about.id.rawValue),
            FilenameEscaping.byIDFilename(pageID: home.id.rawValue),
        ])
    }
}
