import Foundation
import Testing
@testable import WikiFS
@testable import WikiFSCore

/// Tests for `WikiReaderView.linkRoute(for:)` — the pure URL→routing classifier
/// that replaced the buggy `comps.path` extraction. The old code read `""` for
/// the query-encoded `wiki://page?title=…` URLs `WikiLinkMarkdown` emits (no
/// path component), silently no-op'ing every wiki-link click; this suite guards
/// the fix. (The JS application runs inside WKWebView and is covered manually.)
struct WikiReaderRoutingTests {

    @Test func pageLinkRoutesToPage() {
        let url = URL(string: "wiki://page?title=Home")!
        #expect(WikiReaderView.linkRoute(for: url) == .page(title: "Home", fragment: nil))
    }

    @Test func pageLinkPreservesFragment() {
        let url = URL(string: "wiki://page?title=Home#Section")!
        #expect(WikiReaderView.linkRoute(for: url) == .page(title: "Home", fragment: "Section"))
    }

    @Test func sourceLinkRoutesToSource() {
        let url = URL(string: "wiki://source?title=Paper")!
        #expect(WikiReaderView.linkRoute(for: url) == .source(title: "Paper", fragment: nil))
    }

    @Test func sourceLinkWithQuoteFragment() {
        let url = URL(string: "wiki://source?title=Paper#%22a%20quote%22")!
        #expect(WikiReaderView.linkRoute(for: url) == .source(title: "Paper", fragment: "\"a quote\""))
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
        #expect(WikiReaderView.linkRoute(for: url) == .page(title: "Page Name", fragment: nil))
    }

    @Test func httpLinkIsInertToTheClassifier() {
        // External links are handled separately in decidePolicyFor (→ browser),
        // not by the wiki classifier; it returns inert for non-wiki URLs.
        let url = URL(string: "https://example.com")!
        #expect(WikiReaderView.linkRoute(for: url) == .inert)
    }
}
