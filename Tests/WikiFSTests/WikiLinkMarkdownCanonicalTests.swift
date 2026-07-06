import Foundation
import Testing
@testable import WikiFSCore

/// Phase 5 tests for `WikiLinkMarkdown.linkified` display-at-render (AC.5) and
/// the `?id=` URL contract (AC.7). A canonical `[[page:ULID|Stale Alias]]` must
/// render the CURRENT name (self-heal) and emit `wiki://page?id=<ULID>&title=…`.
struct WikiLinkMarkdownCanonicalTests {

    private let pageID = PageID(rawValue: "01HXXXXXXXXXXXXXXXXXXXXXXX")
    private let sourceID = PageID(rawValue: "01JZZZZZZZZZZZZZZZZZZZZZZZ")

    // MARK: - AC.5 — display-at-render self-heals a stale alias

    @Test func canonicalPageLinkShowsCurrentName() {
        let body = "[[page:\(pageID.rawValue)|Old Title]]"
        let out = WikiLinkMarkdown.linkified(body,
            isResolved: { _, _ in true },
            displayName: { id, kind in kind == .page && id == pageID ? "New Title" : nil })
        #expect(out.contains("New Title"))
        #expect(!out.contains("Old Title"))
    }

    @Test func canonicalSourceLinkShowsCurrentName() {
        let body = "[[source:\(sourceID.rawValue)|Old Paper]]"
        let out = WikiLinkMarkdown.linkified(body,
            isResolved: { _, _ in true },
            displayName: { id, kind in kind == .source && id == sourceID ? "New Paper" : nil })
        #expect(out.contains("New Paper"))
        #expect(!out.contains("Old Paper"))
    }

    @Test func deletedCanonicalTargetFallsBackToAliasThenGhosts() {
        // displayName returns nil (deleted target) → falls back to the stored
        // alias; isResolved returns false → renders as a ghost (missing host).
        let body = "[[page:\(pageID.rawValue)|Stale Alias]]"
        let out = WikiLinkMarkdown.linkified(body,
            isResolved: { _, _ in false },
            displayName: { _, _ in nil })
        #expect(out.contains("Stale Alias"))
        #expect(out.contains("wiki://missing"))
    }

    @Test func noDisplayNameKeepsStoredAlias() {
        // Default displayName (nil) → stored-alias behavior, like non-reader callers.
        let body = "[[page:\(pageID.rawValue)|Stored Alias]]"
        let out = WikiLinkMarkdown.linkified(body, isResolved: { _, _ in true })
        #expect(out.contains("Stored Alias"))
    }

    // MARK: - AC.7 — ?id= URL contract

    @Test func canonicalPageLinkEmitsIdQuery() {
        let body = "[[page:\(pageID.rawValue)|Title]]"
        let out = WikiLinkMarkdown.linkified(body,
            isResolved: { _, _ in true },
            displayName: { id, kind in kind == .page && id == pageID ? "Title" : nil })
        // The URL carries both id= and title=.
        #expect(out.contains("wiki://page?id=\(pageID.rawValue)&title="))
        // id(from:) recovers the ULID.
        let url = URL(string: out.components(separatedBy: "](").last!.dropLast().description)!
        #expect(WikiLinkMarkdown.id(from: url) == pageID)
        #expect(WikiLinkMarkdown.target(from: url) == "Title")
    }

    @Test func canonicalSourceLinkEmitsIdQuery() {
        let body = "[[source:\(sourceID.rawValue)|Paper]]"
        let out = WikiLinkMarkdown.linkified(body,
            isResolved: { _, _ in true },
            displayName: { id, kind in kind == .source && id == sourceID ? "Paper" : nil })
        #expect(out.contains("wiki://source?id=\(sourceID.rawValue)&title="))
    }

    @Test func legacyLinkEmitsTitleOnly() {
        // Non-canonical links keep the legacy ?title=-only URL (no id=).
        let out = WikiLinkMarkdown.linkified("[[Home]]", isResolved: { _, _ in true })
        #expect(out.contains("wiki://page?title="))
        #expect(!out.contains("id="))
    }
}
