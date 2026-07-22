import Foundation

/// Loads prompt markdown files bundled as SwiftPM resources.
///
/// The prompts live as `.md` files in `Sources/WikiFSCore/Resources/Prompts/`
/// and are declared in `Package.swift` via `.copy("Resources/Prompts")`.
/// At build time SwiftPM bundles them into the module's resource bundle,
/// accessible via `Bundle.module`. This type provides the same `static let`
/// API surface as the former code-generated `GeneratedPrompts` enum, but each
/// constant is loaded from the bundle at access time.
///
/// To edit a prompt, modify the `.md` file in
/// `Sources/WikiFSCore/Resources/Prompts/` (or the canonical source in
/// `prompts/` and run `make prompts` to sync).
enum GeneratedPrompts {
    /// Loads a prompt's verbatim bytes from the bundled resources.
    /// Fatal if the file is missing (build-time wiring bug).
    private static func load(_ name: String) -> String {
        guard let url = Bundle.module.url(
            forResource: name, withExtension: "md",
            subdirectory: "Prompts"
        ) ?? Bundle.module.url(forResource: name, withExtension: "md"),
              let body = try? String(contentsOf: url, encoding: .utf8)
        else {
            fatalError("GeneratedPrompts: cannot load '\(name).md' from Bundle.module — check Package.swift resources declaration")
        }
        return body
    }

    static let systemPromptDefault = load("system-prompt-default")
    static let wikiIndexDefault = load("wiki-index-default")
    static let ingestWriteRule = load("ingest-write-rule")
    static let footnoteConclusionsRule = load("footnote-conclusions-rule")
    static let answerCitationRule = load("answer-citation-rule")
    static let digesterPrompt = load("digester-prompt")
    static let extractionSystem = load("extraction-system")
    static let extractionInstruction = load("extraction-instruction")
    static let sourceReaderDescription = load("source-reader-description")
    static let dontRediscoverLeaf = load("dont-rediscover-leaf")
    static let wikiTreeRender = load("wiki-tree-render")
    static let ingestSingleTask = load("ingest-single-task")
    static let ingestCuratorTask = load("ingest-curator-task")
    static let queryTask = load("query-task")
    static let chat = load("chat")
    static let lintTask = load("lint-task")
    static let lintPageTask = load("lint-page-task")
    static let ingestPlanner = load("ingest-planner")
    static let ingestExecutor = load("ingest-executor")
    static let ingestFinalizer = load("ingest-finalizer")
}
