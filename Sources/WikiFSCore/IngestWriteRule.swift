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
  public static let writes = """
    WRITES — READ THIS FIRST. The wiki mount is READ-ONLY BY DESIGN. NEVER write \
    files under it and NEVER search for a "mutation tool" or test whether the mount \
    is writable — writing the mount fails ON PURPOSE; do not probe it. The ONLY way \
    to create or update content is the `wikictl` command. It is already on your PATH \
    and already targets THIS wiki via the $WIKI_DB environment variable — do NOT \
    pass --wiki. Deliver the body via FILE, not a shell pipe or heredoc: write the \
    body to a file in your current working directory, then pass `--body-file <path>`. \
    Do NOT use `printf '<body>' | wikictl … --body-file -` or a `<<EOF` heredoc — \
    under the sandbox the body can arrive empty (a heredoc stages a temp file the \
    sandbox denies), and `wikictl` refuses an empty body. Write with:
      wikictl page upsert --title T --body-file ./body.md
      wikictl index set --body-file ./index.md
      wikictl log append --kind ingest --title "…" --note "…"
    After a write, read it back with `wikictl page get` (the mount lags the database \
    by ~5s, so cat-ing the mount right after a write shows stale bytes). Cross-link \
    pages with [[Page Title]] wiki-links.
    """

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
      "DO NOT REDISCOVER. The wiki's current state — existing page titles (your "
        + "cross-link vocabulary), the current index.md body, and the recent log "
        + "tail — is already staged locally at \(stateFilePath). Read THAT; do NOT run "
        + "`wikictl page list` or read index.md/log.md to rediscover it."
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
