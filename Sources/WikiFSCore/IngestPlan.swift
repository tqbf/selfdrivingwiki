import Foundation

/// The app-side decision of HOW to run an Ingest: a single Opus pass for a tiny
/// source, or an Opus curator that fans out to Sonnet `source-reader` DIGESTERS for
/// anything larger (`plans/llm-wiki.md` Phase D / `feature/ingest-fewer-turns`).
///
/// **Guiding principle (the user's correction).** Opus is ALWAYS the curator — it
/// decides what goes in the wiki and WRITES everything (pages + index + log) via
/// `wikictl`. Sonnet exists ONLY to chew through large volumes of source content: a
/// Sonnet worker READS an assigned chunk and returns a structured DIGEST. Sonnet
/// NEVER writes wiki content and has no `wikictl`.
///
/// PURE and unit-tested. The decision is driven purely by source size against a
/// named threshold; the plan then carries the top-level `--model` alias (always
/// `opus`) and, for the large-source mode, the `--agents` JSON defining one Sonnet
/// `source-reader` digester. The app picks the mode when building the Ingest command;
/// `OperationCommand.build` turns the plan into argv.
///
/// **Model tiering (verified against the installed CLI 2.1.178, real smoke test).**
/// `--model <m>` sets the top-level model; the aliases `opus` and `sonnet` resolve to
/// `claude-opus-4-8` and `claude-sonnet-4-6`. `--agents '{…}'` defines inline
/// subagents that carry their OWN `model` (a smoke test confirmed the `source-reader`
/// worker ran on `claude-sonnet-4-6` while the top level ran on `claude-opus-4-8`,
/// and the worker — given only `["Read","Bash"]` — read the staged source and
/// returned its digest to the Opus parent). The custom agent's `prompt` does NOT
/// inherit `--append-system-prompt`, so the worker prompt is SELF-SUFFICIENT — but
/// because the worker never writes, it carries NO write rule; it only digests.
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

  /// The top-level `--model` alias. ALWAYS `opus` — Opus is the curator/writer in
  /// both modes; the single pass and the curator both run on Opus.
  public var topLevelModelAlias: String {
    switch self {
    case .singleOpus, .opusCurator: "opus"
    }
  }

  /// The `--agents` JSON for the large-source mode (one Sonnet `source-reader`
  /// digester), or nil for the single pass (no subagents). Built from
  /// `digesterPrompt` so the worker's read-only digest contract is in one place.
  public func agentsJSON() -> String? {
    switch self {
    case .singleOpus:
      return nil
    case .opusCurator:
      return Self.agentsJSON(digesterPrompt: Self.digesterPrompt)
    }
  }

  /// The self-sufficient `source-reader` subagent prompt. The worker is a pure
  /// DIGESTER: it reads an assigned chunk of the staged source and returns a
  /// structured digest. It does NOT write to the wiki, has no `wikictl`, and carries
  /// NO write rule — its only job is to read volume and hand structured facts back to
  /// the Opus curator, which does all the writing. Because a custom agent's `prompt`
  /// does NOT inherit `--append-system-prompt`, this is self-contained.
  public static let digesterPrompt: String = GeneratedPrompts.digesterPrompt

  /// Build the `--agents` JSON object for one Sonnet `source-reader` digester. The
  /// shape was verified against the installed CLI (2.1.178): keys `description`,
  /// `prompt`, `model`, `tools` — `model` is the per-subagent alias (`sonnet`).
  /// `tools` is `["Bash","Read"]`: READ-ONLY (Read for the staged source, Bash for
  /// `cat`/`sed`/`grep` on the chunk) — NO wiki-writing tools, since the worker only
  /// digests. JSON is assembled via `JSONSerialization` so the multi-line prompt is
  /// correctly escaped.
  static func agentsJSON(digesterPrompt: String) -> String {
    let agents: [String: Any] = [
      "source-reader": [
        "description": GeneratedPrompts.sourceReaderDescription,
        "model": "sonnet",
        "prompt": digesterPrompt,
        "tools": ["Bash", "Read"],
      ]
    ]
    // Sorted keys so the rendered JSON is deterministic (stable argv → testable,
    // and a stable prompt prefix for caching).
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: agents, options: [.sortedKeys]),
      let json = String(data: data, encoding: .utf8)
    else {
      return "{}"
    }
    return json
  }
}
