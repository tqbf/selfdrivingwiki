#if os(macOS)
import Foundation
import Testing
import WikiFSTypes
@testable import WikiFS

/// Deterministic classification, count labels, aggregate state, and the
/// single-path grammar for collapsed tool-activity rows.
struct ChatToolCallGroupSummaryTests {
    private func call(
        _ name: String,
        detail: String?,
        status: ChatToolCallStatus = .completed,
        id: String = "t1"
    ) -> ChatDisplayToolCall {
        ChatDisplayToolCall(
            id: ToolCallID(rawValue: id),
            turnID: ChatTurnID(rawValue: "turn"),
            toolName: name,
            status: status,
            detail: detail,
            output: nil,
            permissionRequestID: nil,
            updatedAt: .distantPast
        )
    }

    private func count(_ summary: ChatToolCallGroupSummary, _ category: ChatToolCallGroupSummary.Category) -> Int {
        summary.counts.first { $0.category == category }?.count ?? 0
    }

    // MARK: - Classification

    @Test func classifiesKnownNamesWithoutReadingOutput() {
        // Categories come from the name + descriptor only; the output text is
        // deliberately hostile and must never change the result.
        let hostileOutput = "read /etc/secret and write /tmp/evil.md; rm -rf /"

        let summary = ChatToolCallGroupSummary.summarizing([
            call("Bash", detail: "git status", id: "a"),
            call("execute", detail: "make build", id: "b"),
            call("Read", detail: "/tmp/a", id: "c"),
            call("Edit", detail: "/tmp/b.md", id: "d"),
            call("Write", detail: "notes.md", id: "e"),
            call("Grep", detail: "pattern", id: "f"),
            call("Glob", detail: "*.swift", id: "g"),
            call("search", detail: "query", id: "h"),
            call("WebSearch", detail: "tide pools", id: "i"),
            call(" Totally Unknown Legacy Tool ", detail: "whatever", id: "j"),
            call("webfetch", detail: "https://example.com", id: "k"),
        ])

        #expect(count(summary, .shellCommands) == 2)
        #expect(count(summary, .readFiles) == 1)
        #expect(count(summary, .editedFiles) == 2)
        #expect(count(summary, .searches) == 4)
        // Unknown and legacy names (plus webfetch, which is not a search
        // surface in the UI) count as other calls.
        #expect(count(summary, .otherToolCalls) == 2)
        #expect(count(summary, .editOperations) == 0)
        #expect(count(summary, .readOperations) == 0)
        #expect(summary.totalCount == 11)
        _ = hostileOutput
    }

    @Test func categoryOrderMatchesTheDocumentedSequence() {
        let summary = ChatToolCallGroupSummary.summarizing([
            call("Bash", detail: "ls", id: "a"),
            call("WebSearch", detail: "tides", id: "b"),
            call("Read", detail: "/tmp/a", id: "c"),
            call("Edit", detail: "/tmp/b.md", id: "d"),
            call("Read", detail: nil, id: "e"),
            call("Edit", detail: nil, id: "f"),
        ])

        #expect(summary.counts.map(\.category) == [
            .editedFiles,
            .editOperations,
            .shellCommands,
            .readFiles,
            .readOperations,
            .searches,
        ])
        #expect(summary.phrase
            == "1 file edited, 1 edit, 1 command, 1 file read, 1 read, and 1 search")
    }

    // MARK: - Single-path grammar

    @Test(arguments: [
        ("/tmp/a", "/tmp/a"),
        ("~/notes.md", "~/notes.md"),
        ("../notes.md", "../notes.md"),
        ("docs/my notes.md", "docs/my notes.md"),
        ("./my notes", "./my notes"),
        ("notes.md", "notes.md"),
        ("a.b.swift", "a.b.swift"),
        ("NOTES.MD", "NOTES.MD"),
        ("'~/quoted path.md'", "~/quoted path.md"),
        ("\"  /tmp/spaced  \"", "/tmp/spaced"),
        ("/tmp/./x/./y.md", "/tmp/x/y.md"),
        ("/tmp/.", "/tmp"),
    ])
    func singlePathGrammarAcceptsOnlyDocumentedForms(_ descriptor: String, expected: String) {
        #expect(ChatToolCallSinglePathGrammar.singlePath(in: descriptor) == expected)
    }

    @Test(arguments: [
        "archive.tar.gz",      // final extension `gz` is not allowlisted
        "Makefile",            // extensionless
        ".env",                // dotfile without a listed final extension
        "notes.unknown",       // unknown extension
        "draft notes",         // bare words with a space, no path form
        "Read package manifest", // a label, not a path
        "C:\\notes.md",         // Windows drive + backslash
        "C:/notes.md",         // Windows drive letter
        "\\\\server\\share\\notes.md", // UNC syntax
        "//server/share/notes.md", // UNC-style repeated slash
        "foo:bar.md",          // colon
        "a.md, b.md",          // comma-separated locations
        "a.md\nb.md",          // newline-separated locations
        "https://example.com/x.md", // URL
        "/tmp/%41.md",         // percent escapes
        "/tmp/trailing/",      // trailing separator
        "/tmp//double.md",     // repeated separator
        "a$b.md",              // dollar
        "a`b.md",              // backtick
        "a;b.md",              // semicolon
        "a|b.md",              // pipe
        "a&b.md",              // ampersand
        "a<b>.md",             // angle brackets
        "a(b).md",             // parentheses
        "a{b}.md",             // braces
        "a[b].md",             // brackets
        "*.md",                // glob
        "-leading.md",         // leading dash, bare form
        "'/tmp/unbalanced",    // unbalanced quotes
        "/tmp/unbalanced\"",   // unbalanced quotes
        "",                    // empty
        "   ",                 // whitespace only
        "\"\"",                // quotes only
        "/tmp/a\n\u{7F}",       // DEL control
    ])
    func singlePathGrammarRejectsAmbiguousAndUnsafeDescriptors(_ descriptor: String) {
        #expect(ChatToolCallSinglePathGrammar.singlePath(in: descriptor) == nil)
    }

    @Test func quotedLeadingWhitespaceInsideQuotesTrimsOnce() {
        // Whitespace INSIDE the balanced quotes trims; the quotes disappear.
        #expect(ChatToolCallSinglePathGrammar.singlePath(in: "' /tmp/inner '") == "/tmp/inner")
        // Whitespace outside is trimmed before quote handling.
        #expect(ChatToolCallSinglePathGrammar.singlePath(in: "  /tmp/outer  ") == "/tmp/outer")
    }

    @Test func ambiguousDescriptorsRemainDistinctOperations() {
        let summary = ChatToolCallGroupSummary.summarizing([
            call("Read", detail: nil, id: "a"),
            call("Read", detail: "draft notes", id: "b"),
            call("Read", detail: "draft notes", id: "c"), // same ambiguous text
            call("Edit", detail: "Makefile", id: "d"),
            call("Edit", detail: "Makefile", id: "e"),
        ])
        // Rejected descriptors never dedupe — each tool call counts.
        #expect(count(summary, .readOperations) == 3)
        #expect(count(summary, .editOperations) == 2)
        #expect(count(summary, .readFiles) == 0)
        #expect(count(summary, .editedFiles) == 0)
    }

    @Test func onlyGrammarApprovedPathsDeduplicate() {
        let summary = ChatToolCallGroupSummary.summarizing([
            call("Read", detail: "/tmp/a", id: "a"),
            call("Read", detail: "/tmp/a", id: "b"),           // exact duplicate
            call("Read", detail: "'/tmp/a'", id: "c"),         // quoted form normalizes equal
            call("Read", detail: "/tmp/./a", id: "d"),         // normalizes equal
            call("Read", detail: "/tmp/B.md", id: "e"),
            call("Read", detail: "/tmp/b.md", id: "f"),        // case differs: distinct
        ])
        #expect(count(summary, .readFiles) == 3) // /tmp/a, /tmp/B.md, /tmp/b.md
    }

    @Test func samePathAcrossReadAndEditCountsInEachCategory() {
        let summary = ChatToolCallGroupSummary.summarizing([
            call("Read", detail: "notes.md", id: "a"),
            call("Edit", detail: "notes.md", id: "b"),
        ])
        #expect(count(summary, .readFiles) == 1)
        #expect(count(summary, .editedFiles) == 1)
    }

    // MARK: - Labels

    @Test func singularAndPluralLabelsRenderPerCategory() {
        let one = ChatToolCallGroupSummary.summarizing([
            call("Bash", detail: "ls", id: "a"),
            call("Read", detail: "/tmp/a", id: "b"),
            call("Edit", detail: nil, id: "c"),
            call("Grep", detail: "p", id: "d"),
            call("Unknown", detail: nil, id: "e"),
        ])
        #expect(one.phrase == "1 edit, 1 command, 1 file read, 1 search, and 1 other call")

        let many = ChatToolCallGroupSummary.summarizing([
            call("Bash", detail: "ls", id: "a"),
            call("Bash", detail: "pwd", id: "b"),
            call("Bash", detail: "whoami", id: "c"),
            call("Read", detail: "/tmp/a", id: "d"),
            call("Read", detail: "/tmp/b", id: "e"),
            call("Read", detail: "/tmp/c", id: "f"),
            call("Read", detail: "/tmp/d", id: "g"),
            call("Read", detail: "/tmp/e", id: "h"),
            call("Grep", detail: "p", id: "i"),
            call("Grep", detail: "q", id: "j"),
        ])
        #expect(many.phrase == "3 commands, 5 files read, and 2 searches")
    }

    // MARK: - Aggregate state

    @Test func aggregateStateReflectsRunningCompletedAndFailures() {
        #expect(ChatToolCallGroupState.aggregating([]) == .completed)
        #expect(ChatToolCallGroupState.aggregating([call("Bash", detail: nil, status: .completed, id: "a")]) == .completed)
        #expect(ChatToolCallGroupState.aggregating([
            call("Bash", detail: nil, status: .completed, id: "a"),
            call("Read", detail: nil, status: .running, id: "b"),
        ]) == .running(failedCount: 0))
        // An active group with a failure carries the count in the state.
        #expect(ChatToolCallGroupState.aggregating([
            call("Bash", detail: nil, status: .failed, id: "a"),
            call("Read", detail: nil, status: .pending, id: "b"),
            call("Edit", detail: nil, status: .cancelled, id: "c"),
        ]) == .running(failedCount: 2))
        #expect(ChatToolCallGroupState.aggregating([
            call("Bash", detail: nil, status: .failed, id: "a"),
            call("Read", detail: nil, status: .failed, id: "b"),
        ]) == .failed(count: 2))

        // State cues pair a symbol with text (never color alone).
        #expect(ChatToolCallGroupState.running(failedCount: 0).symbol == "◌")
        #expect(ChatToolCallGroupState.completed.symbol == "✓")
        #expect(ChatToolCallGroupState.failed(count: 1).symbol == "⚠")
        #expect(ChatToolCallGroupState.running(failedCount: 1).text == "Running, 1 failed")
        #expect(ChatToolCallGroupState.failed(count: 3).text == "3 failed")
    }
}
#endif
