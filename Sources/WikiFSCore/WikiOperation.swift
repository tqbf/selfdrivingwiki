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
  /// Summarize one already-ingested source file into the wiki.
  ///
  /// - `sourcePath`: the source's mount-relative path under `$WIKI_ROOT` (kept for
  ///   reference / the rare mount fallback).
  /// - `stagedSourcePath`: the ABSOLUTE scratch path the app staged the raw source
  ///   bytes to (read from SQLite, not the laggy mount) — what the agent actually
  ///   reads.
  /// - `stateFilePath`: the ABSOLUTE scratch path of the staged `WIKI_STATE.md`
  ///   snapshot (titles + index.md + log tail) — so the agent skips orientation.
  /// - `plan`: the model-tiering decision (single Opus pass vs Opus curator + Sonnet
  ///   digesters), which selects between the single-pass and curate-and-fan-out
  ///   prompt. Opus writes in BOTH modes.
  case ingest(
    sourcePath: String,
    stagedSourcePath: String,
    stateFilePath: String,
    plan: IngestPlan
  )

  /// Answer a question from the wiki's contents, returning a cited answer.
  /// `stateFilePath` is the staged `WIKI_STATE.md` snapshot.
  case query(question: String, stateFilePath: String)

  /// Health-check the wiki and report findings. `stateFilePath` is the staged
  /// `WIKI_STATE.md` snapshot.
  case lint(stateFilePath: String)

  /// A short, stable identifier for the operation kind (logging / UI).
  public var kind: Kind {
    switch self {
    case .ingest: .ingest
    case .query: .query
    case .lint: .lint
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
    case .query, .lint: "opus"
    }
  }

  /// The `--agents` JSON for this operation, or nil when it runs single-agent.
  /// Only a large-source Ingest defines subagents (the Sonnet `source-reader`
  /// digester); the tiny Ingest, Query, and Lint never do.
  public var agentsJSON: String? {
    switch self {
    case .ingest(_, _, _, let plan): plan.agentsJSON()
    case .query, .lint: nil
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
    case .ingest(_, let stagedSourcePath, let stateFilePath, let plan):
      switch plan {
      case .singleOpus:
        return Self.ingestSinglePrompt(
          wikiRoot: wikiRoot,
          stagedSourcePath: stagedSourcePath,
          stateFilePath: stateFilePath)
      case .opusCurator:
        return Self.ingestCuratorPrompt(
          wikiRoot: wikiRoot,
          stagedSourcePath: stagedSourcePath,
          stateFilePath: stateFilePath)
      }
    case .query(let question, let stateFilePath):
      return Self.queryPrompt(
        wikiRoot: wikiRoot, question: question, stateFilePath: stateFilePath)
    case .lint(let stateFilePath):
      return Self.lintPrompt(wikiRoot: wikiRoot, stateFilePath: stateFilePath)
    }
  }

  // MARK: - Ingest prompts

  /// Single-pass Ingest (tiny source): one Opus pass does the whole ingest itself via
  /// `wikictl`. No fan-out — Opus reads the small staged source and writes the pages
  /// + index + log. (Opus is the curator even for small sources.) Leads with the
  /// write rule because Opus is the writer.
  private static func ingestSinglePrompt(
    wikiRoot: String,
    stagedSourcePath: String,
    stateFilePath: String
  ) -> String {
    """
    \(IngestWriteRule.writes)

    \(IngestWriteRule.dontRediscover(stateFilePath: stateFilePath, sourceFilePath: stagedSourcePath))

    \(footnoteConclusionsRule)

    TASK — Ingest this one source into the wiki, following the Ingest workflow from \
    your instructions. Act immediately; do not explore the mount first. Read the \
    staged source, DECIDE what belongs in the wiki, and write one or more \
    summary/entity/concept pages via `wikictl page upsert` (cross-linking with \
    [[wiki links]]), rewrite index.md via `wikictl index set`, and record it with \
    `wikictl log append --kind ingest`. Work autonomously to completion; the live \
    app shows your changes as they land.

    WIKI_ROOT (resolved, read-only mount — reference only): \(wikiRoot)
    """
  }

  /// Large-source Ingest: an Opus CURATOR delegates raw source ingestion to Sonnet
  /// `source-reader` digesters, then DECIDES the page set and WRITES every page +
  /// index.md + the log entry itself. The 2..19 digester guardrail and the
  /// "fork more for follow-up questions / pull pages to double-check" affordances are
  /// stated prompt-level. Leads with the write rule because Opus is the writer.
  private static func ingestCuratorPrompt(
    wikiRoot: String,
    stagedSourcePath: String,
    stateFilePath: String
  ) -> String {
    """
    \(IngestWriteRule.writes)

    \(IngestWriteRule.dontRediscover(stateFilePath: stateFilePath, sourceFilePath: stagedSourcePath))

    \(footnoteConclusionsRule)

    TASK — Ingest this one source into the wiki, following the Ingest workflow from \
    your instructions. You are the CURATOR: you decide what goes in the wiki and you \
    write everything. The source is LARGE — use Sonnet `source-reader` workers, not \
    Opus, to do the raw source ingestion: they read the bulk source chunks and return \
    structured digests for you to synthesize. Act immediately; do not explore the \
    mount first.

    1. INSPECT the staged source's size and structure WITHOUT reading the whole bulk \
       — e.g. `wc -l`/`head` for text, or count pages for a PDF — then split it into \
       chunks (byte/line ranges, sections, or page ranges).
    2. FAN OUT RAW INGESTION to Sonnet `source-reader` subagents via the Task tool — \
       use MORE THAN 1 and FEWER THAN 20 workers (between 2 and 19). Size the fan-out \
       to the material: do NOT spawn 15 workers for 3 pages; one worker can digest \
       adjacent chunks. In each worker's task, give it the staged source path \
       (\(stagedSourcePath)) and the exact chunk/section/page-range it must DIGEST. \
       Each worker READS its chunk and returns a structured digest; workers do NOT \
       write to the wiki.
    3. SYNTHESIZE the digests, DECIDE the set of wiki pages this ingest should \
       produce (summary pages plus the entity/concept pages it mentions), reusing \
       existing titles where they fit. You MAY fork MORE `source-reader` workers to \
       ask follow-up QUESTIONS of the source ("re-read section 4 and tell me X"), \
       and you MAY pull specific existing wiki pages with `wikictl page get` to \
       double-check facts before/while writing. Keep TOTAL Sonnet worker invocations \
       under 20 across the whole run (initial digest fan-out plus any follow-ups).
    4. WRITE every page yourself via `wikictl page upsert` (cross-linking with \
       [[wiki links]]), then rewrite index.md wholesale via `wikictl index set` so it \
       catalogs the new pages, and append the log entry with \
       `wikictl log append --kind ingest`.

    Work autonomously to completion; the live app shows changes as they land.

    WIKI_ROOT (resolved, read-only mount — reference only): \(wikiRoot)
    """
  }

  /// Ingest-written pages should make provenance visible without making the agent
  /// chase or construct durable URLs. The reader renders Markdown footnotes.
  private static let footnoteConclusionsRule = """
    FOOTNOTE CONCLUSIONS — When you add synthesized conclusions, interpretations, \
    or non-obvious facts to wiki pages, footnote them in Markdown using `[^id]` \
    references and `[^id]: Source filename, page N` definitions. We do NOT need \
    real links; use concise provenance such as a source file name plus page, \
    section, heading, line range, or chunk range.
    """

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

    TASK — Answer a question from this wiki, following the Query workflow from your \
    instructions. The mount has a root `WIKI-STRUCTURE.md` file that explains the \
    current filesystem layout and `wikictl` cheatsheet; read it when you need to \
    orient to paths or raw sources.

    To answer, pull wiki pages from SQLite with `wikictl page get --title T` (or \
    `--id I`) so you see fresh authoritative content. If a page contains Markdown \
    footnotes (`[^id]: ...`) that cite a raw source, FOLLOW THEM: resolve the source \
    filename/path using `$WIKI_ROOT/files/by-name/`, `$WIKI_ROOT/files/by-id/`, or \
    `$WIKI_ROOT/indexes/files.jsonl`, then read the raw file from the mount (use the \
    `Read` tool or shell commands such as `cat`, `python`, `pdftotext`, or `strings` \
    as appropriate for text/PDF/binary files). Cite the page titles and any \
    `files/...` paths or footnote source locations your answer draws on. If you file \
    a useful answer back as a page, write it via `wikictl page upsert` and log it \
    with `wikictl log append --kind query`.

    WIKI_ROOT (resolved, read-only mount — reference only): \(wikiRoot)
    Question: \(question)
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

    WIKI_ROOT (resolved, read-only mount — reference only): \(wikiRoot)
    """
  }
}
