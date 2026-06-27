import Foundation
import Testing
@testable import WikiFSCore

/// Tests for the pure seatbelt profile generator — the exact `(version 1)` /
/// `(allow default)` / `(deny file-write*)` skeleton, the SCRATCH_DIR subpath allow,
/// the four WIKI_DB literal allows (base + wal/shm/journal), and extra-path splicing
/// with tilde expansion + relative junk dropping. Pure; no shell, no IO.
struct SandboxProfileTests {

  static let scratchDir = "/Users/me/Library/Caches/Self Driving Wiki-agent/UUID"
  static let wikiDB = "/Users/me/Library/Group Containers/group.x/01WIKI.sqlite"

  private func profile(_ extra: [String] = []) -> String {
    SandboxProfile.generate(
      scratchDir: Self.scratchDir,
      wikiDBPath: Self.wikiDB,
      extraAllowedPaths: extra)
  }

  // MARK: - Skeleton

  @Test func startsWithVersionAndAllowDefault() {
    let p = profile()
    let lines = p.split(separator: "\n").map(String.init)
    #expect(lines[0] == "(version 1)")
    #expect(lines[1] == "(allow default)")
    #expect(lines[2] == "(deny file-write*)")
  }

  @Test func deniesAllWritesThenReallowsScratchAndDB() {
    let p = profile()
    #expect(p.contains("(deny file-write*)"))
    #expect(p.contains("(allow file-write* (subpath (param \"SCRATCH_DIR\")))"))
    #expect(p.contains("(allow file-write* (literal (param \"WIKI_DB\")))"))
  }

  // MARK: - SQLite sidecars

  @Test func allowsDBPlusWalShmJournalSidecars() {
    let p = profile()
    #expect(p.contains("(allow file-write* (literal (string-append (param \"WIKI_DB\") \"-wal\")))"))
    #expect(p.contains("(allow file-write* (literal (string-append (param \"WIKI_DB\") \"-shm\")))"))
    #expect(p.contains("(allow file-write* (literal (string-append (param \"WIKI_DB\") \"-journal\")))"))
  }

  @Test func sidecarSuffixesAreExactlyWalShmJournal() {
    #expect(SandboxProfile.sqliteSidecarSuffixes == ["-wal", "-shm", "-journal"])
  }

  // MARK: - Claude config writes (generate)

  @Test func generate_allowsClaudeSubpathWrite() {
    let p = profile()
    #expect(p.contains("(allow file-write* (subpath (string-append (param \"HOME\") \"/.claude\")))"))
  }

  @Test func generate_allowsClaudeJsonLiteralWrite() {
    #expect(profile().contains("(allow file-write* (literal (string-append (param \"HOME\") \"/.claude.json\")))"))
  }

  // MARK: - Claude per-session temp dir (the EPERM-on-Bash regression)

  /// Claude Code mkdir's its session temp dir under /private/tmp/claude-<uid>/ before
  /// running any shell command; without this allow rule the sandboxed agent's Bash tool
  /// dies with EPERM on the first invocation.
  @Test func generate_allowsClaudeTempSubpathWrite() {
    #expect(profile().contains("(allow file-write* (subpath (param \"CLAUDE_TMP\")))"))
  }

  @Test func readOnly_allowsClaudeTempSubpathWrite() {
    #expect(readOnlyProfile().contains("(allow file-write* (subpath (param \"CLAUDE_TMP\")))"))
  }

  @Test func defaultClaudeTempBaseIsPrivateTmpClaudeUid() {
    #expect(SandboxProfile.defaultClaudeTempBase() == "/private/tmp/claude-\(getuid())")
  }

  // MARK: - Extra allowed paths

  @Test func splicesInValidAbsolutePathAsLiteral() {
    // A non-existent path (not a directory) → `literal`.
    let p = profile(["/Users/me/some-file.txt"])
    #expect(p.contains("(allow file-write* (literal \"/Users/me/some-file.txt\"))"))
  }

  @Test func splicesInExistingDirectoryAsSubpath() {
    // `/tmp` exists and is a directory → `subpath`.
    let p = profile(["/tmp"])
    #expect(p.contains("(allow file-write* (subpath \"/tmp\"))"))
  }

  @Test func dropsRelativeAndNonAbsoluteExtraPaths() {
    let p = profile(["relative/path", "just-a-name"])
    #expect(!p.contains("relative/path"))
    #expect(!p.contains("just-a-name"))
  }

  @Test func escapesQuotesAndBackslashesInExtraPaths() {
    let p = profile(["/path/with\"quote"])
    #expect(p.contains("\\\"quote"))
  }

  // MARK: - generateReadOnly

  private func readOnlyProfile() -> String {
    SandboxProfile.generateReadOnly(scratchDir: Self.scratchDir)
  }

  @Test func readOnly_startsWithVersionAndAllowDefault() {
    let p = readOnlyProfile()
    let lines = p.split(separator: "\n").map(String.init)
    #expect(lines[0] == "(version 1)")
    #expect(lines[1] == "(allow default)")
    #expect(lines[2] == "(deny file-write*)")
  }

  /// Regression guard: adding new allowances must not drop the default-deny fence.
  @Test func readOnly_stillDeniesFileWriteStar() {
    #expect(readOnlyProfile().contains("(deny file-write*)"))
  }

  @Test func readOnly_allowsClaudeSubpathWrite() {
    #expect(readOnlyProfile().contains("(allow file-write* (subpath (string-append (param \"HOME\") \"/.claude\")))"))
  }

  @Test func readOnly_allowsClaudeJsonLiteralWrite() {
    #expect(readOnlyProfile().contains("(allow file-write* (literal (string-append (param \"HOME\") \"/.claude.json\")))"))
  }

  // MARK: - SandboxInvocation (Equatable + defines)

  @Test func invocationCarriesHomeScratchAndWikiDBDefines() {
    let inv = SandboxProfile.invocation(
      homePath: "/Users/me",
      scratchDir: Self.scratchDir,
      wikiDBPath: Self.wikiDB,
      claudeTempBase: "/private/tmp/claude-999")
    #expect(inv.defines.count == 4)
    // Order matters for the argv emit.
    #expect(inv.defines[0].0 == "HOME")
    #expect(inv.defines[0].1 == "/Users/me")
    #expect(inv.defines[1].0 == "SCRATCH_DIR")
    #expect(inv.defines[1].1 == Self.scratchDir)
    #expect(inv.defines[2].0 == "WIKI_DB")
    #expect(inv.defines[2].1 == Self.wikiDB)
    // CLAUDE_TMP canonicalizes via realpath; the non-existent probe path falls back to
    // the input (same behaviour the other defines rely on for non-existent paths).
    #expect(inv.defines[3].0 == "CLAUDE_TMP")
    #expect(inv.defines[3].1 == "/private/tmp/claude-999")
    #expect(inv.profile == profile([]))
  }

  @Test func readOnlyInvocationCarriesHomeScratchAndClaudeTempDefines() {
    let inv = SandboxProfile.readOnlyInvocation(
      homePath: "/Users/me",
      scratchDir: Self.scratchDir,
      claudeTempBase: "/private/tmp/claude-999")
    #expect(inv.defines.count == 3)
    // Order matters for the argv emit.
    #expect(inv.defines[0].0 == "HOME")
    #expect(inv.defines[0].1 == "/Users/me")
    #expect(inv.defines[1].0 == "SCRATCH_DIR")
    // readOnlyInvocation canonicalizes via realpath; non-existent paths fall back to
    // the input (same behaviour the invocation test relies on for Self.scratchDir).
    #expect(inv.defines[1].1 == Self.scratchDir)
    #expect(inv.defines[2].0 == "CLAUDE_TMP")
    #expect(inv.defines[2].1 == "/private/tmp/claude-999")
  }

  @Test func invocationEquatableComparesProfileAndDefines() {
    let a = SandboxProfile.invocation(
      homePath: "/h", scratchDir: "/s", wikiDBPath: "/d")
    let b = SandboxProfile.invocation(
      homePath: "/h", scratchDir: "/s", wikiDBPath: "/d")
    let c = SandboxProfile.invocation(
      homePath: "/h2", scratchDir: "/s", wikiDBPath: "/d")
    #expect(a == b)
    #expect(a != c)
  }

  // MARK: - Symlink resolution (the seatbelt matches the canonical path)

  @Test func invocationResolvesSymlinkedScratchToCanonicalPath() throws {
    // `/tmp` is a symlink to `/private/tmp` on macOS. A scratch dir created under
    // `/tmp` must surface in the invocation as its canonical `/private/tmp/...` path,
    // or the seatbelt `subpath` allow silently fails. Create a real dir to make the
    // resolution observable (resolvingSymlinksInPath only resolves existing paths).
    let symlinkScratch = "/tmp/sdw-symlink-probe-\(UUID().uuidString)"
    try FileManager.default.createDirectory(
      atPath: symlinkScratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: symlinkScratch) }

    let inv = SandboxProfile.invocation(
      homePath: "/Users/me",
      scratchDir: symlinkScratch,
      wikiDBPath: "/Users/me/db.sqlite")

    let resolved = try #require(inv.defines.first { $0.0 == "SCRATCH_DIR" }?.1)
    #expect(resolved.hasPrefix("/private/tmp/"))
    #expect(resolved.contains("sdw-symlink-probe-"))
    // The profile references SCRATCH_DIR by param; the resolved canonical value
    // flows in via the -D define (asserted above).
    #expect(inv.profile.contains("(subpath (param \"SCRATCH_DIR\"))"))
  }

  @Test func invocationResolvesExtraAllowedSymlinksToo() throws {
    let symlinkPath = "/tmp/sdw-extra-probe-\(UUID().uuidString)"
    try FileManager.default.createDirectory(
      atPath: symlinkPath, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: symlinkPath) }

    let inv = SandboxProfile.invocation(
      homePath: "/Users/me",
      scratchDir: "/Users/me/scratch",
      wikiDBPath: "/Users/me/db.sqlite",
      extraAllowedPaths: [symlinkPath])
    // The canonical /private/tmp path must appear as the allow, not the /tmp form.
    #expect(inv.profile.contains("/private/tmp/sdw-extra-probe-"))
    #expect(!inv.profile.contains("(subpath \"\(symlinkPath)\"))"))
  }
}
