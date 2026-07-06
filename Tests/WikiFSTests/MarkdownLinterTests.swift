import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiCtlCore

/// Tests for MarkdownLinter — live markdownlint validation via JavaScriptCore.
/// The linter loads the committed vendored bundle
/// (`Resources/markdownlint.bundle.js`), which is the proof the feature runs with
/// NO Node installed: these tests execute in the `swift test` process, which has
/// no app bundle and no Node — only the macOS JavaScriptCore system framework.
struct MarkdownLinterTests {

    /// Resolve the committed bundle relative to this test file
    /// (Tests/WikiFSTests → ../../Resources/markdownlint.bundle.js).
    private func bundleSource() -> String? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../Resources/markdownlint.bundle.js")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func linter() throws -> MarkdownLinter {
        guard let src = bundleSource(), !src.isEmpty else {
            throw ValidationFailure("Resources/markdownlint.bundle.js not found or empty")
        }
        guard let l = MarkdownLinter(jsSource: src) else {
            throw ValidationFailure("MarkdownLinter failed to load __markdownlint")
        }
        return l
    }
    private struct ValidationFailure: Error { let msg: String; init(_ s: String) { msg = s } }

    // MARK: - init / load

    @Test func emptySourceReturnsNil() {
        #expect(MarkdownLinter(jsSource: "") == nil)
    }

    // MARK: - lint

    @Test func lintFlagsTrailingSpaces() throws {
        let l = try linter()
        let findings = l.lint(markdown: "text with trailing space   \n")
        #expect(findings.contains { $0.ruleID == "MD009" })
    }

    @Test func lintFlagsHardTabs() throws {
        let l = try linter()
        let findings = l.lint(markdown: "text\twith tabs\n")
        #expect(findings.contains { $0.ruleID == "MD010" })
    }

    @Test func lintFlagsMultipleBlanks() throws {
        let l = try linter()
        let findings = l.lint(markdown: "# Title\n\n\n\ntext\n")
        #expect(findings.contains { $0.ruleID == "MD012" })
    }

    @Test func lintFlagsMissingSpaceAfterHeading() throws {
        let l = try linter()
        let findings = l.lint(markdown: "#No space after hash\n")
        #expect(findings.contains { $0.ruleID == "MD018" })
    }

    @Test func lintFlagsMissingBlankAroundFence() throws {
        let l = try linter()
        let md = "# Title\n```\ncode\n```\n"
        let findings = l.lint(markdown: md)
        #expect(findings.contains { $0.ruleID == "MD031" })
    }

    @Test func lintReturnsNoFindingsForCleanDoc() throws {
        let l = try linter()
        let clean = "# Title\n\nSome paragraph text here.\n"
        #expect(l.lint(markdown: clean).isEmpty)
    }

    @Test func wikiLinksProduceNoFinding() throws {
        let l = try linter()
        let md = "See [[some wiki link]] and [[another]] for details.\n"
        #expect(l.lint(markdown: md).isEmpty)
    }

    // MARK: - fix

    @Test func fixStripsTrailingWhitespace() throws {
        let l = try linter()
        let outcome = l.fix(markdown: "# Title\ntrailing   \n")
        #expect(!outcome.fixed.contains("   "))
        #expect(outcome.unfixable.isEmpty)
    }

    @Test func fixAddsSpaceAfterHeadingMarker() throws {
        let l = try linter()
        let outcome = l.fix(markdown: "#No space\n")
        #expect(outcome.fixed.hasPrefix("# No space"))
        #expect(outcome.unfixable.isEmpty)
    }

    @Test func fixAddsBlankLineAroundFence() throws {
        let l = try linter()
        let fence = String(repeating: "`", count: 3)
        let md = "# Title\n\(fence)\ncode\n\(fence)\nmore text\n"
        let outcome = l.fix(markdown: md)
        // The fence should now have a blank line before it (MD031 fix).
        #expect(outcome.fixed.contains("\n\n\(fence)"))
        #expect(outcome.unfixable.isEmpty)
    }

    @Test func fixEnsuresSingleTrailingNewline() throws {
        let l = try linter()
        let outcome = l.fix(markdown: "# Title\n\nText")
        #expect(outcome.fixed.hasSuffix("\n"))
        #expect(!outcome.fixed.hasSuffix("\n\n"))
        #expect(outcome.unfixable.isEmpty)
    }

    @Test func fixReturnsBodyUnchangedWhenNoFindings() throws {
        let l = try linter()
        let clean = "# Title\n\nSome paragraph text here.\n"
        let outcome = l.fix(markdown: clean)
        #expect(outcome.fixed == clean)
        #expect(outcome.unfixable.isEmpty)
    }

    @Test func fixCollapsesMultipleBlankLines() throws {
        let l = try linter()
        let outcome = l.fix(markdown: "# Title\n\n\n\nText\n")
        #expect(!outcome.fixed.contains("\n\n\n"))
        #expect(outcome.unfixable.isEmpty)
    }

    // MARK: - mermaid-fence composition safety

    @Test func fixLeavesMermaidBlockContentsUntouched() throws {
        let l = try linter()
        let fence = String(repeating: "`", count: 3)
        let md = "# Title   \n\n\(fence)mermaid\nflowchart LR\nA-->B\n\(fence)\nmore text"
        let outcome = l.fix(markdown: md)
        // The mermaid block contents must be byte-for-byte intact.
        #expect(outcome.fixed.contains("flowchart LR"))
        #expect(outcome.fixed.contains("A-->B"))
        // Trailing whitespace on the heading is stripped.
        #expect(outcome.fixed.hasPrefix("# Title\n"))
        // The fence content itself is NOT modified by cosmetic fixes.
        #expect(outcome.unfixable.isEmpty)
    }

    @Test func lintDoesNotFlagMermaidBlockContents() throws {
        let l = try linter()
        let fence = String(repeating: "`", count: 3)
        // Mermaid syntax that WOULD trigger cosmetic rules if scanned as prose
        // (no space after #, trailing spaces inside the block) — but fenced code
        // blocks must be left alone.
        let md = "# Title\n\n\(fence)mermaid\nflowchart LR\n  A-->B\n\(fence)\n"
        let findings = l.lint(markdown: md)
        #expect(findings.allSatisfy { $0.lineNumber != 4 })  // flowchart line
        #expect(findings.allSatisfy { $0.lineNumber != 5 })  // A-->B line
    }

    // MARK: - describe

    @Test func describeFormatsFindings() throws {
        let l = try linter()
        let findings = l.lint(markdown: "#No space\ntrailing   \n")
        let desc = MarkdownLinter.describe(findings)
        #expect(!desc.isEmpty)
        #expect(desc.contains("markdown:"))
        #expect(desc.contains("MD018"))
        #expect(desc.contains("line 1"))
    }

    @Test func describeEmptyForNoFindings() {
        #expect(MarkdownLinter.describe([]).isEmpty)
    }

    // MARK: - Wiki-link embeds (Phase 4a)

    @Test func embedSourceSyntaxProducesNoFalsePositives() throws {
        // `![[source:img.png]]` has a leading `!` before `[[` that could be
        // parsed as a CommonMark image start — verify markdownlint doesn't flag it.
        let l = try linter()
        let findings = l.lint(markdown: "See this image:\n\n![[source:diagram.png]]\n\nText after.\n")
        #expect(findings.isEmpty)
    }
}
