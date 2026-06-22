import Testing
@testable import WikiFSCore

/// Pure tests for `WikiLinkRewriter.rewriteSourceBase` — the heart of Phase D.
struct WikiLinkRewriterTests {

    // MARK: - Basic base swap

    @Test func rewritesSimpleSourceLink() {
        let result = WikiLinkRewriter.rewriteSourceBase(
            in: "See [[source:Old]] for details.",
            matching: "Old", to: "New")
        #expect(result == "See [[source:New]] for details.")
    }

    @Test func caseInsensitiveMatch() {
        let result = WikiLinkRewriter.rewriteSourceBase(
            in: "[[source:old]]",
            matching: "Old", to: "New")
        #expect(result == "[[source:New]]")
    }

    @Test func whitespaceCollapsedMatch() {
        let result = WikiLinkRewriter.rewriteSourceBase(
            in: "[[source:  old base  ]]",
            matching: "old base", to: "new name")
        #expect(result == "[[source:new name]]")
    }

    @Test func noMatchReturnsNil() {
        let result = WikiLinkRewriter.rewriteSourceBase(
            in: "[[source:Other]]",
            matching: "Old", to: "New")
        #expect(result == nil)
    }

    // MARK: - Fragment preservation

    @Test func preservesHeadingFragment() {
        let result = WikiLinkRewriter.rewriteSourceBase(
            in: "[[source:Old#Section]]",
            matching: "Old", to: "New")
        #expect(result == "[[source:New#Section]]")
    }

    @Test func preservesQuotedFragment() {
        let result = WikiLinkRewriter.rewriteSourceBase(
            in: "[[source:Old#\"a quoted passage\"]]",
            matching: "Old", to: "New")
        #expect(result == "[[source:New#\"a quoted passage\"]]")
    }

    @Test func preservesFragmentWithInnerHash() {
        let result = WikiLinkRewriter.rewriteSourceBase(
            in: "[[source:Old#C# is sharp]]",
            matching: "Old", to: "New")
        #expect(result == "[[source:New#C# is sharp]]")
    }

    // MARK: - Alias preservation

    @Test func preservesAlias() {
        let result = WikiLinkRewriter.rewriteSourceBase(
            in: "[[source:Old|display text]]",
            matching: "Old", to: "New")
        #expect(result == "[[source:New|display text]]")
    }

    @Test func preservesFragmentAndAlias() {
        let result = WikiLinkRewriter.rewriteSourceBase(
            in: "[[source:Old#\"q\"|alias]]",
            matching: "Old", to: "New")
        #expect(result == "[[source:New#\"q\"|alias]]")
    }

    // MARK: - Non-source links unchanged

    @Test func ignoresPageLink() {
        let body = "[[Old]] and [[source:Old]]"
        let result = WikiLinkRewriter.rewriteSourceBase(
            in: body, matching: "Old", to: "New")
        // Only the source: one changes; the plain [[Old]] is a page link.
        #expect(result == "[[Old]] and [[source:New]]")
    }

    @Test func ignoresExplicitPageLink() {
        let body = "[[page:Old]] and [[source:Old]]"
        let result = WikiLinkRewriter.rewriteSourceBase(
            in: body, matching: "Old", to: "New")
        #expect(result == "[[page:Old]] and [[source:New]]")
    }

    // MARK: - Code span/fence protection

    @Test func ignoresLinkInsideInlineCodeSpan() {
        let body = "`[[source:Old]]` outside [[source:Old]]"
        let result = WikiLinkRewriter.rewriteSourceBase(
            in: body, matching: "Old", to: "New")
        #expect(result == "`[[source:Old]]` outside [[source:New]]")
    }

    @Test func ignoresLinkInsideFencedCodeBlock() {
        let body = """
        [[source:Old]] outside

        ```
        [[source:Old]] inside
        ```

        [[source:Old]] outside again
        """
        let result = WikiLinkRewriter.rewriteSourceBase(
            in: body, matching: "Old", to: "New")
        // Inside the fence is untouched.
        #expect(result!.contains("[[source:Old]] inside"))
        // Outside links are rewritten.
        #expect(result!.contains("[[source:New]] outside"))
        #expect(result!.contains("[[source:New]] outside again"))
    }

    // MARK: - Multiple occurrences

    @Test func rewritesMultipleOccurrencesOfSameSource() {
        let body = "[[source:Old]] and [[source:Old#Section]] and [[source:Old|alias]]"
        let result = WikiLinkRewriter.rewriteSourceBase(
            in: body, matching: "Old", to: "New")
        #expect(result == "[[source:New]] and [[source:New#Section]] and [[source:New|alias]]")
    }

    @Test func rewritesMixedWithOtherSources() {
        let body = "[[source:Old]] and [[source:Other]] and [[source:Old#x]]"
        let result = WikiLinkRewriter.rewriteSourceBase(
            in: body, matching: "Old", to: "New")
        #expect(result == "[[source:New]] and [[source:Other]] and [[source:New#x]]")
    }

    // MARK: - Empty body

    @Test func emptyBodyReturnsNil() {
        #expect(WikiLinkRewriter.rewriteSourceBase(in: "", matching: "Old", to: "New") == nil)
    }

    // MARK: - Alias with fragment after alias (edge: fragment inside alias text)

    @Test func aliasContainingHashIsNotTreatedAsFragment() {
        // The regex group 1 captures the target (before `|`), group 2 captures
        // alias (after `|`). `#` inside the alias is NOT a fragment.
        let result = WikiLinkRewriter.rewriteSourceBase(
            in: "[[source:Old|see #1]]",
            matching: "Old", to: "New")
        #expect(result == "[[source:New|see #1]]")
    }
}
