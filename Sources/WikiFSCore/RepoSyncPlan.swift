import Foundation

/// The app-side decision of WHETHER and HOW to run a repo ingest — the repo
/// analogue of `IngestPlan`, and the place the "a repo is mutable" difference
/// actually lives.
///
/// `IngestPlan.decide(sourceByteSize:)` answers one question ("is this document
/// big?") because a dropped file is ingested exactly once. A tracked repo asks
/// two: *is there anything new since the wiki was last told about this repo* and
/// *how much*. So the plan is a three-way outcome, and only the two doing-work
/// outcomes carry a model tier.
///
/// **Same tiering philosophy as `IngestPlan` (do not diverge).** Opus is ALWAYS
/// the curator and the writer; Sonnet `repo-reader` workers exist only to chew
/// through volume and return digests. The tier decides whether there IS a
/// fan-out, never who writes.
public enum RepoSyncPlan: Equatable, Sendable {
  /// The wiki is already current with upstream — nothing to run. (The tracker
  /// uses this to stay quiet; auto-ingest must never fire on an unchanged repo.)
  case upToDate

  /// The wiki has never been told about this repo: read the whole checkout.
  /// `fileCount` is the tracked-file count that picked the tier.
  case initial(tier: Tier, fileCount: Int)

  /// The wiki knows this repo as of `from`; bring it to `to`. `changedFileCount`
  /// is the size of the diff that picked the tier.
  case incremental(from: String, to: String, tier: Tier, changedFileCount: Int)

  /// Which model shape runs, mirroring `IngestPlan`'s two cases exactly.
  public enum Tier: Equatable, Sendable {
    /// One Opus pass reads the material and writes the pages itself.
    case singleOpus
    /// An Opus curator fans out to Sonnet `repo-reader` digesters, then decides
    /// the page set and writes every page.
    case opusCurator
  }

  /// A repo with fewer tracked files than this is small enough for one Opus pass
  /// to read directly. Sized so a small utility or config repo stays a single
  /// pass while any real codebase gets the fan-out.
  public static let smallRepoFileThreshold = 25

  /// A diff touching fewer files than this is a single Opus pass. A typical
  /// commit or two lands well under it; a merged feature branch does not.
  public static let smallDiffFileThreshold = 10

  /// Decide the plan.
  ///
  /// - Parameters:
  ///   - headCommit: upstream tip from the last fetch (nil ⇒ never cloned).
  ///   - lastIngestedCommit: the agent-confirmed watermark (nil ⇒ never ingested).
  ///   - historyIsContinuous: whether `lastIngestedCommit` is still an ancestor of
  ///     `headCommit`. False after a force-push/rebase, where the commit range is
  ///     meaningless — we fall back to a full re-read rather than diffing across
  ///     rewritten history.
  ///   - changedFileCount / trackedFileCount: the two sizes that pick the tier.
  public static func decide(
    headCommit: String?,
    lastIngestedCommit: String?,
    historyIsContinuous: Bool,
    changedFileCount: Int,
    trackedFileCount: Int
  ) -> RepoSyncPlan {
    guard let head = headCommit, !head.isEmpty else { return .upToDate }
    guard let last = lastIngestedCommit, !last.isEmpty else {
      return .initial(tier: tier(forFileCount: trackedFileCount), fileCount: trackedFileCount)
    }
    guard head != last else { return .upToDate }
    guard historyIsContinuous else {
      // Rewritten history: `last..head` would list the wrong commits (or none),
      // so re-read the checkout as if it were new.
      return .initial(tier: tier(forFileCount: trackedFileCount), fileCount: trackedFileCount)
    }
    return .incremental(
      from: last, to: head,
      tier: changedFileCount < smallDiffFileThreshold ? .singleOpus : .opusCurator,
      changedFileCount: changedFileCount)
  }

  private static func tier(forFileCount count: Int) -> Tier {
    count < smallRepoFileThreshold ? .singleOpus : .opusCurator
  }

  /// The tier, or nil when there is no work to do.
  public var tier: Tier? {
    switch self {
    case .upToDate: nil
    case .initial(let tier, _): tier
    case .incremental(_, _, let tier, _): tier
    }
  }

  /// Whether this plan would start an agent run.
  public var hasWork: Bool { tier != nil }
}
