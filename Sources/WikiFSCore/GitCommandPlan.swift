import Foundation

/// The exact `git` argv for every command the repo tracker runs.
///
/// PURE, exactly like `OperationCommand`: this file decides WHAT to run, the
/// app's `GitRunner` decides HOW (it owns the `Process`, the resolved `git`
/// path, and the pipes). Keeping argv here means every flag is unit-testable
/// without spawning anything, and the set of git commands the app can issue is
/// enumerable in one place — which matters because ALL of them must be read-only
/// with respect to the user's own repositories.
///
/// **Every repo-scoped command carries `-C <path>`** rather than relying on the
/// process working directory: the tracker may fetch several repos concurrently,
/// and a shared cwd would be a race.
public enum GitCommandPlan {
  /// Clone a fresh tracking checkout.
  ///
  /// `--filter=blob:none` makes this a *treeless-ish* partial clone: full commit
  /// and tree history (needed to diff arbitrary commit ranges) but blobs fetched
  /// only when a file is actually materialized. A big repo clones in seconds
  /// instead of minutes, and the checked-out working tree the agent greps is
  /// still complete. `--no-tags` keeps the fetch cheap.
  public static func clone(remote: String, into path: String, branch: String?) -> [String] {
    var args = ["clone", "--filter=blob:none", "--no-tags"]
    if let branch, !branch.isEmpty {
      args += ["--branch", branch]
    }
    args += [remote, path]
    return args
  }

  /// Fetch upstream without touching the working tree. `--prune` keeps deleted
  /// remote branches from lingering as stale drift.
  public static func fetch(at path: String) -> [String] {
    ["-C", path, "fetch", "--prune", "--no-tags", "origin"]
  }

  /// Fast-forward the working tree to a fetched commit. Used ONLY on the app's
  /// own clone (never on user checkouts), so a hard reset is safe: nothing here
  /// is ever edited by hand.
  public static func resetHard(at path: String, to ref: String) -> [String] {
    ["-C", path, "reset", "--hard", ref]
  }

  /// Resolve a ref to a full 40-char SHA.
  public static func revParse(at path: String, ref: String) -> [String] {
    ["-C", path, "rev-parse", ref]
  }

  /// The branch the clone is on (`main`, `master`, …). Used when the user didn't
  /// name one and we accepted the remote's default.
  public static func currentBranch(at path: String) -> [String] {
    ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"]
  }

  /// `true` (exit 0) when `ancestor` is reachable from `descendant`. The tracker
  /// uses this to detect a force-push: when the last ingested commit is no longer
  /// an ancestor of the new head, the commit range is meaningless and the sync
  /// falls back to a full re-read.
  public static func isAncestor(at path: String, ancestor: String, descendant: String) -> [String] {
    ["-C", path, "merge-base", "--is-ancestor", ancestor, descendant]
  }

  /// One-line commit subjects for `from..to` (or the most recent `limit` commits
  /// when `from` is nil). `--no-decorate` keeps the output stable.
  public static func logRange(at path: String, from: String?, to: String, limit: Int) -> [String] {
    var args = ["-C", path, "log", "--no-decorate", "--no-merges", "--date=short"]
    args += ["--pretty=format:%h %ad %an: %s", "--max-count=\(limit)"]
    args.append(from.map { "\($0)..\(to)" } ?? to)
    return args
  }

  /// `git diff --stat` between two commits — the shape-of-the-change summary the
  /// agent reads before deciding which pages need revising.
  public static func diffStat(at path: String, from: String, to: String) -> [String] {
    ["-C", path, "diff", "--stat", "\(from)..\(to)"]
  }

  /// The changed paths between two commits, one per line.
  public static func changedFiles(at path: String, from: String, to: String) -> [String] {
    ["-C", path, "diff", "--name-only", "\(from)..\(to)"]
  }

  /// Every tracked file in the working tree, one per line. Used for the initial
  /// ingest's file count and the top-level tree listing.
  public static func listFiles(at path: String) -> [String] {
    ["-C", path, "ls-files"]
  }

  /// Commit timestamp (ISO-8601) for a ref, so the state file can say how old the
  /// tip is without the app inventing a format.
  public static func commitDate(at path: String, ref: String) -> [String] {
    ["-C", path, "show", "--no-patch", "--format=%cI", ref]
  }

  /// Leading `-c` config that routes github.com credentials through the GitHub
  /// CLI, prepended to EVERY invocation.
  ///
  /// **Why this exists.** A GUI-spawned `git` has no terminal and no useful
  /// credential state, so a private repo fails at clone with "could not read
  /// Username". The user is already authenticated — `gh` holds a token — and the
  /// supported way to lend it to git is `gh auth git-credential`, which is
  /// exactly what `gh auth setup-git` installs. We pass the same two lines as
  /// `-c` flags instead of writing them, so the app **never edits the user's
  /// gitconfig**: our auth arrangement lives and dies with our own processes.
  ///
  /// The empty first `helper=` is not redundant — it resets any inherited helper
  /// chain for this host, so a stale osxkeychain entry can't answer first with a
  /// dead token. (`gh auth setup-git` writes the same pair for the same reason.)
  ///
  /// Scoped to `credential.https://github.com.helper`, so it is inert for every
  /// other host — which is why it can be applied unconditionally rather than
  /// threading each command's remote down to here. Returns `[]` when `gh` isn't
  /// installed, leaving the user's own helpers untouched.
  public static func githubCredentialArguments(ghPath: String?) -> [String] {
    guard let ghPath, !ghPath.isEmpty else { return [] }
    return [
      "-c", "credential.https://github.com.helper=",
      // `!cmd` is git's shell-command helper form. Quoted so a path with spaces
      // (a `gh` inside an .app bundle, say) doesn't split into two words.
      "-c", "credential.https://github.com.helper=!'\(ghPath)' auth git-credential",
    ]
  }
}
