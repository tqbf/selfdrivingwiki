import Foundation

/// The typed fetch lifecycle of one source acquired by a fetcher package.
/// Stored on the source row (`sources.fetch_state`); `nil` means the source
/// was never a fetch target.
///
/// - `pending`: the byteless source exists with its acquisition plan; no
///   fetch has succeeded yet. A failed or empty fetch stays here so the
///   normal queue retry path can run the fetch again.
/// - `formatJobPending`: the acquired bytes are persisted and the follow-on
///   format extraction still owes a run. Written in the SAME wiki-store
///   transaction as the acquired blob, so a crash can never strand the bytes
///   without the marker the queue startup recovery scan reads.
/// - `complete`: the pipeline finished — either the fetch returned Markdown
///   (marked complete in the same transaction as the derived version) or the
///   deduped format job completed.
public enum SourceFetchState: String, Codable, Hashable, Sendable, CaseIterable {
    case pending
    case formatJobPending = "formatJobPending"
    case complete
}
