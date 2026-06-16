import Testing
@testable import WikiFSCore

struct ClaudePromptHelpTests {
  @Test func exposesCommandOperationPromptsAgentsAndSystemPromptPlaceholder() {
    let documents = ClaudePromptHelp.documents
    #expect(documents.map(\.id) == [
      "command",
      "ingest-single",
      "ingest-curator",
      "query",
      "lint",
      "agents",
      "append-system-prompt",
    ])
  }

  @Test func commandTemplateUsesTheRealOperationCommandSurface() {
    let template = ClaudePromptHelp.commandTemplate
    #expect(template.contains("claude"))
    #expect(template.contains("-p"))
    #expect(template.contains("--model"))
    #expect(template.contains("opus"))
    #expect(template.contains("--output-format"))
    #expect(template.contains("stream-json"))
    #expect(template.contains("--append-system-prompt"))
    #expect(template.contains("--dangerously-skip-permissions"))
    #expect(template.contains("--agents"))
    #expect(template.contains("WIKI_ROOT=<resolved WIKI_ROOT mount path>"))
    #expect(template.contains("WIKI_DB=<active wiki ULID>"))
    #expect(!template.contains("\\\n+"))
  }

  @Test func promptDocumentsComeFromProductionPromptBuilders() {
    let byID = Dictionary(uniqueKeysWithValues: ClaudePromptHelp.documents.map { ($0.id, $0.body) })
    let tiny = WikiOperation.ingest(
      sourcePath: "files/by-id/<file-id>",
      stagedSourcePath: ClaudePromptHelp.stagedSourcePlaceholder,
      stateFilePath: ClaudePromptHelp.stateFilePlaceholder,
      plan: .singleOpus)
    let curated = WikiOperation.ingest(
      sourcePath: "files/by-id/<file-id>",
      stagedSourcePath: ClaudePromptHelp.stagedSourcePlaceholder,
      stateFilePath: ClaudePromptHelp.stateFilePlaceholder,
      plan: .opusCurator)

    #expect(byID["ingest-single"] == tiny.prompt(wikiRoot: ClaudePromptHelp.wikiRootPlaceholder))
    #expect(byID["ingest-curator"] == curated.prompt(wikiRoot: ClaudePromptHelp.wikiRootPlaceholder))
    #expect(byID["agents"] == IngestPlan.opusCurator.agentsJSON())
  }
}
