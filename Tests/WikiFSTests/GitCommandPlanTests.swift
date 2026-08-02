import Foundation
import Testing

@testable import WikiFSCore

/// Locks the exact `git` argv the tracker issues. This is the whole reason the
/// plan is split from `GitRunner`: the invariant that matters — every repo-scoped
/// command is `-C`-anchored, and NOTHING here mutates a repository other than the
/// app's own checkout — is checkable without spawning a process.
struct GitCommandPlanTests {

  @Test func cloneIsPartialAndTagless() {
    let args = GitCommandPlan.clone(remote: "https://host/o/r", into: "/tmp/c", branch: nil)
    #expect(args == ["clone", "--filter=blob:none", "--no-tags", "https://host/o/r", "/tmp/c"])
  }

  @Test func cloneCarriesAnExplicitBranch() {
    let args = GitCommandPlan.clone(remote: "https://host/o/r", into: "/tmp/c", branch: "develop")
    #expect(args.contains("--branch"))
    #expect(args[args.firstIndex(of: "--branch")! + 1] == "develop")
    // The remote and target stay last, in that order.
    #expect(args.suffix(2) == ["https://host/o/r", "/tmp/c"])
  }

  @Test func emptyBranchIsTreatedAsUnspecified() {
    let args = GitCommandPlan.clone(remote: "https://host/o/r", into: "/tmp/c", branch: "")
    #expect(!args.contains("--branch"))
  }

  @Test func everyRepoScopedCommandIsAnchoredWithDashC() {
    // A command that relied on the process cwd would race the tracker's
    // concurrent per-repo work.
    let commands: [[String]] = [
      GitCommandPlan.fetch(at: "/tmp/c"),
      GitCommandPlan.resetHard(at: "/tmp/c", to: "abc"),
      GitCommandPlan.revParse(at: "/tmp/c", ref: "HEAD"),
      GitCommandPlan.currentBranch(at: "/tmp/c"),
      GitCommandPlan.isAncestor(at: "/tmp/c", ancestor: "a", descendant: "b"),
      GitCommandPlan.logRange(at: "/tmp/c", from: nil, to: "HEAD", limit: 5),
      GitCommandPlan.diffStat(at: "/tmp/c", from: "a", to: "b"),
      GitCommandPlan.changedFiles(at: "/tmp/c", from: "a", to: "b"),
      GitCommandPlan.listFiles(at: "/tmp/c"),
      GitCommandPlan.commitDate(at: "/tmp/c", ref: "HEAD"),
    ]
    for command in commands {
      #expect(command.prefix(2) == ["-C", "/tmp/c"])
    }
  }

  @Test func logRangeUsesDoubleDotWhenBounded() {
    let bounded = GitCommandPlan.logRange(at: "/tmp/c", from: "aaa", to: "bbb", limit: 50)
    #expect(bounded.last == "aaa..bbb")
    #expect(bounded.contains("--max-count=50"))

    let unbounded = GitCommandPlan.logRange(at: "/tmp/c", from: nil, to: "bbb", limit: 10)
    #expect(unbounded.last == "bbb")
  }

  @Test func diffCommandsSpanTheRange() {
    #expect(GitCommandPlan.diffStat(at: "/tmp/c", from: "a", to: "b").last == "a..b")
    #expect(GitCommandPlan.changedFiles(at: "/tmp/c", from: "a", to: "b").last == "a..b")
    #expect(GitCommandPlan.changedFiles(at: "/tmp/c", from: "a", to: "b").contains("--name-only"))
  }

  @Test func fetchPrunesAndNeverTouchesTheWorkingTree() {
    let args = GitCommandPlan.fetch(at: "/tmp/c")
    #expect(args.contains("--prune"))
    #expect(args.contains("fetch"))
    #expect(!args.contains("pull"))
    #expect(!args.contains("merge"))
  }
}
