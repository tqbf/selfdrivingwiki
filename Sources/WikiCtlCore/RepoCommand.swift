import Foundation
import WikiFSCore

/// The `wikictl repo …` subcommands, executed against an already-opened
/// `WikiStore`. Split from process concerns exactly like `PageCommand` /
/// `LogIndexCommand`, so the surface is unit-testable against a temp DB.
///
/// **This is a deliberately small surface.** The agent can READ tracking state
/// and move ONE field — the ingested watermark. It cannot add, remove, or
/// re-point a tracked repo: adding one means cloning it over the network into
/// app-managed storage, which is the app's job. Keeping `add`/`remove` out of the
/// CLI is what stops an agent run from quietly expanding what the wiki tracks.
public enum RepoCommand {

  public enum Action: Equatable {
    case list(json: Bool)
    case get(name: String)
    /// Move the ingested watermark for `name` to `commit`. The one write.
    case markIngested(name: String, commit: String)
  }

  /// Run one action against `store`. Reads never commit; `markIngested` does, so
  /// `wikictl` posts the change notification and the app's sidebar picks the new
  /// state up without a relaunch.
  public static func run(_ action: Action, in store: WikiStore) throws -> PageCommand.Result {
    switch action {
    case .list(let json):
      return try list(in: store, json: json)
    case .get(let name):
      let repo = try require(name: name, in: store)
      return PageCommand.Result(output: detail(for: repo), didCommit: false)
    case .markIngested(let name, let commit):
      let repo = try require(name: name, in: store)
      try store.markRepoIngested(id: repo.id, commit: commit)
      return PageCommand.Result(output: "\(repo.name) \(commit)", didCommit: true)
    }
  }

  // MARK: - list

  private static func list(in store: WikiStore, json: Bool) throws -> PageCommand.Result {
    let repos = try store.listRepos()
    if json {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let lines = try repos.map { repo -> String in
        let data = try encoder.encode(JSONRow(repo))
        return String(decoding: data, as: UTF8.self)
      }
      return PageCommand.Result(output: lines.joined(separator: "\n"), didCommit: false)
    }
    // TSV: name <tab> branch <tab> head <tab> last-ingested, one repo per line.
    // `-` for a commit the repo doesn't have yet, so the columns always line up.
    let lines = repos.map { repo in
      [repo.name, repo.branch, repo.headCommit ?? "-", repo.lastIngestedCommit ?? "-"]
        .joined(separator: "\t")
    }
    return PageCommand.Result(output: lines.joined(separator: "\n"), didCommit: false)
  }

  /// One JSON line for `repo list --json`.
  private struct JSONRow: Encodable {
    let name: String
    let remote: String
    let branch: String
    let head: String?
    let lastIngested: String?
    let autoIngest: Bool

    init(_ repo: TrackedRepo) {
      name = repo.name
      remote = repo.remoteURL
      branch = repo.branch
      head = repo.headCommit
      lastIngested = repo.lastIngestedCommit
      autoIngest = repo.autoIngest
    }
  }

  // MARK: - get

  /// The human/agent-readable detail block for one repo. Named fields rather than
  /// TSV because this is what an agent reads when it wants to know exactly which
  /// commit it's being asked to cover.
  private static func detail(for repo: TrackedRepo) -> String {
    var lines = [
      "name\t\(repo.name)",
      "remote\t\(repo.remoteURL)",
      "branch\t\(repo.branch)",
      "head\t\(repo.headCommit ?? "-")",
      "last_ingested\t\(repo.lastIngestedCommit ?? "-")",
      "auto_ingest\t\(repo.autoIngest ? "on" : "off")",
    ]
    if let fetchedAt = repo.lastFetchedAt {
      lines.append("last_fetched\t\(ISO8601DateFormatter().string(from: fetchedAt))")
    }
    return lines.joined(separator: "\n")
  }

  private static func require(name: String, in store: WikiStore) throws -> TrackedRepo {
    guard let repo = try store.findRepo(name: name) else {
      throw PageCommand.Failure.message("no tracked repository named \(name.debugDescription)")
    }
    return repo
  }
}
