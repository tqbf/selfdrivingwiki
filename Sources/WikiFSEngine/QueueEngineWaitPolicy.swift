import Foundation
import WikiFSCore
import WikiFSTypes

/// Named wait deadlines for the queue engine's bounded waits.
///
/// All waits that ride ``QueueEngineDeadlineSource`` are bounded by named
/// policies here so a deadline and its rationale have exactly one home.
public enum QueueEngineWaitPolicy: Sendable {
    /// Upper bound for `QueueEngine.waitForCompletion(of:)` — 35 minutes,
    /// derived from the host ceiling with margin.
    ///
    /// `ExtractorHostLimits.maximumDurationMilliseconds` caps an extraction
    /// manifest at 30 minutes, and packages legitimately declare the FULL 30
    /// minutes (Pdf2md and DoclingServe do; only Zotero and
    /// YouTubeTranscript declare 10 minutes). Per-worker lease deadlines are
    /// derived from that same manifest field (`ProcessExtractorProvider`'s
    /// `deadlineMillisecondsSince1970`), so a 30-minute run is an EXPECTED
    /// case, not an anomaly — the completion-wait bound must therefore sit
    /// strictly above the ceiling. `QueueEngineBoundedWaitTests` asserts the
    /// ordering so the two constants cannot drift apart silently.
    public static let completionWaitDeadline: Duration = .seconds(35 * 60)
}

/// Typed failure for a bounded `waitForCompletion` wait.
public enum QueueEngineCompletionWaitError: Error, Equatable, Sendable {
    /// The worker did not settle within
    /// ``QueueEngineWaitPolicy/completionWaitDeadline``. The item is left
    /// untouched (still running) — the WAIT is bounded, not the work; a
    /// later `waitForCompletion` observes the item's real outcome.
    case timeout(itemID: QueueItem.ID)
}
