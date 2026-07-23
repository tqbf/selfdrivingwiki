import Foundation
import WikiFSCore

/// The per-run intent the UI builds at click time — the operation kind plus the raw
/// inputs (source bytes, the state-snapshot text) read from SQLite — which the
/// `AgentLauncher` STAGES into the per-run scratch dir and finalizes into a
/// `WikiOperation` carrying the staged absolute paths (`feature/ingest-fewer-turns`).
///
/// This is the app-side seam: it owns the file writes (`AgentStaging`), which is why
/// it lives in the app target, not `WikiFSCore`. The pure pieces it composes — the
/// `WIKI_STATE.md` rendering (`WikiStateSnapshot.renderStateFile`), the staged leaf
/// names (`AgentStaging`), the tiny-vs-non-tiny decision (`IngestPlan.decide`), and
/// the prompts (`WikiOperation`) — are all unit-tested in the core.
public enum OperationRequest: Sendable {
  /// One source for ingest: raw bytes + extension + mount-relative display path
  /// + provenance for the staged-leaf stem. `name` drives the shell-safe stem
  /// (`source.effectiveName`); `sourceID` is the full ULID disambiguator
  /// (`source.id.rawValue`). Neither is the staged leaf itself — that is computed
  /// by `AgentStaging.shellSafeLeaf` so the leaf is shell-safe by construction.
  public struct StagedSource: Equatable, Sendable {
    public let bytes: Data
    public let ext: String         // lowercased, e.g. "md", "pdf"
    public let displayPath: String  // mount-relative, e.g. "sources/by-id/<ulid>.md"
    public let name: String         // source.effectiveName — drives the staged leaf stem
    public let sourceID: String     // source.id.rawValue (full ULID) — disambiguator

    public init(bytes: Data, ext: String, displayPath: String, name: String, sourceID: String) {
      self.bytes = bytes
      self.ext = ext
      self.displayPath = displayPath
      self.name = name
      self.sourceID = sourceID
    }
  }

  /// Ingest one or more sources in a single agent run. `stateMarkdown` is the
  /// rendered `WIKI_STATE.md`.
  case ingest(sources: [StagedSource], stateMarkdown: String)

  /// Answer a question. `stateMarkdown` is the rendered `WIKI_STATE.md`.
  case query(question: String, stateMarkdown: String)

  /// Lint the wiki. `stateMarkdown` is the rendered `WIKI_STATE.md`.
  case lint(stateMarkdown: String)

  /// Lint a single page. `brokenLinks` comes from `WikiStoreModel.preflightLint`
  /// (pre-computed before the LLM run so the agent has concrete targets).
  case lintPage(pageTitle: String, brokenLinks: [String], stateMarkdown: String)

  /// Which generation lane this request runs on (Phase 2: lane-aware gate).
  /// Ingest-class operations (ingest, lint, lintPage) serialize on `.ingest`;
  /// query/chat runs on `.interactive` so they don't block on a long ingest.
  var generationLane: GenerationGate.GenerationLane {
    switch self {
    case .ingest, .lint, .lintPage: return .ingest
    case .query: return .interactive
    }
  }

  /// Stage this request's inputs into `scratch` and return the finalized
  /// `WikiOperation`. Writes `WIKI_STATE.md` (always) and, for Ingest, the raw
  /// source bytes as `<shellSafeStem>--<full-ULID>.<ext>` leaves (shell-safe by
  /// construction so the executor's BARE `{{PRIMARY_SOURCE_FILE}}` injection
  /// is safe); the Ingest plan (single Opus pass vs Opus curator + Sonnet
  /// `source-reader` digesters) is decided from the total staged byte size.
  /// Throws if a write fails.
  func stage(into scratch: URL) throws -> WikiOperation {
    switch self {
    case .ingest(let sources, let stateMarkdown):
      let stateFilePath = try AgentStaging.stageStateFile(stateMarkdown, in: scratch)
      let stagedSourcePaths = try AgentStaging.stageSources(
        sources.map { ($0.bytes, $0.ext, $0.name, $0.sourceID) }, in: scratch)
      let totalBytes = sources.reduce(0) { $0 + $1.bytes.count }
      let plan = IngestPlan.decide(sourceByteSize: totalBytes)
      return .ingest(
        sourcePaths: sources.map(\.displayPath),
        stagedSourcePaths: stagedSourcePaths,
        stateFilePath: stateFilePath,
        plan: plan)

    case .query(let question, let stateMarkdown):
      let stateFilePath = try AgentStaging.stageStateFile(stateMarkdown, in: scratch)
      return .query(question: question, stateFilePath: stateFilePath)

    case .lint(let stateMarkdown):
      let stateFilePath = try AgentStaging.stageStateFile(stateMarkdown, in: scratch)
      return .lint(stateFilePath: stateFilePath)

    case .lintPage(let pageTitle, let brokenLinks, let stateMarkdown):
      let stateFilePath = try AgentStaging.stageStateFile(stateMarkdown, in: scratch)
      return .lintPage(pageTitle: pageTitle, brokenLinks: brokenLinks, stateFilePath: stateFilePath)
    }
  }
}
