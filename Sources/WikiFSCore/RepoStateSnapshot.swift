import Foundation

/// A LIVE snapshot of ONE tracked repository at run start, staged into the
/// agent's scratch dir as `REPO_STATE.md` — the repo counterpart of
/// `WikiStateSnapshot`/`WIKI_STATE.md`.
///
/// **Why stage this instead of letting the agent run git.** Same reasoning as
/// `WikiStateSnapshot`: the app already knows every one of these facts (it just
/// ran the fetch), so handing them over up front removes a fistful of
/// orientation turns — `git log`, `git diff --stat`, `ls-files`, "which commit
/// am I even looking at". The agent's turns should go into READING CODE, not
/// re-deriving state the tracker already computed.
///
/// **The static/dynamic split (do NOT duplicate).** Conventions — page shapes,
/// the `[[link]]` rule, the `wikictl` reference — stay in the maintainer schema
/// delivered via `--append-system-prompt`. This carries only what is true of THIS
/// repo at THIS commit.
///
/// PURE value type: gathering the git output lives in the app (`RepoTracker` /
/// `AgentOperationRunner`); rendering stays here so it is unit-testable without
/// a real checkout.
public struct RepoStateSnapshot: Equatable, Sendable {
  /// The minimal repo facts the *Query* prompt needs (name, where the checkout
  /// is, what commit it's at) — small enough to list every tracked repo in a
  /// conversation prompt without bloating it.
  public struct Context: Equatable, Hashable, Sendable {
    public let name: String
    public let clonePath: String
    public let headCommit: String
    public let branch: String

    public init(name: String, clonePath: String, headCommit: String, branch: String) {
      self.name = name
      self.clonePath = clonePath
      self.headCommit = headCommit
      self.branch = branch
    }

    /// The `TRACKED REPOSITORIES` block shared by the one-shot and interactive
    /// Query prompts. Returns "" for an empty list, so a wiki with no tracked
    /// repos produces a byte-identical prompt to before this feature existed.
    public static func promptBlock(for repos: [Context]) -> String {
      guard !repos.isEmpty else { return "" }
      let rows = repos.map {
        "- \($0.name) — branch \($0.branch), commit \(String($0.headCommit.prefix(7))), "
          + "checkout: \($0.clonePath)"
      }
      return """
        TRACKED REPOSITORIES — This wiki tracks the git checkouts below. They are \
        REAL local directories (not the read-only mount), and you may read them \
        freely with Read/Grep/Glob and shell tools to answer questions about the \
        code itself. Treat them as READ-ONLY: never write a file into a checkout, \
        and never run a git command that mutates one (no commit, checkout, pull, \
        reset, clean). When an answer rests on source you read there, cite it as \
        `repo owner/name@<short-sha>, path/to/File.ext:LINES`.

        \(rows.joined(separator: "\n"))
        """
    }
  }

  public let name: String
  public let remoteURL: String
  public let branch: String
  public let clonePath: String
  public let headCommit: String
  public let headCommittedAt: String?
  public let lastIngestedCommit: String?
  /// `git log --pretty` lines for the range being ingested, most recent first.
  public let commitLog: [String]
  /// How many commits were dropped by `maxListedCommits`.
  public let truncatedCommitCount: Int
  /// `git diff --stat` output for an incremental sync; nil for an initial one.
  public let diffStat: String?
  /// Changed paths (incremental) or the tracked-file listing (initial).
  public let files: [String]
  /// How many paths were dropped by `maxListedFiles`.
  public let truncatedFileCount: Int
  /// Total tracked files in the checkout, regardless of the listing cap.
  public let trackedFileCount: Int
  /// The plan this snapshot was built for — decides which sections render.
  public let plan: RepoSyncPlan

  /// Caps, sized like `WikiStateSnapshot.maxListedTitles`: enough for the agent
  /// to plan against, bounded so a 40k-file monorepo can't blow up the prompt.
  public static let maxListedFiles = 300
  public static let maxListedCommits = 50

  public init(
    name: String,
    remoteURL: String,
    branch: String,
    clonePath: String,
    headCommit: String,
    headCommittedAt: String?,
    lastIngestedCommit: String?,
    commitLog: [String],
    truncatedCommitCount: Int,
    diffStat: String?,
    files: [String],
    truncatedFileCount: Int,
    trackedFileCount: Int,
    plan: RepoSyncPlan
  ) {
    self.name = name
    self.remoteURL = remoteURL
    self.branch = branch
    self.clonePath = clonePath
    self.headCommit = headCommit
    self.headCommittedAt = headCommittedAt
    self.lastIngestedCommit = lastIngestedCommit
    self.commitLog = commitLog
    self.truncatedCommitCount = truncatedCommitCount
    self.diffStat = diffStat
    self.files = files
    self.truncatedFileCount = truncatedFileCount
    self.trackedFileCount = trackedFileCount
    self.plan = plan
  }

  /// Build a snapshot from raw git output, applying both caps. Kept pure (no
  /// process spawning, no store access) so it's testable: the app gathers the
  /// lists and hands them in, exactly as `WikiStateSnapshot.make` does.
  public static func make(
    name: String,
    remoteURL: String,
    branch: String,
    clonePath: String,
    headCommit: String,
    headCommittedAt: String?,
    lastIngestedCommit: String?,
    allCommitLines: [String],
    diffStat: String?,
    allFiles: [String],
    trackedFileCount: Int,
    plan: RepoSyncPlan
  ) -> RepoStateSnapshot {
    let commits = Array(allCommitLines.prefix(maxListedCommits))
    let files = Array(allFiles.prefix(maxListedFiles))
    return RepoStateSnapshot(
      name: name,
      remoteURL: remoteURL,
      branch: branch,
      clonePath: clonePath,
      headCommit: headCommit,
      headCommittedAt: headCommittedAt,
      lastIngestedCommit: lastIngestedCommit,
      commitLog: commits,
      truncatedCommitCount: max(0, allCommitLines.count - commits.count),
      diffStat: diffStat,
      files: files,
      truncatedFileCount: max(0, allFiles.count - files.count),
      trackedFileCount: trackedFileCount,
      plan: plan
    )
  }

  /// Render the standalone `REPO_STATE.md` the app stages into the run's scratch
  /// dir. The operation prompt names this file's absolute path and tells the
  /// agent to read it FIRST, so it never has to re-run git to learn what changed.
  public func renderStateFile() -> String {
    var lines: [String] = []
    lines.append("# REPO_STATE")
    lines.append("")
    lines.append(
      "Live snapshot of the tracked repository this run covers, authoritative as of "
        + "run start. Everything here was gathered by the app with git; you do NOT need "
        + "to re-run `git log`, `git diff`, or `ls-files` to learn what changed.")

    lines.append("")
    lines.append("## Repository")
    lines.append("")
    lines.append("- Name: \(name)")
    lines.append("- Remote: \(remoteURL)")
    lines.append("- Branch: \(branch)")
    lines.append("- Checkout (READ-ONLY — never write here): \(clonePath)")
    lines.append("- Head commit: \(headCommit)")
    if let headCommittedAt {
      lines.append("- Head committed at: \(headCommittedAt)")
    }
    lines.append("- Tracked files: \(trackedFileCount)")
    lines.append(
      "- Wiki was last brought up to date at: "
        + (lastIngestedCommit.map { "\($0)" } ?? "never — this is the first pass"))

    lines.append("")
    lines.append("## Scope of this pass")
    lines.append("")
    switch plan {
    case .upToDate:
      lines.append("Nothing to do — the wiki is already current with \(headCommit).")
    case .initial(_, let fileCount):
      lines.append(
        "FIRST PASS over the whole checkout (\(fileCount) tracked files). Establish the "
          + "wiki's coverage of this repository: what it is, how it is structured, and how "
          + "its major parts work.")
    case .incremental(let from, let to, _, let changedFileCount):
      lines.append(
        "INCREMENTAL pass over \(from)..\(to) (\(changedFileCount) changed files). The wiki "
          + "already covers this repository as of \(from) — REVISE the existing pages that "
          + "these changes affect rather than starting over, and add pages only for genuinely "
          + "new subject matter.")
    }

    if !commitLog.isEmpty {
      lines.append("")
      lines.append("## Commits (most recent first)")
      lines.append("")
      lines.append(commitLog.map { "- \($0)" }.joined(separator: "\n"))
      if truncatedCommitCount > 0 {
        lines.append("")
        lines.append("(…and \(truncatedCommitCount) more commits in this range.)")
      }
    }

    if let diffStat, !diffStat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      lines.append("")
      lines.append("## Diff stat")
      lines.append("")
      lines.append("```")
      lines.append(diffStat.trimmingCharacters(in: .newlines))
      lines.append("```")
    }

    if !files.isEmpty {
      lines.append("")
      switch plan {
      case .incremental:
        lines.append("## Changed files")
      case .upToDate, .initial:
        lines.append("## Files in the checkout")
      }
      lines.append("")
      lines.append("Paths are relative to the checkout directory above.")
      lines.append("")
      lines.append(files.map { "- \($0)" }.joined(separator: "\n"))
      if truncatedFileCount > 0 {
        lines.append("")
        lines.append(
          "(…and \(truncatedFileCount) more — list the rest yourself with "
            + "`git -C \(clonePath) ls-files` only if you actually need it.)")
      }
    }

    return lines.joined(separator: "\n") + "\n"
  }

  /// The `Context` for this repo, for reuse in Query prompts.
  public var context: Context {
    Context(name: name, clonePath: clonePath, headCommit: headCommit, branch: branch)
  }
}
