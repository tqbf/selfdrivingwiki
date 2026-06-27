import Foundation
import Testing
@testable import WikiFSCore

/// Tests for Phase C / `feature/ingest-fewer-turns` deterministic seams: the
/// `WikiOperation` prompts (the write rule + staged paths + don't-rediscover), the
/// `OperationCommand` env/argv/cwd construction (the EXACT `claude -p` flag surface —
/// Opus top-level in both Ingest modes, plus the `--agents` Sonnet `source-reader`
/// DIGESTER for the large-source mode), the `IngestPlan` tiny-vs-large decision, and
/// the `PathPreflight`. The corrected division of labor: Opus is ALWAYS the
/// curator/writer; Sonnet only digests source volume and never writes. These are the
/// seams the structural gate verifier relies on — kept pure/injectable so they test
/// without a real `claude -p` run.
struct OperationCommandTests {

  // MARK: - Fixtures

  private static let resolvedRoot = "/Users/me/Library/CloudStorage/WikiFS-Research"
  private static let stagedSource = "/tmp/scratch-xyz/source.pdf"
  private static let stateFile = "/tmp/scratch-xyz/WIKI_STATE.md"

  /// A large-source ingest operation — Opus curator + Sonnet source-reader digesters.
  private static func curatedIngest() -> WikiOperation {
    .ingest(
      sourcePaths: ["files/by-id/01ABC.pdf"],
      stagedSourcePaths: [stagedSource],
      stateFilePath: stateFile,
      plan: .opusCurator)
  }

  /// A tiny ingest operation — single Opus pass.
  private static func tinyIngest() -> WikiOperation {
    .ingest(
      sourcePaths: ["files/by-id/01ABC.txt"],
      stagedSourcePaths: ["/tmp/scratch-xyz/source.txt"],
      stateFilePath: stateFile,
      plan: .singleOpus)
  }

  private func build(
    operation: WikiOperation = OperationCommandTests.curatedIngest(),
    wikictlDir: String = "/Apps/Self Driving Wiki.app/Contents/Helpers",
    basePATH: String = "/usr/bin:/bin"
  ) -> OperationCommand {
    OperationCommand.build(
      operation: operation,
      wikiRoot: OperationCommandTests.resolvedRoot,
      wikiID: "01WIKIULID",
      systemPrompt: "You are the maintainer.",
      scratchDirectory: "/tmp/scratch-xyz",
      wikictlDirectory: wikictlDir,
      resolvedExecutable: "/opt/homebrew/bin/claude",
      baseEnvironment: ["PATH": basePATH, "HOME": "/Users/me"])
  }

  // MARK: - OperationCommand construction

  @Test func usesResolvedClaudeExecutable() {
    #expect(build().executable == "/opt/homebrew/bin/claude")
  }

  @Test func argumentsCarryPromptModelStreamFlagsAppendSystemPromptAndSkipPermissions() {
    let cmd = build(operation: Self.tinyIngest())
    // -p <prompt> --model <alias> --output-format stream-json --verbose
    //   --include-partial-messages --append-system-prompt <prompt>
    //   --dangerously-skip-permissions
    #expect(cmd.arguments[0] == "-p")
    #expect(cmd.arguments[1] == Self.tinyIngest().prompt(wikiRoot: Self.resolvedRoot))
    #expect(cmd.arguments[2] == "--model")
    #expect(cmd.arguments[3] == "opus")  // tiny → single Opus pass (Opus is the writer)
    #expect(cmd.arguments[4] == "--output-format")
    #expect(cmd.arguments[5] == "stream-json")
    #expect(cmd.arguments[6] == "--verbose")
    #expect(cmd.arguments[7] == "--include-partial-messages")
    #expect(cmd.arguments[8] == "--append-system-prompt")
    #expect(cmd.arguments[9] == "You are the maintainer.")
    #expect(cmd.arguments[10] == "--dangerously-skip-permissions")
    #expect(!cmd.arguments.contains("--allowedTools"))
  }

  // MARK: - Model tiering (problem #3) — Opus always writes; Sonnet only digests

  @Test func tinyIngestRunsSingleOpusPassWithNoAgents() {
    let cmd = build(operation: Self.tinyIngest())
    // Tiny source → top-level model is OPUS (Opus is the curator/writer even for a
    // small source), and NO --agents (single agent, no fan-out).
    let modelIndex = cmd.arguments.firstIndex(of: "--model")!
    #expect(cmd.arguments[modelIndex + 1] == "opus")
    #expect(!cmd.arguments.contains("--agents"))
  }

  @Test func largeIngestRunsOpusWithASonnetDigesterAgent() {
    let cmd = build(operation: Self.curatedIngest())
    // Large source → top-level model is opus (the curator/writer), plus --agents
    // defining a sonnet `source-reader` DIGESTER (read-only).
    let modelIndex = cmd.arguments.firstIndex(of: "--model")!
    #expect(cmd.arguments[modelIndex + 1] == "opus")
    #expect(cmd.arguments.contains("--agents"))
    let agentsIndex = cmd.arguments.firstIndex(of: "--agents")!
    let json = cmd.arguments[agentsIndex + 1]
    // The agents JSON defines the source-reader on the sonnet model.
    #expect(json.contains("source-reader"))
    #expect(json.contains("\"model\":\"sonnet\""))
    // It must be valid JSON with the verified shape (description/prompt/model/tools).
    let data = json.data(using: .utf8)!
    let parsed = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    let worker = parsed["source-reader"] as! [String: Any]
    #expect(worker["model"] as? String == "sonnet")
    // READ-ONLY tools — no wikictl / no write tools (the worker only digests).
    #expect((worker["tools"] as? [String]) == ["Bash", "Read"])
    #expect((worker["description"] as? String)?.isEmpty == false)
    #expect((worker["prompt"] as? String)?.isEmpty == false)
  }

  @Test func queryAndLintStayOpusSingleAgent() {
    for operation: WikiOperation in [
      .query(question: "How does X work?", stateFilePath: Self.stateFile),
      .queryConversation(stateFilePath: Self.stateFile, allowWikiEdits: false),
      .lint(stateFilePath: Self.stateFile),
    ] {
      let cmd = build(operation: operation)
      let modelIndex = cmd.arguments.firstIndex(of: "--model")!
      #expect(cmd.arguments[modelIndex + 1] == "opus")
      #expect(!cmd.arguments.contains("--agents"))
    }
  }

  @Test func interactiveQueryUsesStreamingInputAndNoPositionalPrompt() {
    let cmd = OperationCommand.buildInteractiveQuery(
      operation: .queryConversation(stateFilePath: Self.stateFile, allowWikiEdits: false),
      wikiRoot: Self.resolvedRoot,
      wikiID: "01WIKIULID",
      systemPrompt: "You are the maintainer.",
      scratchDirectory: "/tmp/scratch-xyz",
      wikictlDirectory: "/Apps/Self Driving Wiki.app/Contents/Helpers",
      resolvedExecutable: "/opt/homebrew/bin/claude",
      baseEnvironment: ["PATH": "/usr/bin:/bin"])

    #expect(cmd.executable == "/opt/homebrew/bin/claude")
    #expect(cmd.arguments[0] == "-p")
    #expect(cmd.arguments.contains("--input-format"))
    let inputIndex = cmd.arguments.firstIndex(of: "--input-format")!
    #expect(cmd.arguments[inputIndex + 1] == "stream-json")
    let outputIndex = cmd.arguments.firstIndex(of: "--output-format")!
    #expect(cmd.arguments[outputIndex + 1] == "stream-json")
    #expect(cmd.arguments.contains("--verbose"))
    #expect(cmd.arguments.contains("--dangerously-skip-permissions"))
    #expect(!cmd.arguments.contains { $0.hasPrefix("Question:") })
    #expect(cmd.environment["WIKI_ROOT"] == Self.resolvedRoot)
    #expect(cmd.environment["WIKI_DB"] == "01WIKIULID")
    #expect(cmd.environment["PATH"] == "/Apps/Self Driving Wiki.app/Contents/Helpers:/usr/bin:/bin")
  }

  @Test func interactiveQueryPromptAnswersByDefaultAndWritesOnlyOnRequest() {
    let cmd = OperationCommand.buildInteractiveQuery(
      operation: .queryConversation(stateFilePath: Self.stateFile, allowWikiEdits: true),
      wikiRoot: Self.resolvedRoot,
      wikiID: "01WIKIULID",
      systemPrompt: "schema",
      scratchDirectory: "/tmp/scratch-xyz",
      wikictlDirectory: "/helpers",
      resolvedExecutable: "claude",
      baseEnvironment: [:])
    let promptIndex = cmd.arguments.firstIndex(of: "--append-system-prompt")!
    let prompt = cmd.arguments[promptIndex + 1]

    #expect(prompt.contains("interactive Query conversation"))
    #expect(prompt.contains("Answer in chat by default"))
    #expect(prompt.contains("Only change the wiki when the user explicitly asks"))
    #expect(prompt.contains("Do the wiki/source inspection silently"))
    #expect(prompt.contains("Do NOT narrate process steps"))
    #expect(prompt.contains("Do not advertise capabilities"))
    #expect(prompt.contains("wikictl page upsert"))
    #expect(prompt.contains("wikictl log append --kind query"))
    #expect(prompt.contains(Self.stateFile))
    #expect(prompt.contains(Self.resolvedRoot))
  }

  // MARK: - Digester prompt digests, does NOT write (no write rule, no wikictl)

  @Test func digesterPromptDigestsAndDoesNotWriteTheWiki() {
    // The Sonnet `source-reader` worker ONLY reads source volume and returns a
    // digest. Its prompt must NOT carry the write rule or any wikictl write commands —
    // Opus is the only writer.
    let json = IngestPlan.opusCurator.agentsJSON()!
    let data = json.data(using: .utf8)!
    let parsed = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    let worker = parsed["source-reader"] as! [String: Any]
    let prompt = worker["prompt"] as! String
    // It tells the worker to digest, not write.
    #expect(prompt.contains("STRUCTURED DIGEST"))
    #expect(prompt.lowercased().contains("you do not write to the wiki"))
    #expect(prompt.contains("Return your digest as your final message"))
    // It carries NO wiki-write instructions: no write rule, no wikictl write
    // commands. (It may NAME wikictl to say it has none — "You have NO wikictl" —
    // so we assert on the write COMMANDS, not the bare word.)
    #expect(!prompt.contains("READ-ONLY BY DESIGN"))
    #expect(!prompt.contains("page upsert"))
    #expect(!prompt.contains("index set"))
    #expect(!prompt.contains("log append"))
    #expect(!prompt.contains("FOOTNOTE CONCLUSIONS"))
  }

  // MARK: - Env / PATH / cwd (unchanged surface)

  @Test func environmentExportsWikiRootAndWikiDB() {
    let cmd = build()
    #expect(cmd.environment["WIKI_ROOT"] == Self.resolvedRoot)
    #expect(cmd.environment["WIKI_DB"] == "01WIKIULID")
  }

  @Test func prependsWikictlDirectoryToChildPATH() {
    let cmd = build(wikictlDir: "/Apps/Self Driving Wiki.app/Contents/Helpers", basePATH: "/usr/bin:/bin")
    #expect(cmd.environment["PATH"] == "/Apps/Self Driving Wiki.app/Contents/Helpers:/usr/bin:/bin")
  }

  @Test func cwdIsTheWritableScratchDirNotTheMount() {
    let cmd = build()
    #expect(cmd.currentDirectoryPath == "/tmp/scratch-xyz")
    #expect(cmd.currentDirectoryPath != Self.resolvedRoot)
  }

  @Test func inheritsBaseEnvironment() {
    #expect(build().environment["HOME"] == "/Users/me")
  }

  @Test func usesSkipPermissionsNotAFineGrainedAllowlist() {
    let cmd = build()
    #expect(cmd.arguments.contains("--dangerously-skip-permissions"))
    #expect(!cmd.arguments.contains("--allowedTools"))
    #expect(!cmd.arguments.contains("--allowed-tools"))
    #expect(!cmd.arguments.contains { $0.contains("Bash(wikictl") })
  }

  // MARK: - Debug summary (redacted, secret-safe)

  @Test func debugSummaryTruncatesLongPayloadArgsButKeepsFlags() {
    let longPrompt = String(repeating: "x", count: 5000)
    let cmd = build(operation: .query(question: longPrompt, stateFilePath: Self.stateFile))
    let summary = cmd.debugSummary
    // Flags survive verbatim…
    #expect(summary.contains("--model"))
    #expect(summary.contains("--output-format"))
    #expect(summary.contains("--dangerously-skip-permissions"))
    // …but the multi-thousand-char prompt is collapsed to a length marker, not dumped.
    #expect(!summary.contains(longPrompt))
    #expect(summary.contains(" chars)"))   // a truncation marker is present
    #expect(!summary.contains(String(repeating: "x", count: 200)))
  }

  @Test func debugSummaryReportsAuthSetButNeverSecretValues() {
    // Sandboxed build; the env carries an API key whose VALUE must never appear in
    // the summary. CLAUDE_CONFIG_DIR is intentionally NOT set (fixing the auth bug
    // where redirecting it to an empty scratch dir hid ~/.claude credentials).
    let cmd = OperationCommand.build(
      operation: Self.tinyIngest(),
      wikiRoot: Self.resolvedRoot,
      wikiID: "01WIKIULID",
      systemPrompt: "You are the maintainer.",
      scratchDirectory: "/tmp/scratch-xyz",
      wikictlDirectory: "/Apps/Self Driving Wiki.app/Contents/Helpers",
      resolvedExecutable: "/opt/homebrew/bin/claude",
      sandbox: .init(profile: "(version 1)", defines: []),
      baseEnvironment: ["PATH": "/usr/bin", "HOME": "/Users/me",
                        "ANTHROPIC_API_KEY": "sk-ant-supersecret"])
    let summary = cmd.debugSummary
    // CLAUDE_CONFIG_DIR must NOT appear — we no longer redirect it.
    #expect(!summary.contains("CLAUDE_CONFIG_DIR"))
    #expect(summary.contains("sandboxed=true"))
    // The key's PRESENCE is reported by name; its value is never logged.
    #expect(summary.contains("authSet=[ANTHROPIC_API_KEY]"))
    #expect(!summary.contains("sk-ant-supersecret"))
  }

  @Test func eachOperationKindBuildsAValidCommand() {
    for operation: WikiOperation in [
      Self.tinyIngest(),
      Self.curatedIngest(),
      .query(question: "How does X compare to Y?", stateFilePath: Self.stateFile),
      .queryConversation(stateFilePath: Self.stateFile, allowWikiEdits: false),
      .lint(stateFilePath: Self.stateFile),
    ] {
      let cmd = OperationCommand.build(
        operation: operation,
        wikiRoot: "/mount",
        wikiID: "01W",
        systemPrompt: "schema",
        scratchDirectory: "/scratch",
        wikictlDirectory: "/helpers",
        resolvedExecutable: "claude",
        baseEnvironment: [:])
      #expect(cmd.arguments[0] == "-p")
      #expect(cmd.arguments[1] == operation.prompt(wikiRoot: "/mount"))
      #expect(cmd.arguments.contains("--model"))
      #expect(cmd.arguments.contains("--dangerously-skip-permissions"))
      #expect(cmd.environment["WIKI_DB"] == "01W")
    }
  }

  // MARK: - IngestPlan decision (the tiny-vs-large threshold)

  @Test func tinySourceUnderThresholdPicksSingleOpus() {
    #expect(IngestPlan.decide(sourceByteSize: 0) == .singleOpus)
    #expect(IngestPlan.decide(sourceByteSize: IngestPlan.tinySourceByteThreshold - 1) == .singleOpus)
  }

  @Test func sourceAtOrAboveThresholdPicksOpusCurator() {
    #expect(IngestPlan.decide(sourceByteSize: IngestPlan.tinySourceByteThreshold) == .opusCurator)
    #expect(IngestPlan.decide(sourceByteSize: 5_000_000) == .opusCurator)
  }

  @Test func thresholdIsAround4KB() {
    // A sensible named constant: text under ~4 KB is tiny.
    #expect(IngestPlan.tinySourceByteThreshold == 4096)
  }

  @Test func bothModesRunTopLevelOpusOnlyTheFanOutDiffers() {
    // Opus is the curator/writer in BOTH modes — the top-level model is always opus.
    #expect(IngestPlan.singleOpus.topLevelModelAlias == "opus")
    #expect(IngestPlan.opusCurator.topLevelModelAlias == "opus")
    // The tiering is in the fan-out: only the large-source mode forks Sonnet digesters.
    #expect(IngestPlan.singleOpus.agentsJSON() == nil)
    #expect(IngestPlan.opusCurator.agentsJSON() != nil)
  }

  // MARK: - Prompts: the write rule (problem #1)

  @Test func everyOperationPromptLeadsWithTheUnmissableWriteRule() {
    for operation: WikiOperation in [
      Self.tinyIngest(),
      Self.curatedIngest(),
      .query(question: "q", stateFilePath: Self.stateFile),
      .queryConversation(stateFilePath: Self.stateFile, allowWikiEdits: true),
      .lint(stateFilePath: Self.stateFile),
    ] {
      let prompt = operation.prompt(wikiRoot: Self.resolvedRoot)
      // The read-only-by-design rule + the "never search for a mutation tool / never
      // test the mount" guard + the exact wikictl write commands MUST be in the -p
      // prompt itself (not only the appended system prompt).
      #expect(prompt.contains("READ-ONLY BY DESIGN"))
      #expect(prompt.contains("NEVER search for a \"mutation tool\""))
      #expect(prompt.contains("wikictl page upsert --title T --body-file -"))
      #expect(prompt.contains("wikictl index set --body-file -"))
      #expect(prompt.contains("wikictl log append --kind ingest"))
      #expect(prompt.contains("$WIKI_DB"))
      #expect(prompt.contains("[[Page Title]]"))
    }
  }

  // MARK: - Prompts: the staged paths + don't-rediscover (problem #2)

  @Test func ingestPromptsNameTheStagedSourceAndStateAndForbidRediscovery() {
    for operation in [Self.tinyIngest(), Self.curatedIngest()] {
      let prompt = operation.prompt(wikiRoot: Self.resolvedRoot)
      // Names the staged WIKI_STATE.md and the staged source path(s).
      #expect(prompt.contains(Self.stateFile) || prompt.contains("/tmp/scratch-xyz/WIKI_STATE.md"))
      guard case .ingest(_, let stagedPaths, _, _) = operation else { Issue.record("not ingest"); return }
      for path in stagedPaths {
        #expect(prompt.contains(path))
      }
      // Forbids the orientation turns.
      #expect(prompt.contains("DO NOT REDISCOVER"))
      #expect(prompt.contains("do NOT run `wikictl page list`"))
    }
  }

  @Test func ingestPromptsTellOpusToFootnoteConclusionsWithSourceLocations() {
    for operation in [Self.tinyIngest(), Self.curatedIngest()] {
      let prompt = operation.prompt(wikiRoot: Self.resolvedRoot)
      #expect(prompt.contains("FOOTNOTE EVERY CLAIM"))
      #expect(prompt.contains("FOR WIKI SOURCES"))
      #expect(prompt.contains("FOR EXTERNAL SOURCES"))
      #expect(prompt.contains("wikictl source list --json"))
      #expect(prompt.contains("[[source:DisplayName#"))
      #expect(prompt.contains("`[^id]: [[source:"))
      #expect(prompt.contains("distinctive quote"))
      #expect(prompt.contains("`#` IS NOT `|`"))
      #expect(prompt.contains("WRONG — do NOT do any of this"))
    }
  }

  @Test func queryAndLintPromptsDoNotCarryIngestFootnoteRule() {
    for operation: WikiOperation in [
      .query(question: "q", stateFilePath: Self.stateFile),
      .queryConversation(stateFilePath: Self.stateFile, allowWikiEdits: false),
      .lint(stateFilePath: Self.stateFile),
    ] {
      let prompt = operation.prompt(wikiRoot: Self.resolvedRoot)
      #expect(!prompt.contains("FOOTNOTE EVERY CLAIM"))
      #expect(!prompt.contains("`[^id]: [[source:"))
    }
  }

  @Test func queryPromptsCarryAnswerCitationRule() {
    // Query ANSWERS cite sources differently from Ingest footnotes: a source
    // wikilink plus the visible passage. Both Query surfaces carry that rule.
    for operation: WikiOperation in [
      .query(question: "q", stateFilePath: Self.stateFile),
      .queryConversation(stateFilePath: Self.stateFile, allowWikiEdits: false),
    ] {
      let prompt = operation.prompt(wikiRoot: Self.resolvedRoot)
      #expect(prompt.contains("CITE SOURCES IN YOUR ANSWER"))
      #expect(prompt.contains("[[source:DisplayName"))
      #expect(prompt.contains("[[source:Claim File Helper — ProPublica]]"))
    }
    // Lint health-checks; it doesn't cite sources, so it carries neither rule.
    let lint = WikiOperation.lint(stateFilePath: Self.stateFile)
      .prompt(wikiRoot: Self.resolvedRoot)
    #expect(!lint.contains("CITE SOURCES IN YOUR ANSWER"))
    #expect(!lint.contains("FOOTNOTE EVERY CLAIM"))
  }

  @Test func queryAndLintPromptsNameStateAndForbidRediscovery() {
    for operation: WikiOperation in [
      .query(question: "q", stateFilePath: Self.stateFile),
      .queryConversation(stateFilePath: Self.stateFile, allowWikiEdits: false),
      .lint(stateFilePath: Self.stateFile),
    ] {
      let prompt = operation.prompt(wikiRoot: Self.resolvedRoot)
      #expect(prompt.contains(Self.stateFile))
      #expect(prompt.contains("DO NOT REDISCOVER"))
      // No source for query/lint, so it must not claim a staged source.
      #expect(!prompt.contains("source is staged"))
    }
  }

  @Test func queryPromptNamesWikiStructureAndCanFollowFootnotesToRawFiles() {
    let prompt = WikiOperation.query(
      question: "q",
      stateFilePath: Self.stateFile
    ).prompt(wikiRoot: Self.resolvedRoot)

    #expect(prompt.contains("WIKI-STRUCTURE.md"))
    #expect(prompt.contains("wikictl page get --title T"))
    #expect(prompt.contains("Markdown footnotes"))
    #expect(prompt.contains("FOLLOW THEM"))
    // The Query prompt now routes raw-file reads through wikictl, not the mount.
    #expect(prompt.contains("wikictl source list"))
    #expect(prompt.contains("wikictl source cat --id"))
    #expect(prompt.contains("wikictl source export --id"))
    #expect(prompt.contains("Read"))
    #expect(prompt.contains("pdftotext"))
    #expect(prompt.contains("strings"))
    // Old mount paths should be gone.
    #expect(!prompt.contains("$WIKI_ROOT/files/by-name/"))
    #expect(!prompt.contains("$WIKI_ROOT/files/by-id/"))
    #expect(!prompt.contains("$WIKI_ROOT/indexes/files.jsonl"))
    #expect(!prompt.contains("files/..."))
  }

  // MARK: - Prompts: the curator digester-fan-out guardrail (large ingest only)

  @Test func curatorPromptStatesThe2to19DigesterGuardrailAndIterativeUse() {
    let prompt = Self.curatedIngest().prompt(wikiRoot: Self.resolvedRoot)
    // The 2..19 guardrail, on the Sonnet `source-reader` digesters.
    #expect(prompt.contains("MORE THAN 1 and FEWER THAN 20"))
    #expect(prompt.contains("between 2 and 19"))
    #expect(prompt.contains("source-reader"))
    #expect(prompt.contains("use Sonnet `source-reader` workers, not Opus"))
    #expect(prompt.contains("FAN OUT RAW INGESTION to Sonnet `source-reader` subagents"))
    // Size the fan-out to the material.
    #expect(prompt.contains("do NOT spawn 15 workers for 3 pages"))
    // Opus may fork MORE workers for follow-up questions, and may pull pages to
    // double-check before/while writing — the iterative use, capped at <20 total.
    #expect(prompt.contains("follow-up"))
    #expect(prompt.contains("QUESTIONS"))
    #expect(prompt.contains("wikictl page get"))
    #expect(prompt.contains("double-check"))
    #expect(prompt.contains("under 20"))
    // The workers DIGEST (read) — they do not write the wiki.
    #expect(prompt.lowercased().contains("workers do not"))
    // The curator (Opus) writes the pages + index + log itself.
    #expect(prompt.contains("WRITE every page yourself"))
    #expect(prompt.contains("wikictl index set"))
  }

  @Test func tinyIngestPromptHasNoDigesterFanOut() {
    // The single Opus pass has no fan-out.
    let prompt = Self.tinyIngest().prompt(wikiRoot: Self.resolvedRoot)
    #expect(!prompt.contains("between 2 and 19"))
    #expect(!prompt.contains("source-reader"))
  }

  // MARK: - Prompts: DRY against the schema (no layout duplication)

  @Test func ingestAndLintPromptsDoNotDuplicateTheSchemaLayoutMap() {
    for operation: WikiOperation in [
      Self.tinyIngest(),
      Self.curatedIngest(),
      .lint(stateFilePath: Self.stateFile),
    ] {
      let prompt = operation.prompt(wikiRoot: Self.resolvedRoot)
      // The resolved root is still injected and labelled WIKI_ROOT.
      #expect(prompt.contains(Self.resolvedRoot))
      #expect(prompt.contains("WIKI_ROOT"))
      // The schema's layout map lives ONLY in --append-system-prompt (CLAUDE.md) —
      // the operational write rule is duplicated here BY DESIGN, but the layout map
      // and conventions are NOT.
      #expect(!prompt.contains("pages/by-title/"))
      #expect(!prompt.contains("files/by-name/"))
      #expect(!prompt.contains("TREE.md"))
      #expect(!prompt.contains("Concept pages explain one idea"))
    }
  }

  @Test func operationKindTitlesAreStable() {
    #expect(Self.tinyIngest().kind == .ingest)
    #expect(WikiOperation.query(question: "q", stateFilePath: "s").kind == .query)
    #expect(WikiOperation.lint(stateFilePath: "s").kind == .lint)
    #expect(WikiOperation.Kind.ingest.title == "Ingest")
    #expect(WikiOperation.Kind.query.title == "Query")
    #expect(WikiOperation.Kind.lint.title == "Lint")
  }

  // MARK: - Mount-unavailable prompts (the agent reads via wikictl, not the mount)

  @Test func promptsNoteWhenTheMountIsUnavailable() {
    // With an empty WIKI_ROOT (File Provider not mounted), the prompts must tell the
    // agent to read via `wikictl` only, instead of an empty reference path.
    for operation: WikiOperation in [
      Self.tinyIngest(),
      Self.curatedIngest(),
      .query(question: "q", stateFilePath: Self.stateFile),
      .queryConversation(stateFilePath: Self.stateFile, allowWikiEdits: false),
      .lint(stateFilePath: Self.stateFile),
    ] {
      let prompt = operation.prompt(wikiRoot: "")
      #expect(prompt.contains("mount is not available"))
      #expect(prompt.contains("wikictl"))
      // No dangling empty reference path line.
      #expect(!prompt.contains("WIKI_ROOT (resolved, read-only mount — reference only): \n"))
    }
  }

  @Test func promptsKeepTheResolvedMountPathWhenAvailable() {
    // A non-empty WIKI_ROOT still renders the reference-only path line.
    for operation: WikiOperation in [
      Self.tinyIngest(),
      .query(question: "q", stateFilePath: Self.stateFile),
      .lint(stateFilePath: Self.stateFile),
    ] {
      let prompt = operation.prompt(wikiRoot: Self.resolvedRoot)
      #expect(prompt.contains("WIKI_ROOT (resolved, read-only mount — reference only): \(Self.resolvedRoot)"))
      #expect(!prompt.contains("mount is not available"))
    }
  }

  // MARK: - PathPreflight

  @Test func preflightFindsExecutableOnPath() {
    let result = PathPreflight.resolve(
      executable: "claude",
      onPath: "/usr/bin:/opt/homebrew/bin:/bin",
      fileExists: { $0 == "/opt/homebrew/bin/claude" })
    #expect(result == .found(path: "/opt/homebrew/bin/claude"))
  }

  @Test func preflightReportsMissingWhenNotOnPath() {
    let result = PathPreflight.resolve(
      executable: "claude", onPath: "/usr/bin:/bin", fileExists: { _ in false })
    guard case .missing(let reason) = result else {
      Issue.record("expected .missing")
      return
    }
    #expect(reason.contains("claude"))
    #expect(reason.contains("PATH"))
  }

  @Test func preflightHonorsPathOrderFirstHitWins() {
    let result = PathPreflight.resolve(
      executable: "claude",
      onPath: "/a:/b:/c",
      fileExists: { $0 == "/b/claude" || $0 == "/c/claude" })
    #expect(result == .found(path: "/b/claude"))
  }

  @Test func preflightTestsAbsolutePathDirectlyWithoutPath() {
    let found = PathPreflight.resolve(
      executable: "/opt/claude", onPath: "", fileExists: { $0 == "/opt/claude" })
    #expect(found == .found(path: "/opt/claude"))

    let missing = PathPreflight.resolve(
      executable: "/opt/claude", onPath: "", fileExists: { _ in false })
    guard case .missing = missing else {
      Issue.record("expected .missing for absent absolute path")
      return
    }
  }

  @Test func preflightEmptyExecutableIsMissing() {
    let result = PathPreflight.resolve(executable: "", onPath: "/bin", fileExists: { _ in true })
    guard case .missing = result else {
      Issue.record("expected .missing for empty executable")
      return
    }
  }
}
