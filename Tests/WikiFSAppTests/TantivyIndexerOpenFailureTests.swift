#if os(macOS)
import Foundation
import Testing
@testable import WikiFSSearch

struct TantivyIndexerOpenFailureTests {
    private actor ContentSource: TantivyContentSource {
        let document = TantivyContentSnapshot(
            ulid: "01REOPEN0001",
            kind: .page,
            title: "Persistent Search Entry",
            body: "The index remains available after a failed writer open.",
            updatedAt: Date(),
            versionSum: 1
        )

        func snapshot(ulid: String, kind: TantivyDocumentKind) async throws -> TantivyContentSnapshot? {
            guard ulid == document.ulid, kind == document.kind else { return nil }
            return document
        }

        func allSnapshots() async throws -> [TantivyContentSnapshot] {
            [document]
        }
    }

    @Test func indexCanBeReopenedAfterContendedOpenFails() async throws {
        let indexDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tantivy-open-failure-\(UUID().uuidString)", isDirectory: true)
        // Best-effort cleanup: the reopened writer below may still hold file
        // handles when this runs, and macOS then refuses the directory
        // removal (EPERM). The system temp cleaner owns the leftover; the
        // test's assertions never depend on the removal.
        defer {
            do {
                try FileManager.default.removeItem(at: indexDirectory)
            } catch {
                DebugLog.store(
                    "leftover Tantivy test index at \(indexDirectory.path): \(error)")
            }
        }

        let contentSource = ContentSource()
        try await createIndexAndFailContendedOpen(
            at: indexDirectory,
            contentSource: contentSource
        )

        // Inner scope: release the reopened writer BEFORE the deferred
        // cleanup runs, so the directory is normally removable.
        do {
            let reopenedIndexer = try TantivyIndexer(
                indexDirectory: indexDirectory,
                contentSource: contentSource
            )
            let results = try await reopenedIndexer.search(
                query: "persistent",
                kind: .page,
                limit: 10
            )
            #expect(results.contains { $0.title == "Persistent Search Entry" })
        }
    }

    private func createIndexAndFailContendedOpen(
        at indexDirectory: URL,
        contentSource: ContentSource
    ) async throws {
        let writer = try TantivyIndexer(
            indexDirectory: indexDirectory,
            contentSource: contentSource
        )
        try await writer.rebuild()

        do {
            _ = try TantivyIndexer(indexDirectory: indexDirectory, contentSource: contentSource)
            Issue.record("Expected opening a second Tantivy writer for the same directory to fail")
        } catch {
            // The active writer holds the exclusive lock.
        }

        let liveResults = try await writer.search(query: "persistent", kind: .page, limit: 10)
        #expect(liveResults.contains { $0.title == "Persistent Search Entry" })
    }
}
#endif
