import Foundation
import Testing
@testable import WikiFSCore

/// Tests for the pure seatbelt profile generator — the exact `(version 1)` /
/// `(allow default)` / `(deny file-write*)` skeleton and the SCRATCH_DIR
/// subpath allow. Pure; no shell, no IO. Phase 3 of
/// plans/agent-sandbox-scoping.md (§8): the profiles carry NO database
/// grants — those tests now pin the grants' ABSENCE.
struct SandboxProfileTests {

  static let scratchDir = "/Users/me/Library/Caches/Self Driving Wiki-agent/UUID"
  static let wikiDB = "/Users/me/Library/Group Containers/group.x/01WIKI.sqlite"
  static let queueDB = "/Users/me/Library/Group Containers/group.x/queue.sqlite"

  private func profile() -> String {
    SandboxProfile.generate(
      scratchDir: Self.scratchDir)
  }

  // MARK: - Skeleton

  @Test func startsWithVersionAndAllowDefault() {
    let p = profile()
    let lines = p.split(separator: "\n").map(String.init)
    #expect(lines[0] == "(version 1)")
    #expect(lines[1] == "(allow default)")
    #expect(lines[2] == "(deny file-write*)")
  }

  @Test func deniesAllWritesThenReallowsScratchOnly() {
    let p = profile()
    #expect(p.contains("(deny file-write*)"))
    #expect(p.contains("(allow file-write* (subpath (param \"SCRATCH_DIR\")))"))
  }

  @Test func searchDoesNotGrantIndexWriteAccess() {
    let invocation = SandboxProfile.invocation(
      homePath: "/Users/me", scratchDir: Self.scratchDir)
    #expect(!invocation.defines.contains { $0.0.contains("SEARCH_INDEX") })
    #expect(!invocation.profile.contains("SEARCH_INDEX"))
    #expect(!readOnlyProfile().contains("SEARCH_INDEX"))
  }

  // MARK: - No database grants (Phase 3, plans/agent-sandbox-scoping.md §8)

  @Test func noDatabaseGrantsRemainAnywhere() {
    let p = profile()
    #expect(p.contains("WIKI_DB") == false, "the wiki DB grant is gone")
    #expect(p.contains("QUEUE_DB") == false, "the queue DB grant is gone")
    let invocation = SandboxProfile.invocation(
      homePath: "/Users/me", scratchDir: Self.scratchDir)
    #expect(invocation.defines.contains { $0.0 == "WIKI_DB" } == false)
    #expect(invocation.defines.contains { $0.0 == "QUEUE_DB" } == false)
    #expect(invocation.profile.contains("WIKI_DB") == false)
    #expect(invocation.profile.contains("QUEUE_DB") == false)
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

  @Test func invocationCarriesHomeScratchAndClaudeTempDefines() {
    let inv = SandboxProfile.invocation(
      homePath: "/Users/me",
      scratchDir: Self.scratchDir,
      claudeTempBase: "/private/tmp/claude-999")
    #expect(inv.defines.count == 3)
    // Order matters for the argv emit.
    #expect(inv.defines[0].0 == "HOME")
    #expect(inv.defines[0].1 == "/Users/me")
    #expect(inv.defines[1].0 == "SCRATCH_DIR")
    #expect(inv.defines[1].1 == Self.scratchDir)
    // CLAUDE_TMP canonicalizes via realpath; the non-existent probe path falls back to
    // the input (same behaviour the other defines rely on for non-existent paths).
    #expect(inv.defines[2].0 == "CLAUDE_TMP")
    #expect(inv.defines[2].1 == "/private/tmp/claude-999")
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
      homePath: "/h", scratchDir: "/s")
    let b = SandboxProfile.invocation(
      homePath: "/h", scratchDir: "/s")
    let c = SandboxProfile.invocation(
      homePath: "/h2", scratchDir: "/s")
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
      scratchDir: symlinkScratch)

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
      scratchDir: Self.scratchDir, pdf2mdScriptPath: script)
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
      scratchDir: Self.scratchDir, pdf2mdScriptPath: script)
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
    let gen = SandboxProfile.generate(scratchDir: Self.scratchDir)
    let ro = SandboxProfile.generateReadOnly(scratchDir: Self.scratchDir)
    for p in [gen, ro] {
      #expect(!p.contains("PDF2MD_SCRIPT"))
    }
  }

  @Test func emptyPdf2mdPathEmitsNoDeny() {
    let p = SandboxProfile.generate(
      scratchDir: Self.scratchDir, pdf2mdScriptPath: "")
    #expect(!p.contains("PDF2MD_SCRIPT"))
  }

  @Test func invocationCarriesPdf2mdDefineWhenSupplied() {
    let inv = SandboxProfile.invocation(
      homePath: "/Users/me",
      scratchDir: Self.scratchDir,
      claudeTempBase: "/private/tmp/claude-999",
      pdf2mdScriptPath: "/Users/me/app/Contents/Helpers/pdf2md")
    #expect(inv.defines.count == 4)
    // Order matters for the argv emit — PDF2MD_SCRIPT is appended last.
    #expect(inv.defines[3].0 == "PDF2MD_SCRIPT")
    #expect(inv.defines[3].1 == "/Users/me/app/Contents/Helpers/pdf2md")
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
    let rw = SandboxProfile.generate(scratchDir: Self.scratchDir)
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
    let rw = SandboxProfile.generate(scratchDir: Self.scratchDir)
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
    let p = SandboxProfile.generate(scratchDir: Self.scratchDir)
    // settings.json is a FILE → literal, not subpath.
    #expect(p.contains("(deny file-write* (literal (string-append (param \"HOME\") \"/.claude/settings.json\")))"))
    #expect(!p.contains("(deny file-write* (subpath (string-append (param \"HOME\") \"/.claude/settings.json\")))"))
    // hooks is a DIR → subpath, not literal.
    #expect(p.contains("(deny file-write* (subpath (string-append (param \"HOME\") \"/.claude/hooks\")))"))
    #expect(!p.contains("(deny file-write* (literal (string-append (param \"HOME\") \"/.claude/hooks\")))"))
  }

  // MARK: - Provider config-home extras (issue #1251)

  /// Empty extras return the base invocation unchanged — providers whose
  /// config home the base profile already allows (claude) must compile to a
  /// byte-identical profile.
  @Test func addingHomeSubpathsEmptyIsIdentity() {
    let base = SandboxProfile.invocation(
      homePath: "/Users/me", scratchDir: Self.scratchDir)
    let same = SandboxProfile.invocation(base, addingHomeSubpaths: [])
    #expect(same == base)
  }

  /// Each extra subpath appends one `allow file-write*` rule that reuses the
  /// existing HOME define; defines are unchanged (HOME is already present).
  @Test func addingHomeSubpathsAppendsAllowRulesWithoutNewDefines() throws {
    let base = SandboxProfile.invocation(
      homePath: "/Users/me", scratchDir: Self.scratchDir)
    let widened = SandboxProfile.invocation(base, addingHomeSubpaths: [".codex"])
    #expect(widened.profile.contains(
      "(allow file-write* (subpath (string-append (param \"HOME\") \"/.codex\")))"))
    // Appended AFTER the base rules (last-match-wins semantics stay intact).
    #expect(widened.profile.hasSuffix(
      "(allow file-write* (subpath (string-append (param \"HOME\") \"/.codex\")))\n"))
    #expect(widened.defines.map { $0.0 } == base.defines.map { $0.0 })
    #expect(widened.defines.map { $0.1 } == base.defines.map { $0.1 })
    // Two extras append two rules in order.
    let both = SandboxProfile.invocation(base, addingHomeSubpaths: [".codex", ".gemini"])
    #expect(both.profile.contains("\"/.codex\""))
    #expect(both.profile.contains("\"/.gemini\""))
    let codexRange = try #require(both.profile.range(of: "\"/.codex\""))
    let geminiRange = try #require(both.profile.range(of: "\"/.gemini\""))
    #expect(codexRange.lowerBound < geminiRange.lowerBound)
  }

  /// The shared argv wrap: `-p <profile> -D k=v … -- <executable> <args…>`,
  /// the exact pattern the deleted `OperationCommand.applySandbox` used.
  @Test func wrappedArgumentsMatchesDeletedApplySandboxPattern() {
    let invocation = SandboxProfile.SandboxInvocation(
      profile: "(version 1)",
      defines: [("HOME", "/Users/me"), ("SCRATCH_DIR", "/tmp/scratch")])
    let wrapped = SandboxProfile.wrappedArguments(
      executablePath: "/usr/local/bin/claude",
      arguments: ["--print", "hi"],
      invocation: invocation)
    #expect(wrapped == [
      "-p", "(version 1)",
      "-D", "HOME=/Users/me",
      "-D", "SCRATCH_DIR=/tmp/scratch",
      "--", "/usr/local/bin/claude",
      "--print", "hi",
    ])
    // The front-end path is the absolute system location, never a PATH search.
    #expect(SandboxProfile.sandboxExecutablePath == "/usr/bin/sandbox-exec")
  }

  // MARK: - Strict summarizer tier (issue #1276)

  private func strictInvocation() -> SandboxProfile.SandboxInvocation {
    SandboxProfile.strictReadOnlyInvocation(
      homePath: "/Users/me",
      scratchDir: Self.scratchDir,
      claudeTempBase: "/private/tmp/claude-501")
  }

  private func plainReadOnlyInvocation() -> SandboxProfile.SandboxInvocation {
    SandboxProfile.readOnlyInvocation(
      homePath: "/Users/me",
      scratchDir: Self.scratchDir,
      claudeTempBase: "/private/tmp/claude-501")
  }

  /// P1 + P2: strict is purely ADDITIVE — the non-strict profile is its exact
  /// base (byte-identical prefix), and the non-strict invocation keeps its
  /// trailer-less shape so extraction/probe output is unchanged.
  @Test func strict_readOnlyProfileIsAnExactPrefix() {
    let strict = strictInvocation()
    let plain = plainReadOnlyInvocation()
    #expect(strict.baseProfile == plain.profile)
    #expect(plain.trailer.isEmpty)
    #expect(plain.profile == plain.baseProfile)
    #expect(strict.profile.hasPrefix(plain.profile))
    #expect(strict.profile != plain.profile)
  }

  /// P3: the trailer pins the exact deny s-expressions — a silent edit fails.
  @Test func strict_trailerPinsTheRuleText() {
    let strict = strictInvocation()
    let required = [
      // W^X on writable land (exec AND the mmap variant).
      "(deny process-exec* (subpath (param \"SCRATCH_DIR\")))",
      "(deny file-map-executable (subpath (param \"SCRATCH_DIR\")))",
      "(deny process-exec* (subpath (param \"CLAUDE_TMP\")))",
      "(deny process-exec* (subpath \"/private/tmp\"))",
      "(deny file-map-executable (subpath \"/private/tmp\"))",
      "(deny process-exec* (subpath \"/private/var/tmp\"))",
      // macOS pivots/escapes.
      "(deny process-exec* (literal \"/usr/bin/open\"))",
      "(deny process-exec* (literal \"/bin/launchctl\"))",
      "(deny process-exec* (literal \"/usr/bin/osascript\"))",
      "(deny process-exec* (literal \"/usr/bin/security\"))",
      "(deny process-exec* (literal \"/usr/bin/crontab\"))",
      "(deny process-exec* (literal \"/usr/bin/sudo\"))",
      // Credential stores (subpath + literal forms).
      "(deny file-read* (subpath (string-append (param \"HOME\") \"/.ssh\")))",
      "(deny file-read* (subpath (string-append (param \"HOME\") \"/.aws\")))",
      "(deny file-read* (subpath (string-append (param \"HOME\") \"/.gnupg\")))",
      "(deny file-read* (subpath (string-append (param \"HOME\") \"/.config/gcloud\")))",
      "(deny file-read* (literal (string-append (param \"HOME\") \"/.netrc\")))",
      "(deny file-read* (subpath \"/Library/Keychains\"))",
      // Personal data.
      "(deny file-read* (subpath (string-append (param \"HOME\") \"/Library/Safari\")))",
    ]
    for rule in required {
      #expect(strict.trailer.contains(rule), "missing strict rule: \(rule)")
    }
  }

  /// P4 (the highest-value invariant): the seatbelt is LAST-MATCH-WINS, so
  /// layering provider-home write allows must fold them into the BASE and
  /// carry the strict trailer through unchanged — always emitted last.
  @Test func strict_layeredHomeSubpathsKeepTheTrailerLast() {
    let strict = strictInvocation()
    let layered = SandboxProfile.invocation(strict, addingHomeSubpaths: [".codex", ".bun"])
    #expect(layered.baseProfile.contains("\"/.codex\""))
    #expect(layered.baseProfile.contains("\"/.bun\""))
    #expect(layered.trailer == strict.trailer)
    #expect(layered.profile.hasSuffix(strict.trailer.last! + "\n"))
    // The trailer rules must all appear AFTER the layered allows in the
    // effective profile text.
    let lastAllow = layered.baseProfile.range(of: "\"/.bun\"")!.lowerBound
    let firstTrailer = layered.profile.range(of: strict.trailer[0])!.lowerBound
    #expect(lastAllow < firstTrailer)
  }

  /// P5: strict adds NO new defines — argv indices and existing wiring stay
  /// valid.
  @Test func strict_addsNoNewDefines() {
    let plain = plainReadOnlyInvocation()
    let strict = strictInvocation()
    #expect(strict.defines.count == plain.defines.count)
    #expect(strict.defines.map { $0.0 } == plain.defines.map { $0.0 })
    #expect(strict.defines.map { $0.1 } == plain.defines.map { $0.1 })
  }

  /// P8 + canonical-path discipline: the temp denies use the canonical
  /// `/private/tmp` and `/private/var/tmp`, never bare `/tmp`, and no
  /// `string-append` root leaves a doubled slash.
  @Test func strict_usesCanonicalTempPathsNeverBareTmp() {
    let strict = strictInvocation()
    #expect(strict.profile.contains("(deny process-exec* (subpath \"/private/tmp\"))"))
    #expect(strict.profile.contains("(deny process-exec* (subpath \"/private/var/tmp\"))"))
    #expect(!strict.profile.contains("(deny process-exec* (subpath \"/tmp\"))"))
    #expect(!strict.profile.contains("//"))
  }

  /// The fence must stay read-only (no wiki DB ever) and must NOT deny the
  /// interpreters an arbitrary ACP adapter may itself be (`uv`, `bun`,
  /// `python3`, `node`).
  @Test func strict_noWikiDBAndNoInterpreterDenies() {
    let strict = strictInvocation()
    #expect(!strict.profile.contains("WIKI_DB"))
    #expect(!strict.profile.contains("(deny process-exec* (literal \"/usr/bin/python3\"))"))
    #expect(!strict.profile.contains("(deny process-exec* (literal \"/usr/bin/env\"))"))
    #expect(!strict.profile.contains("(deny process-exec* (literal \"/usr/bin/uv\"))"))
    #expect(!strict.profile.contains("(deny process-exec* (literal \"/usr/bin/bun\"))"))
  }

  // MARK: - Scoped-run profile (plans/agent-sandbox-scoping.md §8)

  static let container = "/Users/me/Library/Group Containers/group.x"
  static let daemonEndpoint = container + "/wikid-search.sock"
  static let runsDirectory = container + "/r"
  static let runEndpoint = runsDirectory + "/0a1b2c3d4e5f.sock"

  private func scopedProfile(
    runEndpoint: String = SandboxProfileTests.runEndpoint
  ) throws -> String {
    try SandboxProfile.generateScopedRun(
      scratchDir: Self.scratchDir,
      appGroupContainerPath: Self.container,
      daemonEndpointPath: Self.daemonEndpoint,
      runsDirectoryPath: Self.runsDirectory,
      runEndpointPath: runEndpoint)
  }

  private func scopedInvocation(
    runEndpoint: String = SandboxProfileTests.runEndpoint
  ) throws -> SandboxProfile.SandboxInvocation {
    try SandboxProfile.scopedRunInvocation(
      homePath: "/Users/me",
      scratchDir: Self.scratchDir,
      appGroupContainerPath: Self.container,
      daemonEndpointPath: Self.daemonEndpoint,
      runsDirectoryPath: Self.runsDirectory,
      runEndpointPath: runEndpoint)
  }

  /// The endpoint gate: ordinary + every-run denies, then the ONE assigned
  /// allow — order is load-bearing (the seatbelt is last-match-wins, so the
  /// assigned allow MUST follow both denies).
  @Test func scopedRunDeniesEndpointsThenAllowsTheAssignedOne() throws {
    let p = try scopedProfile()
    let denyOrdinary = "(deny network-outbound (literal (param \"DAEMON_ENDPOINT\")))"
    let denyRuns = "(deny network-outbound (subpath (param \"RUNS_DIR\")))"
    let allowAssigned = "(allow network-outbound (literal (param \"RUN_ENDPOINT\")))"
    #expect(p.contains(denyOrdinary))
    #expect(p.contains(denyRuns))
    #expect(p.contains(allowAssigned))
    let lines = p.split(separator: "\n").map(String.init)
    let denyOrdinaryIndex = try #require(lines.firstIndex(of: denyOrdinary))
    let denyRunsIndex = try #require(lines.firstIndex(of: denyRuns))
    let allowIndex = try #require(lines.firstIndex(of: allowAssigned))
    #expect(denyOrdinaryIndex < allowIndex)
    #expect(denyRunsIndex < allowIndex)
    #expect(allowIndex == lines.count - 1,
            "the assigned-endpoint allow is the LAST rule of the base profile")
  }

  /// §8: no `WIKI_DB`/`QUEUE_DB` write allowances, sidecars, or parameters —
  /// production edit permission lives in the daemon operation policy.
  @Test func scopedRunHasNoWikiOrQueueDBAllowances() throws {
    let p = try scopedProfile()
    #expect(!p.contains("WIKI_DB"))
    #expect(!p.contains("QUEUE_DB"))
  }

  /// The terminal data denies: the whole App Group subtree is read- AND
  /// write-denied, and the denies come AFTER every allowance (they are the
  /// last matching rules for what they name).
  @Test func scopedRunContainerDeniesAreTerminal() throws {
    let p = try scopedProfile()
    let denyRead = "(deny file-read* (subpath (param \"APP_GROUP_DIR\")))"
    let denyWrite = "(deny file-write* (subpath (param \"APP_GROUP_DIR\")))"
    #expect(p.contains(denyRead))
    #expect(p.contains(denyWrite))
    let lines = p.split(separator: "\n").map(String.init)
    let denyReadIndex = try #require(lines.firstIndex(of: denyRead))
    let scratchAllowIndex = try #require(
      lines.firstIndex(of: "(allow file-write* (subpath (param \"SCRATCH_DIR\")))"))
    let claudeAllowIndex = try #require(
      lines.firstIndex(where: { $0.contains("(param \"HOME\") \"/.claude\"") }))
    #expect(scratchAllowIndex < denyReadIndex)
    #expect(claudeAllowIndex < denyReadIndex)
    // Every APP_GROUP_DIR file rule is a deny (nothing later re-opens it in
    // the base; provider layering is HOME-relative — asserted below).
    for line in lines where line.contains("APP_GROUP_DIR") {
      #expect(line.contains("(deny file-"),
              "every APP_GROUP_DIR file rule must be a deny, got: \(line)")
    }
  }

  /// Runtime allowances survive verbatim: scratch, Claude runtime state, the
  /// temp base, the shell device allowances, the execution-vector denies.
  @Test func scopedRunKeepsRuntimeAllowancesAndClaudeDenies() throws {
    let p = try scopedProfile()
    #expect(p.contains("(allow file-write* (subpath (param \"SCRATCH_DIR\")))"))
    #expect(p.contains("(allow file-write* (subpath (param \"CLAUDE_TMP\")))"))
    #expect(p.contains("(allow file-write-data (literal \"/dev/null\"))"))
    #expect(p.contains("(deny file-write* (subpath (string-append (param \"HOME\") \"/.claude/hooks\")))"))
  }

  /// The scoped defines carry every path the profile references.
  @Test func scopedRunInvocationCarriesScopedDefines() throws {
    let inv = try scopedInvocation()
    let defines = Dictionary(uniqueKeysWithValues: inv.defines.map { ($0.0, $0.1) })
    #expect(defines["APP_GROUP_DIR"] == Self.container)
    #expect(defines["DAEMON_ENDPOINT"] == Self.daemonEndpoint)
    #expect(defines["RUNS_DIR"] == Self.runsDirectory)
    #expect(defines["RUN_ENDPOINT"] == Self.runEndpoint)
    #expect(defines["SCRATCH_DIR"] == Self.scratchDir)
  }

  /// #1468, profile side: a run endpoint that cannot fit `sockaddr_un`
  /// throws the operator-actionable error instead of building silently.
  @Test func scopedRunRejectsOverlongRunEndpointPath() {
    let overlong = Self.runsDirectory + "/" + String(repeating: "a", count: 120) + ".sock"
    #expect(overlong.utf8.count > SandboxProfile.maxSocketPathBytes)
    #expect(throws: SandboxProfile.ProfileError.runEndpointPathTooLong(
      limit: SandboxProfile.maxSocketPathBytes, actual: overlong.utf8.count)) {
      try scopedProfile(runEndpoint: overlong)
    }
  }

  /// The strict scoped variant keeps the pivot/W^X trailer LAST — after the
  /// base whose final rule is the assigned-endpoint allow — and the trailer
  /// carries no file or network rules that could shadow the terminal denies.
  @Test func strictScopedRunKeepsTrailerLastWithoutShadowingEndpointRules() throws {
    let base = try scopedInvocation()
    let strict = try SandboxProfile.strictScopedRunInvocation(
      homePath: "/Users/me",
      scratchDir: Self.scratchDir,
      appGroupContainerPath: Self.container,
      daemonEndpointPath: Self.daemonEndpoint,
      runsDirectoryPath: Self.runsDirectory,
      runEndpointPath: Self.runEndpoint)
    #expect(strict.baseProfile == base.profile)
    #expect(!strict.trailer.isEmpty)
    #expect(strict.baseProfile.hasSuffix(
      "(allow network-outbound (literal (param \"RUN_ENDPOINT\")))\n"))
    // Every trailer rule is a DENY — the trailer can only narrow further
    // (HOME-subtree exec/credential reads), never re-open the terminal
    // scoped denies or the assigned-endpoint allow.
    for rule in strict.trailer {
      #expect(rule.hasPrefix("(deny "),
              "the strict trailer must stay deny-only so it cannot shadow the scoped terminal rules: \(rule)")
    }
    #expect(strict.profile.hasSuffix(strict.trailer.last! + "\n"))
  }

  /// Provider layering (`addingHomeSubpaths`) appends write allows AFTER the
  /// terminal section — they are HOME-relative and can never re-open the
  /// container denies.
  @Test func scopedRunContainerDeniesSurviveProviderLayering() throws {
    let base = try scopedInvocation()
    let layered = SandboxProfile.invocation(
      base, addingHomeSubpaths: [".codex", ".gemini"])
    #expect(layered.profile.contains(
      "(allow file-write* (subpath (string-append (param \"HOME\") \"/.codex\")))"))
    let lines = layered.profile.split(separator: "\n").map(String.init)
    for line in lines where line.contains("APP_GROUP_DIR") {
      #expect(line.contains("(deny file-"),
              "layering must not re-open the container, got: \(line)")
    }
  }
}
