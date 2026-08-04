import Foundation

/// The Sonnet `repo-reader` subagent definition for a curator-mode repo ingest —
/// the repo counterpart of `IngestPlan.digesterPrompt` / `IngestPlan.agentsJSON`.
///
/// **Same contract as `source-reader`, different material.** A `source-reader`
/// gets a byte/line/page range of ONE staged document; a `repo-reader` gets a
/// SUBSYSTEM — a directory, a module, or a set of changed files — inside a real
/// checkout, and has to navigate it. So it needs `Grep` and `Glob` on top of
/// `Read`/`Bash`, and it is told the checkout is read-only.
///
/// It still NEVER writes: it has no `wikictl`, and Opus remains the curator that
/// decides the page set and writes every page. Because a custom agent's `prompt`
/// does NOT inherit `--append-system-prompt`, this prompt is self-sufficient.
public enum RepoReaderAgent {
  /// The self-sufficient worker prompt. Read-only, digest-only, and explicit that
  /// citations must carry file paths and line numbers — the curator can't cite
  /// `repo@sha:path:line` provenance it was never handed.
  public static let prompt = """
    You are a repo-reader. The curator has assigned you ONE subsystem of a git \
    checkout — a directory, a module, a package, or a specific set of changed \
    files. READ ONLY what you were assigned and return a STRUCTURED DIGEST of it.

    Navigate with Grep/Glob/Read and shell tools (`ls`, `sed`, `wc`, `git -C <path> \
    log`). Your digest should cover: what this subsystem is FOR, its main types / \
    functions / entry points, how it connects to the rest of the repo (what it \
    calls, what calls it), notable invariants or gotchas the code makes explicit, \
    and — when you were given a commit range — WHAT CHANGED and why it matters. \
    Quote sparingly, and give every non-obvious claim a `path/to/File.ext:LINE` \
    location so the curator can cite it.

    The checkout is READ-ONLY. Do not write, create, or modify any file in it, and \
    do not run a git command that mutates it (no commit, checkout, pull, reset, \
    clean, stash). You do NOT write to the wiki: you have NO wikictl and no write \
    tools — do not look for one, and do not touch the wiki mount. Return your digest \
    as your final message; the curator synthesizes the digests and writes every page \
    itself.
    """

  /// Build the `--agents` JSON object for one Sonnet `repo-reader`. Same shape as
  /// `IngestPlan.agentsJSON` (verified against the installed CLI): `description`,
  /// `prompt`, `model`, `tools`. `tools` is READ-ONLY — `Grep`/`Glob` for
  /// navigation, `Read`/`Bash` for content — with no wiki-writing tool. Sorted keys
  /// so the rendered JSON is deterministic (stable argv → testable).
  public static func agentsJSON(prompt: String = RepoReaderAgent.prompt) -> String {
    let agents: [String: Any] = [
      "repo-reader": [
        "description":
          "Reads one assigned subsystem (directory, module, or changed-file set) of a "
          + "tracked git checkout and returns a structured digest (purpose, main types, "
          + "connections, gotchas, what changed) with path:line locations. Does NOT write "
          + "to the wiki or the checkout. Use to read code volume in parallel.",
        "model": "sonnet",
        "prompt": prompt,
        "tools": ["Bash", "Read", "Grep", "Glob"],
      ]
    ]
    do {
      let data = try JSONSerialization.data(withJSONObject: agents, options: [.sortedKeys])
      guard let json = String(data: data, encoding: .utf8) else {
        DebugLog.agent("RepoReaderAgent.agentsJSON: encoded data is not UTF-8")
        return "{}"
      }
      return json
    } catch {
      DebugLog.agent("RepoReaderAgent.agentsJSON: serialization failed: \(error)")
      return "{}"
    }
  }
}
