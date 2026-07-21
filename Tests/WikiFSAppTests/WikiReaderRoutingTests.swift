#if os(macOS)
import Foundation
import Testing
@testable import WikiFS
@testable import WikiFSEngine
@testable import WikiFSCore

/// Tests for `WikiReaderView.linkRoute(for:)` — the pure URL→routing classifier
/// that replaced the buggy `comps.path` extraction. The old code read `""` for
/// the query-encoded `wiki://page?title=…` URLs `WikiLinkMarkdown` emits (no
/// path component), silently no-op'ing every wiki-link click; this suite guards
/// the fix. (The JS application runs inside WKWebView and is covered manually.)
struct WikiReaderRoutingTests {

    @Test func pageLinkRoutesToPage() {
        let url = URL(string: "wiki://page?title=Home")!
        #expect(WikiReaderView.linkRoute(for: url) == .page(title: "Home", id: nil, fragment: nil))
    }

    @Test func pageLinkPreservesFragment() {
        let url = URL(string: "wiki://page?title=Home#Section")!
        #expect(WikiReaderView.linkRoute(for: url) == .page(title: "Home", id: nil, fragment: "Section"))
    }

    @Test func sourceLinkRoutesToSource() {
        let url = URL(string: "wiki://source?title=Paper")!
        #expect(WikiReaderView.linkRoute(for: url) == .source(title: "Paper", id: nil, fragment: nil, pin: nil))
    }

    @Test func sourceLinkWithQuoteFragment() {
        let url = URL(string: "wiki://source?title=Paper#%22a%20quote%22")!
        #expect(WikiReaderView.linkRoute(for: url) == .source(title: "Paper", id: nil, fragment: "\"a quote\"", pin: nil))
    }

    @Test func missingLinkIsInert() {
        // The linkifier emits wiki://missing?title=… for an unresolved target;
        // it renders red (CSS) but a click does nothing.
        let url = URL(string: "wiki://missing?title=Ghost")!
        #expect(WikiReaderView.linkRoute(for: url) == .inert)
    }

    @Test func samePageAnchorScrollsWithinDocument() {
        let url = URL(string: "wiki://anchor#Section")!
        #expect(WikiReaderView.linkRoute(for: url) == .samePageAnchor(fragment: "Section"))
    }

    @Test func percentEncodedTitleIsDecoded() {
        let url = URL(string: "wiki://page?title=Page%20Name")!
        #expect(WikiReaderView.linkRoute(for: url) == .page(title: "Page Name", id: nil, fragment: nil))
    }

    @Test func httpLinkIsInertToTheClassifier() {
        // External links are handled separately in decidePolicyFor (→ browser),
        // not by the wiki classifier; it returns inert for non-wiki URLs.
        let url = URL(string: "https://example.com")!
        #expect(WikiReaderView.linkRoute(for: url) == .inert)
    }

    // MARK: - Phase 5 canonical `?id=` routing (AC.7)

    @Test func canonicalPageLinkCarriesId() {
        // A rendered canonical link carries `?id=<ULID>&title=…`; the route
        // extracts the id so click-time resolution is a direct row fetch.
        let ulid = "01HXXXXXXXXXXXXXXXXXXXXXXX"
        let url = URL(string: "wiki://page?id=\(ulid)&title=Home")!
        let route = WikiReaderView.linkRoute(for: url)
        #expect(route == .page(title: "Home", id: PageID(rawValue: ulid), fragment: nil))
    }

    @Test func canonicalSourceLinkCarriesId() {
        let ulid = "01JZZZZZZZZZZZZZZZZZZZZZZZ"
        let url = URL(string: "wiki://source?id=\(ulid)&title=Paper#Section")!
        let route = WikiReaderView.linkRoute(for: url)
        #expect(route == .source(title: "Paper", id: PageID(rawValue: ulid), fragment: "Section", pin: nil))
    }

    // MARK: - Phase 6 `@vN` pin routing (AC.5)

    @Test func pinnedSourceLinkCarriesPin() {
        // A pinned quote link carries `&pin=<smvID>`; the route extracts it so
        // the destination loads the pinned extraction.
        let sourceID = "01JZZZZZZZZZZZZZZZZZZZZZZZ"
        let pinID = "01JYYYYYYYYYYYYYYYYYYYYYYY"
        let url = URL(string: "wiki://source?id=\(sourceID)&title=Paper&pin=\(pinID)#%22a%20quote%22")!
        let route = WikiReaderView.linkRoute(for: url)
        #expect(route == .source(title: "Paper", id: PageID(rawValue: sourceID),
                                fragment: "\"a quote\"", pin: PageID(rawValue: pinID)))
    }

    @Test func unpinnedSourceLinkHasNilPin() {
        // A non-quote pinned link (or any normal source link) has no `&pin=`.
        let sourceID = "01JZZZZZZZZZZZZZZZZZZZZZZZ"
        let url = URL(string: "wiki://source?id=\(sourceID)&title=Paper")!
        let route = WikiReaderView.linkRoute(for: url)
        if case .source(_, _, _, let pin) = route {
            #expect(pin == nil)
        } else {
            Issue.record("expected .source route")
        }
    }

    @Test func pinRecoveredFromUrl() {
        let pinID = "01JYYYYYYYYYYYYYYYYYYYYYYY"
        let url = URL(string: "wiki://source?id=01JZZZZZZZZZZZZZZZZZZZZZZZ&title=Paper&pin=\(pinID)#quote")!
        #expect(WikiLinkMarkdown.pin(from: url) == PageID(rawValue: pinID))
    }

    @Test func pinAbsentFromPageUrl() {
        // `pin` is source-only; a page URL never carries it.
        let url = URL(string: "wiki://page?id=01JZZZZZZZZZZZZZZZZZZZZZZZ&title=Home&pin=01JYYYYYYYYYYYYYYYYYYYYYYY")!
        #expect(WikiLinkMarkdown.pin(from: url) == nil)
    }

    @Test func idQueryItemRecovered() {
        let ulid = "01HYYYYYYYYYYYYYYYYYYYYYYY"
        let url = URL(string: "wiki://page?id=\(ulid)&title=Foo")!
        #expect(WikiLinkMarkdown.id(from: url) == PageID(rawValue: ulid))
    }

    @Test func legacyTitleOnlyUrlHasNilId() {
        let url = URL(string: "wiki://page?title=Home")!
        #expect(WikiLinkMarkdown.id(from: url) == nil)
    }
}
#endif
