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

  /// Keep a query conversation open. User turns arrive over stdin, and Claude may
  /// answer only, or update the wiki with `wikictl` when `allowWikiEdits` is true.
  case queryConversation(stateFilePath: String, allowWikiEdits: Bool)

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
    case .query, .queryConversation: .query
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
    case .query, .queryConversation, .lint, .lintPage: "opus"
    }
  }

  /// The `--agents` JSON for this operation, or nil when it runs single-agent.
  /// Only a large-source Ingest defines subagents (the Sonnet `source-reader`
  /// digester); the tiny Ingest, Query, and Lint never do.
  public var agentsJSON: String? {
    switch self {
    case .ingest(_, _, _, let plan): plan.agentsJSON()
    case .query, .queryConversation, .lint, .lintPage: nil
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
    case .queryConversation(let stateFilePath, let allowWikiEdits):
      return Self.queryConversationPrompt(wikiRoot: wikiRoot, stateFilePath: stateFilePath, allowWikiEdits: allowWikiEdits)
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
  static func sourceID(fromPath path: String) -> String {
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
    """
    \(IngestWriteRule.writes)

    \(IngestWriteRule.dontRediscover(stateFilePath: stateFilePath, sourceFilePaths: stagedSourcePaths))

    \(footnoteConclusionsRule)

    \(sourcesSection(sourcePaths: sourcePaths, stagedSourcePaths: stagedSourcePaths))

    TASK — Ingest \(sourcePaths.count) file\(sourcePaths.count == 1 ? "" : "s") into \
    the wiki, following the Ingest workflow from your instructions. Act immediately; \
    do not explore the mount first. Read each staged source, DECIDE what belongs in \
    the wiki, CROSS-REFERENCE across all sources to find connections and avoid \
    duplicates, and write one or more summary/entity/concept pages via \
    `wikictl page upsert` (cross-linking with [[wiki links]]). Then rewrite index.md \
    via `wikictl index set`, and for EACH ingested source record it with \
    `wikictl log append --kind ingest --source <id> --title "<source>"`. \
    The `--source` ids are: \(sourceIDs.joined(separator: ", ")). \
    Each `--source` id is REQUIRED — it marks that file Ingested in the app. \
    Work autonomously to completion; the live app shows your changes as they land.

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
    """
    \(IngestWriteRule.writes)

    \(IngestWriteRule.dontRediscover(stateFilePath: stateFilePath, sourceFilePaths: stagedSourcePaths))

    \(footnoteConclusionsRule)

    \(sourcesSection(sourcePaths: sourcePaths, stagedSourcePaths: stagedSourcePaths))

    TASK — Ingest \(sourcePaths.count) file\(sourcePaths.count == 1 ? "" : "s") into \
    the wiki, following the Ingest workflow from your instructions. You are the \
    CURATOR: you decide what goes in the wiki and you write everything. \
    \(sourcePaths.count == 1 ? "The source is LARGE" : "The sources are LARGE") — \
    use Sonnet `source-reader` workers, not Opus, to do the raw source ingestion: \
    they read the bulk source chunks and return structured digests for you to \
    synthesize. Act immediately; do not explore the mount first.

    1. INSPECT each staged source's size and structure WITHOUT reading the whole bulk \
       — e.g. `wc -l`/`head` for text, or count pages for a PDF — then split it into \
       chunks (byte/line ranges, sections, or page ranges).
    2. FAN OUT RAW INGESTION to Sonnet `source-reader` subagents via the Task tool — \
       use MORE THAN 1 and FEWER THAN 20 workers (between 2 and 19). Size the fan-out \
       to the material: do NOT spawn 15 workers for 3 pages; one worker can digest \
       adjacent chunks. In each worker's task, give it the staged source path(s) \
       (\(stagedSourcePaths.joined(separator: ", "))) and the exact chunk/section/page-range it must DIGEST. \
       Each worker READS its chunk and returns a structured digest; workers do NOT \
       write to the wiki.
    3. SYNTHESIZE the digests, CROSS-REFERENCE across all sources to find connections \
       and avoid duplicate pages, and DECIDE the set of wiki pages this ingest should \
       produce (summary pages plus the entity/concept pages), reusing existing titles \
       where they fit. You MAY fork MORE `source-reader` workers to ask follow-up \
       QUESTIONS ("re-read section 4 and tell me X"), and you MAY pull specific \
       existing wiki pages with `wikictl page get` to double-check facts. Keep TOTAL \
       Sonnet worker invocations under 20 across the whole run.
    4. WRITE every page yourself via `wikictl page upsert` (cross-linking with \
       [[wiki links]]), then rewrite index.md wholesale via `wikictl index set` so it \
       catalogs the new pages, and for EACH ingested source record it with \
       `wikictl log append --kind ingest --source <id> --title "<source>"`. The \
       `--source` ids are: \(sourceIDs.joined(separator: ", ")). Each `--source` id \
       is REQUIRED — it marks that file Ingested in the app.

    Work autonomously to completion; the live app shows changes as they land.

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
    """
    \(IngestWriteRule.writes)

    \(IngestWriteRule.dontRediscover(stateFilePath: stateFilePath))

    \(answerCitationRule)

    TASK — Answer a question from this wiki, following the Query workflow from your \
    instructions. The mount has a root `WIKI-STRUCTURE.md` file that explains the \
    current filesystem layout and `wikictl` cheatsheet; read it when you need to \
    orient to paths or raw sources.

    To answer, pull wiki pages from SQLite with `wikictl page get --title T` (or \
    `--id I`) so you see fresh authoritative content. If a page contains Markdown \
    footnotes (`[^id]: ...`) that cite a raw source, FOLLOW THEM: resolve the source \
    with `wikictl source list` (or `--json`), then read it — for text use \
    `wikictl source cat --id <id>`; for a PDF or other binary run \
    `wikictl source export --id <id>` and run `pdftotext` / `Read` / `strings` on the \
    path it prints. When you cite a source in your answer, follow the CITE SOURCES \
    rule above. If you file a useful answer back as a page, write it via \
    `wikictl page upsert` and log it with `wikictl log append --kind query`.

    \(Self.wikiRootLine(wikiRoot))
    Question: \(question)
    """
  }

  /// Interactive Query stays alive across user turns.
  private static func queryConversationPrompt(
    wikiRoot: String, stateFilePath: String, allowWikiEdits: Bool
  ) -> String {
    if allowWikiEdits {
      return queryConversationReadWritePrompt(wikiRoot: wikiRoot, stateFilePath: stateFilePath)
    } else {
      return queryConversationReadOnlyPrompt(wikiRoot: wikiRoot, stateFilePath: stateFilePath)
    }
  }

  /// Read-only variant: no write instructions, explicit read-only constraint.
  /// The seatbelt sandbox physically blocks writes, so this prompt never mentions
  /// wikictl write commands — the agent learns read operations only.
  private static func queryConversationReadOnlyPrompt(
    wikiRoot: String, stateFilePath: String
  ) -> String {
    """
    \(IngestWriteRule.dontRediscover(stateFilePath: stateFilePath))

    \(answerCitationRule)

    ROLE — You are in a READ-ONLY interactive Query conversation for this wiki. \
    Answer questions from the wiki's existing content ONLY. You are a reader, not \
    a writer — you CANNOT create, edit, or modify anything: no wiki pages, no \
    files, no HTML documents, no code, no output of any kind. Your tools can only \
    READ from the wiki and its sources. Any attempt to create a file or write \
    content will fail and wastes a turn. Do not offer to make changes, create \
    documents, or build anything. Do not use Write, Edit, or any file-creation \
    tool — you are restricted to reading and answering questions only.

    STYLE — Do the wiki/source inspection silently. Do NOT narrate process steps like \
    "I'll check the wiki", "I'll consult the sources", "I'll read WIKI_STATE", or \
    "I found this in the wiki" unless the user explicitly asks how you did it. Do \
    not advertise capabilities or ask generic "what would you like me to do" setup \
    questions. Reply directly and concisely to the user's actual message; when a \
    source materially supports the answer, cite it per the CITE SOURCES rule above.

    When answering, use the Query workflow from your instructions. Pull fresh pages \
    with `wikictl page get --title T` (or `--id I`) as needed. If a page contains \
    Markdown footnotes (`[^id]: ...`) that cite a raw source, resolve it with \
    `wikictl source list` (or `--json`), then read it — for text use \
    `wikictl source cat --id <id>`; for a PDF or other binary run \
    `wikictl source export --id <id>` and run `pdftotext` / `Read` / `strings` on \
    the path it prints.

    \(Self.wikiRootLine(wikiRoot))
    """
  }

  /// Read-write variant: includes full write instructions (current behavior).
  private static func queryConversationReadWritePrompt(
    wikiRoot: String, stateFilePath: String
  ) -> String {
    """
    \(IngestWriteRule.writes)

    \(IngestWriteRule.dontRediscover(stateFilePath: stateFilePath))

    \(answerCitationRule)

    ROLE — You are in an interactive Query conversation for this wiki. The user may \
    ask questions, ask follow-ups, ask you to inspect sources, or ask you to update \
    the wiki. Do not assume every answer should be written back. Answer in chat by \
    default. Only change the wiki when the user explicitly asks you to save, update, \
    add, rewrite, log, or otherwise persist something.

    STYLE — Do the wiki/source inspection silently. Do NOT narrate process steps like \
    "I'll check the wiki", "I'll consult the sources", "I'll read WIKI_STATE", or \
    "I found this in the wiki" unless the user explicitly asks how you did it. Do \
    not advertise capabilities or ask generic "what would you like me to do" setup \
    questions. Reply directly and concisely to the user's actual message; when a \
    source materially supports the answer, cite it per the CITE SOURCES rule above.

    When answering, use the Query workflow from your instructions. Pull fresh pages \
    with `wikictl page get --title T` (or `--id I`) as needed. If a page contains \
    Markdown footnotes (`[^id]: ...`) that cite a raw source, resolve it with \
    `wikictl source list` (or `--json`), then read it — for text use \
    `wikictl source cat --id <id>`; for a PDF or other binary run \
    `wikictl source export --id <id>` and run `pdftotext` / `Read` / `strings` on \
    the path it prints.

    If the user asks you to update the wiki, write via `wikictl page upsert`, update \
    `index.md` if the catalog should change, and append `wikictl log append --kind \
    query` describing the change. Tell the user what you changed and which pages or \
    source paths you relied on.

    \(Self.wikiRootLine(wikiRoot))
    """
  }

  /// Lint stays single-agent Opus, with the write rule (it logs and may file a
  /// report) + the staged-state / don't-rediscover directive.
  private static func lintPrompt(wikiRoot: String, stateFilePath: String) -> String {
    """
    \(IngestWriteRule.writes)

    \(IngestWriteRule.dontRediscover(stateFilePath: stateFilePath))

    TASK — Health-check this wiki and print a clear findings report, following the \
    Lint workflow from your instructions. Record it with \
    `wikictl log append --kind lint`.

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

    return """
      \(IngestWriteRule.writes)

      \(IngestWriteRule.dontRediscover(stateFilePath: stateFilePath))

      TASK — Review and fix the page titled "\(pageTitle)".

      Pre-flight already ran before this agent started:
      - WikiLink bracket syntax (\\]]) auto-corrected if any were present.
      - \(linksSection)

      Steps:
      1. Read the page: `wikictl page get --title "\(pageTitle)"`
      2. For each broken link listed above: search `wikictl page list` to find the \
         correct target, create the page if it should exist, or remove the link if \
         spurious.
      3. Check the page for other issues (stale content, broken external links, \
         factual gaps) and fix what you can.
      4. If any changes are needed, rewrite: `wikictl page upsert --title "\(pageTitle)"`
      5. Record your findings: `wikictl log append --kind lint`

      \(Self.wikiRootLine(wikiRoot))
      """
  }
}
