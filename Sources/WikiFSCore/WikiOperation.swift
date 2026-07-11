import Foundation

/// The three discrete `claude -p` operations the app can run against the
/// currently-selected wiki (`plans/llm-wiki.md` Phase C, decision #2): **Ingest**,
/// **Query**, and **Lint**.
///
/// This is a PURE value type — it carries only the per-run inputs (the ingest
/// source, the query text, the staged scratch paths) and knows how to render the
/// operation's **own prompt**. It deliberately does NOT spawn anything:
/// command/env/cwd assembly lives in `OperationCommand` (also pure), and the actual
/// `Process` spawn lives in the app's `AgentLauncher`. Keeping the prompt/command
/// construction pure is what makes the Phase-C deterministic seams unit-testable
/// without a real agent run.
///
/// **The static/dynamic/operational split.** The maintainer schema
/// (`SystemPrompt.defaultBody`, projected as `CLAUDE.md`/`AGENTS.md`) is delivered
/// every run via `--append-system-prompt` and documents the LAYOUT and CONVENTIONS
/// (page shapes, the `[[link]]` rule, the workflows). Each operation's `-p` prompt
/// carries (a) the OPERATIONAL write rule + the exact `wikictl` write commands —
/// load-bearing enough that the schema-only placement got under-weighted (the agent
/// probed the read-only mount; `feature/ingest-fewer-turns` problem #1) — plus (b)
/// the dynamic per-run facts the schema can't contain: the resolved absolute
/// `WIKI_ROOT` and the absolute scratch paths of the staged source / wiki-state
/// snapshot. It does NOT restate the layout map (DRY against the schema).
public enum WikiOperation: Equatable, Sendable {
  /// Summarize one or more ingested source files into the wiki in a single agent run.
  ///
  /// - `sourcePaths`: the sources' mount-relative paths under `$WIKI_ROOT` (kept for
  ///   reference / the rare mount fallback).
  /// - `stagedSourcePaths`: the ABSOLUTE scratch paths the app staged the raw source
  ///   bytes to as `source-1.<ext>`, `source-2.<ext>`, … (read from SQLite, not the
  ///   laggy mount) — what the agent actually reads.
  /// - `stateFilePath`: the ABSOLUTE scratch path of the staged `WIKI_STATE.md`
  ///   snapshot (titles + index.md + log tail) — so the agent skips orientation.
  /// - `plan`: the model-tiering decision (single Opus pass vs Opus curator + Sonnet
  ///   digesters), based on total source byte size. Opus writes in BOTH modes.
  case ingest(
    sourcePaths: [String],
    stagedSourcePaths: [String],
    stateFilePath: String,
    plan: IngestPlan
  )

  /// Answer a question from the wiki's contents, returning a cited answer.
  /// `stateFilePath` is the staged `WIKI_STATE.md` snapshot.
  case query(question: String, stateFilePath: String)

  /// Keep a query chat open. User turns arrive over stdin, and Claude may
  /// answer or update the wiki with `wikictl`. Chats are always write-capable
  /// now (the read-only Ask mode was removed); `allowWikiEdits` is retained
  /// on the case for signature stability but is always `true` from the chat
  /// path. The one-shot `.query` op remains read-only by construction.
  case queryChat(stateFilePath: String, allowWikiEdits: Bool = true)

  /// Health-check the wiki and report findings. `stateFilePath` is the staged
  /// `WIKI_STATE.md` snapshot.
  case lint(stateFilePath: String)

  /// Health-check a single page. `brokenLinks` is the pre-computed list of
  /// `[[page titles]]` that do not resolve to existing pages (computed in-app
  /// by `WikiStoreModel.preflightLint` before the LLM run so the agent has
  /// concrete targets rather than having to discover issues itself).
  case lintPage(pageTitle: String, brokenLinks: [String], stateFilePath: String)

  /// A short, stable identifier for the operation kind (logging / UI).
  public var kind: Kind {
    switch self {
    case .ingest: .ingest
    case .query, .queryChat: .query
    case .lint, .lintPage: .lint
    }
  }

  public enum Kind: String, CaseIterable, Sendable {
    case ingest
    case query
    case lint

    /// User-facing title for the operation.
    public var title: String {
      switch self {
      case .ingest: "Ingest"
      case .query: "Query"
      case .lint: "Lint"
      }
    }
  }

  /// The top-level `--model` alias for this operation. ALWAYS `opus`: Opus is the
  /// curator/writer for both Ingest modes, and Query/Lint are light, single-agent,
  /// judgement-heavy Opus runs. (Ingest's tiering is in the FAN-OUT — whether it
  /// forks Sonnet digesters — not in the top-level model.)
  public var topLevelModelAlias: String {
    switch self {
    case .ingest(_, _, _, let plan): plan.topLevelModelAlias
    case .query, .queryChat, .lint, .lintPage: "opus"
    }
  }

  /// The `--agents` JSON for this operation, or nil when it runs single-agent.
  /// Only a large-source Ingest defines subagents (the Sonnet `source-reader`
  /// digester); the tiny Ingest, Query, and Lint never do.
  public var agentsJSON: String? {
    switch self {
    case .ingest(_, _, _, let plan): plan.agentsJSON()
    case .query, .queryChat, .lint, .lintPage: nil
    }
  }
}

extension WikiOperation {
  /// The operation's OWN `-p` prompt. Leads with the unmissable write rule + the
  /// exact `wikictl` write commands (problem #1), then the "don't rediscover"
  /// directive naming the staged files (problem #2), then the per-op task. The
  /// schema (delivered via `--append-system-prompt`) still carries the layout map
  /// and conventions — this prompt does NOT restate those (DRY).
  ///
  /// - Parameters:
  ///   - wikiRoot: the wiki's LIVE mount path, RESOLVED at click time and passed in
  ///     (NOT `$WIKI_ROOT` for the agent to expand).
  public func prompt(wikiRoot: String) -> String {
    switch self {
    case .ingest(let sourcePaths, let stagedSourcePaths, let stateFilePath, let plan):
      let sourceIDs = sourcePaths.map { Self.sourceID(fromPath: $0) }
      switch plan {
      case .singleOpus:
        return Self.ingestSinglePrompt(
          wikiRoot: wikiRoot,
          sourcePaths: sourcePaths,
          stagedSourcePaths: stagedSourcePaths,
          stateFilePath: stateFilePath,
          sourceIDs: sourceIDs)
      case .opusCurator:
        return Self.ingestCuratorPrompt(
          wikiRoot: wikiRoot,
          sourcePaths: sourcePaths,
          stagedSourcePaths: stagedSourcePaths,
          stateFilePath: stateFilePath,
          sourceIDs: sourceIDs)
      }
    case .query(let question, let stateFilePath):
      return Self.queryPrompt(
        wikiRoot: wikiRoot, question: question, stateFilePath: stateFilePath)
    case .queryChat(let stateFilePath, let allowWikiEdits):
      return Self.queryChatPrompt(wikiRoot: wikiRoot, stateFilePath: stateFilePath, allowWikiEdits: allowWikiEdits)
    case .lint(let stateFilePath):
      return Self.lintPrompt(wikiRoot: wikiRoot, stateFilePath: stateFilePath)
    case .lintPage(let pageTitle, let brokenLinks, let stateFilePath):
      return Self.lintPagePrompt(
        wikiRoot: wikiRoot, pageTitle: pageTitle,
        brokenLinks: brokenLinks, stateFilePath: stateFilePath)
    }
  }

  /// Recover the source id from its `sources/by-id/<id>[.ext]` path —
  /// the leaf stem IS the id (`FilenameEscaping.byIDSourceFilename`). The agent
  /// echoes it back via `wikictl log append --kind ingest --source <id>`.
  public static func sourceID(fromPath path: String) -> String {
    let leaf = (path as NSString).lastPathComponent
    return (leaf as NSString).deletingPathExtension
  }

  // MARK: - Ingest prompts

  /// The closing `WIKI_ROOT` line. The mount is **reference-only** (the agent reads
  /// pages and raw sources via `wikictl`/SQLite, not the mount), so an unavailable
  /// mount never blocks an operation — but the line tells the agent explicitly when the
  /// mount is down so it doesn't try to read from a path that isn't there.
  private static func wikiRootLine(_ wikiRoot: String) -> String {
    if wikiRoot.isEmpty {
      return "WIKI_ROOT: (File Provider mount is not available for this run — read pages and raw sources via `wikictl` only.)"
    }
    return "WIKI_ROOT (resolved, read-only mount — reference only): \(wikiRoot)"
  }

  /// Single-pass Ingest (tiny total source): one Opus pass does the whole ingest
  /// itself via `wikictl`. No fan-out — Opus reads the small staged source(s) and
  /// writes the pages + index + log. (Opus is the curator even for small sources.)
  /// Leads with the write rule because Opus is the writer.
  private static func ingestSinglePrompt(
    wikiRoot: String,
    sourcePaths: [String],
    stagedSourcePaths: [String],
    stateFilePath: String,
    sourceIDs: [String]
  ) -> String {
    let task = PromptTemplate.fill(GeneratedPrompts.ingestSingleTask, [
      "fileCount": "\(sourcePaths.count)",
      "fileNoun": sourcePaths.count == 1 ? "" : "s",
      "sourceIds": sourceIDs.joined(separator: ", "),
    ])
    return """
    \(IngestWriteRule.writes)

    \(IngestWriteRule.dontRediscover(stateFilePath: stateFilePath, sourceFilePaths: stagedSourcePaths))

    \(footnoteConclusionsRule)

    \(sourcesSection(sourcePaths: sourcePaths, stagedSourcePaths: stagedSourcePaths))

    \(task)

    \(Self.wikiRootLine(wikiRoot))
    """
  }

  /// Large-source Ingest: an Opus CURATOR delegates raw source ingestion to Sonnet
  /// `source-reader` digesters, then DECIDES the page set and WRITES every page +
  /// index.md + the log entries itself. The 2..19 digester guardrail and the
  /// "fork more for follow-up questions / pull pages to double-check" affordances are
  /// stated prompt-level. Leads with the write rule because Opus is the writer.
  private static func ingestCuratorPrompt(
    wikiRoot: String,
    sourcePaths: [String],
    stagedSourcePaths: [String],
    stateFilePath: String,
    sourceIDs: [String]
  ) -> String {
    let task = PromptTemplate.fill(GeneratedPrompts.ingestCuratorTask, [
      "fileCount": "\(sourcePaths.count)",
      "fileNoun": sourcePaths.count == 1 ? "" : "s",
      "largePhrase": sourcePaths.count == 1 ? "The source is LARGE" : "The sources are LARGE",
      "stagedSourceList": stagedSourcePaths.joined(separator: ", "),
      "sourceIds": sourceIDs.joined(separator: ", "),
    ])
    return """
    \(IngestWriteRule.writes)

    \(IngestWriteRule.dontRediscover(stateFilePath: stateFilePath, sourceFilePaths: stagedSourcePaths))

    \(footnoteConclusionsRule)

    \(sourcesSection(sourcePaths: sourcePaths, stagedSourcePaths: stagedSourcePaths))

    \(task)

    \(Self.wikiRootLine(wikiRoot))
    """
  }

  /// Renders the source list for the prompt: each source's scratch path + original
  /// wiki path.
  private static func sourcesSection(sourcePaths: [String], stagedSourcePaths: [String]) -> String {
    var lines = ["SOURCES (\(sourcePaths.count) file\(sourcePaths.count == 1 ? "" : "s")):"]
    for i in 0..<sourcePaths.count {
      let stagedLeaf = (stagedSourcePaths[i] as NSString).lastPathComponent
      lines.append("- \(stagedLeaf)    (from \(sourcePaths[i]))")
    }
    return lines.joined(separator: "\n")
  }

  /// Every claim drawn from a source MUST be footnoted. The format depends on
  /// whether the source lives in the wiki's `sources/` directory.
  /// - Wiki sources (ANY file in `sources/` — look up display names with
  ///   `wikictl source list --json` or check `sources.jsonl`): use
  ///   `[[source:DisplayName#"quote"]]` — a clickable wikilink that navigates to
  ///   the source and scrolls to the quoted passage.
  /// - External sources (papers, books, URLs NOT in `sources/`): use a standard
  ///   academic-style citation: Author (Year), "Title", Journal/Publisher, DOI/URL.
  private static let footnoteConclusionsRule: String = GeneratedPrompts.footnoteConclusionsRule

  /// Citations in a Query ANSWER (chat) — distinct from Ingest's `[^id]` page
  /// footnotes. The answer is prose, so the agent must both LINK the source and
  /// SHOW the passage; without this rule it falls back to inert prose like
  /// `Name.md, "Section" — "quote"` (no link, a `.md` extension, and the passage
  /// stranded outside any link). Ratified format: a source wikilink followed by
  /// the quoted passage in plain text.
  private static let answerCitationRule: String = GeneratedPrompts.answerCitationRule

  // MARK: - Query / Lint prompts

  /// Query stays single-agent Opus, but still gets the write rule (it may file an
  /// answer page) + the staged-state / don't-rediscover directive.
  private static func queryPrompt(
    wikiRoot: String,
    question: String,
    stateFilePath: String
  ) -> String {
    return """
    \(IngestWriteRule.writes)

    \(IngestWriteRule.dontRediscover(stateFilePath: stateFilePath))

    \(answerCitationRule)

    \(GeneratedPrompts.queryTask)

    \(Self.wikiRootLine(wikiRoot))
    Question: \(question)
    """
  }

  /// Interactive chat stays alive across user turns. Chats are always
  /// write-capable now (the read-only Ask mode was removed), so the write-rule
  /// block (`IngestWriteRule.writes`) is always included. The seatbelt sandbox
  /// + `--allowed-tools` remain the authoritative write gate.
  private static func queryChatPrompt(
    wikiRoot: String, stateFilePath: String, allowWikiEdits: Bool = true
  ) -> String {
    let writeRule = allowWikiEdits ? "\(IngestWriteRule.writes)\n\n" : ""
    return """
    \(writeRule)\(IngestWriteRule.dontRediscover(stateFilePath: stateFilePath))

    \(answerCitationRule)

    \(GeneratedPrompts.chat)

    \(Self.wikiRootLine(wikiRoot))
    """
  }

  /// Lint stays single-agent Opus, with the write rule (it logs and may file a
  /// report) + the staged-state / don't-rediscover directive.
  private static func lintPrompt(wikiRoot: String, stateFilePath: String) -> String {
    return """
    \(IngestWriteRule.writes)

    \(IngestWriteRule.dontRediscover(stateFilePath: stateFilePath))

    \(GeneratedPrompts.lintTask)

    \(Self.wikiRootLine(wikiRoot))
    """
  }

  /// Single-page lint: pre-flight results (bracket fixes + broken links) are
  /// passed in so the agent has concrete targets rather than discovering issues
  /// itself. Runs Opus single-agent with full write permissions.
  private static func lintPagePrompt(
    wikiRoot: String,
    pageTitle: String,
    brokenLinks: [String],
    stateFilePath: String
  ) -> String {
    let linksSection: String
    if brokenLinks.isEmpty {
      linksSection = "Broken [[wiki links]]: none detected."
    } else {
      let list = brokenLinks.map { "  - [[\($0)]]" }.joined(separator: "\n")
      linksSection = """
        Broken [[wiki links]] (targets not found in the wiki):
        \(list)
        """
    }
    let task = PromptTemplate.fill(GeneratedPrompts.lintPageTask, [
      "pageTitle": pageTitle,
      "linksSection": linksSection,
    ])
    return """
      \(IngestWriteRule.writes)

      \(IngestWriteRule.dontRediscover(stateFilePath: stateFilePath))

      \(task)

      \(Self.wikiRootLine(wikiRoot))
      """
  }
}
