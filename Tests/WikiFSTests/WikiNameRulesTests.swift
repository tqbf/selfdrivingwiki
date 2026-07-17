import Testing
@testable import WikiFSCore

/// Pure tests for the page-title / source-display-name sanitization rules.
struct WikiNameRulesTests {

    @Test func cleanNamesPassThrough() {
        #expect(WikiNameRules.sanitized("Plain Title") == "Plain Title")
        #expect(WikiNameRules.isLinkable("Plain Title"))
    }

    @Test func hashInsideNameIsKept() {
        // `#` is only unlinkable when LEADING — WikiLinkResolver handles it
        // elsewhere in a name.
        #expect(WikiNameRules.sanitized("Agentic Static Analysis for C# Security Auditing")
                == "Agentic Static Analysis for C# Security Auditing")
    }

    @Test func pipeBecomesDash() {
        #expect(WikiNameRules.sanitized("Foo | Bar") == "Foo - Bar")
        #expect(WikiNameRules.sanitized("A|B") == "A-B")
    }

    @Test func bracketsBecomeParensAsAPair() {
        #expect(WikiNameRules.sanitized("[Editorial] Some Paper") == "(Editorial) Some Paper")
    }

    @Test func leadingHashesAreDropped() {
        #expect(WikiNameRules.sanitized("#hashtag") == "hashtag")
        #expect(WikiNameRules.sanitized("# # Deeply Tagged") == "Deeply Tagged")
    }

    @Test func endsAreTrimmed() {
        #expect(WikiNameRules.sanitized("  Padded  ") == "Padded")
    }

    @Test func emptyResultFallsBackToUntitled() {
        #expect(WikiNameRules.sanitized("#") == "Untitled")
        #expect(WikiNameRules.sanitized("   ") == "Untitled")
    }

    @Test func sanitizedIsIdempotent() {
        for name in ["Foo | Bar", "[Editorial] X", "# #Foo", "C# Guide", "#", "  a  "] {
            let once = WikiNameRules.sanitized(name)
            #expect(WikiNameRules.sanitized(once) == once)
        }
    }

    // MARK: - looseMatchKey

    @Test func looseKeyStripsExtensionAndParenSuffix() {
        // The near-miss the lenient pass exists for: an agent cites
        // "Name (2026)" for a source named "Name.pdf".
        let cited = WikiNameRules.looseMatchKey("Agentic Static Analysis for C# Security Auditing (2026)")
        let stored = WikiNameRules.looseMatchKey("Agentic Static Analysis for C# Security Auditing.pdf")
        #expect(cited == stored)
        #expect(cited == "agentic static analysis for c# security auditing")
    }

    @Test func looseKeyIsCaseAndWhitespaceInsensitive() {
        #expect(WikiNameRules.looseMatchKey("  Some   PAPER ")
                == WikiNameRules.looseMatchKey("some paper"))
    }

    @Test func looseKeyStripsOnlyOneParenGroup() {
        #expect(WikiNameRules.looseMatchKey("A (b) (c)") == "a (b)")
    }

    @Test func looseKeyKeepsNonExtensionDots() {
        // A 6+ char or non-alphanumeric tail is not a file extension.
        #expect(WikiNameRules.looseMatchKey("release.candidate") == "release.candidate")
    }

    // MARK: - dash normalization

    @Test func looseKeyNormalizesEmDashToSpace() {
        // "Self-Driving Wiki — User Guide" (em dash) should match
        // "Self-Driving Wiki User Guide" (no dash at all).
        let withEmDash = WikiNameRules.looseMatchKey("Self-Driving Wiki \u{2014} User Guide")
        let noDash = WikiNameRules.looseMatchKey("Self-Driving Wiki User Guide")
        #expect(withEmDash == noDash)
    }

    @Test func looseKeyNormalizesEnDashToSpace() {
        let withEnDash = WikiNameRules.looseMatchKey("Foo \u{2013} Bar")
        let noDash = WikiNameRules.looseMatchKey("Foo Bar")
        #expect(withEnDash == noDash)
    }

    @Test func looseKeyNormalizesHyphenToSpace() {
        let withHyphen = WikiNameRules.looseMatchKey("Self-Driving Wiki")
        let noDash = WikiNameRules.looseMatchKey("Self Driving Wiki")
        #expect(withHyphen == noDash)
    }

    @Test func looseKeyNormalizesMixedDashVariants() {
        // Em dash, en dash, and hyphen-minus all normalize to space.
        let mixed = WikiNameRules.looseMatchKey("A\u{2014}B\u{2013}C-D")
        let allSpaces = WikiNameRules.looseMatchKey("A B C D")
        #expect(mixed == allSpaces)
    }
}
