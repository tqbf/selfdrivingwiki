import Foundation
import Testing

@testable import WikiFSCore

/// Locks the decision that makes repo tracking *tracking* rather than repeated
/// ingestion: when there is work, whether it is a first pass or a diff, and how
/// big a fan-out it deserves.
struct RepoSyncPlanTests {

  @Test func neverClonedMeansNoWork() {
    #expect(
      RepoSyncPlan.decide(
        headCommit: nil, lastIngestedCommit: nil, historyIsContinuous: false,
        changedFileCount: 0, trackedFileCount: 0) == .upToDate)
    #expect(
      RepoSyncPlan.decide(
        headCommit: "", lastIngestedCommit: nil, historyIsContinuous: false,
        changedFileCount: 0, trackedFileCount: 40) == .upToDate)
  }

  @Test func watermarkAtHeadMeansNoWork() {
    // The load-bearing case for unattended updates: a repo that hasn't moved must
    // never start an agent run.
    let plan = RepoSyncPlan.decide(
      headCommit: "abc", lastIngestedCommit: "abc", historyIsContinuous: true,
      changedFileCount: 0, trackedFileCount: 500)
    #expect(plan == .upToDate)
    #expect(!plan.hasWork)
  }

  @Test func neverIngestedIsAnInitialPass() {
    let plan = RepoSyncPlan.decide(
      headCommit: "abc", lastIngestedCommit: nil, historyIsContinuous: false,
      changedFileCount: 0, trackedFileCount: 400)
    #expect(plan == .initial(tier: .opusCurator, fileCount: 400))
    #expect(plan.tier == .opusCurator)
  }

  @Test func aTinyRepoIsASingleOpusPass() {
    let plan = RepoSyncPlan.decide(
      headCommit: "abc", lastIngestedCommit: nil, historyIsContinuous: false,
      changedFileCount: 0, trackedFileCount: RepoSyncPlan.smallRepoFileThreshold - 1)
    #expect(plan.tier == .singleOpus)
  }

  @Test func thresholdIsExclusive() {
    let atThreshold = RepoSyncPlan.decide(
      headCommit: "abc", lastIngestedCommit: nil, historyIsContinuous: false,
      changedFileCount: 0, trackedFileCount: RepoSyncPlan.smallRepoFileThreshold)
    #expect(atThreshold.tier == .opusCurator)
  }

  @Test func newCommitsAreAnIncrementalPass() {
    let plan = RepoSyncPlan.decide(
      headCommit: "bbb", lastIngestedCommit: "aaa", historyIsContinuous: true,
      changedFileCount: 3, trackedFileCount: 900)
    #expect(plan == .incremental(from: "aaa", to: "bbb", tier: .singleOpus, changedFileCount: 3))
  }

  @Test func aLargeDiffFansOutEvenInASmallRepo() {
    // The tier follows the size of the CHANGE, not the size of the repo — an
    // incremental pass only reads what moved.
    let plan = RepoSyncPlan.decide(
      headCommit: "bbb", lastIngestedCommit: "aaa", historyIsContinuous: true,
      changedFileCount: RepoSyncPlan.smallDiffFileThreshold, trackedFileCount: 12)
    #expect(plan.tier == .opusCurator)
  }

  @Test func rewrittenHistoryFallsBackToAFullReRead() {
    // After a force-push the watermark isn't an ancestor of head, so `last..head`
    // would list the wrong commits (or none at all) — the checkout has to be read
    // as if it were new.
    let plan = RepoSyncPlan.decide(
      headCommit: "bbb", lastIngestedCommit: "aaa", historyIsContinuous: false,
      changedFileCount: 0, trackedFileCount: 300)
    #expect(plan == .initial(tier: .opusCurator, fileCount: 300))
  }

  @Test func emptyWatermarkIsTreatedAsNeverIngested() {
    let plan = RepoSyncPlan.decide(
      headCommit: "abc", lastIngestedCommit: "", historyIsContinuous: true,
      changedFileCount: 0, trackedFileCount: 10)
    #expect(plan == .initial(tier: .singleOpus, fileCount: 10))
  }
}
