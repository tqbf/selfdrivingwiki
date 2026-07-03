import Foundation
import Testing
@testable import WikiFSCore

/// Tests for `AgentCommandConfig` — persistence, tokenizer, tilde expansion.
struct AgentCommandConfigTests {

    // MARK: - Defaults

    @Test func defaultConfigHasClaudeExecutable() {
        #expect(AgentCommandConfig.default.executable == "claude")
        #expect(AgentCommandConfig.default.prefixArguments == "")
        #expect(AgentCommandConfig.default.modelOverride == "")
        #expect(AgentCommandConfig.default.extraEnvironment == "")
    }

    // MARK: - Persistence

    @Test func loadSaveRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-cmd-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let config = AgentCommandConfig(
            executable: "/usr/local/bin/claude",
            prefixArguments: "sandbox-exec -f profile.sb",
            modelOverride: "haiku",
            extraEnvironment: "DEBUG=1\nVERBOSE=true")
        try config.save(to: dir)

        let loaded = AgentCommandConfig.load(from: dir)
        #expect(loaded.executable == "/usr/local/bin/claude")
        #expect(loaded.prefixArguments == "sandbox-exec -f profile.sb")
        #expect(loaded.modelOverride == "haiku")
        #expect(loaded.extraEnvironment == "DEBUG=1\nVERBOSE=true")
    }

    @Test func missingFileReturnsDefault() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-cmd-missing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let loaded = AgentCommandConfig.load(from: dir)
        #expect(loaded == .default)
    }

    @Test func corruptFileReturnsDefault() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-cmd-corrupt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent(AgentCommandConfig.fileName)
        try Data("not valid json".utf8).write(to: url)

        let loaded = AgentCommandConfig.load(from: dir)
        #expect(loaded == .default)
    }

    // MARK: - resolvedExecutable

    @Test func resolvedExecutableDefaultsToClaudeWhenEmpty() {
        let config = AgentCommandConfig(executable: "")
        #expect(config.resolvedExecutable() == "claude")
    }

    @Test func resolvedExecutableExpandsTilde() {
        let config = AgentCommandConfig(executable: "~/bin/my-claude")
        let resolved = config.resolvedExecutable()
        #expect(resolved.hasPrefix("/"))
        #expect(resolved.hasSuffix("/bin/my-claude"))
    }

    // MARK: - Tokenizer

    @Test func tokenizeEmptyString() {
        #expect(AgentCommandConfig.tokenize("") == [])
    }

    @Test func tokenizeWhitespaceOnly() {
        #expect(AgentCommandConfig.tokenize("   ") == [])
    }

    @Test func tokenizeSimpleTokens() {
        #expect(AgentCommandConfig.tokenize("a b c") == ["a", "b", "c"])
    }

    @Test func tokenizePreservesQuotedStrings() {
        let result = AgentCommandConfig.tokenize("a 'b c' d")
        #expect(result == ["a", "b c", "d"])
    }

    @Test func tokenizePreservesDoubleQuotedStrings() {
        let result = AgentCommandConfig.tokenize(#"a "b c" d"#)
        #expect(result == ["a", "b c", "d"])
    }

    @Test func tokenizePreservesEscapedCharacters() {
        let result = AgentCommandConfig.tokenize(#"a\ b c"#)
        #expect(result == ["a b", "c"])
    }

    @Test func tokenizeLiteralBackslashInSingleQuotes() {
        let result = AgentCommandConfig.tokenize(#"'a\b' c"#)
        #expect(result == [#"a\b"#, "c"])
    }

    @Test func tokenizeTrailingBackslashIsLiteral() {
        let result = AgentCommandConfig.tokenize(#"a\"#)
        #expect(result == [#"a\"#])
    }

    @Test func tokenizeDoubleSpaceBetweenTokens() {
        let result = AgentCommandConfig.tokenize("a   b")
        #expect(result == ["a", "b"])
    }

    // MARK: - prefixArguments tokenization

    @Test func tokenizedPrefixArgsEmptyByDefault() {
        #expect(AgentCommandConfig.default.tokenizedPrefixArgs() == [])
    }

    @Test func tokenizedPrefixArgsTokenizesCorrectly() {
        let config = AgentCommandConfig(prefixArguments: "-f profile.sb /bin/claude")
        #expect(config.tokenizedPrefixArgs() == ["-f", "profile.sb", "/bin/claude"])
    }

    // MARK: - Extra environment parsing

    @Test func parsedExtraEnvParsesKeyValue() {
        let config = AgentCommandConfig(extraEnvironment: "FOO=bar\nBAZ=qux")
        let env = config.parsedExtraEnv()
        #expect(env["FOO"] == "bar")
        #expect(env["BAZ"] == "qux")
    }

    @Test func parsedExtraEnvSkipsBlankLines() {
        let config = AgentCommandConfig(extraEnvironment: "FOO=bar\n\nBAZ=qux\n  ")
        let env = config.parsedExtraEnv()
        #expect(env.count == 2)
    }

    @Test func parsedExtraEnvSkipsLinesWithoutEquals() {
        let config = AgentCommandConfig(extraEnvironment: "FOO=bar\ncomment\nBAZ=qux")
        let env = config.parsedExtraEnv()
        #expect(env.count == 2)
        #expect(env["comment"] == nil)
    }

    @Test func parsedExtraEnvStripsExportKeyword() {
        let config = AgentCommandConfig(extraEnvironment: "export FOO=bar\nexport   BAZ=qux")
        let env = config.parsedExtraEnv()
        #expect(env["FOO"] == "bar")
        #expect(env["BAZ"] == "qux")
    }

    @Test func parsedExtraEnvExportWithoutEqualsIsSkipped() {
        // `export FOO` (no assignment) is not a key=value line.
        let config = AgentCommandConfig(extraEnvironment: "export FOO\nBAR=1")
        let env = config.parsedExtraEnv()
        #expect(env["FOO"] == nil)
        #expect(env["BAR"] == "1")
    }

    @Test func parsedExtraEnvDoesNotMangleKeyNamedExport() {
        // `export=foo` is a normal assignment to a key literally named "export".
        let config = AgentCommandConfig(extraEnvironment: "export=foo")
        let env = config.parsedExtraEnv()
        #expect(env["export"] == "foo")
    }

    @Test func parsedExtraEnvStripsDoubleQuotes() {
        let config = AgentCommandConfig(extraEnvironment: #"export CLAUDE_MODEL="sonnet""#)
        let env = config.parsedExtraEnv()
        #expect(env["CLAUDE_MODEL"] == "sonnet")
    }

    @Test func parsedExtraEnvExpandsBraceVar() {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        let config = AgentCommandConfig(extraEnvironment: "DOCS=${HOME}/docs")
        let env = config.parsedExtraEnv()
        #expect(env["DOCS"] == "\(home)/docs")
    }

    @Test func parsedExtraEnvExpandsBareVar() {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        let config = AgentCommandConfig(extraEnvironment: "DOCS=$HOME/docs")
        let env = config.parsedExtraEnv()
        #expect(env["DOCS"] == "\(home)/docs")
    }

    @Test func parsedExtraEnvExpandsVarInsideDoubleQuotes() {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        let config = AgentCommandConfig(extraEnvironment: #"DOCS="$HOME/docs""#)
        let env = config.parsedExtraEnv()
        #expect(env["DOCS"] == "\(home)/docs")
    }

    @Test func parsedExtraEnvSingleQuotesAreLiteral() {
        // Single quotes suppress expansion, like bash.
        let config = AgentCommandConfig(extraEnvironment: "DOCS='$HOME/docs'")
        let env = config.parsedExtraEnv()
        #expect(env["DOCS"] == "$HOME/docs")
    }

    @Test func parsedExtraEnvUnsetVarExpandsToEmpty() {
        let config = AgentCommandConfig(extraEnvironment: "X=${WIKI_TEST_UNSET_VAR_42}/y\nZ=$WIKI_TEST_UNSET_VAR_42")
        let env = config.parsedExtraEnv()
        #expect(env["X"] == "/y")
        #expect(env["Z"] == "")
    }

    @Test func parsedExtraEnvLoneDollarIsLiteral() {
        // `$1` is not a valid name (names can't start with a digit), so the `$`
        // is kept literally rather than treated as a variable reference.
        let config = AgentCommandConfig(extraEnvironment: "FOO=$1")
        let env = config.parsedExtraEnv()
        #expect(env["FOO"] == "$1")
    }

    // MARK: - expandTilde

    @Test func expandTildeReturnsNonTildePathsUnchanged() {
        #expect(AgentCommandConfig.expandTilde("/usr/bin/claude") == "/usr/bin/claude")
        #expect(AgentCommandConfig.expandTilde("claude") == "claude")
    }

    @Test func expandTildeExpandsBareTilde() {
        let result = AgentCommandConfig.expandTilde("~")
        #expect(result.hasPrefix("/"))
        #expect(!result.contains("~"))
    }

    @Test func expandTildeExpandsTildeSlash() {
        let result = AgentCommandConfig.expandTilde("~/bin/claude")
        #expect(result.hasPrefix("/"))
        #expect(result.hasSuffix("/bin/claude"))
    }
}
