#if os(macOS)
import Testing
import WikiFSCore
@testable import WikiFS

/// Unit tests for `OperationNotifier.summary(for:outcome:)` — the pure
/// function that computes the macOS notification title + body from a terminal
/// `QueueItem`.  The `OperationNotifier` class itself (UNUserNotificationCenter
/// wiring, event-stream consumption) is AppKit-coupled and not unit-tested here.
@Suite struct OperationNotifierSummaryTests {

    // MARK: - Helpers

    /// Build a queue item with the given parameters.
    private func makeItem(
        queue: QueueKind,
        sourceIDs: [PageID] = [],
        lintPageIDs: [PageID]? = nil
    ) -> QueueItem {
        QueueItem(
            id: "TESTITEM001",
            queue: queue,
            wikiID: "wiki1",
            payload: QueueItemPayload(
                sourceIDs: sourceIDs,
                lintPageIDs: lintPageIDs),
            state: .completed,
            orderingKey: 1000,
            providerID: "provider-A",
            attempt: 0,
            error: nil,
            createdAt: 1000,
            startedAt: 2000,
            finishedAt: 5000
        )
    }

    // MARK: - operationKind

    @Test func kindExtraction() {
        let item = makeItem(queue: .extraction, sourceIDs: [.init(rawValue: "S1"), .init(rawValue: "S2")])
        let kind = OperationNotifier.operationKind(for: item)
        #expect(kind == .extraction(sourceCount: 2))
    }

    @Test func kindIngestion() {
        let item = makeItem(queue: .ingestion, sourceIDs: [.init(rawValue: "S1")])
        let kind = OperationNotifier.operationKind(for: item)
        #expect(kind == .ingestion(sourceCount: 1))
    }

    @Test func kindLintSpecificPages() {
        let item = makeItem(
            queue: .ingestion,
            lintPageIDs: [.init(rawValue: "P1"), .init(rawValue: "P2"), .init(rawValue: "P3")])
        let kind = OperationNotifier.operationKind(for: item)
        #expect(kind == .lint(pageCount: 3))
    }

    @Test func kindLintWholeWiki() {
        // Empty lintPageIDs array = whole-wiki lint → pageCount is nil.
        let item = makeItem(queue: .ingestion, lintPageIDs: [])
        let kind = OperationNotifier.operationKind(for: item)
        #expect(kind == .lint(pageCount: nil))
    }

    @Test func kindTranscription() {
        let item = makeItem(queue: .transcription, sourceIDs: [.init(rawValue: "S1"), .init(rawValue: "S2")])
        let kind = OperationNotifier.operationKind(for: item)
        #expect(kind == .transcription(sourceCount: 2))
    }

    // MARK: - Completed summaries

    @Test func completedExtraction() {
        let item = makeItem(queue: .extraction, sourceIDs: [.init(rawValue: "S1"), .init(rawValue: "S2"), .init(rawValue: "S3")])
        let s = OperationNotifier.summary(for: item, outcome: .completed)
        #expect(s?.title == "Extraction Complete")
        #expect(s?.body == "3 files processed")
    }

    @Test func completedExtractionSingle() {
        let item = makeItem(queue: .extraction, sourceIDs: [.init(rawValue: "S1")])
        let s = OperationNotifier.summary(for: item, outcome: .completed)
        #expect(s?.body == "1 file processed")
    }

    @Test func completedIngestion() {
        let item = makeItem(queue: .ingestion, sourceIDs: [.init(rawValue: "S1"), .init(rawValue: "S2")])
        let s = OperationNotifier.summary(for: item, outcome: .completed)
        #expect(s?.title == "Ingestion Complete")
        #expect(s?.body == "2 sources ingested")
    }

    @Test func completedIngestionSingle() {
        let item = makeItem(queue: .ingestion, sourceIDs: [.init(rawValue: "S1")])
        let s = OperationNotifier.summary(for: item, outcome: .completed)
        #expect(s?.body == "1 source ingested")
    }

    @Test func completedLintSpecificPages() {
        let item = makeItem(queue: .ingestion, lintPageIDs: [.init(rawValue: "P1"), .init(rawValue: "P2")])
        let s = OperationNotifier.summary(for: item, outcome: .completed)
        #expect(s?.title == "Lint Complete")
        #expect(s?.body == "2 pages linted")
    }

    @Test func completedLintSinglePage() {
        let item = makeItem(queue: .ingestion, lintPageIDs: [.init(rawValue: "P1")])
        let s = OperationNotifier.summary(for: item, outcome: .completed)
        #expect(s?.body == "1 page linted")
    }

    @Test func completedLintWholeWiki() {
        let item = makeItem(queue: .ingestion, lintPageIDs: [])
        let s = OperationNotifier.summary(for: item, outcome: .completed)
        #expect(s?.title == "Lint Complete")
        #expect(s?.body == "All pages linted")
    }

    @Test func completedTranscription() {
        let item = makeItem(queue: .transcription, sourceIDs: [.init(rawValue: "S1"), .init(rawValue: "S2")])
        let s = OperationNotifier.summary(for: item, outcome: .completed)
        #expect(s?.title == "Transcription Complete")
        #expect(s?.body == "2 transcripts fetched")
    }

    @Test func completedTranscriptionSingle() {
        let item = makeItem(queue: .transcription, sourceIDs: [.init(rawValue: "S1")])
        let s = OperationNotifier.summary(for: item, outcome: .completed)
        #expect(s?.body == "1 transcript fetched")
    }

    // MARK: - Failed summaries

    @Test func failedExtraction() {
        let item = makeItem(queue: .extraction, sourceIDs: [.init(rawValue: "S1")])
        let s = OperationNotifier.summary(for: item, outcome: .failed("Connection refused"))
        #expect(s?.title == "Extraction Failed")
        #expect(s?.body == "1 file: Connection refused")
    }

    @Test func failedIngestion() {
        let item = makeItem(queue: .ingestion, sourceIDs: [.init(rawValue: "S1"), .init(rawValue: "S2")])
        let s = OperationNotifier.summary(for: item, outcome: .failed("Timeout"))
        #expect(s?.title == "Ingestion Failed")
        #expect(s?.body == "2 sources: Timeout")
    }

    @Test func failedLintSpecificPages() {
        let item = makeItem(queue: .ingestion, lintPageIDs: [.init(rawValue: "P1"), .init(rawValue: "P2"), .init(rawValue: "P3")])
        let s = OperationNotifier.summary(for: item, outcome: .failed("Syntax error"))
        #expect(s?.title == "Lint Failed")
        #expect(s?.body == "3 pages: Syntax error")
    }

    @Test func failedLintWholeWiki() {
        let item = makeItem(queue: .ingestion, lintPageIDs: [])
        let s = OperationNotifier.summary(for: item, outcome: .failed("Agent crashed"))
        #expect(s?.title == "Lint Failed")
        #expect(s?.body == "Wiki-wide lint: Agent crashed")
    }

    @Test func failedTranscription() {
        let item = makeItem(queue: .transcription, sourceIDs: [.init(rawValue: "S1")])
        let s = OperationNotifier.summary(for: item, outcome: .failed("No captions"))
        #expect(s?.title == "Transcription Failed")
        #expect(s?.body == "1 transcript: No captions")
    }

    @Test func failedEmptyErrorFallsBackToUnknown() {
        let item = makeItem(queue: .extraction, sourceIDs: [.init(rawValue: "S1")])
        let s = OperationNotifier.summary(for: item, outcome: .failed("   "))
        #expect(s?.body == "1 file: Unknown error")
    }

    @Test func failedLongErrorIsTruncated() {
        let item = makeItem(queue: .ingestion, sourceIDs: [.init(rawValue: "S1")])
        let longError = String(repeating: "x", count: 300)
        let s = OperationNotifier.summary(for: item, outcome: .failed(longError))
        #expect(s != nil)
        // Body = "1 source: " + 180 chars + "…"  (U+2026 is one character)
        let expectedPrefix = String(repeating: "x", count: 180)
        #expect(s?.body == "1 source: \(expectedPrefix)\u{2026}")
        #expect(s?.body.count ?? 0 < longError.count + 20)
    }

    // MARK: - Cancelled summaries (not posted today, but tested for completeness)

    @Test func cancelledExtraction() {
        let item = makeItem(queue: .extraction, sourceIDs: [.init(rawValue: "S1"), .init(rawValue: "S2")])
        let s = OperationNotifier.summary(for: item, outcome: .cancelled)
        #expect(s?.title == "Extraction Cancelled")
        #expect(s?.body == "2 files \u{2014} cancelled")
    }

    @Test func cancelledIngestionSingle() {
        let item = makeItem(queue: .ingestion, sourceIDs: [.init(rawValue: "S1")])
        let s = OperationNotifier.summary(for: item, outcome: .cancelled)
        #expect(s?.title == "Ingestion Cancelled")
        #expect(s?.body == "1 source \u{2014} cancelled")
    }

    @Test func cancelledLintWholeWiki() {
        let item = makeItem(queue: .ingestion, lintPageIDs: [])
        let s = OperationNotifier.summary(for: item, outcome: .cancelled)
        #expect(s?.title == "Lint Cancelled")
        #expect(s?.body == "Wiki-wide lint \u{2014} cancelled")
    }

    @Test func cancelledTranscription() {
        let item = makeItem(queue: .transcription, sourceIDs: [.init(rawValue: "S1"), .init(rawValue: "S2")])
        let s = OperationNotifier.summary(for: item, outcome: .cancelled)
        #expect(s?.title == "Transcription Cancelled")
        #expect(s?.body == "2 transcripts \u{2014} cancelled")
    }

    // MARK: - Outcome identifier

    @Test func outcomeIdentifiers() {
        #expect(OperationNotifier.TerminalOutcome.completed.identifier == "completed")
        #expect(OperationNotifier.TerminalOutcome.failed("err").identifier == "failed")
        #expect(OperationNotifier.TerminalOutcome.cancelled.identifier == "cancelled")
    }

    // MARK: - Pluralization edge cases

    @Test func zeroSourcesCompleted() {
        let item = makeItem(queue: .extraction, sourceIDs: [])
        let s = OperationNotifier.summary(for: item, outcome: .completed)
        #expect(s?.body == "0 files processed")
    }

    @Test func zeroSourcesFailed() {
        let item = makeItem(queue: .ingestion, sourceIDs: [])
        let s = OperationNotifier.summary(for: item, outcome: .failed("oops"))
        #expect(s?.body == "0 sources: oops")
    }
}
#endif
