import Foundation

/// Parse + canonicalize the remote URL the user types into "Add Repository…",
/// and derive the `owner/repo` display name from it.
///
/// PURE and unit-tested, modeled on `URLIngestService.normalizeURL` (the same
/// "be forgiving about what the user pastes, strict about what we act on"
/// contract): the sheet calls `parse` on every keystroke to decide whether the
/// Add button is enabled, and the app hands `remote` straight to `git clone`.
///
/// Accepted forms (everything else is rejected):
/// - `https://github.com/owner/repo` (with or without `.git`, with or without a
///   trailing slash)
/// - `http://host/owner/repo` — left on http, NOT silently upgraded: unlike a web
///   page fetch, a git remote may be an internal host where https isn't served,
///   and a wrong guess fails confusingly at clone time.
/// - `github.com/owner/repo` — schemeless, upgraded to https
/// - `git@github.com:owner/repo.git` — scp-form, passed through verbatim (git's
///   own parser owns this shape; rewriting it would break ssh config aliases)
/// - `ssh://git@host/owner/repo.git`
public struct GitRemoteURL: Equatable, Sendable {
  /// The canonical remote string to hand `git clone`.
  public let remote: String
  /// Display name, normally `owner/repo`; falls back to the last path component
  /// for single-segment remotes.
  public let name: String

  public init(remote: String, name: String) {
    self.remote = remote
    self.name = name
  }

  /// Parse user input into a canonical remote + display name, or nil if it isn't
  /// a git remote we're willing to clone.
  public static func parse(_ raw: String) -> GitRemoteURL? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    // scp-form (`git@host:owner/repo.git`) — no scheme, a single colon before a
    // path, and no leading slash. Passed through verbatim.
    if let scp = parseSCPForm(trimmed) { return scp }

    let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    guard let url = URL(string: candidate),
      let scheme = url.scheme?.lowercased(),
      ["https", "http", "ssh", "git"].contains(scheme),
      let host = url.host, !host.isEmpty
    else {
      return nil
    }

    let segments = pathSegments(url.path)
    guard !segments.isEmpty else { return nil }

    // Canonical remote: drop a trailing slash, keep everything else the user
    // typed (including `.git`, which git is happy with either way).
    var remote = candidate
    while remote.hasSuffix("/") { remote.removeLast() }
    return GitRemoteURL(remote: remote, name: displayName(from: segments))
  }

  /// `git@host:owner/repo.git`. Recognized by: no `://`, exactly one `:` that is
  /// followed by a non-numeric path, and a non-empty host part.
  private static func parseSCPForm(_ input: String) -> GitRemoteURL? {
    guard !input.contains("://"), let colon = input.firstIndex(of: ":") else { return nil }
    let hostPart = String(input[input.startIndex..<colon])
    let pathPart = String(input[input.index(after: colon)...])
    guard !hostPart.isEmpty, !pathPart.isEmpty, hostPart.contains("@") || hostPart.contains("."),
      !pathPart.hasPrefix("/"), Int(pathPart.prefix(1)) == nil
    else {
      return nil
    }
    let segments = pathSegments(pathPart)
    guard !segments.isEmpty else { return nil }
    return GitRemoteURL(remote: input, name: displayName(from: segments))
  }

  /// Non-empty path components, with any `.git` suffix stripped from the last one.
  private static func pathSegments(_ path: String) -> [String] {
    var segments = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
    if var last = segments.last, last.hasSuffix(".git") {
      last.removeLast(4)
      segments[segments.count - 1] = last
      if last.isEmpty { segments.removeLast() }
    }
    return segments
  }

  /// `owner/repo` from the last two segments; the single segment alone when
  /// that's all there is (e.g. a bare `host/repo.git` remote).
  private static func displayName(from segments: [String]) -> String {
    segments.suffix(2).joined(separator: "/")
  }
}
