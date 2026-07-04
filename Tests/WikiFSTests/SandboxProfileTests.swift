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

  // MARK: - pdf2md exec/read deny (issue #116 item 1)

  /// Both profiles deny exec AND read of the resolved pdf2md script when a path is
  /// supplied — closes both the direct `pdf2md` exec and the `uv run --script` angle
  /// (uv must `open()` the script to parse its PEP 723 deps).
  @Test func bothProfilesDenyExecAndReadOfResolvedPdf2md() {
    let script = "/Applications/Self Driving Wiki.app/Contents/Helpers/pdf2md"
    let rw = SandboxProfile.generate(
      scratchDir: Self.scratchDir, wikiDBPath: Self.wikiDB, pdf2mdScriptPath: script)
    let ro = SandboxProfile.generateReadOnly(
      scratchDir: Self.scratchDir, pdf2mdScriptPath: script)
    for p in [rw, ro] {
      #expect(p.contains("(deny process-exec* (literal (param \"PDF2MD_SCRIPT\")))"))
      #expect(p.contains("(deny file-read* (literal (param \"PDF2MD_SCRIPT\")))"))
    }
  }

  /// Regression guard: the deny MUST be `literal` on the script file, NOT `subpath`
  /// on its directory. `wikictl` and `pdf2md` are collocated in `Contents/Helpers/`
  /// (and in `build/`, and beside the swift-run exe) — a `subpath` deny would block
  /// `wikictl`, the agent's only sanctioned exec. See `SandboxProfile.pdf2mdDenyRules`.
  @Test func pdf2mdDenyUsesLiteralNotSubpath() {
    let script = "/Applications/Self Driving Wiki.app/Contents/Helpers/pdf2md"
    let p = SandboxProfile.generate(
      scratchDir: Self.scratchDir, wikiDBPath: Self.wikiDB, pdf2mdScriptPath: script)
    #expect(!p.contains("(deny process-exec* (subpath"))
    #expect(!p.contains("(deny file-read* (subpath"))
    // No directory-shaped param either — the collocation trap would name a dir.
    #expect(!p.contains("PDF2MD_DIR"))
  }

  /// Default-nil emission: when no pdf2md path is supplied, neither the deny rules
  /// nor the `PDF2MD_SCRIPT` param reference appear — the profile is byte-identical
  /// to the pre-denial build, so call sites and argv-index tests that don't care about
  /// pdf2md are unaffected (the load-bearing non-breaking guard).
  @Test func defaultNilEmitsNoPdf2mdDeny() {
    let gen = SandboxProfile.generate(scratchDir: Self.scratchDir, wikiDBPath: Self.wikiDB)
    let ro = SandboxProfile.generateReadOnly(scratchDir: Self.scratchDir)
    for p in [gen, ro] {
      #expect(!p.contains("PDF2MD_SCRIPT"))
    }
  }

  @Test func emptyPdf2mdPathEmitsNoDeny() {
    let p = SandboxProfile.generate(
      scratchDir: Self.scratchDir, wikiDBPath: Self.wikiDB, pdf2mdScriptPath: "")
    #expect(!p.contains("PDF2MD_SCRIPT"))
  }

  @Test func invocationCarriesPdf2mdDefineWhenSupplied() {
    let inv = SandboxProfile.invocation(
      homePath: "/Users/me",
      scratchDir: Self.scratchDir,
      wikiDBPath: Self.wikiDB,
      claudeTempBase: "/private/tmp/claude-999",
      pdf2mdScriptPath: "/Users/me/app/Contents/Helpers/pdf2md")
    #expect(inv.defines.count == 5)
    // Order matters for the argv emit — PDF2MD_SCRIPT is appended last.
    #expect(inv.defines[4].0 == "PDF2MD_SCRIPT")
    #expect(inv.defines[4].1 == "/Users/me/app/Contents/Helpers/pdf2md")
    // The define alone is useless without the deny rules in the profile text.
    #expect(inv.profile.contains("(deny process-exec* (literal (param \"PDF2MD_SCRIPT\")))"))
    #expect(inv.profile.contains("(deny file-read* (literal (param \"PDF2MD_SCRIPT\")))"))
  }

  @Test func readOnlyInvocationCarriesPdf2mdDefineWhenSupplied() {
    let inv = SandboxProfile.readOnlyInvocation(
      homePath: "/Users/me",
      scratchDir: Self.scratchDir,
      claudeTempBase: "/private/tmp/claude-999",
      pdf2mdScriptPath: "/Users/me/app/Contents/Helpers/pdf2md")
    #expect(inv.defines.count == 4)  // HOME, SCRATCH_DIR, CLAUDE_TMP, PDF2MD_SCRIPT
    #expect(inv.defines[3].0 == "PDF2MD_SCRIPT")
    #expect(inv.profile.contains("(deny process-exec* (literal (param \"PDF2MD_SCRIPT\")))"))
  }

  /// `/tmp` is a symlink to `/private/tmp`. A pdf2md script resolved under `/tmp`
  /// must surface in the define as its canonical `/private/tmp/...` path, or the
  /// seatbelt `literal` deny would silently fail to match the agent's exec attempt
  /// (the kernel resolves the path it execs). Mirrors the SCRATCH_DIR symlink test.
  @Test func invocationResolvesSymlinkedPdf2mdToCanonicalPath() throws {
    let symlinkScript = "/tmp/sdw-pdf2md-probe-\(UUID().uuidString)"
    // Create a real file so realpath resolves it (realpath returns nil for
    // non-existent paths, falling back to the input — which would hide the
    // /tmp → /private/tmp resolution).
    try "#!/bin/sh\n".write(toFile: symlinkScript, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: symlinkScript) }

    let inv = SandboxProfile.invocation(
      homePath: "/Users/me",
      scratchDir: "/Users/me/scratch",
      wikiDBPath: "/Users/me/db.sqlite",
      pdf2mdScriptPath: symlinkScript)

    let resolved = try #require(inv.defines.first { $0.0 == "PDF2MD_SCRIPT" }?.1)
    #expect(resolved.hasPrefix("/private/tmp/"))
    #expect(resolved.contains("sdw-pdf2md-probe-"))
  }

  // MARK: - ~/.claude write-narrowing (issue #116 item 4)

  /// The execution-vector / credential paths under ~/.claude are denied EVEN THOUGH the
  /// subtree is broadly allowed — a compromised agent can't plant hooks/commands/agents/
  /// skills/plugins or swap credentials/settings/CLAUDE.md for a future unsandboxed session.
  @Test func bothProfilesDenyClaudeHomeExecutionAndCredentialPaths() {
    let rw = SandboxProfile.generate(scratchDir: Self.scratchDir, wikiDBPath: Self.wikiDB)
    let ro = SandboxProfile.generateReadOnly(scratchDir: Self.scratchDir)
    for p in [rw, ro] {
      // Subtree denies (execution vectors).
      for d in ["hooks", "commands", "agents", "skills", "plugins"] {
        #expect(p.contains("(deny file-write* (subpath (string-append (param \"HOME\") \"/.claude/\(d)\")))"))
      }
      // Literal denies (credentials + settings + user-level memory).
      for f in [".credentials.json", "settings.json", "settings.local.json", "CLAUDE.md"] {
        #expect(p.contains("(deny file-write* (literal (string-append (param \"HOME\") \"/.claude/\(f)\")))"))
      }
    }
  }

  /// Regression guard: the broad ~/.claude subtree allow stays (the transcript under
  /// projects/ and other benign runtime writes still need it); only the dangerous
  /// subpaths are carved out. Narrowing the ALLOW itself would break the transcript.
  @Test func bothProfilesStillBroadlyAllowClaudeHomeSubtree() {
    let rw = SandboxProfile.generate(scratchDir: Self.scratchDir, wikiDBPath: Self.wikiDB)
    let ro = SandboxProfile.generateReadOnly(scratchDir: Self.scratchDir)
    for p in [rw, ro] {
      #expect(p.contains("(allow file-write* (subpath (string-append (param \"HOME\") \"/.claude\")))"))
      // The transcript dir is NOT separately denied — it rides the broad allow.
      #expect(!p.contains("\"/.claude/projects"))
    }
  }

  /// Regression guard: dirs use `subpath` (whole subtree), files use `literal` (exact).
  /// Swapping them would either over-deny (a literal on a dir misses new files) or
  /// under-deny (a subpath on a file is equivalent but inconsistent).
  @Test func claudeHomeDenyUsesSubpathForDirsLiteralForFiles() {
    let p = SandboxProfile.generate(scratchDir: Self.scratchDir, wikiDBPath: Self.wikiDB)
    // settings.json is a FILE → literal, not subpath.
    #expect(p.contains("(deny file-write* (literal (string-append (param \"HOME\") \"/.claude/settings.json\")))"))
    #expect(!p.contains("(deny file-write* (subpath (string-append (param \"HOME\") \"/.claude/settings.json\")))"))
    // hooks is a DIR → subpath, not literal.
    #expect(p.contains("(deny file-write* (subpath (string-append (param \"HOME\") \"/.claude/hooks\")))"))
    #expect(!p.contains("(deny file-write* (literal (string-append (param \"HOME\") \"/.claude/hooks\")))"))
  }
}
