import Foundation
import WikiFSCore

/// Runs the `git` commands `GitCommandPlan` describes.
///
/// The app-side half of the split that `AgentLauncher` uses for `claude`:
/// `GitCommandPlan` decides WHAT (pure, unit-tested argv), this decides HOW (the
/// `Process`, the pipes, the resolved binary). Nothing here builds an argument
/// list — if a flag needs changing it changes in the plan, where a test can see it.
///
/// Every call is `async` and runs the process off the main actor, because a clone
/// of a large repository takes minutes and a fetch takes seconds — neither may
/// block the UI. Output is captured whole rather than streamed: git's output here
/// is small and structured (a sha, a file list, a diff stat), unlike the agent's
/// NDJSON, which is why this needs none of `AgentLauncher`'s streaming machinery.
enum GitRunner {
  /// A non-zero exit, carrying git's own stderr. Surfaced VERBATIM in the UI:
  /// git's messages ("Repository not found", "could not read Username",
  /// "Permission denied (publickey)") are the actual diagnosis, and paraphrasing
  /// them would only hide which of the many failure modes happened.
  struct Failure: Error, CustomStringConvertible {
    let arguments: [String]
    let status: Int32
    let stderr: String

    var description: String {
      let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      return detail.isEmpty ? "git exited \(status)" : detail
    }
  }

  /// `git` was not found on the login-shell PATH.
  struct NotInstalled: Error, CustomStringConvertible {
    let reason: String
    var description: String { reason }
  }

  /// Resolve `git` on the LOGIN-shell PATH, not the GUI app's process PATH —
  /// same reasoning as the `claude` preflight: a launchd-minimal PATH usually
  /// lacks `/opt/homebrew/bin`, and on a Mac without the developer tools `git`
  /// exists as a stub that prompts for an Xcode install when run.
  static func resolveGit() -> Result<String, NotInstalled> {
    switch PathPreflight.resolveOnLoginShell(
      executable: "git",
      installHint: "Install the Xcode Command Line Tools (`xcode-select --install`)")
    {
    case .found(let path): .success(path)
    case .missing(let reason): .failure(NotInstalled(reason: reason))
    }
  }

  /// Run one git invocation and return its trimmed stdout. Throws `Failure` on a
  /// non-zero exit and `NotInstalled` when git can't be resolved.
  @discardableResult
  static func run(_ arguments: [String]) async throws -> String {
    let git = try resolveGit().get()
    return try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = arguments
        // Never let git stop to ask a human anything: in a GUI-spawned process
        // an auth prompt would hang the run forever with no visible cause. With
        // these set, a repo needing credentials fails fast and loudly instead,
        // and the error text tells the user to configure their credential helper.
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_ASKPASS"] = "/usr/bin/false"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do {
          try process.run()
        } catch {
          continuation.resume(throwing: error)
          return
        }
        // Read both pipes BEFORE waiting: a repo with a large file list can fill
        // the 64 KB pipe buffer, and waiting first would deadlock against a git
        // that is blocked writing into it.
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        if process.terminationStatus == 0 {
          continuation.resume(returning: stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
          continuation.resume(
            throwing: Failure(
              arguments: arguments, status: process.terminationStatus, stderr: stderr))
        }
      }
    }
  }

  /// Run a git invocation for its EXIT STATUS only (`merge-base --is-ancestor`),
  /// where non-zero is an answer rather than an error.
  static func succeeds(_ arguments: [String]) async -> Bool {
    do {
      _ = try await run(arguments)
      return true
    } catch {
      return false
    }
  }

  /// Stdout split into non-empty trimmed lines — the shape most of these commands
  /// actually produce (file lists, commit lines).
  static func lines(_ arguments: [String]) async throws -> [String] {
    try await run(arguments)
      .split(separator: "\n", omittingEmptySubsequences: true)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }
}
