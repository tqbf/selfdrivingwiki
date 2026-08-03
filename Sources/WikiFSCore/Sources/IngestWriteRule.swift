import Foundation

/// The load-bearing operational rules that MUST live in the `-p` prompt itself —
/// not only in `--append-system-prompt` (`plans/llm-wiki.md` Phase D / the
/// `feature/ingest-fewer-turns` fix).
///
/// **Why this is in the `-p` prompt, not just the schema.** Phase D moved the
/// `wikictl` write-rule entirely into the appended system prompt, which the agent
/// under-weights: in a live run it printed *"The mount is read-only. There must be
/// a dedicated tool for wiki mutations. Let me search."*, ran ToolSearch, then
/// `echo > pages/by-title/__wikitest__.md` to *test* whether the read-only mount is
/// writable. The fix is to put the load-bearing write rule + the exact `wikictl`
/// write commands back in the `-p` prompt, where the agent weights them, while the
/// broader layout/conventions stay in the schema (DRY — see the assertions in
/// `OperationCommandTests`).
///
/// PURE: two constant blocks, composed into each operation prompt. The write rule
/// belongs with WHOEVER WRITES — which is always the top-level OPUS run (the single
/// Ingest pass, the Ingest curator, Query, and Lint). The Sonnet `source-reader`
/// digester never writes, so it carries NO write rule (see `IngestPlan.digesterPrompt`).
public enum IngestWriteRule {
  /// The unmissable imperative write-rule block. Leads every Opus operation prompt
  /// (the single Ingest pass, the Ingest curator, Query, Lint — the writers). States
  /// the read-only-by-design rule, the "never search for a mutation tool / never test
  /// the mount" guard, and the exact `wikictl` write commands — the three problems
  /// #1 fixes. It is NOT in the Sonnet digester prompt, which only reads.
  public static let writes: String = GeneratedPrompts.ingestWriteRule

  /// The "don't rediscover" directive. Names the locally-staged files (the live
  /// wiki-state snapshot and the raw source(s)) and forbids the orientation turns
  /// (`wikictl page list`, re-reading `index.md`/`log.md`) the agent burns
  /// rediscovering what the app already staged — problem #2.
  ///
  /// - Parameters:
  ///   - stateFilePath: absolute scratch path of the staged `WIKI_STATE.md`.
  ///   - sourceFilePaths: absolute scratch paths of the staged source(s) (empty
  ///     for ops with no source, e.g. Query/Lint).
  public static func dontRediscover(stateFilePath: String, sourceFilePaths: [String] = []) -> String {
    var lines = [
      PromptTemplate.fill(GeneratedPrompts.dontRediscoverLeaf, ["stateFilePath": stateFilePath])
    ]
    if !sourceFilePaths.isEmpty {
      let list = sourceFilePaths.enumerated().map { (i, path) in
        "source-\(i + 1) at \(path)"
      }.joined(separator: ", ")
      lines.append(
        "The source(s) to ingest are staged locally — \(list) — read them THERE "
          + "(reliable local disk), not from the laggy read-only mount.")
    }
    return lines.joined(separator: "\n")
  }
}
