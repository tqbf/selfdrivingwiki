import Foundation
import Observation
import WikiFSCore

/// Keeps the app's clones of tracked repositories in sync — the "tracking" half
/// of repository tracking.
///
/// **Everything here is user-initiated.** There is no timer and no unattended
/// agent run: a fetch happens when you ask for one, and an agent pass happens
/// when you click Update. That is a deliberate cost decision — a repo pass is an
/// Opus run with a Sonnet fan-out, and a background loop that starts one while
/// you're asleep spends real money on work you didn't ask for. Discovering drift
/// a click late is a much smaller problem than that.
///
/// **The serialization rule (still needed).** `AgentLauncher` is app-wide and
/// refuses to start a second run (`guard !isRunning`), so a second Update
/// requested while one is going wouldn't queue — it would silently vanish. So the
/// tracker keeps its own FIFO and drains it only when the launcher is idle, and
/// never while an interactive Query session is open (an agent run that grabs the
/// editor lock mid-conversation is its own kind of surprise).
@MainActor
@Observable
final class RepoTracker {
  /// What the tracker is doing to one repo right now, for the sidebar badge.
  enum Activity: Equatable {
    case cloning
    case fetching
    case queuedForIngest
    case ingesting
  }

  /// Per-repo activity, keyed by repo id. Absent == idle.
  private(set) var activity: [PageID: Activity] = [:]
  /// The last error per repo, shown in its detail pane. Cleared on the next
  /// successful operation for that repo. Carries git's own message verbatim.
  private(set) var errors: [PageID: String] = [:]

  private let store: WikiStoreModel
  private let manager: WikiManager
  private let launcher: AgentLauncher
  private let fileProvider: FileProviderSpike

  /// Repos waiting for the launcher to go idle. Ids, not plans: by the time a
  /// queued repo actually runs, the right commit range may have moved on, so the
  /// plan is recomputed at drain time rather than captured here.
  private var pendingIngests: [PageID] = []
  private var isDraining = false

  init(
    store: WikiStoreModel,
    manager: WikiManager,
    launcher: AgentLauncher,
    fileProvider: FileProviderSpike
  ) {
    self.store = store
    self.manager = manager
    self.launcher = launcher
    self.fileProvider = fileProvider
  }

  // MARK: - Checking for new commits

  /// Fetch every tracked repo in the active wiki — the "Check for New Commits"
  /// action. Costs nothing but network: it updates each repo's head so the
  /// sidebar can show which ones have drifted. It NEVER starts an agent run;
  /// that is always a separate, explicit click.
  func fetchAll() async {
    guard manager.activeWikiID != nil else { return }
    for repo in store.repos {
      await fetch(repo)
    }
  }

  /// Whether a check-all would do anything (used to disable the button).
  var isBusy: Bool { !activity.isEmpty }

  // MARK: - Adding

  /// Track a new repository: create the row, then clone it. The row comes first
  /// because its ULID names the checkout directory — and if the clone then fails
  /// (bad URL, no auth, no network) the row SURVIVES carrying the error, so the
  /// user sees a repo they can retry rather than a sheet that silently did
  /// nothing.
  @discardableResult
  func addRepo(remote: GitRemoteURL, branch: String?) async -> TrackedRepo? {
    guard let wikiID = manager.activeWikiID else { return nil }
    let repo: TrackedRepo
    do {
      repo = try store.addRepo(
        name: remote.name, remoteURL: remote.remote, branch: branch ?? "")
    } catch {
      return nil
    }

    activity[repo.id] = .cloning
    defer { if activity[repo.id] == .cloning { activity[repo.id] = nil } }

    do {
      let directory = try RepoCheckoutLocation.directory(
        wikiID: wikiID, repoID: repo.id.rawValue)
      // A leftover directory from a failed earlier attempt would make `git clone`
      // refuse; the ULID makes a collision with a LIVE checkout impossible, so
      // anything here is debris.
      try? FileManager.default.removeItem(at: directory)
      _ = try await GitRunner.run(
        GitCommandPlan.clone(
          remote: remote.remote, into: directory.path, branch: branch))

      // Fill in the branch git actually checked out when the user didn't name one.
      let resolvedBranch = try await GitRunner.run(
        GitCommandPlan.currentBranch(at: directory.path))
      if repo.branch != resolvedBranch {
        store.setRepoBranch(id: repo.id, branch: resolvedBranch)
      }
      let head = try await GitRunner.run(
        GitCommandPlan.revParse(at: directory.path, ref: "HEAD"))
      store.updateRepoSync(id: repo.id, headCommit: head, fetchedAt: Date())
      errors[repo.id] = nil
      // Cloned, NOT ingested. The first pass is an Opus run, so it waits for an
      // explicit "Update Wiki Now" like every other pass — adding a repo says
      // "watch this", not "spend on it right now".
      return store.repo(id: repo.id)
    } catch {
      errors[repo.id] = "\(error)"
      return store.repo(id: repo.id)
    }
  }

  /// Stop tracking: remove the row AND the checkout. Both, or the next repo with
  /// the same remote would inherit a stale working tree.
  func removeRepo(_ repo: TrackedRepo) {
    if let wikiID = manager.activeWikiID {
      try? RepoCheckoutLocation.removeCheckout(wikiID: wikiID, repoID: repo.id.rawValue)
    }
    pendingIngests.removeAll { $0 == repo.id }
    activity[repo.id] = nil
    errors[repo.id] = nil
    store.deleteRepo(id: repo.id)
  }

  // MARK: - Fetch

  /// Fetch one repo and record the upstream tip. Never starts an agent run: its
  /// only effect is that the row can now say whether the repo has drifted.
  func fetch(_ repo: TrackedRepo) async {
    guard let wikiID = manager.activeWikiID,
      let directory = try? RepoCheckoutLocation.directory(
        wikiID: wikiID, repoID: repo.id.rawValue),
      FileManager.default.fileExists(atPath: directory.path)
    else { return }

    activity[repo.id] = .fetching
    defer { if activity[repo.id] == .fetching { activity[repo.id] = nil } }

    do {
      _ = try await GitRunner.run(GitCommandPlan.fetch(at: directory.path))
      let head = try await GitRunner.run(
        GitCommandPlan.revParse(at: directory.path, ref: "origin/\(repo.branch)"))
      // Move the working tree to the fetched tip, so what the agent reads is what
      // the head commit says it is. Safe: this checkout is app-owned and never
      // hand-edited.
      _ = try await GitRunner.run(GitCommandPlan.resetHard(at: directory.path, to: head))
      store.updateRepoSync(id: repo.id, headCommit: head, fetchedAt: Date())
      errors[repo.id] = nil
    } catch {
      errors[repo.id] = "\(error)"
    }
  }

  // MARK: - Ingest queue

  /// "Update Wiki Now" — the ONLY way an agent pass starts. Queued rather than
  /// run directly because the launcher takes one run at a time.
  func requestIngest(_ repo: TrackedRepo) async {
    guard !pendingIngests.contains(repo.id) else { return }
    pendingIngests.append(repo.id)
    activity[repo.id] = .queuedForIngest
    await drainQueue()
  }

  /// Start the next queued repo, if now is a good time. Re-entrant-safe via
  /// `isDraining`, since both `requestIngest` and run-completion call it.
  private func drainQueue() async {
    guard !isDraining else { return }
    isDraining = true
    defer { isDraining = false }

    while !pendingIngests.isEmpty {
      // The two "not now" conditions. An interactive Query session is a HARDER
      // stop than a busy launcher: the user is mid-conversation, and an agent run
      // that grabs the editor lock and rewrites pages underneath them is not a
      // surprise a queued update should be able to produce.
      guard !launcher.isRunning, !launcher.isInteractiveSession else { return }

      let id = pendingIngests.removeFirst()
      guard let repo = store.repo(id: id) else { continue }
      activity[id] = .ingesting
      await AgentOperationRunner.runRepoIngest(
        repo: repo,
        tracker: self,
        launcher: launcher,
        store: store,
        manager: manager,
        fileProvider: fileProvider)

      // `runRepoIngest` returns once the run has STARTED (the launcher streams it
      // asynchronously), so stop and let the run's completion bring us back. If
      // it did NOT start — a missing checkout, a git failure, or a repo that
      // turned out to be up to date — keep draining: waiting on a completion
      // that will never arrive would strand the rest of the queue indefinitely,
      // and with no poll loop nothing would ever come along to unstick it.
      if launcher.isRunning { return }
      if activity[id] == .ingesting { activity[id] = nil }
    }
  }

  /// Called when an agent run finishes, so a queued repo can start. Wired from
  /// the launcher's unlock hook rather than polled.
  func agentRunDidFinish() {
    for (id, state) in activity where state == .ingesting {
      activity[id] = nil
    }
    Task { await drainQueue() }
  }

  /// Record why a repo pass couldn't start (missing checkout, no mount, git gone).
  func recordError(_ message: String, for id: PageID) {
    errors[id] = message
    activity[id] = nil
  }

  /// Clear a repo's activity marker without touching its error.
  func clearActivity(for id: PageID) {
    activity[id] = nil
  }
}
