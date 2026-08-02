import Foundation
import SQLite3
import Testing

@testable import WikiCtlCore
@testable import WikiFSCore

/// The v6 `tracked_repos` migration, the store's repo CRUD, and the `wikictl
/// repo` command surface the agent uses to move the ingested watermark.
struct TrackedRepoStoreTests {

  private func tempStore() throws -> SQLiteWikiStore {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("wikifs-repo-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return try SQLiteWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
  }

  private let noEnv: (String) -> String? = { _ in nil }

  // MARK: - Migration

  @Test func migratesV5DatabaseToV6PreservingData() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("wikifs-repo-mig-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("WikiFS.sqlite")

    // Build a v5 DB by hand (the ladder's previous head), with content in it.
    var db: OpaquePointer?
    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    let v5 = """
      CREATE TABLE pages (id TEXT PRIMARY KEY, title TEXT NOT NULL, slug TEXT NOT NULL,
        body_markdown TEXT NOT NULL DEFAULT '', created_at REAL NOT NULL,
        updated_at REAL NOT NULL, version INTEGER NOT NULL DEFAULT 1);
      CREATE UNIQUE INDEX pages_slug_unique ON pages(slug);
      CREATE TABLE attachments (id TEXT PRIMARY KEY, page_id TEXT, filename TEXT NOT NULL,
        mime_type TEXT, data BLOB NOT NULL, created_at REAL NOT NULL,
        updated_at REAL NOT NULL, version INTEGER NOT NULL DEFAULT 1);
      CREATE TABLE page_links (from_page_id TEXT NOT NULL, to_page_id TEXT NOT NULL,
        link_text TEXT NOT NULL, PRIMARY KEY (from_page_id, to_page_id));
      CREATE TABLE ingested_files (id TEXT PRIMARY KEY, filename TEXT NOT NULL,
        ext TEXT NOT NULL DEFAULT '', mime_type TEXT, byte_size INTEGER NOT NULL,
        content BLOB NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL,
        version INTEGER NOT NULL DEFAULT 1);
      CREATE INDEX ingested_files_created ON ingested_files(created_at);
      CREATE TABLE system_prompt (id INTEGER PRIMARY KEY CHECK (id = 1),
        body_markdown TEXT NOT NULL DEFAULT '', updated_at REAL NOT NULL,
        version INTEGER NOT NULL DEFAULT 1);
      INSERT INTO system_prompt (id, body_markdown, updated_at, version) VALUES (1, 'kept', 0, 1);
      CREATE TABLE log (id TEXT PRIMARY KEY, ts REAL NOT NULL, kind TEXT NOT NULL,
        title TEXT NOT NULL, note TEXT);
      CREATE TABLE wiki_index (id INTEGER PRIMARY KEY CHECK (id = 1),
        body_markdown TEXT NOT NULL DEFAULT '', updated_at REAL NOT NULL,
        version INTEGER NOT NULL DEFAULT 1);
      INSERT INTO wiki_index (id, body_markdown, updated_at, version) VALUES (1, 'catalog', 0, 1);
      INSERT INTO pages (id, title, slug, body_markdown, created_at, updated_at, version)
        VALUES ('01PAGE', 'Kept Page', 'kept-page', 'body', 0, 0, 1);
      PRAGMA user_version=5;
      """
    #expect(sqlite3_exec(db, v5, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)

    // Opening with the current store runs ONLY the v5→6 step.
    let store = try SQLiteWikiStore(databaseURL: url)
    #expect(try store.listRepos().isEmpty)
    // Pre-existing content survives untouched.
    #expect(try store.getPage(id: PageID(rawValue: "01PAGE")).title == "Kept Page")
    #expect(try store.getSystemPrompt().body == "kept")
    #expect(try store.getWikiIndex().body == "catalog")

    var check: OpaquePointer?
    #expect(sqlite3_open(url.path, &check) == SQLITE_OK)
    defer { sqlite3_close(check) }
    var stmt: OpaquePointer?
    #expect(sqlite3_prepare_v2(check, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK)
    defer { sqlite3_finalize(stmt) }
    #expect(sqlite3_step(stmt) == SQLITE_ROW)
    #expect(sqlite3_column_int(stmt, 0) == 6)
    _ = store
  }

  @Test func repoTableIsNotFoldedIntoTheChangeToken() throws {
    // Repos are app + agent state and are NOT projected onto the mount, so
    // tracking one must not move the File Provider's sync anchor.
    let store = try tempStore()
    let before = try store.changeToken()
    let repo = try store.addRepo(
      name: "o/r", remoteURL: "https://host/o/r", branch: "main")
    try store.updateRepoSync(id: repo.id, headCommit: "abc", fetchedAt: Date())
    #expect(try store.changeToken() == before)
  }

  // MARK: - CRUD

  @Test func addListGetRoundTrip() throws {
    let store = try tempStore()
    let added = try store.addRepo(
      name: "jvanderberg/wikimemory",
      remoteURL: "https://github.com/jvanderberg/wikimemory",
      branch: "main")

    #expect(added.headCommit == nil)
    #expect(added.lastIngestedCommit == nil)
    #expect(added.lastFetchedAt == nil)
    #expect(added.autoIngest)  // tracking implies wanting updates
    #expect(added.version == 1)

    let listed = try store.listRepos()
    #expect(listed.count == 1)
    #expect(listed.first?.name == "jvanderberg/wikimemory")
    #expect(try store.getRepo(id: added.id).remoteURL
      == "https://github.com/jvanderberg/wikimemory")
    #expect(try store.findRepo(name: "jvanderberg/wikimemory")?.id == added.id)
    #expect(try store.findRepo(name: "nope/nope") == nil)
  }

  @Test func trackingTheSameRemoteTwiceFails() throws {
    let store = try tempStore()
    _ = try store.addRepo(name: "o/r", remoteURL: "https://host/o/r", branch: "main")
    #expect(throws: (any Error).self) {
      _ = try store.addRepo(name: "o/r", remoteURL: "https://host/o/r", branch: "main")
    }
  }

  @Test func reposAreListedOldestFirst() throws {
    // Oldest-first keeps the sidebar stable as repos sync; most-recent-first
    // (as `ingested_files` uses) would reshuffle on every fetch.
    let store = try tempStore()
    let first = try store.addRepo(name: "o/one", remoteURL: "https://host/o/one", branch: "main")
    let second = try store.addRepo(name: "o/two", remoteURL: "https://host/o/two", branch: "main")
    #expect(try store.listRepos().map(\.id) == [first.id, second.id])
  }

  @Test func fetchAndWatermarkAreSeparateWrites() throws {
    // The whole point of the two columns: the app says what upstream HAS, the
    // agent says what the wiki COVERS, and neither implies the other.
    let store = try tempStore()
    let repo = try store.addRepo(name: "o/r", remoteURL: "https://host/o/r", branch: "main")

    try store.updateRepoSync(id: repo.id, headCommit: "bbb", fetchedAt: Date(timeIntervalSince1970: 100))
    var current = try store.getRepo(id: repo.id)
    #expect(current.headCommit == "bbb")
    #expect(current.lastIngestedCommit == nil)
    #expect(current.isDrifted)  // cloned but never ingested == all pending work
    #expect(current.lastFetchedAt == Date(timeIntervalSince1970: 100))
    #expect(current.version == 2)

    try store.markRepoIngested(id: repo.id, commit: "bbb")
    current = try store.getRepo(id: repo.id)
    #expect(current.lastIngestedCommit == "bbb")
    #expect(!current.isDrifted)
    #expect(current.version == 3)
  }

  @Test func branchAndAutoIngestAreSettable() throws {
    let store = try tempStore()
    let repo = try store.addRepo(name: "o/r", remoteURL: "https://host/o/r", branch: "")
    try store.setRepoBranch(id: repo.id, branch: "trunk")
    #expect(try store.getRepo(id: repo.id).branch == "trunk")

    try store.setRepoAutoIngest(id: repo.id, enabled: false)
    #expect(try store.getRepo(id: repo.id).autoIngest == false)
    try store.setRepoAutoIngest(id: repo.id, enabled: true)
    #expect(try store.getRepo(id: repo.id).autoIngest)
  }

  @Test func deleteRemovesTheRow() throws {
    let store = try tempStore()
    let repo = try store.addRepo(name: "o/r", remoteURL: "https://host/o/r", branch: "main")
    try store.deleteRepo(id: repo.id)
    #expect(try store.listRepos().isEmpty)
    // The remote is free to be tracked again.
    #expect(throws: Never.self) {
      _ = try store.addRepo(name: "o/r", remoteURL: "https://host/o/r", branch: "main")
    }
  }

  @Test func shortHeadIsTheFirstSevenCharacters() throws {
    let store = try tempStore()
    let repo = try store.addRepo(name: "o/r", remoteURL: "https://host/o/r", branch: "main")
    try store.updateRepoSync(
      id: repo.id, headCommit: "0123456789abcdef0123456789abcdef01234567", fetchedAt: Date())
    #expect(try store.getRepo(id: repo.id).shortHead == "0123456")
  }

  // MARK: - Checkout location

  @Test func checkoutPathsAreKeyedByULIDNotName() throws {
    // A rename or a re-pointed remote must never orphan or collide with a
    // checkout, exactly as `DatabaseLocation` keys DBs by ULID.
    #expect(
      RepoCheckoutLocation.relativeComponents(wikiID: "01WIKI", repoID: "01REPO")
        == ["WikiFS", "repos", "01WIKI", "01REPO"])
  }

  // MARK: - wikictl repo

  @Test func parsesRepoCommands() throws {
    // The agent never passes `--wiki`; the wiki comes from $WIKI_DB, which the
    // app puts in the child's environment.
    let env: (String) -> String? = { $0 == "WIKI_DB" ? "ENVWIKI" : nil }
    #expect(try ArgumentParser.parse(["repo", "list"], env: env).command == .repoList(json: false))
    #expect(
      try ArgumentParser.parse(["repo", "list", "--json"], env: env).command
        == .repoList(json: true))
    #expect(
      try ArgumentParser.parse(["repo", "get", "--name", "o/r"], env: env).command
        == .repoGet(name: "o/r"))
    #expect(
      try ArgumentParser.parse(
        ["repo", "mark-ingested", "--name", "o/r", "--commit", "abc"], env: env
      ).command == .repoMarkIngested(name: "o/r", commit: "abc"))
  }

  @Test func rejectsMalformedRepoCommands() {
    #expect(throws: ArgumentParser.Failure.self) {
      _ = try ArgumentParser.parse(["repo"], env: { _ in "W" })
    }
    #expect(throws: ArgumentParser.Failure.self) {
      _ = try ArgumentParser.parse(["repo", "add", "--name", "o/r"], env: { _ in "W" })
    }
    #expect(throws: ArgumentParser.Failure.self) {
      _ = try ArgumentParser.parse(["repo", "get"], env: { _ in "W" })
    }
    #expect(throws: ArgumentParser.Failure.self) {
      _ = try ArgumentParser.parse(["repo", "mark-ingested", "--name", "o/r"], env: { _ in "W" })
    }
  }

  @Test func repoLogKindIsAccepted() throws {
    // The repo pass logs under its own kind so `log.md` can be grepped for the
    // one operation that runs unattended.
    let invocation = try ArgumentParser.parse(
      ["log", "append", "--kind", "repo", "--title", "Synced"], env: { _ in "W" })
    #expect(invocation.command == .logAppend(kind: .repo, title: "Synced", note: nil))
    #expect(LogEntry.Kind.optionList == "ingest|query|lint|repo")
  }

  @Test func repoListPrintsTSVAndJSON() throws {
    let store = try tempStore()
    let repo = try store.addRepo(name: "o/r", remoteURL: "https://host/o/r", branch: "main")
    try store.updateRepoSync(id: repo.id, headCommit: "bbb", fetchedAt: Date())

    let tsv = try RepoCommand.run(.list(json: false), in: store)
    #expect(tsv.output == "o/r\tmain\tbbb\t-")  // "-" keeps the columns aligned
    #expect(!tsv.didCommit)

    let json = try RepoCommand.run(.list(json: true), in: store)
    #expect(json.output.contains("\"name\":\"o\\/r\"") || json.output.contains("\"name\":\"o/r\""))
    #expect(json.output.contains("\"branch\":\"main\""))
  }

  @Test func repoGetPrintsTheTrackingState() throws {
    let store = try tempStore()
    let repo = try store.addRepo(name: "o/r", remoteURL: "https://host/o/r", branch: "main")
    try store.updateRepoSync(id: repo.id, headCommit: "bbb", fetchedAt: Date())

    let result = try RepoCommand.run(.get(name: "o/r"), in: store)
    #expect(result.output.contains("name\to/r"))
    #expect(result.output.contains("head\tbbb"))
    #expect(result.output.contains("last_ingested\t-"))
    #expect(result.output.contains("auto_ingest\ton"))
    #expect(!result.didCommit)
  }

  @Test func markIngestedMovesTheWatermarkAndCommits() throws {
    let store = try tempStore()
    let repo = try store.addRepo(name: "o/r", remoteURL: "https://host/o/r", branch: "main")

    let result = try RepoCommand.run(.markIngested(name: "o/r", commit: "ccc"), in: store)
    // didCommit is what makes `wikictl` post the Darwin notification, which is
    // how the app's sidebar learns the watermark moved.
    #expect(result.didCommit)
    #expect(try store.getRepo(id: repo.id).lastIngestedCommit == "ccc")
  }

  @Test func repoCommandsFailClearlyOnAnUnknownName() throws {
    let store = try tempStore()
    #expect(throws: PageCommand.Failure.self) {
      _ = try RepoCommand.run(.get(name: "nope/nope"), in: store)
    }
    #expect(throws: PageCommand.Failure.self) {
      _ = try RepoCommand.run(.markIngested(name: "nope/nope", commit: "abc"), in: store)
    }
  }
}
