import Foundation

/// The app-side decision of HOW to run an Ingest: a single pass for a tiny
/// source, or a multi-phase planner → executors → finalizer run for anything
/// larger (`plans/llm-wiki.md` Phase D / `plans/acp-multi-provider.md`).
///
/// PURE and unit-tested. The decision is driven purely by source size against a
/// named threshold — it is a source-size predicate, NOT a model or provider
/// choice. WHICH provider/model runs each stage is resolved separately via
/// `AgentProvidersConfig.resolvedProvider(for:)` (per-stage assignments).
///
/// The case names are historical (`singleOpus`/`opusCurator` date from the
/// removed Claude-CLI backend's opus/sonnet tiering); only the tiny-vs-large
/// split they encode is still meaningful.
public enum IngestPlan: Equatable, Sendable {
  /// A single Opus pass does the whole ingest via `wikictl`. No fan-out, no
  /// `--agents` — for a small source Opus reads it directly and writes the pages +
  /// index + log itself (Opus must be the one deciding what goes in the wiki, even
  /// for small sources).
  case singleOpus

  /// An Opus curator orchestrates reading a large source WITHOUT reading the whole
  /// bulk itself: it inspects the source's size/structure, splits it into chunks,
  /// and fans out to 2–19 Sonnet `source-reader` DIGESTERS to read the chunks in
  /// parallel. Opus then synthesizes the digests, decides the page set, and WRITES
  /// all pages + `index.md` + the log entry itself.
  case opusCurator

  /// The byte threshold below which a source is "tiny" and gets the single Opus pass.
  /// Text under ~4 KB is tiny; a large PDF is NOT (it exceeds this even before
  /// counting its non-text heft). Chosen so a short note or paragraph stays a single
  /// pass while anything substantial gets the curator's digester fan-out.
  public static let tinySourceByteThreshold = 4096

  /// Pick the mode from the raw source size. The app passes the source's byte size
  /// (from `SourceSummary.byteSize` / the staged bytes); the decision is a
  /// pure function of that size and the threshold.
  public static func decide(sourceByteSize: Int) -> IngestPlan {
    sourceByteSize < tinySourceByteThreshold ? .singleOpus : .opusCurator
  }

  /// Whether this plan is for a large source that needs multi-phase processing
  /// (planner → executors → finalizer for ACP, or curator + digesters for CLI).
  /// Model-agnostic: any powerful model can be the planner/curator — this is a
  /// source-size predicate, NOT a model-tier gate.
  public var isLargeSource: Bool {
    switch self {
    case .singleOpus: false
    case .opusCurator: true
    }
  }

}
