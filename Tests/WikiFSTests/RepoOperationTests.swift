import Foundation
import Testing

@testable import WikiFSCore

/// The repo-ingest operation's argv, prompt, and subagent definition — the
/// deterministic seams of the one agent operation that can run unattended.
struct RepoOperationTests {

  private static let resolvedRoot = "/Users/me/Library/CloudStorage/Self Driving Wiki-Notes"
  private static let stateFile = "/tmp/scratch-xyz/WIKI_STATE.md"
  private static let repoStateFile = "/tmp/scratch-xyz/REPO_STATE.md"
  private static let checkout = "/Users/me/Library/Application Support/WikiFS/repos/01W/01R"

  private static func operation(plan: RepoSyncPlan) -> WikiOperation {
    .repoIngest(
      repoName: "owner/repo",
      repoPath: checkout,
      stateFilePath: stateFile,
      repoStateFilePath: repoStateFile,
      plan: plan)
  }

  private static let initialLarge = RepoSyncPlan.initial(tier: .opusCurator, fileCount: 400)
  private static let initialTiny = RepoSyncPlan.initial(tier: .singleOpus, fileCount: 4)
  private static let smallDiff = RepoSyncPlan.incremental(
    from: "aaaaaaa", to: "bbbbbbb", tier: .singleOpus, changedFileCount: 2)

  private func build(plan: RepoSyncPlan) -> OperationCommand {
    OperationCommand.build(
      operation: Self.operation(plan: plan),
      wikiRoot: Self.resolvedRoot,
      wikiID: "01WIKIULID",
      systemPrompt: "You are the maintainer.",
      scratchDirectory: "/tmp/scratch-xyz",
      wikictlDirectory: "/Apps/Self Driving Wiki.app/Contents/Helpers",
      claudeExecutable: "/opt/homebrew/bin/claude",
      baseEnvironment: ["PATH": "/usr/bin:/bin"])
  }

  // MARK: - Kind

  @Test func repoIngestIsItsOwnOperationKind() {
    #expect(Self.operation(plan: Self.initialTiny).kind == .repo)
    #expect(WikiOperation.Kind.repo.title == "Repo")
    #expect(WikiOperation.Kind.allCases.contains(.repo))
  }

  // MARK: - argv + tiering

  @Test func alwaysRunsOnOpus() {
    for plan in [Self.initialTiny, Self.initialLarge, Self.smallDiff] {
      let cmd = build(plan: plan)
      let modelIndex = cmd.arguments.firstIndex(of: "--model")!
      #expect(cmd.arguments[modelIndex + 1] == "opus")
    }
  }

  @Test func onlyTheCuratorTierDefinesSubagents() {
    #expect(!build(plan: Self.initialTiny).arguments.contains("--agents"))
    #expect(!build(plan: Self.smallDiff).arguments.contains("--agents"))
    #expect(build(plan: Self.initialLarge).arguments.contains("--agents"))
  }

  @Test func theRepoReaderIsAReadOnlySonnetWorker() {
    let cmd = build(plan: Self.initialLarge)
    let agents = cmd.arguments[cmd.arguments.firstIndex(of: "--agents")! + 1]
    #expect(agents.contains("repo-reader"))
    #expect(agents.contains("\"model\":\"sonnet\""))
    // Navigation + reading only. A worker with a write tool could edit the
    // checkout; a worker with wikictl could write pages Opus never approved.
    #expect(agents.contains("\"tools\":[\"Bash\",\"Read\",\"Grep\",\"Glob\"]"))
    #expect(!agents.contains("Write"))
    #expect(!agents.contains("Edit"))

    let prompt = RepoReaderAgent.prompt
    #expect(!prompt.contains("wikictl page upsert"))
    #expect(prompt.contains("READ-ONLY"))
    #expect(prompt.contains("path/to/File.ext:LINE"))
  }

  @Test func environmentTargetsThisWikiAndFindsWikictl() {
    let cmd = build(plan: Self.smallDiff)
    #expect(cmd.environment["WIKI_DB"] == "01WIKIULID")
    #expect(cmd.environment["PATH"]
      == "/Apps/Self Driving Wiki.app/Contents/Helpers:/usr/bin:/bin")
    #expect(cmd.currentDirectoryPath == "/tmp/scratch-xyz")
  }

  // MARK: - Prompt

  @Test func promptCarriesTheWriteRuleAndBothStagedStateFiles() {
    let prompt = Self.operation(plan: Self.smallDiff).prompt(wikiRoot: Self.resolvedRoot)
    #expect(prompt.contains("wikictl page upsert --title T --body-file -"))
    #expect(prompt.contains("wikictl index set --body-file -"))
    #expect(prompt.contains(Self.stateFile))
    #expect(prompt.contains(Self.repoStateFile))
    #expect(prompt.contains("do NOT run `wikictl page list`"))
  }

  @Test func promptForbidsWritingTheCheckout() {
    // The checkout is an ordinary directory, so a write there would SUCCEED —
    // the prohibition has to be explicit, unlike the mount's read-only-by-design.
    let prompt = Self.operation(plan: Self.initialTiny).prompt(wikiRoot: Self.resolvedRoot)
    #expect(prompt.contains(Self.checkout))
    #expect(prompt.contains("writes there would SUCCEED"))
    #expect(prompt.contains("no commit, checkout, pull, fetch, reset, clean, stash"))
  }

  @Test func promptRequiresCommitPinnedFootnotes() {
    let prompt = Self.operation(plan: Self.initialTiny).prompt(wikiRoot: Self.resolvedRoot)
    #expect(prompt.contains("repo owner/name@<short-sha>, path/to/File.ext:120-160"))
  }

  @Test func promptEndsWithTheWatermarkInstruction() {
    // mark-ingested LAST and only on success: it decides what the next pass
    // re-reads, so marking an unfinished run silently loses work.
    let prompt = Self.operation(plan: Self.smallDiff).prompt(wikiRoot: Self.resolvedRoot)
    #expect(prompt.contains("wikictl log append --kind repo"))
    #expect(prompt.contains("wikictl repo mark-ingested --name owner/repo"))
    #expect(prompt.contains("mark-ingested LAST"))
  }

  @Test func curatorTierPromptFansOutWithinTheGuardrail() {
    let prompt = Self.operation(plan: Self.initialLarge).prompt(wikiRoot: Self.resolvedRoot)
    #expect(prompt.contains("`repo-reader`"))
    #expect(prompt.contains("MORE THAN 1 and FEWER THAN 20"))
    #expect(prompt.contains("under 20"))
  }

  @Test func singleTierPromptDoesNotMentionWorkers() {
    let prompt = Self.operation(plan: Self.initialTiny).prompt(wikiRoot: Self.resolvedRoot)
    #expect(!prompt.contains("repo-reader"))
    #expect(prompt.contains("READ the material yourself"))
  }

  @Test func incrementalPromptSaysReviseAndInitialSaysEstablish() {
    let incremental = Self.operation(plan: Self.smallDiff).prompt(wikiRoot: Self.resolvedRoot)
    #expect(incremental.contains("REVISE them"))
    #expect(incremental.contains("do not create a second page"))

    let initial = Self.operation(plan: Self.initialTiny).prompt(wikiRoot: Self.resolvedRoot)
    #expect(initial.contains("DECIDE the set of pages this repository deserves"))
  }

  // MARK: - Repo-aware Query

  @Test func queryWithNoReposIsByteIdenticalToBeforeRepoTracking() {
    // The compatibility lock: adding the feature must not perturb the prompt of
    // a wiki that tracks nothing.
    let query = WikiOperation.query(question: "What is X?", stateFilePath: Self.stateFile)
    #expect(
      query.prompt(wikiRoot: Self.resolvedRoot)
        == query.prompt(wikiRoot: Self.resolvedRoot, repos: []))

    let conversation = WikiOperation.queryConversation(stateFilePath: Self.stateFile)
    #expect(
      conversation.prompt(wikiRoot: Self.resolvedRoot)
        == conversation.prompt(wikiRoot: Self.resolvedRoot, repos: []))
  }

  @Test func queryWithReposCanReadTheTrackedSource() {
    let contexts = [
      RepoStateSnapshot.Context(
        name: "owner/repo", clonePath: Self.checkout,
        headCommit: "bbbbbbbbbbbbbbb", branch: "main")
    ]
    for operation in [
      WikiOperation.query(question: "How does auth work?", stateFilePath: Self.stateFile),
      WikiOperation.queryConversation(stateFilePath: Self.stateFile),
    ] {
      let prompt = operation.prompt(wikiRoot: Self.resolvedRoot, repos: contexts)
      #expect(prompt.contains("TRACKED REPOSITORIES"))
      #expect(prompt.contains(Self.checkout))
      #expect(prompt.contains("owner/repo"))
      // Still a Query: the wiki-first instructions survive the new block.
      #expect(prompt.contains("wikictl page get"))
    }
  }

  @Test func repoContextsReachTheCommandThroughBuild() {
    let contexts = [
      RepoStateSnapshot.Context(
        name: "owner/repo", clonePath: Self.checkout, headCommit: "bbb", branch: "main")
    ]
    let cmd = OperationCommand.build(
      operation: .query(question: "Q?", stateFilePath: Self.stateFile),
      wikiRoot: Self.resolvedRoot,
      wikiID: "01WIKIULID",
      systemPrompt: "schema",
      scratchDirectory: "/tmp/scratch-xyz",
      wikictlDirectory: "/helpers",
      claudeExecutable: "claude",
      repos: contexts,
      baseEnvironment: ["PATH": "/usr/bin"])
    #expect(cmd.arguments[1].contains("TRACKED REPOSITORIES"))

    let interactive = OperationCommand.buildInteractiveQuery(
      operation: .queryConversation(stateFilePath: Self.stateFile),
      wikiRoot: Self.resolvedRoot,
      wikiID: "01WIKIULID",
      systemPrompt: "schema",
      scratchDirectory: "/tmp/scratch-xyz",
      wikictlDirectory: "/helpers",
      claudeExecutable: "claude",
      repos: contexts,
      baseEnvironment: ["PATH": "/usr/bin"])
    let appended = interactive.arguments[
      interactive.arguments.firstIndex(of: "--append-system-prompt")! + 1]
    #expect(appended.contains("TRACKED REPOSITORIES"))
  }

  // MARK: - Staging

  @Test func repoStateHasItsOwnStagedLeafName() {
    #expect(AgentStaging.repoStateFileName == "REPO_STATE.md")
    #expect(AgentStaging.stateFileName == "WIKI_STATE.md")
  }

  @Test func stagesBothStateFilesIntoTheScratchDirectory() throws {
    let scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("wikifs-repo-staging-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

    let wikiState = try AgentStaging.stageStateFile("# WIKI_STATE\n", in: scratch)
    let repoState = try AgentStaging.stageRepoState("# REPO_STATE\n", in: scratch)
    #expect(wikiState.hasSuffix("/WIKI_STATE.md"))
    #expect(repoState.hasSuffix("/REPO_STATE.md"))
    #expect(try String(contentsOfFile: repoState, encoding: .utf8) == "# REPO_STATE\n")
  }
}
