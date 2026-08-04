import Testing
@testable import WikiFSCore

/// Locks the pure progress-message contract for the repository reader
/// fan-out. The daemon emits these from the parent task-group completion loop
/// — never from child tasks — so the helper must be deterministic and free of
/// side effects.
struct ReaderFanoutProgressTests {
    @Test func startMessageShowsZeroOfTotal() {
        let message = ReaderFanoutProgress.start(repositoryName: "swift-markdown", total: 3)

        #expect(message == "Reading swift-markdown with 3 readers (0/3)…")
    }

    @Test func readerCompletedMessageShowsCountOfTotal() {
        let message = ReaderFanoutProgress.readerCompleted(
            repositoryName: "swift-markdown", completed: 2, total: 5)

        #expect(message == "Reading swift-markdown with 5 readers (2/5)…")
    }

    @Test func readerCompletedAtFullCountStillShowsIntermediate() {
        let message = ReaderFanoutProgress.readerCompleted(
            repositoryName: "swift-markdown", completed: 5, total: 5)

        #expect(message == "Reading swift-markdown with 5 readers (5/5)…")
    }

    @Test func curatorHandoffMessageAnnouncesCurator() {
        let message = ReaderFanoutProgress.curatorHandoff(
            repositoryName: "swift-markdown", total: 19)

        #expect(message == "All 19 readers finished for swift-markdown, starting curator…")
    }

    @Test func startWithSingleReaderStillFormats() {
        let message = ReaderFanoutProgress.start(repositoryName: "mono", total: 2)

        #expect(message == "Reading mono with 2 readers (0/2)…")
    }

    @Test func allMessagesIncludeRepositoryName() {
        let name = "my-repo"
        #expect(ReaderFanoutProgress.start(repositoryName: name, total: 3).contains(name))
        #expect(ReaderFanoutProgress.readerCompleted(repositoryName: name, completed: 1, total: 3).contains(name))
        #expect(ReaderFanoutProgress.curatorHandoff(repositoryName: name, total: 3).contains(name))
    }
}
