#if os(macOS)
import Testing
import Foundation
@testable import WikiFS
import WikiFSCore

/// Pure-logic tests for `EnvVarText` — the bash-style `KEY=value` parser behind
/// the provider Environment text box. Copy/paste is the common path, so the
/// parser must tolerate comments, blank lines, `export ` prefixes, quoted
/// values, and duplicate keys.
@Suite("EnvVarText")
struct EnvVarTextTests {

    @Test func parsesSimpleAssignments() {
        let env = EnvVarText.parse("FOO=bar\nBAZ=qux")
        #expect(env == ["FOO": "bar", "BAZ": "qux"])
    }

    @Test func skipsCommentsAndBlankLines() {
        let env = EnvVarText.parse("""
        # a comment
        FOO=bar

        #KEY=ignored
        BAZ=qux
        """)
        #expect(env == ["FOO": "bar", "BAZ": "qux"])
    }

    @Test func stripsExportPrefix() {
        let env = EnvVarText.parse("export FOO=bar")
        #expect(env == ["FOO": "bar"])
    }

    @Test func stripsMatchingSurroundingQuotes() {
        let env = EnvVarText.parse("""
        A="hello world"
        B='single'
        C="mismatched'
        """)
        #expect(env["A"] == "hello world")
        #expect(env["B"] == "single")
        // Mismatched quotes are left intact.
        #expect(env["C"] == "\"mismatched'")
    }

    @Test func lastDuplicateKeyWins() {
        let env = EnvVarText.parse("FOO=one\nFOO=two")
        #expect(env == ["FOO": "two"])
    }

    @Test func trimsWhitespaceAroundKeyAndValue() {
        let env = EnvVarText.parse("  FOO =  bar  ")
        #expect(env == ["FOO": "bar"])
    }

    @Test func valueMayContainEquals() {
        let env = EnvVarText.parse("URL=https://x.test?a=1&b=2")
        #expect(env["URL"] == "https://x.test?a=1&b=2")
    }

    @Test func malformedLinesFlagNonAssignments() {
        let bad = EnvVarText.malformedLines("FOO=bar\ngarbage line\n# comment\n=novalue")
        #expect(bad == ["garbage line", "=novalue"])
    }

    @Test func formatRoundTripsThroughParse() {
        let env = ["B": "2", "A": "1"]
        let text = EnvVarText.format(env)
        // Sorted, one per line.
        #expect(text == "A=1\nB=2")
        #expect(EnvVarText.parse(text) == env)
    }

    @Test func seedUsesExistingEnvAsAssignments() {
        let provider = AgentProvider(
            id: "p", label: "P", command: ["x"], env: ["FOO": "bar"],
            enabled: true, isDefault: false)
        let seed = EnvVarText.seed(for: provider)
        #expect(seed == "FOO=bar")
        #expect(EnvVarText.parse(seed) == ["FOO": "bar"])
    }

    @Test func seedForEmptyEnvIsAllCommentsSoItParsesEmpty() {
        let provider = AgentProvider(
            id: "claude-acp", label: "Claude", command: ["x"], env: [:],
            enabled: true, isDefault: false)
        let seed = EnvVarText.seed(for: provider)
        // Every line is a comment/blank → nothing is set until the user edits.
        #expect(EnvVarText.parse(seed).isEmpty)
    }
}
#endif
