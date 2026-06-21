import Foundation

/// Renders the exact `claude -p` command/prompt templates for the Help menu.
///
/// This intentionally calls the production prompt builders (`WikiOperation`,
/// `OperationCommand`, and `IngestPlan`) using placeholder paths, so the help
/// window stays coupled to the real invocation surface instead of a stale copy.
public enum ClaudePromptHelp {
  public static let wikiRootPlaceholder = "<resolved WIKI_ROOT mount path>"
  public static let wikiIDPlaceholder = "<active wiki ULID>"
  public static let systemPromptPlaceholder = "<active wiki System Prompt body>"
  public static let scratchDirectoryPlaceholder = "<per-run writable scratch directory>"
  public static let wikictlDirectoryPlaceholder = "<app bundle Contents/Helpers>"
  public static let stagedSourcePlaceholder = "<scratch>/source"
  public static let stateFilePlaceholder = "<scratch>/WIKI_STATE.md"

  public static var documents: [ClaudePromptHelpDocument] {
    [
      ClaudePromptHelpDocument(
        id: "command",
        title: "Command Template",
        summary: "The argv, cwd, and environment used when the app launches Claude.",
        body: commandTemplate),
      ClaudePromptHelpDocument(
        id: "ingest-single",
        title: "Ingest -p Prompt (Single Opus)",
        summary: "Used for tiny sources below the ingest fan-out threshold.",
        body: tinyIngest.prompt(wikiRoot: wikiRootPlaceholder)),
      ClaudePromptHelpDocument(
        id: "ingest-curator",
        title: "Ingest -p Prompt (Opus Curator)",
        summary: "Used for larger sources; Opus writes while Sonnet workers digest chunks.",
        body: curatedIngest.prompt(wikiRoot: wikiRootPlaceholder)),
      ClaudePromptHelpDocument(
        id: "query",
        title: "Query -p Prompt",
        summary: "Used when answering a question from the wiki.",
        body: WikiOperation
          .query(question: "<question typed in the Query sheet>", stateFilePath: stateFilePlaceholder)
          .prompt(wikiRoot: wikiRootPlaceholder)),
      ClaudePromptHelpDocument(
        id: "lint",
        title: "Lint -p Prompt",
        summary: "Used when health-checking the wiki.",
        body: WikiOperation
          .lint(stateFilePath: stateFilePlaceholder)
          .prompt(wikiRoot: wikiRootPlaceholder)),
      ClaudePromptHelpDocument(
        id: "agents",
        title: "Large Ingest --agents JSON",
        summary: "The inline source-reader subagent template passed only for large-source ingest.",
        body: IngestPlan.opusCurator.agentsJSON() ?? "{}"),
      ClaudePromptHelpDocument(
        id: "append-system-prompt",
        title: "--append-system-prompt",
        summary: "This is not duplicated here because it is the editable System Prompt document.",
        body: systemPromptPlaceholder),
    ]
  }

  public static var commandTemplate: String {
    let command = OperationCommand.build(
      operation: curatedIngest,
      wikiRoot: wikiRootPlaceholder,
      wikiID: wikiIDPlaceholder,
      systemPrompt: systemPromptPlaceholder,
      scratchDirectory: scratchDirectoryPlaceholder,
      wikictlDirectory: wikictlDirectoryPlaceholder,
      claudeExecutable: "claude",
      baseEnvironment: ["PATH": "<inherited PATH>"])

    return """
      cwd: \(command.currentDirectoryPath)
      env:
        WIKI_ROOT=\(command.environment["WIKI_ROOT"] ?? "")
        WIKI_DB=\(command.environment["WIKI_DB"] ?? "")
        PATH=\(command.environment["PATH"] ?? "")

      argv:
      \(renderCommand(command))
      """
  }

  private static var tinyIngest: WikiOperation {
    .ingest(
      sourcePaths: ["sources/by-id/<file-id>"],
      stagedSourcePaths: [stagedSourcePlaceholder],
      stateFilePath: stateFilePlaceholder,
      plan: .singleOpus)
  }

  private static var curatedIngest: WikiOperation {
    .ingest(
      sourcePaths: ["sources/by-id/<file-id>"],
      stagedSourcePaths: [stagedSourcePlaceholder],
      stateFilePath: stateFilePlaceholder,
      plan: .opusCurator)
  }

  private static func renderCommand(_ command: OperationCommand) -> String {
    ([command.executable] + command.arguments)
      .map(shellQuoted)
      .joined(separator: " \\\n  ")
  }

  private static func shellQuoted(_ value: String) -> String {
    if value.range(of: #"^[A-Za-z0-9_@%+=:,./-]+$"#, options: .regularExpression) != nil {
      return value
    }
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
