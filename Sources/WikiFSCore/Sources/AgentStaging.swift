import Foundation

/// Stages the inputs an agent run reads from RELIABLE local disk into the per-run
/// scratch dir, instead of the read-only / ~5s-laggy File Provider mount
/// (`feature/ingest-fewer-turns` — the user called this out as load-bearing).
///
/// Two kinds of staged files, both read from SQLite at click time:
/// - `WIKI_STATE.md` — the live wiki-state snapshot (titles + index.md + log tail),
///   so the Opus curator reads the cross-link vocabulary locally and skips
///   orientation turns (problem #2).
/// - `<shellSafeStem>--<full-ULID>.<ext>` — the raw bytes of the ingest source(s)
///   (Ingest only), so the curator and its digesters read from local disk, not
///   the mount. The leaf is shell-safe BY CONSTRUCTION (matches
///   `^[A-Za-z0-9._-]+$`) because the executor prompt injects it BARE into
///   `sed`/`cat` (`prompts/ingest-executor.md`); the stem carries provenance
///   (`source.effectiveName`) and the full ULID disambiguator guarantees
///   collision-freedom (a `shortID` prefix collides for same-millisecond ULIDs,
///   which is the normal case in a multi-file drag-drop). See
///   `shellSafeLeaf(name:sourceID:ext:)`.
///
/// The path math (the shell-safe leaf) is PURE and unit-tested via
/// `shellSafeLeaf`; only the actual writes touch the filesystem (the thin app
/// seam). Absolute paths are returned so the operation prompt can name exactly
/// where the agent should read.
public enum AgentStaging {
  /// The fixed leaf name of the staged wiki-state snapshot.
  public static let stateFileName = "WIKI_STATE.md"

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

  /// Write multiple source files as `<shellSafeStem>--<full-ULID>.<ext>` leaves
  /// into `scratchDirectory`. Returns their absolute paths in the same order.
  /// Each entry is `(bytes, ext, name, sourceID)`. Throws on the first write
  /// failure.
  ///
  /// The leaf is `shellSafeLeaf(name:sourceID:ext:)` — shell-safe by
  /// construction and collision-free across same-millisecond ULIDs. The
  /// `sourceID` is the FULL ULID (`source.id.rawValue`), not the 8-char
  /// `FilenameEscaping.shortID` (which lies entirely within the ms-timestamp
  /// prefix and would silently collide for same-ms sources).
  @discardableResult
  public static func stageSources(
    _ sources: [(bytes: Data, ext: String, name: String, sourceID: String)],
    in scratchDirectory: URL
  ) throws -> [String] {
    var paths: [String] = []
    for source in sources {
      let leaf = shellSafeLeaf(name: source.name, sourceID: source.sourceID, ext: source.ext)
      let url = scratchDirectory.appendingPathComponent(leaf, isDirectory: false)
      try source.bytes.write(to: url, options: .atomic)
      paths.append(url.path)
    }
    return paths
  }

  /// STAGING-specific shell-safe leaf. Intentionally diverges from the File
  /// Provider's `sources/by-name/` naming (which keeps spaces via
  /// `FilenameEscaping.byNameSourceFilename`): the executor prompt injects this
  /// leaf BARE (unquoted) into `sed -n 'START,ENDp' {{PRIMARY_SOURCE_FILE}}` and
  /// `cat {{PRIMARY_SOURCE_FILE}}` (`prompts/ingest-executor.md`), so it must
  /// contain no spaces or shell metacharacters. The whole leaf matches
  /// `^[A-Za-z0-9._-]+$`.
  ///
  /// Algorithm:
  /// 1. `escapeTitle` — strip control chars, replace `/` & `:` with `-`, handle
  ///    leading `.` and empty → `untitled` (`FilenameEscaping.swift`).
  /// 2. Replace every char outside `[A-Za-z0-9._-]` with `-`. This covers spaces
  ///    AND shell metacharacters `; & $ \` ( ) | < > \ " ' ! * ? [ ] { }`.
  /// 3. Collapse runs of `-` and trim leading/trailing `-` (tidy, deterministic).
  /// 4. Sanitize the extension the same way so the WHOLE leaf is shell-safe.
  ///
  /// `sourceID` is the FULL 26-char ULID: `shortID` (first 8 chars) lives in the
  /// ms-timestamp prefix and collides for same-millisecond ULIDs (a normal case
  /// in multi-file drag-drop), which would silently overwrite a staged file
  /// (`.atomic` write has no collision check). The full ULID restores
  /// collision-freedom by construction.
  ///
  /// Examples:
  ///   `("Neuralwatt Cloud Platform", "01KXY…", "html")` →
  ///     `Neuralwatt-Cloud-Platform--01KXY….html`
  ///   `("Cost & Revenue (Q3)",       "01KXY…", "md")` →
  ///     `Cost-Revenue-Q3--01KXY….md`
  ///   `("",                          "01KXY…", "md")` →
  ///     `untitled--01KXY….md`
  public static func shellSafeLeaf(name: String, sourceID: String, ext: String) -> String {
    // (1) escapeTitle: strip control chars, replace `/` & `:` with `-`, handle
    //     leading `.` and empty → "untitled" (FilenameEscaping.swift).
    var stem = FilenameEscaping.escapeTitle(name)
    // (2) Replace every char outside [A-Za-z0-9._-] with '-'. This covers spaces
    //     AND shell metacharacters ; & $ ` ( ) | < > \ " ' ! * ? [ ] { }.
    let allowed = CharacterSet(charactersIn:
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
    stem = String(stem.unicodeScalars.map {
      allowed.contains($0) ? Character($0) : "-"
    })
    // (3) Collapse runs of '-' and trim leading/trailing '-' (tidy, deterministic).
    while stem.contains("--") { stem = stem.replacingOccurrences(of: "--", with: "-") }
    stem = stem.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    if stem.isEmpty { stem = "untitled" }
    // (4) Sanitize the extension the same way so the whole leaf is shell-safe.
    let safeExt = String(ext.lowercased().unicodeScalars.compactMap { scalar -> Character? in
      allowed.contains(scalar) ? Character(scalar) : nil
    })
    let base = "\(stem)--\(sourceID)"   // full 26-char ULID (fix #2)
    return safeExt.isEmpty ? base : "\(base).\(safeExt)"
  }
}
