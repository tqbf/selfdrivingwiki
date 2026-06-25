import Foundation
import Testing
@testable import WikiFSCore

/// Sandbox-wrapping tests for `OperationCommand.build` / `buildInteractiveQuery`.
/// Verifies the seatbelt argv shape (AC.2), byte-identical-when-off (AC.1), the
/// relocation env (`CLAUDE_CONFIG_DIR`/`TMPDIR`) present-on / absent-off, and that
/// the provider's own prefix args land AFTER `-- <providerExe>`.
struct SandboxedOperationCommandTests {

  static let resolvedRoot = "/Users/me/Library/CloudStorage/WikiFS-Research"
  static let scratch = "/tmp/scratch-xyz"
  static let stateFile = "/tmp/scratch-xyz/WIKI_STATE.md"
  static let providerExe = "/opt/homebrew/bin/claude"
  static let wikiDBPath = "/Users/me/Library/Group Containers/group.x/01WIKI.sqlite"

  static let sandbox = SandboxProfile.invocation(
    homePath: "/Users/me",
    scratchDir: Self.scratch,
    wikiDBPath: Self.wikiDBPath)

  private func buildOn(
    operation: WikiOperation = .query(question: "q?", stateFilePath: Self.stateFile),
    command: AgentCommandConfig = .default
  ) -> OperationCommand {
    OperationCommand.build(
      operation: operation,
      wikiRoot: Self.resolvedRoot,
      wikiID: "01WIKIULID",
      systemPrompt: "schema",
      scratchDirectory: Self.scratch,
      wikictlDirectory: "/helpers",
      resolvedExecutable: Self.providerExe,
      command: command,
      sandbox: Self.sandbox,
      baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": "/Users/me"])
  }

  // MARK: - AC.1: byte-identical when sandbox is nil

  @Test func offPathExecutableIsProviderAndArgumentsStartWithP() {
    let cmd = OperationCommand.build(
      operation: .query(question: "q?", stateFilePath: Self.stateFile),
      wikiRoot: Self.resolvedRoot,
      wikiID: "01WIKIULID",
      systemPrompt: "schema",
      scratchDirectory: Self.scratch,
      wikictlDirectory: "/helpers",
      resolvedExecutable: Self.providerExe,
      baseEnvironment: [:])
    #expect(cmd.executable == Self.providerExe)
    #expect(cmd.arguments[0] == "-p")
    // No relocation env set when sandbox is off.
    #expect(cmd.environment["CLAUDE_CONFIG_DIR"] == nil)
    #expect(cmd.environment["TMPDIR"] == nil)
  }

  // MARK: - AC.2: sandbox-on argv shape

  @Test func onPathUsesSandboxExecutableAndWrappedHead() {
    let cmd = buildOn()
    #expect(cmd.executable == OperationCommand.sandboxExecutable)
    #expect(OperationCommand.sandboxExecutable == "/usr/bin/sandbox-exec")

    let args = cmd.arguments
    #expect(args[0] == "-p")
    #expect(args[1] == Self.sandbox.profile)
    #expect(args[2] == "-D")
    #expect(args[3] == "HOME=/Users/me")
    #expect(args[4] == "-D")
    #expect(args[5] == "SCRATCH_DIR=\(Self.scratch)")
    #expect(args[6] == "-D")
    #expect(args[7] == "WIKI_DB=\(Self.wikiDBPath)")
    #expect(args[8] == "--")
    #expect(args[9] == Self.providerExe)
    #expect(args[10] == "-p")
  }

  @Test func onPathPreservesAppOwnedEnvAndSetsRelocation() {
    let cmd = buildOn()
    #expect(cmd.environment["WIKI_ROOT"] == Self.resolvedRoot)
    #expect(cmd.environment["WIKI_DB"] == "01WIKIULID")
    #expect(cmd.environment["PATH"] == "/helpers:/usr/bin:/bin")
    #expect(cmd.environment["CLAUDE_CONFIG_DIR"] == Self.scratch + "/.claude-config")
    #expect(cmd.environment["TMPDIR"] == Self.scratch + "/.tmp")
  }

  @Test func prefixArgsLandAfterTheProviderSeparator() {
    let cfg = AgentCommandConfig(executable: "claude", prefixArguments: "--foo bar")
    let cmd = buildOn(command: cfg)
    let sepIndex = cmd.arguments.firstIndex(of: "--")!
    let providerIndex = sepIndex + 1
    #expect(cmd.arguments[providerIndex] == Self.providerExe)
    #expect(cmd.arguments[providerIndex + 1] == "--foo")
    #expect(cmd.arguments[providerIndex + 2] == "bar")
    #expect(cmd.arguments[providerIndex + 3] == "-p")
  }

  // MARK: - Interactive query also wraps

  @Test func interactiveQueryWrapsIdentically() {
    let cmd = OperationCommand.buildInteractiveQuery(
      operation: .queryConversation(stateFilePath: Self.stateFile, allowWikiEdits: false),
      wikiRoot: Self.resolvedRoot,
      wikiID: "01WIKIULID",
      systemPrompt: "schema",
      scratchDirectory: Self.scratch,
      wikictlDirectory: "/helpers",
      resolvedExecutable: Self.providerExe,
      sandbox: Self.sandbox,
      baseEnvironment: ["PATH": "/usr/bin:/bin"])
    #expect(cmd.executable == OperationCommand.sandboxExecutable)
    #expect(cmd.arguments[0] == "-p")
    #expect(cmd.arguments[1] == Self.sandbox.profile)
    #expect(cmd.arguments[8] == "--")
    #expect(cmd.arguments[9] == Self.providerExe)
    #expect(cmd.environment["CLAUDE_CONFIG_DIR"] == Self.scratch + "/.claude-config")
    #expect(cmd.environment["TMPDIR"] == Self.scratch + "/.tmp")
    // The WIKI_DB env var (the ULID the agent/wikictl use) is NOT clobbered by the
    // `-D WIKI_DB=<path>` profile param — they are separate channels.
    #expect(cmd.environment["WIKI_DB"] == "01WIKIULID")
    #expect(cmd.environment["WIKI_DB"] != Self.wikiDBPath)
  }
}
