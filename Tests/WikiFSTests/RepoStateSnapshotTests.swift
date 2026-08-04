import Foundation
import Testing

@testable import WikiFSCore

/// Locks the staged `REPO_STATE.md` document and the tracked-repositories block
/// spliced into Query prompts.
struct RepoStateSnapshotTests {

  private func snapshot(
    plan: RepoSyncPlan,
    commits: [String] = [],
    diffStat: String? = nil,
    files: [String] = [],
    lastIngested: String? = nil,
    trackedFileCount: Int = 3
  ) -> RepoStateSnapshot {
    RepoStateSnapshot.make(
      name: "owner/repo",
      remoteURL: "https://github.com/owner/repo",
      branch: "main",
      clonePath: "/checkouts/repo",
      headCommit: "bbbbbbbbbbbb",
      headCommittedAt: "2026-08-01T12:00:00Z",
      lastIngestedCommit: lastIngested,
      allCommitLines: commits,
      diffStat: diffStat,
      allFiles: files,
      trackedFileCount: trackedFileCount,
      plan: plan)
  }

  // MARK: - The document

  @Test func headerCarriesTheFactsTheAgentWouldOtherwiseRunGitFor() {
    let text = snapshot(plan: .initial(tier: .singleOpus, fileCount: 3)).renderStateFile()
    #expect(text.hasPrefix("# REPO_STATE"))
    #expect(text.contains("owner/repo"))
    #expect(text.contains("https://github.com/owner/repo"))
    #expect(text.contains("Branch: main"))
    #expect(text.contains("bbbbbbbbbbbb"))
    #expect(text.contains("/checkouts/repo"))
    #expect(text.contains("2026-08-01T12:00:00Z"))
  }

  @Test func theCheckoutIsLabelledReadOnly() {
    // The checkout is a real directory, so a write there would SUCCEED — the
    // read-only claim has to be stated, not inferred from the mount's behavior.
    let text = snapshot(plan: .initial(tier: .singleOpus, fileCount: 3)).renderStateFile()
    #expect(text.contains("READ-ONLY"))
  }

  @Test func anInitialPassDescribesTheWholeCheckout() {
    let text = snapshot(
      plan: .initial(tier: .opusCurator, fileCount: 120),
      files: ["a.swift", "b.swift"],
      trackedFileCount: 120
    ).renderStateFile()
    #expect(text.contains("FIRST PASS"))
    #expect(text.contains("120 tracked files"))
    #expect(text.contains("## Files in the checkout"))
    #expect(text.contains("never — this is the first pass"))
  }

  @Test func anIncrementalPassDescribesTheRangeAndSaysReviseNotRestart() {
    let text = snapshot(
      plan: .incremental(from: "aaa", to: "bbbbbbbbbbbb", tier: .singleOpus, changedFileCount: 2),
      commits: ["abc123 2026-07-31 Ann: fix the thing"],
      diffStat: " a.swift | 4 ++--",
      files: ["a.swift", "b.swift"],
      lastIngested: "aaa"
    ).renderStateFile()
    #expect(text.contains("INCREMENTAL pass over aaa..bbbbbbbbbbbb"))
    #expect(text.contains("REVISE the existing pages"))
    #expect(text.contains("## Changed files"))
    #expect(text.contains("## Commits (most recent first)"))
    #expect(text.contains("fix the thing"))
    #expect(text.contains("## Diff stat"))
    #expect(text.contains("a.swift | 4 ++--"))
  }

  @Test func emptySectionsAreOmittedRatherThanRenderedBlank() {
    let text = snapshot(plan: .initial(tier: .singleOpus, fileCount: 0)).renderStateFile()
    #expect(!text.contains("## Commits"))
    #expect(!text.contains("## Diff stat"))
    #expect(!text.contains("## Files in the checkout"))
  }

  // MARK: - Caps

  @Test func fileAndCommitListsAreCappedWithACountOfWhatWasDropped() {
    let manyFiles = (0..<(RepoStateSnapshot.maxListedFiles + 25)).map { "file\($0).swift" }
    let manyCommits = (0..<(RepoStateSnapshot.maxListedCommits + 5)).map { "sha\($0) subject" }
    let snap = snapshot(
      plan: .incremental(
        from: "aaa", to: "bbbbbbbbbbbb", tier: .opusCurator,
        changedFileCount: manyFiles.count),
      commits: manyCommits,
      files: manyFiles,
      lastIngested: "aaa")

    #expect(snap.files.count == RepoStateSnapshot.maxListedFiles)
    #expect(snap.truncatedFileCount == 25)
    #expect(snap.commitLog.count == RepoStateSnapshot.maxListedCommits)
    #expect(snap.truncatedCommitCount == 5)

    let text = snap.renderStateFile()
    #expect(text.contains("…and 25 more"))
    #expect(text.contains("…and 5 more commits"))
  }

  // MARK: - The Query prompt block

  @Test func noTrackedReposRendersNothingAtAll() {
    // Load-bearing: a wiki with no repos must produce a byte-identical Query
    // prompt to one built before repo tracking existed.
    #expect(RepoStateSnapshot.Context.promptBlock(for: []).isEmpty)
  }

  @Test func trackedReposBlockNamesPathsCommitsAndTheCitationForm() {
    let block = RepoStateSnapshot.Context.promptBlock(for: [
      RepoStateSnapshot.Context(
        name: "owner/repo", clonePath: "/checkouts/repo",
        headCommit: "bbbbbbbbbbbb", branch: "main")
    ])
    #expect(block.contains("TRACKED REPOSITORIES"))
    #expect(block.contains("owner/repo"))
    #expect(block.contains("/checkouts/repo"))
    #expect(block.contains("bbbbbbb"))  // short sha
    #expect(block.contains("READ-ONLY"))
    #expect(block.contains("repo owner/name@<short-sha>"))
  }

  @Test func contextRoundTripsFromASnapshot() {
    let context = snapshot(plan: .initial(tier: .singleOpus, fileCount: 3)).context
    #expect(context.name == "owner/repo")
    #expect(context.clonePath == "/checkouts/repo")
    #expect(context.headCommit == "bbbbbbbbbbbb")
    #expect(context.branch == "main")
  }
}
