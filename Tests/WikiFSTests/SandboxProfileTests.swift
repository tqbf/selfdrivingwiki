import Foundation
import Testing
@testable import WikiFSCore

/// Tests for the pure seatbelt profile generator — the exact `(version 1)` /
/// `(allow default)` / `(deny file-write*)` skeleton, the SCRATCH_DIR subpath allow,
/// and the four WIKI_DB literal allows (base + wal/shm/journal). Pure; no shell, no IO.
struct SandboxProfileTests {

  static let scratchDir = "/Users/me/Library/Caches/Self Driving Wiki-agent/UUID"
  static let wikiDB = "/Users/me/Library/Group Containers/group.x/01WIKI.sqlite"

  private func profile() -> String {
    SandboxProfile.generate(
      scratchDir: Self.scratchDir,
      wikiDBPath: Self.wikiDB)
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

  // MARK: - Agent runtime writes (shell devices + Claude cwd markers)

  /// zsh redirects to /dev/null on startup; without a write allow the shell prints
  /// `operation not permitted: /dev/null` on every command. Scoped to `file-write-data`
  /// (no chmod/unlink) on only the devices a piped shell actually touches — `/dev/tty`
  /// and `/dev/dtracehelper` are deliberately excluded as unneeded.
  @Test func bothProfilesAllowMinimalDeviceDataWrites() {
    for p in [profile(), readOnlyProfile()] {
      #expect(p.contains("(allow file-write-data (literal \"/dev/null\"))"))
      #expect(p.contains("(allow file-write-data (subpath \"/dev/fd\"))"))
      // Deliberately NOT allowed (least privilege).
      #expect(!p.contains("/dev/tty"))
      #expect(!p.contains("/dev/dtracehelper"))
    }
  }

  /// Claude Code's Bash tool creates per-shell cwd markers as `/private/tmp/claude-<hex>-cwd`,
  /// siblings of (not under) the per-session CLAUDE_TMP base. Scoped to exactly that marker
  /// shape — NOT a broad `/private/tmp/claude-*` prefix — so the agent can't write across
  /// other uids'/sessions' temp dirs in shared /private/tmp.
  @Test func bothProfilesAllowOnlyClaudeCwdMarkerShape() {
    for p in [profile(), readOnlyProfile()] {
      #expect(p.contains("(allow file-write* (regex #\"^/private/tmp/claude-[A-Za-z0-9]+-cwd(/|$)\"))"))
      // Not the broad prefix that would open the whole claude-* namespace.
      #expect(!p.contains("(allow file-write* (regex #\"^/private/tmp/claude-\"))"))
    }
  }

  @Test func defaultClaudeTempBaseIsPrivateTmpClaudeUid() {
    #expect(SandboxProfile.defaultClaudeTempBase() == "/private/tmp/claude-\(getuid())")
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
    #expect(inv.profile == profile())
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
}
