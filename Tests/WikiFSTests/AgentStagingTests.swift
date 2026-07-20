import Foundation
import Testing
@testable import WikiFSCore

/// Tests for the PURE staging seams (`feature/ingest-fewer-turns`): the
/// shell-safe staged-leaf math, the `WIKI_STATE.md` rendering, and the worker
/// prompt's self-sufficient write rule. The actual file writes are a thin app
/// seam (`AgentStaging.stage*`); what's pure is tested here.
struct AgentStagingTests {

  // MARK: - Staged leaf names (shell-safe path math)

  @Test func stateFileNameIsFixed() {
    #expect(AgentStaging.stateFileName == "WIKI_STATE.md")
  }

  @Test func shellSafeLeafPreservesSimpleAsciiStem() {
    #expect(AgentStaging.shellSafeLeaf(name: "Neuralwatt Cloud Platform", sourceID: "01KXYMP7J6HZ3E34ZZX02HKS1F", ext: "html")
            == "Neuralwatt-Cloud-Platform--01KXYMP7J6HZ3E34ZZX02HKS1F.html")
    #expect(AgentStaging.shellSafeLeaf(name: "Trip Report", sourceID: "01ABCDEF", ext: "pdf")
            == "Trip-Report--01ABCDEF.pdf")
    #expect(AgentStaging.shellSafeLeaf(name: "Home", sourceID: "01KV6EAH", ext: "md")
            == "Home--01KV6EAH.md")
  }

  @Test func shellSafeLeafReplacesSpacesAndShellMetacharactersWithDashes() {
    // Spaces and shell metacharacters (; & $ ` ( ) | < > \ " ' ! * ? [ ] { })
    // all become '-'. Runs of '-' collapse, ends trimmed.
    #expect(AgentStaging.shellSafeLeaf(name: "Cost & Revenue (Q3)", sourceID: "01K", ext: "md")
            == "Cost-Revenue-Q3--01K.md")
    #expect(AgentStaging.shellSafeLeaf(name: "name with $vars", sourceID: "01K", ext: "pdf")
            == "name-with-vars--01K.pdf")
    // The shell metacharacters " ` | ; are all replaced with '-'.
    #expect(AgentStaging.shellSafeLeaf(name: "a\"b`c|d;e", sourceID: "01K", ext: "txt")
            == "a-b-c-d-e--01K.txt")
  }

  @Test func shellSafeLeafReplacesPathSeparatorsWithDashes() {
    // `escapeTitle` already replaces '/' and ':' with '-' (FilenameEscaping.swift).
    #expect(AgentStaging.shellSafeLeaf(name: "a/b:c", sourceID: "01K", ext: "txt")
            == "a-b-c--01K.txt")
    // Leading '.' is prefixed with '_' by escapeTitle (the '.' is kept, the
    // '_' prepended). Both '_' and '.' are in the shell-safe allowed set, so
    // the leaf `_.hidden--01K.md` matches `^[A-Za-z0-9._-]+$`.
    #expect(AgentStaging.shellSafeLeaf(name: ".hidden", sourceID: "01K", ext: "md")
            == "_.hidden--01K.md")
  }

  @Test func shellSafeLeafFallsBackToUntitledForEmptyOrAllMetacharName() {
    // `escapeTitle` returns "untitled" for an empty stem. A name consisting
    // entirely of disallowed chars collapses to empty → "untitled".
    #expect(AgentStaging.shellSafeLeaf(name: "", sourceID: "01K", ext: "md")
            == "untitled--01K.md")
    #expect(AgentStaging.shellSafeLeaf(name: "  ", sourceID: "01K", ext: "md")
            == "untitled--01K.md")
    #expect(AgentStaging.shellSafeLeaf(name: "$$$", sourceID: "01K", ext: "md")
            == "untitled--01K.md")
  }

  @Test func shellSafeLeafSanitizesExtension() throws {
    // The extension is filtered through the same allowed set so the WHOLE leaf
    // is shell-safe. Matches prior behavior: extensions are lowercased (defensive),
    // and any char outside [A-Za-z0-9._-] is dropped (per the plan's `.filter`
    // pseudocode — filtration, not replacement, keeps extensions tidy).
    // Upstream `SourceSummary.ext` is already lowercased with no leading dot,
    // but `shellSafeLeaf` stays correct even for adversarial ext input.
    #expect(AgentStaging.shellSafeLeaf(name: "Doc", sourceID: "01K", ext: "MD")
            == "Doc--01K.md")  // lowercased
    #expect(AgentStaging.shellSafeLeaf(name: "Doc", sourceID: "01K", ext: ".md")
            == "Doc--01K..md")  // '.' kept (allowed); still shell-safe
    #expect(AgentStaging.shellSafeLeaf(name: "Doc", sourceID: "01K", ext: "pdf ")
            == "Doc--01K.pdf")  // trailing space filtered out
    // A weird extension with shell metacharacters is sanitized by filtering
    // the offending char out — the result is shell-safe (regex matches).
    #expect(AgentStaging.shellSafeLeaf(name: "Doc", sourceID: "01K", ext: "md;rm")
            == "Doc--01K.mdrm")
    let shellSafePattern = try NSRegularExpression(pattern: "^[A-Za-z0-9._-]+$")
    for ext in ["MD", ".md", "pdf ", "md;rm", "md`rm", "md$rm"] {
      let leaf = AgentStaging.shellSafeLeaf(name: "Doc", sourceID: "01K", ext: ext)
      let range = NSRange(location: 0, length: leaf.utf16.count)
      #expect(shellSafePattern.firstMatch(in: leaf, range: range) != nil,
              "leaf \(leaf) for ext \(ext) is not shell-safe")
    }
  }

  @Test func shellSafeLeafOmitsExtensionWhenEmpty() {
    // No trailing dot when ext is empty (consistent with FilenameEscaping).
    #expect(AgentStaging.shellSafeLeaf(name: "Notes", sourceID: "01K", ext: "")
            == "Notes--01K")
  }

  @Test func shellSafeLeafIsCollisionFreeForSameMsSameNameSources() {
    // The full ULID disambiguates (fix #2). shortID (first 8 chars) lives in
    // the ms-timestamp prefix and would collide for same-ms ULIDs — but two
    // distinct full ULIDs always produce distinct leaves even with identical
    // names. (Repo scenario: multi-file drag-drop allocating ULIDs in a tight
    // loop — same ms, same effectiveName if the filenames match, but unique IDs.)
    let leaf1 = AgentStaging.shellSafeLeaf(name: "Same Name", sourceID: "01KXYMP7J6HZ3E34ZZX02HKS1F", ext: "md")
    let leaf2 = AgentStaging.shellSafeLeaf(name: "Same Name", sourceID: "01KXYMP7J6HZ3E34ZZX02HKS1G", ext: "md")
    #expect(leaf1 != leaf2)
    // Distinct ULIDs → distinct leaves.
    #expect(leaf1 == "Same-Name--01KXYMP7J6HZ3E34ZZX02HKS1F.md")
    #expect(leaf2 == "Same-Name--01KXYMP7J6HZ3E34ZZX02HKS1G.md")
  }

  // MARK: - Actual staging (round-trip through a temp dir)

  @Test func stagesStateFileIntoScratchAndReturnsAbsolutePath() throws {
    let scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }

    let statePath = try AgentStaging.stageStateFile("# WIKI_STATE\nhello", in: scratch)

    #expect(statePath == scratch.appendingPathComponent("WIKI_STATE.md").path)
    #expect(try String(contentsOfFile: statePath, encoding: .utf8) == "# WIKI_STATE\nhello")
  }

  @Test func stagesMultipleSourcesWithDescriptiveShellSafeLeaves() throws {
    let scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }

    let sources: [(bytes: Data, ext: String, name: String, sourceID: String)] = [
      (Data("first".utf8),  "md",   "Neuralwatt Cloud Platform", "01KXYMP7J6HZ3E34ZZX02HKS1F"),
      (Data("second".utf8), "pdf",  "MCR Protocol",               "01KXYMKF1EF820Y5KZ6FTBAQRS"),
    ]
    let paths = try AgentStaging.stageSources(sources, in: scratch)

    #expect(paths.count == 2)
    // AC.1: leaves are descriptive + shell-safe + carry the full ULID.
    let leaf0 = (paths[0] as NSString).lastPathComponent
    let leaf1 = (paths[1] as NSString).lastPathComponent
    #expect(leaf0 == "Neuralwatt-Cloud-Platform--01KXYMP7J6HZ3E34ZZX02HKS1F.md")
    #expect(leaf1 == "MCR-Protocol--01KXYMKF1EF820Y5KZ6FTBAQRS.pdf")
    // The absolute paths are returned.
    #expect(paths[0] == scratch.appendingPathComponent(leaf0).path)
    #expect(paths[1] == scratch.appendingPathComponent(leaf1).path)
    // The bytes round-trip (atomic write survived).
    #expect(try Data(contentsOf: URL(fileURLWithPath: paths[0])) == Data("first".utf8))
    #expect(try Data(contentsOf: URL(fileURLWithPath: paths[1])) == Data("second".utf8))
  }

  @Test func stagesEmptySourcesListReturnsEmpty() throws {
    let scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }

    let paths = try AgentStaging.stageSources([], in: scratch)
    #expect(paths.isEmpty)
  }

  /// AC.3: every staged source leaf matches `^[A-Za-z0-9._-]+$` (shell-safe)
  /// regardless of `effectiveName` content, and the full ULID disambiguator
  /// survives intact (AC.2). Feeds adversarial `effectiveName`s that would
  /// break the executor's BARE `{{PRIMARY_SOURCE_FILE}}` if the escaper were
  /// ever bypassed.
  @Test func stagedSourceLeavesAreShellSafe() throws {
    let scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }

    // Adversarial effectiveNames: spaces, shell metacharacters, path separators.
    let ulid = "01KXYMP7J6HZ3E34ZZX02HKS1F"
    let cases: [(name: String, ext: String)] = [
      ("Cost & Revenue (Q3)", "md"),
      ("a/b:c", "txt"),
      ("name with $vars", "pdf"),
      ("Neuralwatt Cloud Platform", "html"),
      ("", "md"),                         // empty → untitled stem
      ("a\"b`c|d;e$f(g)h!i", "md"),
    ]
    let sources = cases.map { (Data("x".utf8), $0.ext, $0.name, ulid) }
    let paths = try AgentStaging.stageSources(sources, in: scratch)

    let shellSafePattern = try NSRegularExpression(pattern: "^[A-Za-z0-9._-]+$")
    let leaves = paths.map { ($0 as NSString).lastPathComponent }
    for (i, leaf) in leaves.enumerated() {
      let range = NSRange(location: 0, length: leaf.utf16.count)
      #expect(shellSafePattern.firstMatch(in: leaf, range: range) != nil,
              "leaf \(leaf) (from \(cases[i].name)) is not shell-safe")
      // The full ULID disambiguator survives intact (AC.2 / fix #2).
      #expect(leaf.contains(ulid))
    }
  }

  // MARK: - WIKI_STATE.md rendering

  @Test func stateFileRendersTitlesIndexAndLog() {
    let snapshot = WikiStateSnapshot.make(
      allTitles: ["Calvin Cycle", "Photosynthesis"],
      indexBody: "# Index\n- [[Calvin Cycle]]",
      logLines: ["## [2026-06-16] ingest | notes.txt"])
    let md = snapshot.renderStateFile()

    #expect(md.contains("# WIKI_STATE"))
    #expect(md.contains("- Calvin Cycle"))
    #expect(md.contains("- Photosynthesis"))
    #expect(md.contains("# Index"))
    #expect(md.contains("## [2026-06-16] ingest | notes.txt"))
    // It tells the agent not to re-fetch the state.
    #expect(md.lowercased().contains("do not need to run `wikictl page list`"))
  }

  @Test func stateFileHandlesFreshAndEmptyWiki() {
    let snapshot = WikiStateSnapshot.make(allTitles: [], indexBody: "", logLines: [])
    let md = snapshot.renderStateFile()
    #expect(md.contains("fresh wiki"))
    #expect(md.contains("Empty."))
  }

  @Test func stateFileNotesTruncatedPageCount() {
    let many = (1...200).map { "Page \($0)" }
    let snapshot = WikiStateSnapshot.make(allTitles: many, indexBody: "", logLines: [])
    let md = snapshot.renderStateFile()
    // Capped at maxListedTitles with a note about the remainder.
    #expect(snapshot.pageTitles.count == WikiStateSnapshot.maxListedTitles)
    #expect(md.contains("and \(200 - WikiStateSnapshot.maxListedTitles) more"))
  }
}
