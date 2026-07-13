import Testing
@testable import WikiFSCore

/// Pure unit tests for the `ShellWords` split/join helper backing the Agents
/// Settings command text field (Phase 3 of `plans/acp-multi-provider.md`).
@Suite struct ShellWordsTests {

    @Test func splitsOnWhitespace() {
        #expect(ShellWords.split("bun x @agentclientprotocol/claude-agent-acp") ==
                 ["bun", "x", "@agentclientprotocol/claude-agent-acp"])
    }

    @Test func collapsesRepeatedWhitespace() {
        #expect(ShellWords.split("hermes   acp\t--flag") == ["hermes", "acp", "--flag"])
    }

    @Test func emptyInputYieldsNoWords() {
        #expect(ShellWords.split("") == [])
        #expect(ShellWords.split("   ") == [])
    }

    @Test func doubleQuotedWordKeepsInternalSpaces() {
        #expect(ShellWords.split(#""opencode acp" --flag"#) == ["opencode acp", "--flag"])
    }

    @Test func singleQuotedWordIsLiteral() {
        #expect(ShellWords.split(#"'a\ b' c"#) == [#"a\ b"#, "c"])
    }

    @Test func doubleQuoteEscapesQuoteAndBackslash() {
        #expect(ShellWords.split(#""say \"hi\"" next"#) == [#"say "hi""#, "next"])
        #expect(ShellWords.split(#""a\\b""#) == [#"a\b"#])
    }

    @Test func unquotedBackslashEscapesNextChar() {
        #expect(ShellWords.split(#"a\ b c"#) == ["a b", "c"])
    }

    @Test func unterminatedQuoteConsumesRestOfInput() {
        #expect(ShellWords.split(#"foo "bar baz"#) == ["foo", "bar baz"])
    }

    @Test func joinPlainWordsIsSpaceSeparated() {
        #expect(ShellWords.join(["hermes", "acp"]) == "hermes acp")
    }

    @Test func joinQuotesWordsContainingWhitespace() {
        #expect(ShellWords.join(["opencode acp", "--flag"]) == #""opencode acp" --flag"#)
    }

    @Test func joinThenSplitRoundTrips() {
        let words = ["/path with spaces/bin", "--model", "say \"hi\""]
        #expect(ShellWords.split(ShellWords.join(words)) == words)
    }

    @Test func joinEmptyArrayYieldsEmptyString() {
        #expect(ShellWords.join([]) == "")
    }
}
