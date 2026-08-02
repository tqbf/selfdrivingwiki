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

  /// Keep a query conversation open. User turns arrive over stdin, and Claude may
  /// answer only, or update the wiki with `wikictl` when the conversation asks for it.
  case queryConversation(stateFilePath: String)

  /// Health-check the wiki and report findings. `stateFilePath` is the staged
  /// `WIKI_STATE.md` snapshot.
  case lint(stateFilePath: String)

  /// Bring the wiki up to date with a tracked git repository.
  ///
  /// The repo analogue of `.ingest`. The differences that matter: the material is
  /// a live checkout on disk rather than staged bytes, so `repoPath` is a real
  /// directory the agent navigates; and the work is usually a DIFF rather than a
  /// document, so `plan` carries the commit range as well as the model tier.
  ///
  /// - `repoName`: the `owner/repo` display name — how the agent addresses this
  ///   repo in `wikictl repo mark-ingested`.
  /// - `repoPath`: the ABSOLUTE path of the app's read-only checkout.
  /// - `stateFilePath` / `repoStateFilePath`: the ABSOLUTE scratch paths of the
  ///   staged `WIKI_STATE.md` and `REPO_STATE.md` snapshots.
  /// - `plan`: initial-vs-incremental plus the tier (single Opus pass vs Opus
  ///   curator + Sonnet `repo-reader` digesters). Opus writes in BOTH modes.
  case repoIngest(
    repoName: String,
    repoPath: String,
    stateFilePath: String,
    repoStateFilePath: String,
    plan: RepoSyncPlan
  )

  /// A short, stable identifier for the operation kind (logging / UI).
  public var kind: Kind {
    switch self {
    case .ingest: .ingest
    case .query, .queryConversation: .query
    case .lint: .lint
    case .repoIngest: .repo
    }
  }

  public enum Kind: String, CaseIterable, Sendable {
    case ingest
    case query
    case lint
    case repo

    /// User-facing title for the operation.
    public var title: String {
      switch self {
      case .ingest: "Ingest"
      case .query: "Query"
      case .lint: "Lint"
      case .repo: "Repo"
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
    case .query, .queryConversation, .lint, .repoIngest: "opus"
    }
  }

  /// The `--agents` JSON for this operation, or nil when it runs single-agent.
  /// Only a large-source Ingest defines subagents (the Sonnet `source-reader`
  /// digester); the tiny Ingest, Query, and Lint never do.
  public var agentsJSON: String? {
    switch self {
    case .ingest(_, _, _, let plan): plan.agentsJSON()
    case .repoIngest(_, _, _, _, let plan):
      plan.tier == .opusCurator ? RepoReaderAgent.agentsJSON() : nil
    case .query, .queryConversation, .lint: nil
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
  ///   - repos: the wiki's tracked repositories (name + checkout path + commit), so
  ///     a Query can read the tracked SOURCE as well as the wiki. Only the Query
  ///     prompts use it, and an EMPTY list renders nothing — a wiki with no tracked
  ///     repos produces a byte-identical prompt to before repo tracking existed.
  public func prompt(wikiRoot: String, repos: [RepoStateSnapshot.Context] = []) -> String {
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
        wikiRoot: wikiRoot, question: question, stateFilePath: stateFilePath, repos: repos)
    case .queryConversation(let stateFilePath):
      return Self.queryConversationPrompt(
        wikiRoot: wikiRoot, stateFilePath: stateFilePath, repos: repos)
    case .lint(let stateFilePath):
      return Self.lintPrompt(wikiRoot: wikiRoot, stateFilePath: stateFilePath)
    case .repoIngest(let repoName, let repoPath, let stateFilePath, let repoStateFilePath, let plan):
      return Self.repoIngestPrompt(
        wikiRoot: wikiRoot,
        repoName: repoName,
        repoPath: repoPath,
        stateFilePath: stateFilePath,
        repoStateFilePath: repoStateFilePath,
        plan: plan)
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

  // MARK: - Repo ingest prompt

  /// Bring the wiki up to date with a tracked repository. ONE prompt builder for
  /// both tiers and both modes, because — unlike the document ingest, where the
  /// single-pass and curator prompts describe genuinely different procedures — the
  /// repo task is the same task at two sizes: the tier only decides whether to
  /// fan out, and `REPO_STATE.md` already says whether this is a first pass or a
  /// diff. Keeping it one builder is what stops the two variants drifting.
  ///
  /// Leads with the write rule because Opus is the writer, then the staged-state
  /// directive, then the two rules that are specific to code as a source: the
  /// checkout is read-only, and provenance is `repo@sha:path:line`.
  private static func repoIngestPrompt(
    wikiRoot: String,
    repoName: String,
    repoPath: String,
    stateFilePath: String,
    repoStateFilePath: String,
    plan: RepoSyncPlan
  ) -> String {
    """
    \(IngestWriteRule.writes)

    \(IngestWriteRule.dontRediscover(stateFilePath: stateFilePath))

    \(repoCheckoutRule(repoName: repoName, repoPath: repoPath))

    \(repoFootnoteRule)

    TASK — Bring this wiki up to date with the tracked repository \(repoName), \
    following the Ingest workflow from your instructions. Act immediately; do not \
    explore the mount first.

    1. READ \(repoStateFilePath) FIRST. The app already ran the git commands for you: \
       it tells you the head commit, whether this is a first pass or an incremental \
       one, the commits in range, the diff stat, and the files that matter. Do NOT \
       re-derive any of that.
    \(repoBodySteps(plan: plan, repoPath: repoPath))
    \(repoWriteSteps(repoName: repoName, plan: plan))

    Work autonomously to completion; the live app shows changes as they land.

    Repository checkout (read-only): \(repoPath)
    WIKI_ROOT (resolved, read-only mount — reference only): \(wikiRoot)
    """
  }

  /// The middle of the repo task — the only part that differs by tier. Single-pass
  /// reads the material itself; curator fans out to Sonnet `repo-reader` workers
  /// with the same 2–19 guardrail and follow-up affordances as the document
  /// curator (the guardrail is stated prompt-level in both).
  private static func repoBodySteps(plan: RepoSyncPlan, repoPath: String) -> String {
    let scope: String
    switch plan {
    case .upToDate, .initial:
      scope =
        "the subsystems of the repository (split it by directory / module / package — "
        + "not by arbitrary file count)"
    case .incremental:
      scope =
        "the changed area (split the changed files by subsystem, and include enough "
        + "surrounding context for each worker to judge what the change means)"
    }

    switch plan.tier {
    case .singleOpus, nil:
      return """
        2. READ the material yourself with Read/Grep/Glob, starting from the repo's own \
           README and entry points. Go deep enough to explain HOW things work, not just \
           what files exist.
        """
    case .opusCurator:
      return """
        2. FAN OUT the reading to Sonnet `repo-reader` subagents via the Task tool — use \
           MORE THAN 1 and FEWER THAN 20 workers (between 2 and 19). Size the fan-out to \
           the material: do NOT spawn 15 workers for a two-file change. Split \(scope). \
           Give each worker the checkout path (\(repoPath)) and its exact assignment. \
           Workers READ and return structured digests; they do NOT write.
        3. SYNTHESIZE the digests. You MAY fork MORE `repo-reader` workers to ask \
           follow-up questions ("re-read the enumerator and tell me X"), and you MAY pull \
           existing wiki pages with `wikictl page get` to check facts before writing. Keep \
           TOTAL worker invocations under 20 across the whole run.
        """
    }
  }

  /// The write half of the repo task. Initial and incremental differ in INTENT —
  /// establish coverage vs revise what drifted — and saying so is what keeps an
  /// incremental pass from bolting on duplicate pages instead of editing.
  private static func repoWriteSteps(repoName: String, plan: RepoSyncPlan) -> String {
    let intent: String
    switch plan {
    case .upToDate, .initial:
      intent =
        "DECIDE the set of pages this repository deserves — an overview page plus pages "
        + "for its major subsystems, concepts, and entry points — reusing existing titles "
        + "where they fit"
    case .incremental:
      intent =
        "DECIDE which EXISTING pages these commits made stale and REVISE them. Add a new "
        + "page only for genuinely new subject matter; do not create a second page about "
        + "something the wiki already covers"
    }
    return """
      4. \(intent). WRITE every page yourself via `wikictl page upsert` (cross-linking with \
         [[wiki links]]), then rewrite index.md wholesale via `wikictl index set` so it \
         catalogs the current page set.
      5. RECORD the pass: `wikictl log append --kind repo --title "…" --note "…"`, then \
         `wikictl repo mark-ingested --name \(repoName) --commit <head commit from \
         REPO_STATE.md>`. Run mark-ingested LAST and ONLY if you actually wrote the pages — \
         it is the watermark that decides what the next pass re-reads, so marking a run \
         you did not finish silently loses that work.
      """
  }

  /// The checkout is a REAL directory, not the mount — which means the read-only
  /// rule the agent already knows ("the mount rejects writes on purpose") does NOT
  /// protect it: a write here would succeed. Hence an explicit prohibition, and an
  /// explicit ban on mutating git commands, which are the plausible way an agent
  /// would "helpfully" try to update a checkout it thinks is stale.
  private static func repoCheckoutRule(repoName: String, repoPath: String) -> String {
    """
    THE CHECKOUT — \(repoName) is cloned at \(repoPath). Unlike the wiki mount this \
    is an ordinary local directory, so writes there would SUCCEED — do not make them. \
    Never create, edit, or delete a file inside the checkout, and never run a git \
    command that mutates it (no commit, checkout, pull, fetch, reset, clean, stash); \
    the app owns syncing it. Read it freely with Read/Grep/Glob and read-only shell \
    commands, including read-only git (`git -C \(repoPath) log`, `show`, `blame`).
    """
  }

  /// Provenance for code. Same "no real links" philosophy as
  /// `footnoteConclusionsRule`, but a repo is mutable, so a citation without a
  /// commit is a citation to a moving target — the sha is what makes a footnote
  /// still checkable after the next sync.
  private static let repoFootnoteRule = """
    FOOTNOTE CONCLUSIONS — When you state how something works, footnote it in \
    Markdown using `[^id]` references and definitions of the form \
    `[^id]: repo owner/name@<short-sha>, path/to/File.ext:120-160`. Always include the \
    commit: the checkout moves, so a path alone stops being checkable after the next \
    sync. We do NOT need real links.
    """

  /// The tracked-repositories block as spliced into a Query prompt, or `""` when
  /// the wiki tracks none. The surrounding newlines live HERE rather than in the
  /// template so that an empty list collapses to the exact prompt text that
  /// existed before repo tracking — no stray blank line, no test churn.
  private static func repoBlock(_ repos: [RepoStateSnapshot.Context]) -> String {
    let block = RepoStateSnapshot.Context.promptBlock(for: repos)
    return block.isEmpty ? "" : "\n\(block)\n"
  }

  // MARK: - Query / Lint prompts

  /// Query stays single-agent Opus, but still gets the write rule (it may file an
  /// answer page) + the staged-state / don't-rediscover directive.
  private static func queryPrompt(
    wikiRoot: String,
    question: String,
    stateFilePath: String,
    repos: [RepoStateSnapshot.Context]
  ) -> String {
    """
    \(IngestWriteRule.writes)

    \(IngestWriteRule.dontRediscover(stateFilePath: stateFilePath))
    \(Self.repoBlock(repos))
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

  /// Interactive Query stays alive across user turns. It gives Claude permission
  /// to either answer conversationally or make durable wiki updates on request.
  private static func queryConversationPrompt(
    wikiRoot: String,
    stateFilePath: String,
    repos: [RepoStateSnapshot.Context]
  ) -> String {
    """
    \(IngestWriteRule.writes)

    \(IngestWriteRule.dontRediscover(stateFilePath: stateFilePath))
    \(Self.repoBlock(repos))
    ROLE — You are in an interactive Query conversation for this wiki. The user may \
    ask questions, ask follow-ups, ask you to inspect sources, or ask you to update \
    the wiki. Do not assume every answer should be written back. Answer in chat by \
    default. Only change the wiki when the user explicitly asks you to save, update, \
    add, rewrite, log, or otherwise persist something.

    STYLE — Do the wiki/source inspection silently. Do NOT narrate process steps like \
    "I'll check the wiki", "I'll consult the sources", "I'll read WIKI_STATE", or \
    "I found this in the wiki" unless the user explicitly asks how you did it. Do \
    not advertise capabilities or ask generic "what would you like me to do" setup \
    questions. Reply directly and concisely to the user's actual message; cite pages \
    or sources only when they materially support the answer.

    When answering, use the Query workflow from your instructions. Pull fresh pages \
    with `wikictl page get --title T` (or `--id I`) as needed. If a page contains \
    Markdown footnotes (`[^id]: ...`) that cite a raw source, follow them through \
    `$WIKI_ROOT/files/by-name/`, `$WIKI_ROOT/files/by-id/`, or \
    `$WIKI_ROOT/indexes/files.jsonl`, then read the raw file from the mount with the \
    Read tool or shell tools such as `cat`, `python`, `pdftotext`, or `strings`.

    If the user asks you to update the wiki, write via `wikictl page upsert`, update \
    `index.md` if the catalog should change, and append `wikictl log append --kind \
    query` describing the change. Tell the user what you changed and which pages or \
    source paths you relied on.

    WIKI_ROOT (resolved, read-only mount — reference only): \(wikiRoot)
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
