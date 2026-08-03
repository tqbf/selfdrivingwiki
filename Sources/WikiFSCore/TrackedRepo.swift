import Foundation

/// Stable identity for a `tracked_repos` row.
///
/// Repository rows are neither pages nor sources. Keeping their ULIDs in a
/// distinct namespace prevents a repository checkout from ever being addressed
/// by a page/source API merely because both persistence columns are `TEXT`.
public struct TrackedRepoID: RawRepresentable, Hashable, Codable, Sendable,
    Comparable, CustomStringConvertible, Identifiable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public var id: String { rawValue }
    public var description: String { rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One git repository this wiki tracks — a `tracked_repos` row (schema v49).
///
/// **Why this is not an ingested file.** Every other source in this wiki is
/// *immutable verbatim bytes stored in SQLite* (`ingested_files`): staged once,
/// ingested once, never re-read. A tracked repo is the opposite — it is remote,
/// mutable, lives on disk as a working tree outside the database, and gets
/// ingested repeatedly as commits land. The two facts that carry that difference
/// are `headCommit` (what upstream has) and `lastIngestedCommit` (what the wiki
/// has actually been told about); the gap between them IS the work queue.
///
/// **Who moves the watermark.** The app only ever writes `headCommit` /
/// `lastFetchedAt` (it ran `git fetch`, it knows). `lastIngestedCommit` is moved
/// by the AGENT via `wikictl repo mark-ingested`, at the end of a run that
/// actually wrote pages — the app proposes a commit range, the agent confirms
/// what it covered. That keeps the watermark honest when a run is interrupted.
///
/// `id` uses its own `TrackedRepoID` namespace. The raw ULID still sorts by
/// tracking order, while the type system prevents it from leaking into page or
/// source boundaries. Identifiable + Hashable so it drives SwiftUI directly.
public struct TrackedRepo: Identifiable, Hashable, Sendable {
  public let id: TrackedRepoID
  /// Display name, `owner/repo`, derived from the remote by `GitRemoteURL`.
  public let name: String
  /// The remote as handed to `git clone` (canonical form, no trailing slash).
  public let remoteURL: String
  /// The branch being tracked. `nil` until the daemon finishes the initial
  /// clone and discovers the remote's default branch.
  public let branch: String?
  /// Upstream tip as of the last successful fetch; nil before the first clone.
  public let headCommit: String?
  /// The commit the WIKI has been brought up to date with, as confirmed by the
  /// agent. nil until the first successful repo ingest.
  public let lastIngestedCommit: String?
  public let lastFetchedAt: Date?
  public let createdAt: Date
  public let updatedAt: Date
  public let version: Int

  public init(
    id: TrackedRepoID,
    name: String,
    remoteURL: String,
    branch: String?,
    headCommit: String?,
    lastIngestedCommit: String?,
    lastFetchedAt: Date?,
    createdAt: Date,
    updatedAt: Date,
    version: Int
  ) {
    self.id = id
    self.name = name
    self.remoteURL = remoteURL
    self.branch = branch
    self.headCommit = headCommit
    self.lastIngestedCommit = lastIngestedCommit
    self.lastFetchedAt = lastFetchedAt
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.version = version
  }

  /// True when upstream has commits the wiki has not been told about — as of the
  /// last fetch, which is always user-initiated, so this answers "what did I know
  /// when I last checked", not "what is true upstream right now".
  ///
  /// A repo that has never been ingested (`lastIngestedCommit == nil`) but HAS
  /// been cloned is drifted by definition — the whole repo is the pending work.
  public var isDrifted: Bool {
    guard let headCommit, !headCommit.isEmpty else { return false }
    return headCommit != lastIngestedCommit
  }

  /// The first 7 characters of `headCommit`, for compact display. Empty when the
  /// repo has not been cloned yet.
  public var shortHead: String {
    String((headCommit ?? "").prefix(7))
  }
}
