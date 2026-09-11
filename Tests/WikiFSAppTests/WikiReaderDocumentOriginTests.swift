#if os(macOS)
import Foundation
import Testing
@testable import WikiFS

/// Tests for `WikiReaderDocumentOrigin` — the tokenized reader document URL
/// and the same-document fragment classification. The `?load=<uuid>` staging
/// token must not break footnote/heading anchor links: `href="#target"`
/// resolved against the tokenized base *retains* the `load` query, so
/// `isSameDocumentFragment` accepts exactly that query and rejects unrelated
/// or malformed ones.
@Suite(.serialized, .timeLimit(.minutes(3)))
@MainActor
struct WikiReaderDocumentOriginTests {

    /// AC.9 — a fragment link resolved against the tokenized base is
    /// same-document (pins the anchor-link fix). The resolved URL retains the
    /// base's `load` query, though `URLComponents(url:)` fails to parse that
    /// inconsistent result (see `isOwnOrEmptyQuery`).
    @Test func fragmentLinkResolvesAgainstTokenizedBase() {
        let base = WikiReaderDocumentOrigin.url(loadToken: UUID())
        let fragment = URL(string: "#wiki-fn-n10", relativeTo: base)!

        #expect(fragment.fragment == "wiki-fn-n10")
        #expect(fragment.query != nil)
        #expect(WikiReaderDocumentOrigin.isSameDocumentFragment(fragment) == true)
    }

    /// AC.9 — WHATWG resolution (WebKit's) *retains* the base's `load` query;
    /// a fragment URL carrying exactly the document's valid token is also
    /// same-document.
    @Test func fragmentWithOwnValidLoadQueryAccepted() throws {
        let token = UUID()
        let url = try #require(URL(string:
            "wiki-reader://reader/document.html?load=\(token.uuidString)#wiki-fn-n10"))

        #expect(WikiReaderDocumentOrigin.isSameDocumentFragment(url) == true)
    }

    /// AC.9 — a relative source link (`[Back](../README.md)`) is NOT a
    /// same-document fragment (no fragment component).
    @Test func relativeSourceLinkIsNotFragment() {
        let base = WikiReaderDocumentOrigin.url(loadToken: UUID())
        let link = URL(string: "../README.md", relativeTo: base)!

        #expect(WikiReaderDocumentOrigin.isSameDocumentFragment(link) == false)
    }

    /// AC.9 — a fragment URL with an unrelated query is rejected.
    @Test func fragmentWithUnrelatedQueryRejected() throws {
        let url = try #require(URL(string: "wiki-reader://reader/document.html?src=notes#section"))

        #expect(WikiReaderDocumentOrigin.isSameDocumentFragment(url) == false)
    }

    /// AC.9 — a fragment URL with a malformed `load` value is rejected.
    @Test func fragmentWithMalformedLoadQueryRejected() throws {
        let url = try #require(URL(string: "wiki-reader://reader/document.html?load=not-a-uuid#section"))

        #expect(WikiReaderDocumentOrigin.isSameDocumentFragment(url) == false)
    }

    /// AC.9 — a fragment URL with an extra query item alongside `load` is
    /// rejected (only exactly the document's own token qualifies).
    @Test func fragmentWithExtraQueryItemsRejected() throws {
        let token = UUID()
        let url = try #require(URL(string:
            "wiki-reader://reader/document.html?load=\(token.uuidString)&extra=1#section"))

        #expect(WikiReaderDocumentOrigin.isSameDocumentFragment(url) == false)
    }

    /// The document URL round-trips through `loadToken(from:)`, and the
    /// parser rejects non-document URLs and malformed queries so the scheme
    /// handler misses loudly instead of serving the wrong document.
    @Test func loadTokenRoundTripAndRejection() throws {
        let token = UUID()
        let documentURL = WikiReaderDocumentOrigin.url(loadToken: token)

        #expect(WikiReaderDocumentOrigin.loadToken(from: documentURL) == token)
        #expect(documentURL.path == "/document.html")

        // Not a reader document URL.
        let foreign = try #require(URL(string: "https://example.com/document.html?load=\(token.uuidString)"))
        #expect(WikiReaderDocumentOrigin.loadToken(from: foreign) == nil)

        // Missing query, unrelated query, malformed UUID, duplicate items.
        #expect(WikiReaderDocumentOrigin.loadToken(from: try #require(URL(string: "wiki-reader://reader/document.html"))) == nil)
        #expect(WikiReaderDocumentOrigin.loadToken(from: try #require(URL(string: "wiki-reader://reader/document.html?src=notes"))) == nil)
        #expect(WikiReaderDocumentOrigin.loadToken(from: try #require(URL(string: "wiki-reader://reader/document.html?load=nope"))) == nil)
        #expect(WikiReaderDocumentOrigin.loadToken(from: try #require(URL(string: "wiki-reader://reader/document.html?load=\(token.uuidString)&load=\(token.uuidString)"))) == nil)
    }
}
#endif
