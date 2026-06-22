import Foundation
import Testing
import WikiFSCore

/// Unit tests for `WikiLinkMenuBuilder` — the pure, storage-free half of the
/// right-click link context menu. Covers which actions apply per link URL kind
/// (`actions(for:)`) and the canonical `[[…]]` reconstruction for "Copy as Wiki
/// Link" (`wikiLinkString(for:)`). The view layer in `WikiFS` maps these
/// actions to menu items with real closures.
struct WikiLinkMenuBuilderTests {

  private func url(_ s: String) -> URL {
    guard let url = URL(string: s) else {
      Issue.record("bad test URL: \(s)"); return URL(fileURLWithPath: "/")
    }
    return url
  }

  // MARK: - actions(for:)

  @Test func resolvedPageLinkGetsFindSimilarCopyCopyPath() {
    #expect(
      WikiLinkMenuBuilder.actions(for: url("wiki://page?title=Foo"))
        == [.findSimilar, .copyWikiLink, .copyFilePath])
  }

  @Test func resolvedSourceLinkGetsFindSimilarCopyCopyPath() {
    #expect(
      WikiLinkMenuBuilder.actions(for: url("wiki://source?title=Bar"))
        == [.findSimilar, .copyWikiLink, .copyFilePath])
  }

  @Test func missingLinkGetsSuggestAndCopy() {
    #expect(
      WikiLinkMenuBuilder.actions(for: url("wiki://missing?title=Baz"))
        == [.suggest, .copyWikiLink])
  }

  @Test func samePageAnchorHasNoActions() {
    #expect(WikiLinkMenuBuilder.actions(for: url("wiki://anchor#Section")) == [])
  }

  @Test func externalHttpsGetsBrowserAndCopy() {
    #expect(
      WikiLinkMenuBuilder.actions(for: url("https://github.com/foo/bar"))
        == [.openInBrowser, .copyLink])
  }

  @Test func externalMailtoGetsBrowserAndCopy() {
    #expect(
      WikiLinkMenuBuilder.actions(for: url("mailto:user@example.com"))
        == [.openInBrowser, .copyLink])
  }

  @Test func pageLinkWithFragmentStillResolved() {
    #expect(
      WikiLinkMenuBuilder.actions(for: url("wiki://page?title=Foo#Section"))
        == [.findSimilar, .copyWikiLink, .copyFilePath])
  }

  @Test func encodedTitleIsAccepted() {
    // "Baz Q" percent-encoded in the query value still classifies as a page link.
    #expect(
      WikiLinkMenuBuilder.actions(for: url("wiki://page?title=Baz%20Q"))
        == [.findSimilar, .copyWikiLink, .copyFilePath])
  }

  // MARK: - wikiLinkString(for:)

  @Test func copyPageLink() {
    #expect(WikiLinkMenuBuilder.wikiLinkString(for: url("wiki://page?title=Foo")) == "[[Foo]]")
  }

  @Test func copySourceLink() {
    #expect(
      WikiLinkMenuBuilder.wikiLinkString(for: url("wiki://source?title=Bar"))
        == "[[source:Bar]]")
  }

  @Test func copyMissingLinkAsPageForm() {
    // Missing links can't recover an intended `source:` prefix from the
    // unresolved URL, so they copy as the plain page form.
    #expect(WikiLinkMenuBuilder.wikiLinkString(for: url("wiki://missing?title=Baz")) == "[[Baz]]")
  }

  @Test func copyPageLinkWithFragment() {
    #expect(
      WikiLinkMenuBuilder.wikiLinkString(for: url("wiki://page?title=Foo#Section"))
        == "[[Foo#Section]]")
  }

  @Test func copySourceLinkWithQuoteFragment() {
    // fragment `%22quote%22` decodes to `"quote"`.
    #expect(
      WikiLinkMenuBuilder.wikiLinkString(for: url("wiki://source?title=Bar#%22quote%22"))
        == "[[source:Bar#\"quote\"]]")
  }

  @Test func copyEncodedTitleDecodes() {
    #expect(
      WikiLinkMenuBuilder.wikiLinkString(for: url("wiki://page?title=Baz%20Q"))
        == "[[Baz Q]]")
  }

  @Test func copyExternalLinkReturnsNil() {
    #expect(WikiLinkMenuBuilder.wikiLinkString(for: url("https://github.com")) == nil)
  }

  @Test func copySamePageAnchorReturnsNil() {
    // Anchors carry no `?title=`, so `target(from:)` returns nil.
    #expect(WikiLinkMenuBuilder.wikiLinkString(for: url("wiki://anchor#Section")) == nil)
  }
}
