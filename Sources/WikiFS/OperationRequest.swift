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
  /// Ingest one source. `sourceBytes` are the verbatim bytes read from SQLite (NOT
  /// the mount); `ext` is the source's lowercased extension; `sourcePath` is the
  /// mount-relative reference path; `stateMarkdown` is the rendered `WIKI_STATE.md`.
  case ingest(sourceBytes: Data, ext: String, sourcePath: String, stateMarkdown: String)

  /// Answer a question. `stateMarkdown` is the rendered `WIKI_STATE.md`.
  case query(question: String, stateMarkdown: String)

  /// Lint the wiki. `stateMarkdown` is the rendered `WIKI_STATE.md`.
  case lint(stateMarkdown: String)

  /// Stage this request's inputs into `scratch` and return the finalized
  /// `WikiOperation`. Writes `WIKI_STATE.md` (always) and, for Ingest, the raw
  /// `source.<ext>`; the Ingest plan (single Opus pass vs Opus curator + Sonnet
  /// `source-reader` digesters) is decided from the staged source's byte size. Throws
  /// if a write fails.
  func stage(into scratch: URL) throws -> WikiOperation {
    switch self {
    case .ingest(let sourceBytes, let ext, let sourcePath, let stateMarkdown):
      let stateFilePath = try AgentStaging.stageStateFile(stateMarkdown, in: scratch)
      let stagedSourcePath = try AgentStaging.stageSource(sourceBytes, ext: ext, in: scratch)
      let plan = IngestPlan.decide(sourceByteSize: sourceBytes.count)
      return .ingest(
        sourcePath: sourcePath,
        stagedSourcePath: stagedSourcePath,
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
