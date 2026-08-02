import Foundation

/// Where the app keeps its own clones of tracked repositories.
///
/// `~/Library/Application Support/WikiFS/repos/<wikiULID>/<repoULID>/`
///
/// **Deliberately NOT the App Group container.** `DatabaseLocation` puts the
/// per-wiki `.sqlite` in `~/Library/Group Containers/group.org.sockpuppet.wiki/`
/// because the sandboxed File Provider extension must read it. Nothing reads a
/// repo checkout except the app and the agent it spawns — and the container is
/// the surface that wiki export/import copies around, so dropping multi-hundred-MB
/// working trees in it would silently bloat every backup.
///
/// **Keyed by ULID, never by name**, matching `DatabaseLocation`'s `<ulid>.sqlite`
/// rule: renaming a wiki or re-pointing a repo's remote must never orphan or
/// collide with an existing checkout.
public enum RepoCheckoutLocation {
  /// The path components under Application Support, exposed separately so the
  /// layout is unit-testable without touching the real home directory.
  public static func relativeComponents(wikiID: String, repoID: String) -> [String] {
    ["WikiFS", "repos", wikiID, repoID]
  }

  /// The root under which every wiki's clones live. Creates it if needed.
  public static func reposRoot() throws -> URL {
    let base = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true)
    let dir = base
      .appendingPathComponent("WikiFS", isDirectory: true)
      .appendingPathComponent("repos", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// The checkout directory for one repo in one wiki. Creates the PARENT (the
  /// per-wiki directory) but not the leaf — `git clone` requires the target
  /// directory to be absent or empty, and creating it here would be a footgun.
  public static func directory(wikiID: String, repoID: String) throws -> URL {
    let wikiDir = try reposRoot().appendingPathComponent(wikiID, isDirectory: true)
    try FileManager.default.createDirectory(at: wikiDir, withIntermediateDirectories: true)
    return wikiDir.appendingPathComponent(repoID, isDirectory: true)
  }

  /// Remove one repo's checkout. Best-effort: a missing directory is success,
  /// since the caller's intent is "this checkout should not exist".
  public static func removeCheckout(wikiID: String, repoID: String) throws {
    let dir = try directory(wikiID: wikiID, repoID: repoID)
    guard FileManager.default.fileExists(atPath: dir.path) else { return }
    try FileManager.default.removeItem(at: dir)
  }
}
