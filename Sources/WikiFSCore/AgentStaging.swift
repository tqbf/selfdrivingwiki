import Foundation

/// Stages the inputs an agent run reads from RELIABLE local disk into the per-run
/// scratch dir, instead of the read-only / ~5s-laggy File Provider mount
/// (`feature/ingest-fewer-turns` — the user called this out as load-bearing).
///
/// Two staged files, both read from SQLite at click time:
/// - `WIKI_STATE.md` — the live wiki-state snapshot (titles + index.md + log tail),
///   so the Opus curator reads the cross-link vocabulary locally and skips
///   orientation turns (problem #2).
/// - `source.<ext>` — the raw bytes of the ingest source (Ingest only), so the Opus
///   curator and its Sonnet `source-reader` digesters read the source from local
///   disk, not the mount.
///
/// The path math (leaf filenames, the `source.<ext>` extension handling) is PURE
/// and unit-tested via `stateFileName` / `sourceFileName`; only the actual writes
/// touch the filesystem (the thin app seam). Absolute paths are returned so the
/// operation prompt can name exactly where the agent should read.
public enum AgentStaging {
  /// The fixed leaf name of the staged wiki-state snapshot.
  public static let stateFileName = "WIKI_STATE.md"

  /// The leaf name of the staged source: `source` plus the source's lowercased
  /// extension (no dot when the source has none). PURE — the same escaping the rest
  /// of the app uses isn't needed here because the leaf is app-chosen, not derived
  /// from the (untrusted) original filename.
  public static func sourceFileName(ext: String) -> String {
    let trimmed = ext.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
    return trimmed.isEmpty ? "source" : "source.\(trimmed)"
  }

  /// Write `WIKI_STATE.md` into `scratchDirectory` and return its absolute path.
  /// Throws if the write fails (the caller surfaces it as a preflight error rather
  /// than launching a run that would fall back to probing the mount).
  @discardableResult
  public static func stageStateFile(
    _ stateMarkdown: String,
    in scratchDirectory: URL
  ) throws -> String {
    let url = scratchDirectory.appendingPathComponent(stateFileName, isDirectory: false)
    try Data(stateMarkdown.utf8).write(to: url, options: .atomic)
    return url.path
  }

  /// Write the raw `source.<ext>` bytes into `scratchDirectory` and return its
  /// absolute path. Throws if the write fails.
  @discardableResult
  public static func stageSource(
    _ bytes: Data,
    ext: String,
    in scratchDirectory: URL
  ) throws -> String {
    let url = scratchDirectory.appendingPathComponent(
      sourceFileName(ext: ext), isDirectory: false)
    try bytes.write(to: url, options: .atomic)
    return url.path
  }
}
