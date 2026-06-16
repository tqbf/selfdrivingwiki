import Foundation

/// The three discrete `claude -p` operations the app can run against the
/// currently-selected wiki (`plans/llm-wiki.md` Phase C, decision #2): **Ingest**,
/// **Query**, and **Lint**.
///
/// This is a PURE value type — it carries only the per-run inputs (the ingest
/// source, the query text) and knows how to render the operation's **own prompt**.
/// It deliberately does NOT spawn anything: command/env/cwd assembly lives in
/// `OperationCommand` (also pure), and the actual `Process` spawn lives in the
/// app's `AgentLauncher`. Keeping the prompt/command construction pure is what
/// makes the Phase-C deterministic seams unit-testable without a real agent run.
///
/// ⚠️ **Self-sufficient prompts.** The per-wiki `system_prompt` singleton is still
/// the Phase-D stub, so each operation's own prompt must spell out how to act with
/// `wikictl` (write via `wikictl page upsert`, record via `wikictl log append`,
/// rewrite via `wikictl index set`, read-back via `wikictl page get` because the
/// mount lags ~5s). This makes the structural Phase-C gate pass before Phase D
/// lands the real schema.
public enum WikiOperation: Equatable, Sendable {
    /// Summarize one already-ingested source file into the wiki. `sourcePath` is
    /// the source's mount-relative path under `$WIKI_ROOT` (e.g.
    /// `files/by-id/<ulid>.<ext>`), so the agent can `Read` it directly.
    case ingest(sourcePath: String)

    /// Answer a question from the wiki's contents, returning a cited answer.
    case query(question: String)

    /// Health-check the wiki (contradictions, stale claims, orphan pages, missing
    /// cross-refs, concepts lacking a page) and report findings.
    case lint

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
}

extension WikiOperation {
    /// The operation's OWN prompt — the `-p` argument handed to `claude`. Written
    /// to be self-sufficient against today's stub `system_prompt`: it tells the
    /// agent exactly which `wikictl` calls to make and reminds it of the
    /// read-after-write rule. The agent runs against `$WIKI_DB` (already exported)
    /// and reads sources under `$WIKI_ROOT`.
    public var prompt: String {
        switch self {
        case .ingest(let sourcePath):
            return Self.ingestPrompt(sourcePath: sourcePath)
        case .query(let question):
            return Self.queryPrompt(question: question)
        case .lint:
            return Self.lintPrompt
        }
    }

    private static let toolingPreamble = """
    You maintain a wiki stored in SQLite. Read the wiki through the read-only \
    filesystem mount at $WIKI_ROOT (browse with find/cat/grep/Read). WRITE only \
    through the `wikictl` command — never edit files under $WIKI_ROOT, the mount \
    is read-only. `wikictl` writes the wiki selected by the WIKI_DB environment \
    variable (already set), so do NOT pass --wiki. After any write, read it back \
    with `wikictl page get` (NOT by cat-ing the mount, which lags a few seconds).

    wikictl commands you will use:
      wikictl page list                         list id / title / path per page
      wikictl page get --title T | --id I       print a page body (instant, authoritative)
      printf '%s' "<body>" | wikictl page upsert --title T --body-file -   create/update a page
      wikictl log append --kind ingest|query|lint --title "…" [--note "…"]  record an action
      printf '%s' "<body>" | wikictl index set --body-file -               rewrite index.md
    Use [[Page Title]] wiki-links in page bodies to cross-reference other pages.
    """

    private static func ingestPrompt(sourcePath: String) -> String {
        """
        \(toolingPreamble)

        TASK — Ingest a source into the wiki.
        The source to ingest is at: $WIKI_ROOT/\(sourcePath)
        Read it (use the Read tool for PDFs/images; cat for text). Then:
          1. Write at least one summary page capturing the source's key content,
             via `wikictl page upsert`. Cite the source by its files/ path.
          2. Create or update any relevant entity/concept pages it mentions,
             cross-linking with [[wiki-links]].
          3. Rewrite the curated index at index.md via `wikictl index set` so it
             lists the pages you just wrote (read the current index first with
             `cat "$WIKI_ROOT/index.md"`).
          4. Append a log entry recording this ingest:
             `wikictl log append --kind ingest --title "<source name>" --note "<one line>"`.
        Work autonomously to completion — do not ask for confirmation. The live
        app shows your changes as they land.
        """
    }

    private static func queryPrompt(question: String) -> String {
        """
        \(toolingPreamble)

        TASK — Answer a question from the wiki.
        Question: \(question)
        Search the wiki under $WIKI_ROOT (find/grep/cat the pages, index.md, and
        log.md) and answer concisely. CITE the page titles or files/ paths your
        answer draws on. If the wiki lacks the information, say so plainly rather
        than guessing. You MAY file the answer back as a page via
        `wikictl page upsert` if it would be useful to keep, then append
        `wikictl log append --kind query --title "<the question>"`.
        """
    }

    private static let lintPrompt = """
    \(toolingPreamble)

    TASK — Health-check the wiki and report.
    Survey the wiki under $WIKI_ROOT (page list via `wikictl page list`, bodies
    via cat/grep, the link graph in indexes/links.jsonl, index.md, log.md). Report
    on:
      • contradictions or claims that disagree across pages,
      • stale claims that look outdated,
      • orphan pages (no inbound [[links]]),
      • missing cross-references between related pages,
      • concepts mentioned repeatedly but lacking their own page.
    Print a clear findings report. Then append
    `wikictl log append --kind lint --title "Wiki lint" --note "<summary of findings>"`.
    You MAY also file the report as a page via `wikictl page upsert` if useful.
    Do not modify existing page content beyond adding cross-reference links you are
    confident about.
    """
}
