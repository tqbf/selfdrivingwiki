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
enum OperationRequest {
  /// One source for ingest: raw bytes + extension + mount-relative display path.
  struct StagedSource: Equatable, Sendable {
    let bytes: Data
    let ext: String         // lowercased, e.g. "md", "pdf"
    let displayPath: String  // mount-relative, e.g. "sources/by-id/<ulid>.md"

    init(bytes: Data, ext: String, displayPath: String) {
      self.bytes = bytes
      self.ext = ext
      self.displayPath = displayPath
    }
  }

  /// Ingest one or more sources in a single agent run. `stateMarkdown` is the
  /// rendered `WIKI_STATE.md`.
  case ingest(sources: [StagedSource], stateMarkdown: String)

  /// Answer a question. `stateMarkdown` is the rendered `WIKI_STATE.md`.
  case query(question: String, stateMarkdown: String)

  /// Lint the wiki. `stateMarkdown` is the rendered `WIKI_STATE.md`.
  case lint(stateMarkdown: String)

  /// Stage this request's inputs into `scratch` and return the finalized
  /// `WikiOperation`. Writes `WIKI_STATE.md` (always) and, for Ingest, the raw
  /// `source-1.<ext>`, `source-2.<ext>`, …; the Ingest plan (single Opus pass vs
  /// Opus curator + Sonnet `source-reader` digesters) is decided from the total
  /// staged byte size. Throws if a write fails.
  func stage(into scratch: URL) throws -> WikiOperation {
    switch self {
    case .ingest(let sources, let stateMarkdown):
      let stateFilePath = try AgentStaging.stageStateFile(stateMarkdown, in: scratch)
      let stagedSourcePaths = try AgentStaging.stageSources(
        sources.map { ($0.bytes, $0.ext) }, in: scratch)
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
    }
  }
}
