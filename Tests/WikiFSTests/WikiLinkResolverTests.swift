import Testing
@testable import WikiFSCore

/// Pure tests for the lookup-driven `[[wiki-link]]` target disambiguation.
struct WikiLinkResolverTests {

    // MARK: - candidateSplits ordering

    @Test func plainTargetHasSingleCandidate() {
        let splits = WikiLinkResolver.candidateSplits(of: "Home")
        #expect(splits == [.init(base: "Home", fragment: nil)])
    }

    @Test func candidatesGoLongestBaseFirst() {
        let splits = WikiLinkResolver.candidateSplits(of: "C# Guide#Methods")
        #expect(splits == [
            .init(base: "C# Guide#Methods", fragment: nil),
            .init(base: "C# Guide", fragment: "Methods"),
            .init(base: "C", fragment: " Guide#Methods"),
        ])
    }

    @Test func quoteAnchorTargetSplitsAtEveryHash() {
        let splits = WikiLinkResolver.candidateSplits(of: "C# Notes#\"a # quote\"")
        #expect(splits.first == .init(base: "C# Notes#\"a # quote\"", fragment: nil))
        #expect(splits.contains(.init(base: "C# Notes", fragment: "\"a # quote\"")))
        #expect(splits.contains(.init(base: "C", fragment: " Notes#\"a # quote\"")))
    }

    @Test func emptyBaseCandidatesAreSkipped() {
        // "#Section" has no name-bearing reading other than the whole string —
        // the split at position 0 (a same-page anchor) is not a candidate.
        let splits = WikiLinkResolver.candidateSplits(of: "#Section")
        #expect(splits == [.init(base: "#Section", fragment: nil)])
    }

    @Test func trailingHashYieldsNilFragment() {
        let splits = WikiLinkResolver.candidateSplits(of: "Page#")
        #expect(splits == [
            .init(base: "Page#", fragment: nil),
            .init(base: "Page", fragment: nil),
        ])
    }

    @Test func basesAreNormalized() {
        // Split bases get whitespace-collapsed ends ("Foo " → "Foo"); fragments
        // stay verbatim.
        let splits = WikiLinkResolver.candidateSplits(of: "Foo #Bar")
        #expect(splits.contains(.init(base: "Foo", fragment: "Bar")))
    }

    // MARK: - resolvedSplit

    @Test func resolvesLongestKnownBase() {
        let known: Set<String> = ["C# Guide"]
        let split = WikiLinkResolver.resolvedSplit(of: "C# Guide#Methods") { known.contains($0) }
        #expect(split == .init(base: "C# Guide", fragment: "Methods"))
    }

    @Test func exactFullTargetBeatsAnchorReading() {
        // Both "Page#Section" (a literal title) and "Page" exist — the exact
        // full-target match wins.
        let known: Set<String> = ["Page#Section", "Page"]
        let split = WikiLinkResolver.resolvedSplit(of: "Page#Section") { known.contains($0) }
        #expect(split == .init(base: "Page#Section", fragment: nil))
    }

    @Test func plainAnchorSplitStillResolves() {
        let known: Set<String> = ["Page"]
        let split = WikiLinkResolver.resolvedSplit(of: "Page#Section") { known.contains($0) }
        #expect(split == .init(base: "Page", fragment: "Section"))
    }

    @Test func nothingKnownReturnsNil() {
        let split = WikiLinkResolver.resolvedSplit(of: "Ghost#Section") { _ in false }
        #expect(split == nil)
    }

    @Test func throwingLookupPropagates() {
        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try WikiLinkResolver.resolvedSplit(of: "X") { _ in throw Boom() }
        }
    }
}
